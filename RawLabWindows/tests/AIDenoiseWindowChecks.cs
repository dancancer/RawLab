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
        var failDraft=false;
        var job=new AIDenoiseJob((identity,snapshot,progress)=>{
            if(!PhotoInput.IsRaw(identity.Source.Path))throw new InvalidOperationException("Fixture: AI requires calibrated RAW");
            if(identity.Lens!=snapshot.Lens)throw new Exception("AI snapshot lost draft lens settings");
            Interlocked.Increment(ref started);
            if(Volatile.Read(ref failDraft) && snapshot.Lens.Distortion)throw new InvalidOperationException("Fixture: draft model failure");
            release.Wait(TimeSpan.FromSeconds(30));progress.Token.ThrowIfCancellationRequested();
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
            var previewBefore=typeof(MainWindow).GetField("hslAcceptedWork",flags)!.GetValue(window);
            Settings().Set(Parameter.Exposure,.25);Call("MarkEdited");Call("Schedule",false);
            Pump(()=>!ReferenceEquals(previewBefore,typeof(MainWindow).GetField("hslAcceptedWork",flags)!.GetValue(window)));
            check(job.State.IsRunning && !Settings().AIDenoiseEnabled,"Ordinary preview continues while the first AI result is being prepared");
            Call("ExecuteReset",new EditorResetScope(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Denoise));
            check(job.State.Status==AIDenoiseStatus.Idle,"Reset neutral denoise cancels pending AI intent");
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Completion after reset cannot re-enable AI");
            Begin();
            ((Button)window.DenoiseEditor.FindName("AICancel")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Cancelling first AI request restores ordinary export");
            Begin();Call("BeginEditGesture");
            typeof(MainWindow).GetField("interacting",flags)!.SetValue(window,true);
            Settings().Set(Parameter.Exposure,.75);Call("MarkEdited");release.Set();
            Pump(()=>Settings().AIDenoiseEnabled);
            Call("CancelEditGesture");
            check(Settings().AIDenoiseEnabled,"Cancelling a parameter gesture preserves AI enabled by an asynchronous completion");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
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
            release.Reset();Volatile.Write(ref failDraft,true);Settings().AIDenoiseEnabled=true;
            var beforeDraft=started;
            Call("BeginTransform",TransformTool.Lens);Pump(()=>started>beforeDraft);
            var originalPreparation=job.Completion;
            var transform=(TransformDraft)typeof(MainWindow).GetField("transform",flags)!.GetValue(window)!;
            transform.Update(new GeometrySettings {StraightenDegrees=1});Call("Schedule",false);
            check(ReferenceEquals(originalPreparation,job.Completion),"Geometry-only draft keeps the same AI task");
            var failurePendingType=typeof(MainWindow).GetNestedType("PendingAllReset",BindingFlags.NonPublic)!;
            var failurePending=Activator.CreateInstance(failurePendingType,BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance,
                null,new object?[]{typeof(MainWindow).GetField("file",flags)!.GetValue(window),
                    typeof(MainWindow).GetField("openRevision",flags)!.GetValue(window),EditorAdjustmentTool.Exposure,null},null);
            typeof(MainWindow).GetField("pendingAllReset",flags)!.SetValue(window,failurePending);
            Call("UpdateLensDraft",new LensSettings(Distortion:true));release.Set();
            Pump(()=>job.State.Status==AIDenoiseStatus.Failed);
            window.Dispatcher.Invoke(()=>{},DispatcherPriority.ApplicationIdle);
            check(typeof(MainWindow).GetField("pendingAllReset",flags)!.GetValue(window)==null,
                "AI preparation failure clears the pending all-reset continuation before preview can run");
            check(job.Identity?.Lens.Distortion==true && !Settings().Lens.Distortion,
                "Active lens draft prepares its own identity without committing lens settings");
            var failedPreparation=job.Completion;Call("Schedule",false);
            check(ReferenceEquals(failedPreparation,job.Completion),"Same failed draft identity does not retry automatically");
            release.Reset();var beforeRestore=started;Call("CancelTransformDraft");
            Pump(()=>started>beforeRestore && job.State.IsRunning);
            check(job.Identity?.Lens.Distortion==false && !Settings().Lens.Distortion,
                "Cancelling a failed lens draft restores the committed AI identity");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            Volatile.Write(ref failDraft,false);
            var beforeMissing=started;
            Begin();
            var pendingType=typeof(MainWindow).GetNestedType("PendingAllReset",BindingFlags.NonPublic)!;
            var pending=Activator.CreateInstance(pendingType,BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance,
                null,new object?[]{typeof(MainWindow).GetField("file",flags)!.GetValue(window),
                    typeof(MainWindow).GetField("openRevision",flags)!.GetValue(window),EditorAdjustmentTool.Exposure,null},null);
            typeof(MainWindow).GetField("pendingAllReset",flags)!.SetValue(window,pending);
            release.Set();
            Pump(()=>job.State.Status==AIDenoiseStatus.Failed);
            check(typeof(MainWindow).GetField("pendingAllReset",flags)!.GetValue(window)==null,
                "Native preview failure clears the pending post-reset tool return");
            check(started-beforeMissing==4 && job.State.Error==Loc.Text("AI 降噪结果连续未就绪，请重试。") &&
                window.AdjustmentPanel.IsEnabled && ((Button)window.DenoiseEditor.FindName("AIRetry")).IsEnabled,
                "Repeated native AI_NOT_READY stops after three re-preparations and keeps retry controls usable");
            Call("Schedule",false);Pump(()=>job.Completion.IsCompleted);
            check(started-beforeMissing==4,"Ordinary preview requests do not restart an exhausted AI preparation");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            Pump(()=>window.ExportPng.IsEnabled);
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
            Pump(()=>!window.IsEnabled || !window.IsVisible);
            check(window.IsVisible && !window.IsEnabled,"Closing waits for the active AI worker");
            release.Set();Pump(()=>!window.IsVisible);
        } finally {
            release.Set();
            if(window.IsVisible){
                typeof(MainWindow).GetField("pendingAllReset",flags)!.SetValue(window,null);
                Settings().AIDenoiseEnabled=false;Call("ResetAITask");Call("CancelTransformDraft");
                window.Close();Pump(()=>!window.IsVisible);
            }
            app.Shutdown();
        }
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
