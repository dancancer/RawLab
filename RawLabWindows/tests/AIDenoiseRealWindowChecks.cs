using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AIDenoiseRealWindowChecks
{
    internal static void Run(string model,string raw,string cache,string output,Action<bool,string> check)
    {
        var app=Application.Current ?? TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var job=new AIDenoiseJob((identity,snapshot,progress)=>{
            using var worker=new RenderEngine(0,aiModelDirectory:model,aiCacheDirectory:cache,aiBackend:identity.Backend);
            worker.PrepareAI(identity.Source.Path,snapshot,progress);
        });
        var window=new MainWindow(new UsageAnalytics(),null,job){Width=1440,Height=920};
        TestWindowState.Isolate(window,output);
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.NonPublic;
        var engine=new RenderEngine(1,aiModelDirectory:model,aiCacheDirectory:cache,aiBackend:2);
        typeof(MainWindow).GetField("engine",flags)!.SetValue(window,engine);
        object? Call(string name,params object[] args)=>typeof(MainWindow).GetMethod(name,flags)!.Invoke(window,args);
        Adjustments Settings()=>(Adjustments)typeof(MainWindow).GetField("settings",flags)!.GetValue(window)!;
        try {
            window.Show();window.OpenFile(raw);Pump(()=>window.ExportPng.IsEnabled);
            Call("SelectTool",EditorAdjustmentTool.Denoise);
            var before=Settings().Denoise;
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=true;
            var committedLens=Settings().Lens;
            Call("BeginTransform",TransformTool.Lens);
            Call("UpdateLensDraft",committedLens with{Distortion=!committedLens.Distortion});
            Pump(()=>Settings().AIDenoiseEnabled && window.ApplyDraftButton.IsEnabled);
            check(Settings().Lens==committedLens && job.Identity?.Lens.Distortion!=committedLens.Distortion,
                "First AI completion prepares the draft lens without committing it");
            check((bool)Call("ApplyTransformDraft")!,"AI-prepared lens draft applies after first enablement");
            Pump(()=>Settings().AIDenoiseEnabled && window.ExportPng.IsEnabled);
            check(job.State.Status==AIDenoiseStatus.Ready && (engine.LastAIBackend=="RAW=DirectML; RGB=ISP:CPU/RGB:DirectML" ||
                engine.LastAIBackend=="SceneRGB=DirectML"),
                "Real WPF AI toggle and lens preview use the completed hardware result");
            check(engine.LastBackend==3,"Real WPF photo preview executes on Direct3D 11 hardware");
            var accepted=(RenderedImage)typeof(MainWindow).GetField("result",flags)!.GetValue(window)!;
            ViewComparisonChecks.CheckHistogram(accepted,check,"AI after frame");
            window.SetComparisonMode(true,false);Pump(()=>window.ExportPng.IsEnabled);
            var neutral=(RenderedImage)typeof(MainWindow).GetField("neutralResult",flags)!.GetValue(window)!;
            ViewComparisonChecks.CheckHistogram(neutral,check,"AI neutral comparison");
            window.SetComparisonMode(false,false);Pump(()=>window.ExportPng.IsEnabled);
            Call("BeginHoldingBeforeCore",true);
            check(window.HistogramSource.Text==Loc.Text("调整前"),"Holding Before switches AI comparison statistics to the neutral frame");
            Call("EndHoldingBefore");
            check(!((StackPanel)window.DenoiseEditor.FindName("OrdinaryDenoise")).IsEnabled && Settings().Denoise==before,
                "Real WPF keeps ordinary denoise parameters while AI is active");
            Directory.CreateDirectory(output);Capture(window,Path.Combine(output,"ai-ready.png"));
            Settings().Set(Parameter.Exposure,1);Call("MarkEdited");Call("Schedule",false);
            Pump(()=>window.ExportPng.IsEnabled);
            check(Settings().AIDenoiseEnabled && job.State.Status==AIDenoiseStatus.Ready,"Exposure adjustment retains prepared AI state");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            Pump(()=>window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled && ((StackPanel)window.DenoiseEditor.FindName("OrdinaryDenoise")).IsEnabled,
                "Disabling real AI returns to the ordinary preview and export path");
        } finally {window.Close();Pump(()=>!window.IsVisible);app.Shutdown();}
    }
    private static void Capture(MainWindow window,string path)
    {
        var content=(FrameworkElement)window.Content;content.UpdateLayout();
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth),(int)Math.Ceiling(content.ActualHeight),96,96,PixelFormats.Pbgra32);
        bitmap.Render(content);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file=File.Create(path);encoder.Save(file);
    }
    private static void Pump(Func<bool> done)
    {
        var clock=Stopwatch.StartNew();
        while(!done()) {
            if(clock.Elapsed>TimeSpan.FromMinutes(3))throw new TimeoutException("Real AI window did not settle");
            var frame=new DispatcherFrame();var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(30)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
}
