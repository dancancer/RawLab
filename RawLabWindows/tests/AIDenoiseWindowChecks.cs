using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AIDenoiseWindowChecks
{
    internal static void Run(string raw,string output,Action<bool,string> check)
    {
        var app=Application.Current ?? TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        using var release=new ManualResetEventSlim();
        var started=0;
        var job=new AIDenoiseJob((identity,_,progress)=>{
            if(!PhotoInput.IsRaw(identity.Source.Path))throw new InvalidOperationException("Fixture: AI requires calibrated RAW");
            Interlocked.Increment(ref started);release.Wait(TimeSpan.FromSeconds(30));progress.Token.ThrowIfCancellationRequested();
        });
        var window=new MainWindow(new UsageAnalytics(),null,job);
        TestWindowState.Isolate(window,output);window.Show();window.GpuMode.SelectedIndex=1;
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.NonPublic;
        object? Call(string name,params object[] args)=>typeof(MainWindow).GetMethod(name,flags)!.Invoke(window,args);
        Adjustments Settings()=>(Adjustments)typeof(MainWindow).GetField("settings",flags)!.GetValue(window)!;
        void Begin()
        {
            release.Reset();var before=started;
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=true;
            Pump(()=>started>before);
            check(job.State.IsRunning && !Settings().AIDenoiseEnabled && !window.ExportPng.IsEnabled,
                "Pending first AI request neither persists AI nor exports a stale preview");
        }
        try {
            window.OpenFile(raw);Pump(()=>window.ExportPng.IsEnabled);
            Begin();
            Call("ExecuteReset",new EditorResetScope(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Denoise));
            check(job.State.Status==AIDenoiseStatus.Idle,"Reset neutral denoise cancels pending AI intent");
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Completion after reset cannot re-enable AI");
            Begin();
            ((Button)window.DenoiseEditor.FindName("AICancel")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Cancelling first AI request restores ordinary export");
            foreach(var scope in new[]{new EditorResetScope(EditorResetKind.All),new EditorResetScope(EditorResetKind.Group,EditorAdjustmentGroup.Detail)}) {
                Settings().Denoise=DenoiseSettings.Clean;
                Begin();var prepared=window.PrepareReset(scope)!;
                var revision=(long)typeof(MainWindow).GetField("editRevision",flags)!.GetValue(window)!;
                check(window.CommitReset(prepared,revision) && job.State.Status==AIDenoiseStatus.Idle,"Committed reset cancels pending AI: "+scope.Kind);
                release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            }
            Begin();window.OpenFile(raw);release.Set();
            Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Photo reopen rejects a stale AI completion");
            Directory.CreateDirectory(output);var raster=Path.Combine(output,"unsupported.png");
            var pixels=Enumerable.Repeat((byte)160,32*24*3).ToArray();
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(32,24,96,96,PixelFormats.Rgb24,null,pixels,32*3)));
            using(var stream=File.Create(raster))encoder.Save(stream);
            window.SaveSettingsCopy(raster,new Adjustments {AIDenoiseEnabled=true}.Capture(),null);
            window.OpenFile(raster);Pump(()=>job.State.Status==AIDenoiseStatus.Failed);
            check(Settings().AIDenoiseEnabled && !window.ExportPng.IsEnabled && ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsEnabled,
                "Unsupported restored AI stays explicit and exposes an enabled off switch");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            Pump(()=>window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Explicitly disabling unsupported AI restores the raster preview");
            window.OpenFile(raw);Pump(()=>window.ExportPng.IsEnabled);
            Begin();window.Close();
            check(window.IsVisible && !window.IsEnabled,"Closing waits for the active AI worker");
            release.Set();Pump(()=>!window.IsVisible);
        } finally { release.Set();if(window.IsVisible){window.Close();Pump(()=>!window.IsVisible);}app.Shutdown(); }
    }
    private static void Pump(Func<bool> done)
    {
        var clock=Stopwatch.StartNew();
        while(!done()) {
            if(clock.Elapsed>TimeSpan.FromSeconds(60))throw new TimeoutException("AI window state did not settle");
            var frame=new DispatcherFrame();var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(20)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
}
