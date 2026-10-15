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
    internal enum Part { All, BusyBatchFirst, BusyForegroundFirst, BusyExportBatchFirst, BusyExportFirst, BusyResumePreview,
        CloseJournalRetry, CloseJournalSync, CloseIdleNoop, CloseThumbnailQueue, CloseRunning, ResizeImportFirst,
        ResizeBatchBeforeImport, ResizeExportFirst, ResizeBatchBeforeExport, LibraryDrop, DialogGeometry, DialogLens }
    internal static readonly IReadOnlyDictionary<string,Part> Parts=new Dictionary<string,Part>(StringComparer.OrdinalIgnoreCase){
        ["all"]=Part.All,["busy-batch-first"]=Part.BusyBatchFirst,["busy-foreground-first"]=Part.BusyForegroundFirst,
        ["busy-export-batch-first"]=Part.BusyExportBatchFirst,["busy-export-first"]=Part.BusyExportFirst,["busy-resume-preview"]=Part.BusyResumePreview,
        ["close-journal-retry"]=Part.CloseJournalRetry,["close-journal-sync"]=Part.CloseJournalSync,["close-idle-noop"]=Part.CloseIdleNoop,
        ["close-thumbnail-queue"]=Part.CloseThumbnailQueue,["close-running"]=Part.CloseRunning,["resize-import-first"]=Part.ResizeImportFirst,
        ["resize-batch-before-import"]=Part.ResizeBatchBeforeImport,["resize-export-first"]=Part.ResizeExportFirst,
        ["resize-batch-before-export"]=Part.ResizeBatchBeforeExport,["library-drop"]=Part.LibraryDrop,
        ["dialog-geometry"]=Part.DialogGeometry,["dialog-lens"]=Part.DialogLens};
    internal static Part ParsePart(string part)=>Parts.TryGetValue(part.Trim(),out var value) ? value :
        throw new ArgumentException("Unknown editor-review part: '"+part+"'. Available: "+string.Join(", ",Parts.Keys));
    internal static void Run(string repo,string raw,Action<bool,string> check,string part="all")
    {
        var selected=ParsePart(part);
        repo=Path.GetFullPath(repo);raw=Path.GetFullPath(raw);
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        var originalHash=SHA256.HashData(File.ReadAllBytes(raw));
        var output=Path.Combine(repo,"build","windows-editor-review",DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(output);
        var inputs=Path.Combine(output,"inputs");Directory.CreateDirectory(inputs);
        var photo=Path.Combine(inputs,"photo"+Path.GetExtension(raw));File.Copy(raw,photo);
        var other=Path.Combine(inputs,"other"+Path.GetExtension(raw));File.Copy(raw,other);
        var app=TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            var executed=0;
            void RunPart(Part candidate,Action action){if(selected==Part.All || selected==candidate){action();executed++;}}
            RunPart(Part.BusyBatchFirst,()=>BusyOrder(false,false));RunPart(Part.BusyForegroundFirst,()=>BusyOrder(true,false));
            RunPart(Part.BusyExportBatchFirst,()=>BusyOrder(false,true));RunPart(Part.BusyExportFirst,()=>BusyOrder(true,true));
            RunPart(Part.BusyResumePreview,()=>BusyOrder(true,false,true));RunPart(Part.CloseJournalRetry,CloseJournalRetry);
            RunPart(Part.CloseJournalSync,()=>{CloseIdleJournalRetry(false);CloseIdleJournalRetry(true);});
            RunPart(Part.CloseIdleNoop,CloseIdleNoop);RunPart(Part.CloseThumbnailQueue,()=>{CloseThumbnailQueue(false);CloseThumbnailQueue(true);CloseSourceThumbnail();});
            RunPart(Part.CloseRunning,CloseRunning);RunPart(Part.ResizeImportFirst,()=>ResizeOrder(true,false));
            RunPart(Part.ResizeBatchBeforeImport,()=>ResizeOrder(false,false));RunPart(Part.ResizeExportFirst,()=>ResizeOrder(true,true));
            RunPart(Part.ResizeBatchBeforeExport,()=>ResizeOrder(false,true));RunPart(Part.LibraryDrop,LibraryDrop);
            RunPart(Part.DialogGeometry,()=>DraftDialog(false));RunPart(Part.DialogLens,()=>DraftDialog(true));
            check(executed==(selected==Part.All ? Parts.Count-1 : 1),"Every selected editor scenario actually executes");
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
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(app.Windows.Count==1,"Manual editor fixture creates exactly one private main window: "+name);return window;
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
            var folder=new LibraryEntry(Path.GetDirectoryName(photo)!,true);
            var loading=folder.Load();InteractionChecks.PumpUntil(()=>loading.IsCompleted);loading.GetAwaiter().GetResult();
            check(folder.Children.Count==2 && folder.Children.All(entry=>entry.Path==photo || entry.Path==other),
                "Close recovery library excludes earlier exported images and contains only its two source photos");
            window.Files.ItemsSource=new[]{folder};folder.IsExpanded=true;window.UpdateLayout();
            var visible=folder.Children.First(entry=>entry.Path==photo);
            InteractionChecks.PumpUntil(()=>visible.Thumbnail!=null);
            check(Get<HashSet<LibraryEntry>>(window,"visibleThumbnails").Contains(visible),"Close recovery starts with an actually visible loaded library thumbnail");
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
                    check(visible.Thumbnail==null,"Deferred owner close releases the visible library thumbnail");
                    held.Release();InteractionChecks.PumpUntil(()=>preflight!.IsCompleted);preflight!.GetAwaiter().GetResult();
                    check(batch.IsVisible && batch.CloseFailed && !batch.Discarded && recovered,"Journal cleanup failure restores the real owner without disposing its engine");
                    check(reported,"Journal cleanup failure reaches the restored main-window error state");
                    InteractionChecks.PumpUntil(()=>visible.Thumbnail!=null);
                    check(Get<HashSet<LibraryEntry>>(window,"visibleThumbnails").Contains(visible),"Failed close reloads visible library thumbnails without scroll or resize");
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
        void CloseIdleNoop()
        {
            var window=Open("close-idle-noop");var journal=Get<BatchJournal>(window,"batchJournal");
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");journal.Save(job);Invoke(window,"ShowBatch",job);
            var batch=Get<BatchExportWindow>(window,"batchWindow");
            var scheduler=Get<object>(window,"scheduler");long Revision()=>(long)scheduler.GetType().GetProperty("Revision")!.GetValue(scheduler)!;
            var revision=Revision();var previous=Get<RenderedImage>(window,"result");
            try
            {
                check(!Get<DispatcherTimer>(window,"previewResize").IsEnabled && Get<int>(window,"previewLongEdge")==Get<int>(window,"requestedPreviewLongEdge"),"No-op close fixture has no pending viewport resize");
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    for(var attempt=0;attempt<3;attempt++)
                    {
                        window.Close();
                        check(batch.CloseFailed && window.IsVisible && window.IsEnabled && !Get<bool>(window,"closing"),"Repeated idle close failure restores the owner");
                        check(Revision()==revision && ReferenceEquals(previous,Get<RenderedImage>(window,"result")) && window.ExportPng.IsEnabled,
                            "Idle close failure with an exact unchanged frame submits no render: "+attempt);
                    }
                }
            }
            finally{window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
        }
        void CloseThumbnailQueue(bool initial)
        {
            var window=Open("thumbnail-queue-"+initial);var journal=Get<BatchJournal>(window,"batchJournal");
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            if(initial)job.Items=[BatchItem.Create(photo),BatchItem.Create(other)];journal.Save(job);
            var step=new SteppedContext(SynchronizationContext.Current!);Task? preflight=null;BatchExportWindow? batch=null;
            try
            {
                if(initial)
                {
                    step.Capture(()=>Invoke(window,"ShowBatch",job));batch=Get<BatchExportWindow>(window,"batchWindow");
                    // Loaded is delivered by WPF; explicitly step its real async body under the held context.
                    InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);
                    InteractionChecks.PumpUntil(()=>Get<System.Collections.IEnumerable>(batch,"rows").Cast<BatchRow>().All(row=>row.Thumbnail!=null));
                    foreach(var row in Get<System.Collections.IEnumerable>(batch,"rows").Cast<BatchRow>())row.SetThumbnail(null);
                    step.Capture(()=>preflight=(Task)Invoke(batch,"LoadThumbnails")!);
                }
                else
                {
                    Invoke(window,"ShowBatch",job);batch=Get<BatchExportWindow>(window,"batchWindow");
                    InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);
                    step.Capture(()=>preflight=batch.AddInputs([photo,other]));
                    step.Next();
                }
                InteractionChecks.PumpUntil(()=>step.Pending);
                var posts=step.Posts;var rows=Get<System.Collections.IEnumerable>(batch!,"rows").Cast<BatchRow>().ToArray();
                check(rows.Length==2,"Thumbnail cancellation fixture has two real RAW rows: "+initial);
                var clock=Stopwatch.StartNew();if(initial)Click(batch!.CloseAction);else window.Close();step.Release();
                InteractionChecks.PumpUntil(()=>preflight!.IsCompleted && (initial ? !batch!.IsVisible : !window.IsVisible));preflight!.GetAwaiter().GetResult();
                check(rows.All(row=>row.Thumbnail==null),"Closing never publishes an in-flight or queued row thumbnail: "+initial);
                check(step.Posts==posts,"Closing starts no later native thumbnail work: "+initial);
                Console.WriteLine($"thumbnail-close initial={initial}; elapsed-ms={clock.Elapsed.TotalMilliseconds:F2}; posts-after-close={step.Posts-posts}");
            }
            finally{step.Release();if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}}
        }
        void CloseSourceThumbnail()
        {
            var window=Open("source-thumbnail-close");var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            Invoke(window,"ShowBatch",job);var batch=Get<BatchExportWindow>(window,"batchWindow");
            var step=new SteppedContext(SynchronizationContext.Current!);
            try
            {
                InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);batch.SourceThumbnail.Source=null;
                step.Capture(()=>batch.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent)));
                InteractionChecks.PumpUntil(()=>step.Pending);Click(batch.CloseAction);step.Next();
                check(!batch.IsVisible && batch.SourceThumbnail.Source==null,"The real Loaded handler never publishes its late source thumbnail after closing");
            }
            finally{step.Release();window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
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
                var ghost=Path.Combine(folders,"not-created","ghost.ARW");
                check(RouteDrop(window.Files,Data(ghost),false).Effects==DragDropEffects.Copy,"Drag hover accepts format without probing the filesystem");
                check(RouteDrop(window.Files,Data(ghost),true).Effects==DragDropEffects.None,"Actual drop still rejects a nonexistent path");
                check(RouteDrop(window.Files,Data(first),false,DragDropEffects.Move).Effects==DragDropEffects.None,"Drag hover rejects move-only transfers");
                var format=new FormatOnlyDrop();var hoverClock=Stopwatch.StartNew();var allocated=GC.GetAllocatedBytesForCurrentThread();
                for(var i=0;i<1000;i++)RouteDrop(window.Files,format,false);
                check(format.PayloadReads==0,"One thousand drag-hover events never request file paths or filesystem metadata");
                Console.WriteLine($"drag-hover-1000-ms={hoverClock.Elapsed.TotalMilliseconds:F2}; managed-bytes={GC.GetAllocatedBytesForCurrentThread()-allocated}");
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
                check(RouteDrop(window.Files,Data(first),false).Effects==DragDropEffects.None,"Busy editor rejects drag hover");
                var busy=RouteDrop(window.Files,Data(folders),true);
                check(busy.Effects==DragDropEffects.None && library.Roots.Count==3,"Busy editor rejects folder drops without changing the library");
                Set(window,"foregroundBusy",false);Invoke(window,"RefreshControls");
                Set(window,"closing",true);var closing=RouteDrop(window.Files,Data(folders),true);Set(window,"closing",false);
                check(closing.Effects==DragDropEffects.None && library.Roots.Count==3,"Closing editor rejects folder drops");
                Set(window,"closing",true);
                check(RouteDrop(window.Files,Data(first),false).Effects==DragDropEffects.None && RouteDrop(window,Data(folders),true).Effects==DragDropEffects.None,
                    "Closing state rejects both tree hover and the root-window drop entry");
                Set(window,"closing",false);
                check(RouteDrop(window,Data(folders),true,DragDropEffects.Move).Effects==DragDropEffects.None && library.Roots.Count==3,"Root-window drops reject move-only transfers");
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
    private sealed class SteppedContext(SynchronizationContext target):SynchronizationContext
    {
        private readonly Queue<(SendOrPostCallback Callback,object? State)> pending=[];
        private bool released;
        public int Posts {get;private set;}
        public bool Pending{get{lock(pending)return pending.Count>0;}}
        public override void Post(SendOrPostCallback callback,object? state)
        {
            lock(pending){Posts++;if(!released){pending.Enqueue((callback,state));return;}}
            target.Post(_=>Capture(()=>callback(state)),null);
        }
        public void Capture(Action action){var previous=Current;SetSynchronizationContext(this);try{action();}finally{SetSynchronizationContext(previous);}}
        public void Next()
        {
            InteractionChecks.PumpUntil(()=>Pending);
            (SendOrPostCallback Callback,object? State) next;lock(pending)next=pending.Dequeue();
            Capture(()=>next.Callback(next.State));
        }
        public void Release(){lock(pending){released=true;while(pending.TryDequeue(out var next)){var item=next;target.Post(_=>Capture(()=>item.Callback(item.State)),null);}}}
    }
    private sealed class FormatOnlyDrop:IDataObject
    {
        public int PayloadReads {get;private set;}
        public object GetData(string format,bool autoConvert){PayloadReads++;throw new InvalidOperationException("Drag hover must not read payload paths");}
        public object GetData(string format)=>GetData(format,false);
        public object GetData(Type format)=>GetData(format.FullName!,false);
        public bool GetDataPresent(string format,bool autoConvert)=>format==DataFormats.FileDrop;
        public bool GetDataPresent(string format)=>GetDataPresent(format,false);
        public bool GetDataPresent(Type format)=>false;
        public string[] GetFormats(bool autoConvert)=>[DataFormats.FileDrop];
        public string[] GetFormats()=>GetFormats(false);
        public void SetData(string format,object data,bool autoConvert)=>throw new NotSupportedException();
        public void SetData(string format,object data)=>throw new NotSupportedException();
        public void SetData(Type format,object data)=>throw new NotSupportedException();
        public void SetData(object data)=>throw new NotSupportedException();
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
