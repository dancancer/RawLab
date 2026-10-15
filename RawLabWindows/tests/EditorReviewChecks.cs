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
            if(part is "all" or "dialog-geometry")DraftDialog(false);
            if(part is "all" or "dialog-lens")DraftDialog(true);
            check(new[]{raw,photo,other}.All(path=>originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(path)))),
                "Editor review regressions preserve the external RAW and both source copies");
        }
        finally{app.Shutdown();}

        MainWindow Open(string name)
        {
            var window=new MainWindow();
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
                        Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight),clipping:false)!;
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
    private static byte[] Pixels(BitmapSource image)
    {
        var stride=image.PixelWidth*4;var bytes=new byte[stride*image.PixelHeight];image.CopyPixels(bytes,stride,0);return bytes;
    }
}
