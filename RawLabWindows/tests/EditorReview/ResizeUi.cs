using System.Diagnostics;
using System.IO;
using System.Reflection;
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
}
