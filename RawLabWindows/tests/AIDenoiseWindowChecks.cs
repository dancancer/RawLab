using System.Diagnostics;
using System.IO;
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
        var window=TestWindowState.CreateIsolatedWindow(output,aiJob:job);
        window.Show();window.GpuMode.SelectedIndex=1;
        Adjustments Settings()=>window.Settings;
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
            var previewBefore=window.HslAcceptedWorkToken;
            Settings().Set(Parameter.Exposure,.25);window.MarkEditedForTests();window.ScheduleForTests(false,false);
            Pump(()=>!ReferenceEquals(previewBefore,window.HslAcceptedWorkToken));
            check(job.State.IsRunning && !Settings().AIDenoiseEnabled,"Ordinary preview continues while the first AI result is being prepared");
            window.ExecuteResetForTests(new EditorResetScope(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Denoise));
            check(job.State.Status==AIDenoiseStatus.Idle,"Reset neutral denoise cancels pending AI intent");
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Completion after reset cannot re-enable AI");
            Begin();
            ((Button)window.DenoiseEditor.FindName("AICancel")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Cancelling first AI request restores ordinary export");
            Begin();window.BeginEditGestureForTests();
            window.Interacting=true;
            Settings().Set(Parameter.Exposure,.75);window.MarkEditedForTests();release.Set();
            Pump(()=>Settings().AIDenoiseEnabled);
            window.CancelEditGestureForTests();
            check(Settings().AIDenoiseEnabled,"Cancelling a parameter gesture preserves AI enabled by an asynchronous completion");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            foreach(var scope in new[]{new EditorResetScope(EditorResetKind.All),new EditorResetScope(EditorResetKind.Group,EditorAdjustmentGroup.Detail)}) {
                Settings().Denoise=DenoiseSettings.Clean;
                Begin();var prepared=window.PrepareReset(scope)!;
                var revision=window.EditRevision;
                check(window.CommitReset(prepared,revision) && job.State.Status==AIDenoiseStatus.Idle,"Committed reset cancels pending AI: "+scope.Kind);
                release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            }
            Begin();window.OpenFile(raw);release.Set();
            Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            check(!Settings().AIDenoiseEnabled,"Photo reopen rejects a stale AI completion");
            release.Reset();Volatile.Write(ref failDraft,true);Settings().AIDenoiseEnabled=true;
            var beforeDraft=started;
            window.BeginTransformForTests(TransformTool.Lens);Pump(()=>started>beforeDraft);
            var originalPreparation=job.Completion;
            var transform=window.TransformDraft;
            transform.Update(new GeometrySettings {StraightenDegrees=1});window.ScheduleForTests(false,false);
            check(ReferenceEquals(originalPreparation,job.Completion),"Geometry-only draft keeps the same AI task");
            window.SetPendingAllResetForTests(window.CurrentFile,window.OpenRevision,EditorAdjustmentTool.Exposure,null);
            window.UpdateLensDraftForTests(new LensSettings(Distortion:true));release.Set();
            Pump(()=>job.State.Status==AIDenoiseStatus.Failed);
            window.Dispatcher.Invoke(()=>{},DispatcherPriority.ApplicationIdle);
            check(!window.HasPendingAllReset,
                "AI preparation failure clears the pending all-reset continuation before preview can run");
            check(job.Identity?.Lens.Distortion==true && !Settings().Lens.Distortion,
                "Active lens draft prepares its own identity without committing lens settings");
            var failedPreparation=job.Completion;window.ScheduleForTests(false,false);
            check(ReferenceEquals(failedPreparation,job.Completion),"Same failed draft identity does not retry automatically");
            release.Reset();var beforeRestore=started;window.CancelTransformDraftForTests();
            Pump(()=>started>beforeRestore && job.State.IsRunning);
            check(job.Identity?.Lens.Distortion==false && !Settings().Lens.Distortion,
                "Cancelling a failed lens draft restores the committed AI identity");
            ((CheckBox)window.DenoiseEditor.FindName("AIEnabledBox")).IsChecked=false;
            release.Set();Pump(()=>job.Completion.IsCompleted && window.ExportPng.IsEnabled);
            Volatile.Write(ref failDraft,false);
            var beforeMissing=started;
            Begin();
            window.SetPendingAllResetForTests(window.CurrentFile,window.OpenRevision,EditorAdjustmentTool.Exposure,null);
            release.Set();
            Pump(()=>job.State.Status==AIDenoiseStatus.Failed);
            check(!window.HasPendingAllReset,
                "Native preview failure clears the pending post-reset tool return");
            check(started-beforeMissing==4 && job.State.Error==Loc.Text("AI 降噪结果连续未就绪，请重试。") &&
                window.AdjustmentPanel.IsEnabled && ((Button)window.DenoiseEditor.FindName("AIRetry")).IsEnabled,
                "Repeated native AI_NOT_READY stops after three re-preparations and keeps retry controls usable");
            window.ScheduleForTests(false,false);Pump(()=>job.Completion.IsCompleted);
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
                window.ClearPendingAllResetForTests();
                Settings().AIDenoiseEnabled=false;window.ResetAITaskForTests();window.CancelTransformDraftForTests();
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
