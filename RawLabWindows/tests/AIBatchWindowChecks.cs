using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AIBatchWindowChecks
{
    internal static void Run(string model,string raw,string output,Action<bool,string> check)
    {
        raw=Path.GetFullPath(raw);output=Path.GetFullPath(output);
        Directory.CreateDirectory(output);
        var app=Application.Current ?? TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var settings=new Adjustments {AIDenoiseEnabled=true};
        var job=BatchJob.Create(raw,settings.Capture(),null,"Neutral");
        job.OutputDirectory=Path.Combine(output,"rendered");Directory.CreateDirectory(job.OutputDirectory);
        job.Format=ExportFormat.Png;job.LongEdge=512;
        var journal=new BatchJournal(Path.Combine(output,"journal"));
        var window=new BatchExportWindow(job,journal,backend=>new RenderEngine(0,aiModelDirectory:model,
            aiCacheDirectory:Path.Combine(output,"cache"),aiBackend:backend));
        window.Show();
        try {
            var raster=Path.Combine(output,"raster.png");
            using(var ordinary=new RenderEngine(0))ordinary.Render(raw,new Adjustments(),null,0,output:raster,longEdge:128);
            var clock=Stopwatch.StartNew();var preflight=window.AddInputs([raw,raster]);
            Pump(()=>preflight.IsCompleted);preflight.GetAwaiter().GetResult();
            check(window.Job.Items.Single(item=>item.Input==raw).Selected,"AI RAW remains selected after lightweight batch preflight");
            check(!window.Job.Items.Single(item=>item.Input==raster).Selected,"AI raster target is excluded during batch preflight");
            check(clock.Elapsed<TimeSpan.FromSeconds(5),"AI preflight avoids model preparation and inference");
            void Start() {
                window.PrimaryAction.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                check(window.Running,"Batch export starts through the window's primary action");
            }
            Start();
            Pump(()=>window.AIProgress.IsVisible || !window.Running);
            check(window.AIProgress.IsVisible && window.AIStatus.Text.Length>0,"AI preparation reports progress in the batch window: "+(window.Job.Error ?? window.Job.Items.FirstOrDefault(item=>item.Error!=null)?.Error ?? ""));
            window.CancelExecution();Pump(()=>!window.Running);
            check(window.Job.Cancelled && window.Job.FailedCount==0 && window.Job.Items.Single(item=>item.Input==raw).Status==BatchStatus.Waiting,
                "Cancelling real AI preparation leaves the RAW retryable");
            check(journal.Load()!.Items.Single(item=>item.Input==raw).Status==BatchStatus.Waiting,"Cancelled AI state survives journal reload");
            Start();Pump(()=>!window.Running);
            check(window.Job.SucceededCount==1 && window.Job.FailedCount==0,"Restarted AI batch automatically prepares and exports the RAW");
            var item=window.Job.Items.Single(item=>item.Input==raw);
            check(File.Exists(item.Output),"AI batch publishes its rendered output");
            check(window.AIProgress.Visibility==Visibility.Collapsed,"Completed batch clears AI progress");
        } finally {window.CancelExecution();Pump(()=>!window.Running);window.Close();app.Shutdown();}
    }
    private static void Pump(Func<bool> done)
    {
        var clock=Stopwatch.StartNew();
        while(!done()) {
            if(clock.Elapsed>TimeSpan.FromMinutes(4))throw new TimeoutException("AI batch did not settle");
            var frame=new DispatcherFrame();var timer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(20)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
}
