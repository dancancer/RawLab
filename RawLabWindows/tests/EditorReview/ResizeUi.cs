using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static partial class EditorReviewChecks
{
    private sealed partial class ReviewRun
    {
        void ResizeOrder(bool foregroundFirst,bool export)
        {
            var name="resize-"+export+"-"+foregroundFirst;var window=Open(name);
            var adjustment=window.Settings;adjustment.Denoise=DenoiseSettings.Clean;
            EditorShellChecks.ArrangeLayout(window,new Size(1440,920));window.ScheduleForTests(false,false);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var previousEdge=window.PreviewLongEdge;var previousResult=window.CurrentResult!;
            var held=new HeldContext(SynchronizationContext.Current!);using var releaseBatch=new ManualResetEventSlim();
            var timer=window.PreviewResizeTimer;var pendingBeforeImport=foregroundFirst && !export;
            var look=export ? window.CurrentLut : Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");
            Task? foreground=null,preflight=null;
            try
            {
                window.ShowBatchForTests(BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral"),false);
                var batch=window.BatchWindowInstance!;
                if(pendingBeforeImport)
                {
                    EditorShellChecks.ArrangeLayout(window,new Size(1000,680));
                    check(timer.IsEnabled && !window.ExportPng.IsEnabled,"Denoise viewport resize starts a real pending debounce before import");
                }
                held.Capture(()=>foreground=export ? window.ExportPhoto(ExportFormat.Png,Path.Combine(output,name+".png")) : window.ImportLookFiles([look!]));
                preflight=batch.AddInputs(foregroundFirst ? BlockedInputs() : [photo]);
                if(!pendingBeforeImport)EditorShellChecks.ArrangeLayout(window,new Size(1000,680));
                var edge=window.ResultCanvas.PreviewLongEdge;
                check(edge>0 && edge!=previousEdge && window.RequestedPreviewLongEdge==edge && !window.ExportPng.IsEnabled,
                    "Real viewport resize is retained while foreground and batch are busy: "+name);
                if(pendingBeforeImport)
                {
                    InteractionChecks.PumpUntil(()=>!timer.IsEnabled);
                    check(ReferenceEquals(previousResult,window.CurrentResult),"Busy owners prevent a pending debounce from publishing a premature preview");
                }
                if(foregroundFirst){InteractionChecks.PumpUntil(()=>held.Pending);held.Release();InteractionChecks.PumpUntil(()=>foreground!.IsCompleted);}
                else{InteractionChecks.PumpUntil(()=>preflight.IsCompleted);preflight.GetAwaiter().GetResult();}
                check(!window.ExportPng.IsEnabled && !window.AdjustmentPanel.IsEnabled,"First owner completion cannot unlock the pending resized preview: "+name);
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>foreground!.IsCompleted && preflight.IsCompleted && window.ExportPng.IsEnabled);
                foreground!.GetAwaiter().GetResult();preflight.GetAwaiter().GetResult();
                var actual=window.CurrentResult!;
                check(window.PreviewLongEdge==edge && !timer.IsEnabled && Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge,
                    "Last owner completion restores the requested viewport pixel dimensions: "+name);
                using var oracle=new RenderEngine(0,appPaths:window.Paths);
                var expected=oracle.Render(photo,window.Settings.Clone(),look,edge,clipping:false,viewportPreview:true)!;
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
            const DragDropEffects DefaultAllowed=DragDropEffects.Copy|DragDropEffects.Move;
            try
            {
                var over=window.HandleLibraryDragOver(Data(first,second),DefaultAllowed);
                check(over==DragDropEffects.Copy,"File-tree folder drag explicitly advertises copy, never move");
                var ghost=Path.Combine(folders,"not-created","ghost.ARW");
                check(window.HandleLibraryDragOver(Data(ghost),DefaultAllowed)==DragDropEffects.Copy,"Drag hover accepts format without probing the filesystem");
                check(window.HandleLibraryDrop(Data(ghost),DefaultAllowed)==DragDropEffects.None,"Actual drop still rejects a nonexistent path");
                check(window.HandleLibraryDragOver(Data(first),DragDropEffects.Move)==DragDropEffects.None,"Drag hover rejects move-only transfers");
                var format=new FormatOnlyDrop();var hoverClock=Stopwatch.StartNew();var allocated=GC.GetAllocatedBytesForCurrentThread();
                for(var i=0;i<1000;i++)window.HandleLibraryDragOver(format,DefaultAllowed);
                check(format.PayloadReads==0,"One thousand drag-hover events never request file paths or filesystem metadata");
                Console.WriteLine($"drag-hover-1000-ms={hoverClock.Elapsed.TotalMilliseconds:F2}; managed-bytes={GC.GetAllocatedBytesForCurrentThread()-allocated}");
                var library=window.LibraryInstance;var storage=Path.Combine(output,"library-folders.json");
                library.SettingsPath=storage;library.Roots.Clear();
                var dropped=window.HandleLibraryDrop(Data(first,second),DefaultAllowed);
                check(dropped==DragDropEffects.Copy && library.Roots.Select(root=>root.Path).SequenceEqual(new[]{first,second}),
                    "Dropping multiple folders on the empty file tree adds directory roots");
                var saved=System.Text.Json.JsonSerializer.Deserialize<string[]>(File.ReadAllText(storage))!;
                check(saved.SequenceEqual(new[]{first,second}) && library.Roots.All(root=>root.IsFolder),"Dropped folder roots persist through the existing library store");
                window.HandleLibraryDrop(Data(first+Path.DirectorySeparatorChar,second.ToUpperInvariant()),DefaultAllowed);
                check(library.Roots.Count==2,"Repeated folder drops ignore case and trailing separators");
                InteractionChecks.PumpUntil(()=>window.Files.ItemContainerGenerator.ContainerFromItem(library.Roots[0]) is TreeViewItem);
                window.HandleLibraryDrop(Data(third,other),DefaultAllowed);
                check(library.Roots.Count==3 && library.Roots[2].Path==third && window.CurrentFile==photo,
                    "Dropping folders on an existing row adds roots without opening a mixed-in RAW");
                var invalid=window.HandleLibraryDragOver(new DataObject(DataFormats.UnicodeText,"not a folder"),DefaultAllowed);
                check(invalid==DragDropEffects.None,"File tree rejects unsupported drag data");
                var move=window.HandleLibraryDrop(Data(folders),DragDropEffects.Move);
                check(move==DragDropEffects.None && library.Roots.Count==3,"File-tree drops never accept a move-only transfer");
                window.ForegroundBusy=true;window.RefreshControlsForTests();
                check(window.HandleLibraryDragOver(Data(first),DefaultAllowed)==DragDropEffects.None,"Busy editor rejects drag hover");
                var busy=window.HandleLibraryDrop(Data(folders),DefaultAllowed);
                check(busy==DragDropEffects.None && library.Roots.Count==3,"Busy editor rejects folder drops without changing the library");
                window.ForegroundBusy=false;window.RefreshControlsForTests();
                window.ClosingFlag=true;var closing=window.HandleLibraryDrop(Data(folders),DefaultAllowed);window.ClosingFlag=false;
                check(closing==DragDropEffects.None && library.Roots.Count==3,"Closing editor rejects folder drops");
                window.ClosingFlag=true;
                check(window.HandleLibraryDragOver(Data(first),DefaultAllowed)==DragDropEffects.None && window.HandleFilesDrop(Data(folders),DefaultAllowed)==DragDropEffects.None,
                    "Closing state rejects both tree hover and the root-window drop entry");
                window.ClosingFlag=false;
                check(window.HandleFilesDrop(Data(folders),DragDropEffects.Move)==DragDropEffects.None && library.Roots.Count==3,"Root-window drops reject move-only transfers");
                window.HandleLibraryDrop(Data(other),DefaultAllowed);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(window.CurrentFile==other && library.Roots.Count==3,"A RAW-only drop on the tree retains the existing photo-open behavior");
                check(new[]{first,second,third}.All(Directory.Exists) && File.Exists(other),"Folder drops retain the original folders and RAW files");
            }
            finally
            {
                window.ForegroundBusy=false;window.ClosingFlag=false;window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
        }
        void DraftDialog(bool lens)
        {
            var window=Open("dialog-"+lens);var held=new HeldContext(SynchronizationContext.Current!);
            DispatcherTimer? timer=null;string? failure=null;var sawDisabled=false;var applied=false;
            try
            {
                Click(lens ? window.LensCategory : window.GeometryCategory);
                InteractionChecks.PumpUntil(()=>window.TransformPreviewReady && !window.PreviewResizeTimer.IsEnabled);
                held.Capture(()=>{
                    if(lens)((CheckBox)window.LensEditor.FindName("Distortion")).IsChecked=true;
                    else ((Slider)window.GeometryEditor.FindName("StraightenSlider")).Value=.55;
                });
                check(!window.ApplyDraftButton.IsEnabled,"Draft change starts an exact preview before leaving: "+lens);
                var watch=Stopwatch.StartNew();
                timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(20)};
                timer.Tick+=(_,_)=>{
                    var dialog=app.Windows.OfType<Window>().SingleOrDefault(candidate=>candidate.Title==Loc.Text("保留这次几何或镜头修改？"));
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
                timer.Start();var resolved=window.ResolveTransformDraftForTests();timer.Stop();
                check(sawDisabled && applied && resolved && failure==null,failure ?? "Leave-dialog Apply follows the completed exact preview: "+lens);
                check(!window.TransformDraft.Active,"Apply-and-leave commits and ends the real draft: "+lens);
                InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            }
            finally
            {
                timer?.Stop();held.Release();
                if(window.TransformDraft.Active)window.CancelTransformDraftForTests();
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
        }
    }
}
