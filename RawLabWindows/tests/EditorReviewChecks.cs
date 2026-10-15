using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class EditorReviewChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string repo,string raw,Action<bool,string> check,string part="all")
    {
        repo=Path.GetFullPath(repo);raw=Path.GetFullPath(raw);
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        var originalHash=SHA256.HashData(File.ReadAllBytes(raw));
        var output=Path.Combine(repo,"build","windows-editor-review",DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(output);
        var photo=Path.Combine(output,"photo"+Path.GetExtension(raw));File.Copy(raw,photo);
        var other=Path.Combine(output,"other"+Path.GetExtension(raw));File.Copy(raw,other);
        var app=new App();app.InitializeComponent();app.ShutdownMode=ShutdownMode.OnExplicitShutdown;
        foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            if(part is "all" or "busy-batch-first")BusyOrder(false,false);
            if(part is "all" or "busy-foreground-first")BusyOrder(true,false);
            if(part is "all" or "busy-export-batch-first")BusyOrder(false,true);
            if(part is "all" or "busy-export-first")BusyOrder(true,true);
            if(part is "all" or "busy-resume-preview")BusyOrder(true,false,true);
            if(part is "all" or "close-journal-retry")CloseJournalRetry();
            if(part is "all" or "close-journal-sync"){CloseIdleJournalRetry(false);CloseIdleJournalRetry(true);}
            if(part is "all" or "close-running")CloseRunning();
            if(part is "all" or "resize-import-first")ResizeOrder(true,false);
            if(part is "all" or "resize-batch-before-import")ResizeOrder(false,false);
            if(part is "all" or "resize-export-first")ResizeOrder(true,true);
            if(part is "all" or "resize-batch-before-export")ResizeOrder(false,true);
            if(part is "all" or "library-drop")LibraryDrop();
            if(part is "all" or "dialog-geometry")DraftDialog(false);
            if(part is "all" or "dialog-lens")DraftDialog(true);
            check(new[]{raw,photo,other}.All(path=>originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(path)))),
                "Editor review regressions preserve the external RAW and both source copies");
        }
        finally{app.Shutdown();}

        MainWindow Open(string name)
        {
            var window=new MainWindow();
            TestWindowState.Isolate(window,Path.Combine(output,name));
            Set(window,"editStore",new EditStore(Path.Combine(output,name,"edits")));
            Set(window,"batchJournal",new BatchJournal(Path.Combine(output,name,"batch")));
            window.GpuMode.SelectedIndex=1;window.Show();
            InteractionChecks.PumpUntil(()=>window.IsLoaded);window.OpenFile(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);return window;
        }
        void BusyOrder(bool foregroundFirst,bool export,bool resumePreview=false)
        {
            var name="busy-"+export+"-"+foregroundFirst+"-"+resumePreview;
            var window=Open(name);var destination=Path.Combine(output,name+".png");
            Set(window,"exportLongEdge",128);
            var held=new HeldContext(SynchronizationContext.Current!);
            using var releaseBatch=new ManualResetEventSlim();
            Task? foreground=null,preflight=null;
            try
            {
                var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
                Invoke(window,"ShowBatch",job);
                var batch=Get<BatchExportWindow>(window,"batchWindow");
                check(batch.Owner==window,"Busy regression uses the real MainWindow batch owner wiring");
                var look=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");
                held.Capture(()=>foreground=export ? window.ExportPhoto(ExportFormat.Png,destination) : window.ImportLookFiles([look]));
                InteractionChecks.PumpUntil(()=>held.Pending);
                check(!foreground!.IsCompleted && (!export || !File.Exists(destination)),"Foreground completion is held before publication: "+name);
                preflight=batch.AddInputs(foregroundFirst ? BlockedInputs() : [photo]);
                if(foregroundFirst)
                {
                    held.Release();InteractionChecks.PumpUntil(()=>foreground!.IsCompleted);
                    check(!preflight.IsCompleted && batch.Busy,"Foreground completion leaves batch preflight active");
                }
                else
                {
                    InteractionChecks.PumpUntil(()=>preflight.IsCompleted);preflight.GetAwaiter().GetResult();
                    check(!foreground!.IsCompleted && !batch.Busy,"Batch completion leaves foreground work active: "+name);
                }
                check(!window.AdjustmentPanel.IsEnabled && !window.ExportPng.IsEnabled && !window.BatchExportMenu.IsEnabled &&
                    window.BusyIndicator.Visibility==Visibility.Visible,"The remaining busy owner keeps editing and export gated: "+name);
                window.OpenFile(other);
                check(Get<string>(window,"file")==photo,"The remaining busy owner blocks photo switching: "+name);
                if(resumePreview)
                {
                    releaseBatch.Set();InteractionChecks.PumpUntil(()=>preflight.IsCompleted && window.ExportPng.IsEnabled);
                    var actual=Get<RenderedImage>(window,"result");
                    using var oracle=new RenderEngine(0);
                    var expected=oracle.Render(photo,Get<Adjustments>(window,"settings").Clone(),look,
                        Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight),clipping:false,viewportPreview:true)!;
                    check(Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),
                        "The last batch owner resumes the imported look preview before export is enabled");
                    return;
                }
                window.Close();
                check(window.IsVisible && Get<object?>(window,"engine")!=null && !Get<bool>(window,"closeFinished"),
                    "Close waits for the remaining busy owner without releasing the render engine: "+name);
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>foreground!.IsCompleted && preflight.IsCompleted && !window.IsVisible);
                foreground!.GetAwaiter().GetResult();preflight.GetAwaiter().GetResult();
                check(Get<bool>(window,"closeFinished"),"The final busy owner releases deferred close: "+name);
                if(export)check(File.Exists(destination) && File.ReadAllBytes(destination)[24]==16 && Get<string>(window,"lastExportedPath")==destination &&
                    !Directory.EnumerateFiles(output,".rawlab-*").Any(),"Deferred close publishes the actual sixteen-bit single export without staging files: "+name);
                else check(((Task<IReadOnlyList<string>>)foreground).Result.Count==0,"Foreground import completes without validation errors: "+name);
            }
            finally
            {
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>(foreground?.IsCompleted ?? true) && (preflight?.IsCompleted ?? true));
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
            IEnumerable<string> BlockedInputs(){releaseBatch.Wait();yield return photo;}
        }
        void CloseJournalRetry()
        {
            var window=Open("close-journal-retry");var held=new HeldContext(SynchronizationContext.Current!);
            var journal=Get<BatchJournal>(window,"batchJournal");var engine=Get<object>(window,"engine");
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");journal.Save(job);
            using var releasePreflight=new ManualResetEventSlim();
            Task? preflight=null;var recovered=false;var reported=false;
            try
            {
                Invoke(window,"ShowBatch",job);var batch=Get<BatchExportWindow>(window,"batchWindow");
                batch.BusyChanged+=active=>{
                    if(active || !batch.CloseFailed)return;
                    recovered=window.IsVisible && window.IsEnabled && !Get<bool>(window,"closing") &&
                        !Get<bool>(window,"closeFinished") && ReferenceEquals(engine,Get<object?>(window,"engine"));
                    reported=batch.Job.Error!=null && window.Status.Text==batch.Job.Error;
                };
                held.Capture(()=>preflight=batch.AddInputs(BlockedInputs()));releasePreflight.Set();InteractionChecks.PumpUntil(()=>held.Pending);
                var previousEdge=Get<int>(window,"previewLongEdge");window.ResultCanvas.Viewport!.Magnify(.5);var edge=window.ResultCanvas.PreviewLongEdge;
                check(edge>0 && edge!=previousEdge && Get<int>(window,"requestedPreviewLongEdge")==edge && !window.ExportPng.IsEnabled,
                    "Journal retry fixture retains a genuinely changed viewport request while preflight is busy");
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    window.Close();
                    check(window.IsVisible && !window.IsEnabled && Get<bool>(window,"closing"),"Owner waits for preflight before attempting journal cleanup");
                    held.Release();InteractionChecks.PumpUntil(()=>preflight!.IsCompleted);preflight!.GetAwaiter().GetResult();
                    check(batch.IsVisible && batch.CloseFailed && !batch.Discarded && recovered,"Journal cleanup failure restores the real owner without disposing its engine");
                    check(reported,"Journal cleanup failure reaches the restored main-window error state");
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                    check(window.AdjustmentPanel.IsEnabled && !Get<bool>(window,"closing"),"Failed owner close resumes an exact preview and editing");
                    var actual=Get<RenderedImage>(window,"result");using var oracle=new RenderEngine(0);
                    var expected=oracle.Render(photo,Get<Adjustments>(window,"settings").Clone(),Get<string?>(window,"lut"),edge,clipping:false,viewportPreview:true)!;
                    check(Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge && Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),
                        "Failed owner close restores the deferred viewport size and exact preview pixels");
                    var before=Get<Adjustments>(window,"settings")[Parameter.Exposure];window.ValueSlider.Value+=.025;
                    check(Get<Adjustments>(window,"settings")[Parameter.Exposure]>before,"Restored owner accepts an actual adjustment after cleanup failure");
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                }
                window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(Get<string>(window,"file")==other,"Restored owner permits photo switching after cleanup failure");
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                check(batch.Discarded && journal.Load()==null && Get<bool>(window,"closeFinished") && Get<object?>(window,"engine")==null,
                    "Retry closes the recovered owner and discards the journal after its lock is released");
            }
            finally
            {
                releasePreflight.Set();held.Release();InteractionChecks.PumpUntil(()=>preflight?.IsCompleted ?? true);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
            IEnumerable<string> BlockedInputs(){releasePreflight.Wait();yield return photo;}
        }
        void CloseIdleJournalRetry(bool foreground)
        {
            var window=Open("close-idle-"+foreground);var journal=Get<BatchJournal>(window,"batchJournal");
            var engine=Get<object>(window,"engine");var held=new HeldContext(SynchronizationContext.Current!);Task? import=null;
            var adjustment=Get<Adjustments>(window,"settings");adjustment.Denoise=DenoiseSettings.Clean;Invoke(window,"Schedule",false);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var job=BatchJob.Create(photo,adjustment.Capture(),null,"Neutral");journal.Save(job);Invoke(window,"ShowBatch",job);
            var batch=Get<BatchExportWindow>(window,"batchWindow");var previous=Get<int>(window,"previewLongEdge");
            var look=Get<string?>(window,"lut");var timer=Get<DispatcherTimer>(window,"previewResize");
            try
            {
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    window.ResultCanvas.Viewport!.Magnify(.5);var edge=window.ResultCanvas.PreviewLongEdge;
                    check(timer.IsEnabled && edge!=previous && !window.ExportPng.IsEnabled,"Idle-close fixture has a real pending denoise resize: "+foreground);
                    if(foreground){look=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");held.Capture(()=>import=window.ImportLookFiles([look]));}
                    window.Close();
                    check(window.IsVisible && window.IsEnabled && !Get<bool>(window,"closing") && !Get<bool>(window,"closeFinished") &&
                        batch.IsVisible && batch.CloseFailed && !batch.Busy && !batch.Discarded && ReferenceEquals(engine,Get<object>(window,"engine")),
                        "Synchronous journal failure cancels owner close without disposing its engine: "+foreground);
                    var scheduler=Get<object>(window,"scheduler");var rendering=(bool)scheduler.GetType().GetProperty("Busy")!.GetValue(scheduler)!;
                    if(foreground)check(!timer.IsEnabled && !rendering && Get<int>(window,"requestedPreviewLongEdge")==edge,
                        "Synchronous close failure retains the pending size without rendering during foreground work");
                    else check(timer.IsEnabled || rendering,"Synchronous close failure resubmits the pending resize without another input");
                    check(window.Status.Text==batch.Job.Error,"Synchronous journal failure reaches the main-window error state: "+foreground);
                    if(foreground)
                    {
                        check(!window.AdjustmentPanel.IsEnabled && !window.ExportPng.IsEnabled && window.BusyIndicator.Visibility==Visibility.Visible,
                            "Cancelled owner close retains the foreground busy gate");
                        held.Release();InteractionChecks.PumpUntil(()=>import!.IsCompleted);import!.GetAwaiter().GetResult();
                    }
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                    var actual=Get<RenderedImage>(window,"result");using var oracle=new RenderEngine(0);
                    var expected=oracle.Render(photo,adjustment.Clone(),look,edge,clipping:false,viewportPreview:true)!;
                    check(Get<int>(window,"previewLongEdge")==edge && !timer.IsEnabled && Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge &&
                        Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),"Synchronous close failure resumes exact resized pixels: "+foreground);
                    check(window.AdjustmentPanel.IsEnabled && window.BusyIndicator.Visibility==Visibility.Collapsed && !batch.Job.Started,
                        "Synchronous close failure restores editing and clears stale busy state: "+foreground);
                }
                window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(Get<string>(window,"file")==other,"Synchronous close recovery permits photo switching: "+foreground);
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                check(batch.Discarded && journal.Load()==null && Get<bool>(window,"closeFinished") && Get<object?>(window,"engine")==null,
                    "Synchronous close retries successfully after releasing the journal: "+foreground);
            }
            finally
            {
                held.Release();InteractionChecks.PumpUntil(()=>import?.IsCompleted ?? true);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
        }
        void CloseRunning()
        {
            var window=Open("close-running");var held=new HeldContext(SynchronizationContext.Current!);
            var journal=Get<BatchJournal>(window,"batchJournal");var engine=Get<object>(window,"engine");
            var destination=Path.Combine(output,"running-output");Directory.CreateDirectory(destination);
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            job.Format=ExportFormat.Png;job.LongEdge=128;job.OutputDirectory=destination;
            job.Items=[BatchItem.Create(photo) with{Selected=true},BatchItem.Create(other) with{Selected=true}];journal.Save(job);
            Invoke(window,"ShowBatch",job);var batch=Get<BatchExportWindow>(window,"batchWindow");
            using var progress=new BatchProgressGate(window.Dispatcher);
            try
            {
                held.Capture(()=>Click(batch.PrimaryAction));InteractionChecks.PumpUntil(()=>progress.Entered);
                var running=AtomicJson.Read<BatchJob>(Path.Combine(journal.DirectoryPath,"job.json"));
                check(batch.Running && running.Items[0].Status==BatchStatus.Running && running.Items[1].Status==BatchStatus.Waiting,
                    "Running-close fixture pauses the real worker after its first journaled item starts");
                window.Close();
                check(window.IsVisible && !window.IsEnabled && Get<bool>(window,"closing") && !Get<bool>(window,"closeFinished") &&
                    ReferenceEquals(engine,Get<object?>(window,"engine")),"Owner close waits for the running batch and retains the render engine");
                check(Get<CancellationTokenSource>(batch,"cancellation").IsCancellationRequested,"Owner close requests stop-after-current-item on the real batch");
                progress.Release();InteractionChecks.PumpUntil(()=>held.Pending);
                var completed=journal.Load()!;var first=completed.Items[0].Output;
                check(completed.Cancelled && completed.SucceededCount==1 && completed.Items[1].Status==BatchStatus.Waiting &&
                    Directory.GetFiles(destination,"*.png").Length==1 && first!=null && File.ReadAllBytes(first)[24]==16,
                    "Running close publishes the current native PNG and leaves the next item unprocessed");
                check(window.IsVisible && batch.Running && ReferenceEquals(engine,Get<object?>(window,"engine")),
                    "Owner remains alive until the batch completion callback is released");
                held.Release();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                var saved=journal.Load()!;
                check(saved.Started && saved.Cancelled && saved.SucceededCount==1 && saved.RemainingCount==1 &&
                    saved.Items[0].Output==first && File.Exists(first) && !Directory.GetFiles(destination,".rawlab-*").Any(),
                    "Deferred running close preserves the completed output and recoverable journal without staging files");
                check(Get<bool>(window,"closeFinished") && Get<object?>(window,"engine")==null && !batch.IsVisible,
                    "Running batch completion finishes owner close and releases the engine exactly at the end");
            }
            finally
            {
                progress.Release();held.Release();InteractionChecks.PumpUntil(()=>!batch.Running);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
        }
        void ResizeOrder(bool foregroundFirst,bool export)
        {
            var name="resize-"+export+"-"+foregroundFirst;var window=Open(name);
            var adjustment=Get<Adjustments>(window,"settings");adjustment.Denoise=DenoiseSettings.Clean;
            EditorShellChecks.ArrangeLayout(window,new Size(1440,920));Invoke(window,"Schedule",false);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var previousEdge=Get<int>(window,"previewLongEdge");var previousResult=Get<RenderedImage>(window,"result");
            var held=new HeldContext(SynchronizationContext.Current!);using var releaseBatch=new ManualResetEventSlim();
            var timer=Get<DispatcherTimer>(window,"previewResize");var pendingBeforeImport=foregroundFirst && !export;
            var look=export ? Get<string?>(window,"lut") : Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");
            Task? foreground=null,preflight=null;
            try
            {
                Invoke(window,"ShowBatch",BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral"));
                var batch=Get<BatchExportWindow>(window,"batchWindow");
                if(pendingBeforeImport)
                {
                    EditorShellChecks.ArrangeLayout(window,new Size(1000,680));
                    check(timer.IsEnabled && !window.ExportPng.IsEnabled,"Denoise viewport resize starts a real pending debounce before import");
                }
                held.Capture(()=>foreground=export ? window.ExportPhoto(ExportFormat.Png,Path.Combine(output,name+".png")) : window.ImportLookFiles([look!]));
                preflight=batch.AddInputs(foregroundFirst ? BlockedInputs() : [photo]);
                if(!pendingBeforeImport)EditorShellChecks.ArrangeLayout(window,new Size(1000,680));
                var edge=window.ResultCanvas.PreviewLongEdge;
                check(edge>0 && edge!=previousEdge && Get<int>(window,"requestedPreviewLongEdge")==edge && !window.ExportPng.IsEnabled,
                    "Real viewport resize is retained while foreground and batch are busy: "+name);
                if(pendingBeforeImport)
                {
                    InteractionChecks.PumpUntil(()=>!timer.IsEnabled);
                    check(ReferenceEquals(previousResult,Get<RenderedImage>(window,"result")),"Busy owners prevent a pending debounce from publishing a premature preview");
                }
                if(foregroundFirst){InteractionChecks.PumpUntil(()=>held.Pending);held.Release();InteractionChecks.PumpUntil(()=>foreground!.IsCompleted);}
                else{InteractionChecks.PumpUntil(()=>preflight.IsCompleted);preflight.GetAwaiter().GetResult();}
                check(!window.ExportPng.IsEnabled && !window.AdjustmentPanel.IsEnabled,"First owner completion cannot unlock the pending resized preview: "+name);
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>foreground!.IsCompleted && preflight.IsCompleted && window.ExportPng.IsEnabled);
                foreground!.GetAwaiter().GetResult();preflight.GetAwaiter().GetResult();
                var actual=Get<RenderedImage>(window,"result");
                check(Get<int>(window,"previewLongEdge")==edge && !timer.IsEnabled && Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge,
                    "Last owner completion restores the requested viewport pixel dimensions: "+name);
                using var oracle=new RenderEngine(0);
                var expected=oracle.Render(photo,Get<Adjustments>(window,"settings").Clone(),look,edge,clipping:false,viewportPreview:true)!;
                check(Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),"Resized exact preview matches an independent CPU render and current look: "+name);
                Console.WriteLine($"viewport-resume {name}: old={previousEdge}, requested={edge}, actual={actual.Image.PixelWidth}x{actual.Image.PixelHeight}");
            }
            finally
            {
                held.Release();releaseBatch.Set();InteractionChecks.PumpUntil(()=>(foreground?.IsCompleted ?? true) && (preflight?.IsCompleted ?? true));
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
            IEnumerable<string> BlockedInputs(){releaseBatch.Wait();yield return photo;}
        }
        void LibraryDrop()
        {
            var window=Open("library-drop");var folders=Path.Combine(output,"dropped folders");
            var first=Path.Combine(folders,"first");var second=Path.Combine(folders,"second");var third=Path.Combine(folders,"third");
            foreach(var path in new[]{first,second,third})Directory.CreateDirectory(path);
            IDataObject Data(params string[] paths)=>new DataObject(DataFormats.FileDrop,paths);
            try
            {
                var over=RouteDrop(window.Files,Data(first,second),false);
                check(over.Handled && over.Effects==DragDropEffects.Copy,"File-tree folder drag explicitly advertises copy, never move");
                var library=Get<Library>(window,"library");var storage=Path.Combine(output,"library-folders.json");
                Set(library,"settingsPath",storage);library.Roots.Clear();
                var dropped=RouteDrop(window.Files,Data(first,second),true);
                check(dropped.Handled && dropped.Effects==DragDropEffects.Copy && library.Roots.Select(root=>root.Path).SequenceEqual(new[]{first,second}),
                    "Dropping multiple folders on the empty file tree adds directory roots");
                var saved=System.Text.Json.JsonSerializer.Deserialize<string[]>(File.ReadAllText(storage))!;
                check(saved.SequenceEqual(new[]{first,second}) && library.Roots.All(root=>root.IsFolder),"Dropped folder roots persist through the existing library store");
                RouteDrop(window.Files,Data(first+Path.DirectorySeparatorChar,second.ToUpperInvariant()),true);
                check(library.Roots.Count==2,"Repeated folder drops ignore case and trailing separators");
                InteractionChecks.PumpUntil(()=>window.Files.ItemContainerGenerator.ContainerFromItem(library.Roots[0]) is TreeViewItem);
                var row=(TreeViewItem)window.Files.ItemContainerGenerator.ContainerFromItem(library.Roots[0]);
                RouteDrop(row,Data(third,other),true);
                check(library.Roots.Count==3 && library.Roots[2].Path==third && Get<string>(window,"file")==photo,
                    "Dropping folders on an existing row adds roots without opening a mixed-in RAW");
                var invalid=RouteDrop(window.Files,new DataObject(DataFormats.UnicodeText,"not a folder"),false);
                check(invalid.Handled && invalid.Effects==DragDropEffects.None,"File tree rejects unsupported drag data");
                var move=RouteDrop(window.Files,Data(folders),true,DragDropEffects.Move);
                check(move.Effects==DragDropEffects.None && library.Roots.Count==3,"File-tree drops never accept a move-only transfer");
                Set(window,"foregroundBusy",true);Invoke(window,"RefreshControls");
                var busy=RouteDrop(window.Files,Data(folders),true);
                check(busy.Effects==DragDropEffects.None && library.Roots.Count==3,"Busy editor rejects folder drops without changing the library");
                Set(window,"foregroundBusy",false);Invoke(window,"RefreshControls");
                Set(window,"closing",true);var closing=RouteDrop(window.Files,Data(folders),true);Set(window,"closing",false);
                check(closing.Effects==DragDropEffects.None && library.Roots.Count==3,"Closing editor rejects folder drops");
                RouteDrop(window.Files,Data(other),true);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(Get<string>(window,"file")==other && library.Roots.Count==3,"A RAW-only drop on the tree retains the existing photo-open behavior");
                check(new[]{first,second,third}.All(Directory.Exists) && File.Exists(other),"Folder drops retain the original folders and RAW files");
            }
            finally
            {
                Set(window,"foregroundBusy",false);Set(window,"closing",false);window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
        }
        void DraftDialog(bool lens)
        {
            var window=Open("dialog-"+lens);var held=new HeldContext(SynchronizationContext.Current!);
            DispatcherTimer? timer=null;string? failure=null;var sawDisabled=false;var applied=false;
            try
            {
                Click(lens ? window.LensCategory : window.GeometryCategory);
                InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
                held.Capture(()=>{
                    if(lens)((CheckBox)window.LensEditor.FindName("Distortion")).IsChecked=true;
                    else ((Slider)window.GeometryEditor.FindName("StraightenSlider")).Value=.55;
                });
                check(!window.ApplyDraftButton.IsEnabled,"Draft change starts an exact preview before leaving: "+lens);
                var watch=Stopwatch.StartNew();
                timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(20)};
                timer.Tick+=(_,_)=>{
                    var dialog=app.Windows.OfType<Window>().SingleOrDefault(candidate=>candidate.Title==Loc.Text("未应用的调整"));
                    if(dialog==null)return;
                    var buttons=((WrapPanel)((StackPanel)dialog.Content).Children[1]).Children.OfType<Button>().ToArray();
                    var apply=buttons.Single(button=>Equals(button.Content,Loc.Text("应用并离开")));
                    if(!sawDisabled){sawDisabled=!apply.IsEnabled;held.Release();}
                    if(window.ApplyDraftButton.IsEnabled)
                    {
                        timer.Stop();applied=apply.IsEnabled;
                        if(!applied)failure="Leave-dialog Apply stays disabled after the exact preview completes: "+lens;
                        Click(applied ? apply : buttons.Single(button=>Equals(button.Content,Loc.Text("继续编辑"))));
                    }
                    else if(watch.Elapsed>TimeSpan.FromMinutes(3)){timer.Stop();failure="Draft preview did not complete inside the leave dialog";dialog.Close();}
                };
                timer.Start();var resolved=(bool)Invoke(window,"ResolveTransformDraft")!;timer.Stop();
                check(sawDisabled && applied && resolved && failure==null,failure ?? "Leave-dialog Apply follows the completed exact preview: "+lens);
                check(!Get<TransformDraft>(window,"transform").Active,"Apply-and-leave commits and ends the real draft: "+lens);
                InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            }
            finally
            {
                timer?.Stop();held.Release();
                if(Get<TransformDraft>(window,"transform").Active)Invoke(window,"CancelTransformDraft");
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
        }
    }
    // Pause the real batch worker at its first progress post, before rendering that item.
    private sealed class BatchProgressGate:IDisposable
    {
        private readonly Dispatcher dispatcher;
        private readonly ManualResetEventSlim entered=new(),release=new();
        private int claimed;
        public bool Entered=>entered.IsSet;
        public BatchProgressGate(Dispatcher dispatcher){this.dispatcher=dispatcher;dispatcher.Hooks.OperationPosted+=Posted;}
        private void Posted(object? sender,DispatcherHookEventArgs args)
        {
            if(dispatcher.CheckAccess() || !new StackTrace().GetFrames().Any(frame=>frame.GetMethod()?.DeclaringType==typeof(BatchRunner)) ||
                Interlocked.Exchange(ref claimed,1)!=0)return;
            entered.Set();if(!release.Wait(TimeSpan.FromMinutes(2)))throw new TimeoutException("Batch progress gate was not released");
        }
        public void Release()=>release.Set();
        public void Dispose(){dispatcher.Hooks.OperationPosted-=Posted;Release();entered.Dispose();release.Dispose();}
    }
    // Hold only dispatcher completion, not rendering, to make both completion orders deterministic.
    private sealed class HeldContext(SynchronizationContext target):SynchronizationContext
    {
        private readonly List<(SendOrPostCallback Callback,object? State)> pending=[];
        private bool released;
        public bool Pending{get{lock(pending)return pending.Count>0;}}
        public override void Post(SendOrPostCallback callback,object? state)
        {
            lock(pending){if(!released){pending.Add((callback,state));return;}}
            target.Post(callback,state);
        }
        public void Capture(Action action)
        {
            var previous=Current;SetSynchronizationContext(this);
            try{action();}finally{SetSynchronizationContext(previous);}
        }
        public void Release()
        {
            lock(pending){released=true;foreach(var (callback,state) in pending)target.Post(callback,state);pending.Clear();}
        }
    }
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static void Set(object owner,string name,object value)=>owner.GetType().GetField(name,Private)!.SetValue(owner,value);
    private static object? Invoke(object owner,string name,params object[] args)=>owner.GetType().GetMethod(name,Private)!.Invoke(owner,args);
    private static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static DragEventArgs RouteDrop(UIElement target,IDataObject data,bool drop,DragDropEffects allowed=DragDropEffects.Copy|DragDropEffects.Move)
    {
        var args=(DragEventArgs)Activator.CreateInstance(typeof(DragEventArgs),BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic,
            null,[data,DragDropKeyStates.None,allowed,target,new Point()],null)!;
        args.RoutedEvent=drop ? UIElement.PreviewDropEvent : UIElement.PreviewDragOverEvent;target.RaiseEvent(args);
        if(!args.Handled){args.RoutedEvent=drop ? UIElement.DropEvent : UIElement.DragOverEvent;target.RaiseEvent(args);}
        return args;
    }
    private static byte[] Pixels(BitmapSource image)
    {
        var stride=image.PixelWidth*4;var bytes=new byte[stride*image.PixelHeight];image.CopyPixels(bytes,stride,0);return bytes;
    }
}
