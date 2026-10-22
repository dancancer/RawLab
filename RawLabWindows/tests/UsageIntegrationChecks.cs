using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using RawLab.Windows;

internal static class UsageIntegrationChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string output,string photo,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var consent=Path.Combine(output,"usage.json");File.WriteAllText(consent,"{\"Enabled\":true}");
        var transport=new Transport();var analytics=new UsageAnalytics(consent,transport);
        var window=new MainWindow(analytics);TestWindowState.Isolate(window,output);
        typeof(MainWindow).GetField("usageAnalytics",Private)!.SetValue(window,analytics);
        window.GpuMode.SelectedIndex=1;window.Show();
        TaskCompletionSource? pendingRelease=null;
        try
        {
            InteractionChecks.PumpUntil(()=>window.IsLoaded && transport.Events.OfType<AppStartedEvent>().Count()==1);
            window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
            check(transport.Starts==1 && transport.Events.OfType<AppStartedEvent>().Count()==1,
                "RUM startup is wired once across repeated main-window Loaded events");
            window.OpenFile(photo);Ready();
            window.ValueSlider.Value=.6;Ready();
            check(transport.Events.OfType<PhotoImportedEvent>().Count()==1,
                "RUM records one successful photo open, not proxy/exact or parameter redraws");
            var films=window.FilmStrip.Children.OfType<Button>().ToArray();
            var neutral=films[0];neutral.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready();
            check(Get<string?>(window,"lut")==null && !transport.Events.OfType<FilmSelectedEvent>().Any(),
                "The fresh neutral photo ignores an unchanged neutral selection");
            films[1].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready();
            check(Get<string?>(window,"lut")!=null && transport.Events.OfType<FilmSelectedEvent>().Count()==1 &&
                transport.Events.OfType<FilmSelectedEvent>().Single().Kind!=FilmKind.None,
                "Usage fixture selects a non-neutral look through the production click handler");
            neutral.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready();
            neutral.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            check(transport.Events.OfType<FilmSelectedEvent>().Count()==2 && transport.Events.OfType<FilmSelectedEvent>().Last().Kind==FilmKind.None,
                "RUM records a changed film click once and ignores the repeated selection");
            Invoke(window,"AboutClicked",window,new RoutedEventArgs());
            var about=Get<AboutWindow>(window,"aboutWindow");var toggle=(CheckBox)about.FindName("UsageConsent");
            check(toggle.IsChecked==true && toggle.IsEnabled,"About shares the active main-window analytics consent");
            toggle.IsChecked=false;InteractionChecks.PumpUntil(()=>!analytics.ConsentGiven && transport.Stops==1);
            var filmCount=transport.Events.OfType<FilmSelectedEvent>().Count();
            films[1].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready();
            check(transport.Events.OfType<FilmSelectedEvent>().Count()==filmCount && File.ReadAllText(consent).Contains("false"),
                "About opt-out persists privately and blocks subsequent editor events");
            toggle.IsChecked=true;InteractionChecks.PumpUntil(()=>analytics.IsActive);
            check(transport.Starts==2 && transport.Events.OfType<AppStartedEvent>().Count()==1,
                "About re-enable does not duplicate the process launch event");
            about.Close();
            var destination=Path.Combine(output,"single.png");
            typeof(MainWindow).GetField("exportLongEdge",Private)!.SetValue(window,128);
            var exported=window.ExportPhoto(ExportFormat.Png,destination);
            InteractionChecks.PumpUntil(()=>exported.IsCompleted);exported.GetAwaiter().GetResult();Ready();
            check(File.Exists(destination) && transport.Events.OfType<ExportCompletedEvent>().Count()==1 &&
                Get<string>(window,"lastExportedPath")==destination,"RUM single export follows successful publication and keeps reveal state");
            var refused=window.ExportPhoto(ExportFormat.Png,photo);
            InteractionChecks.PumpUntil(()=>refused.IsCompleted);refused.GetAwaiter().GetResult();
            check(transport.Events.OfType<ExportCompletedEvent>().Count()==1,"RUM source-overwrite refusal is not a successful export");

            var bad=Path.Combine(output,"bad.arw");File.WriteAllBytes(bad,[1,2,3,4]);
            var journal=Get<BatchJournal>(window,"batchJournal");
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            job.Format=ExportFormat.Png;job.LongEdge=128;job.OutputDirectory=Path.Combine(output,"batch-output");Directory.CreateDirectory(job.OutputDirectory);
            job.Items.Add(BatchItem.Create(photo) with{Selected=true});
            job.Items.Add(BatchItem.Create(bad) with{Selected=true});journal.Save(job);
            Invoke(window,"ShowBatch",job);var batch=Get<BatchExportWindow>(window,"batchWindow");
            RunBatch();
            var first=transport.Events.OfType<BatchExportCompletedEvent>().Single();
            check(first.Outcome==BatchOutcome.Partial && first.SucceededCount==1 && first.FailedCount==1,
                "RUM real batch owner records one partial terminal event with per-run counts");
            File.Copy(photo,bad,true);
            job=batch.Job;job.Items=job.Items.Select(item=>item.Input==bad ? item with{Identity=OriginalIdentity.Read(bad)} : item).ToList();journal.Save(job);
            RunBatch();
            var retry=transport.Events.OfType<BatchExportCompletedEvent>().Last();
            check(transport.Events.OfType<BatchExportCompletedEvent>().Count()==2 && batch.Job.SucceededCount==2 &&
                retry.Outcome==BatchOutcome.Completed && retry.SucceededCount==1 && retry.FailedCount==0,
                "RUM real retry reports only its new success while BusyChanged still gates the editor");
            Invoke(batch,"Refresh");batch.Close();
            check(transport.Events.OfType<BatchExportCompletedEvent>().Count()==2,"Batch refresh and close do not replay terminal analytics");
            foreach(var interrupted in new[]{false,true})
            {
                var terminal=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
                terminal.Items.Add(BatchItem.Create(photo) with{Selected=true});
                terminal.OutputDirectory=Path.Combine(output,interrupted ? "blocked-output" : "cancelled-output");
                if(interrupted)File.WriteAllText(terminal.OutputDirectory,"not a directory");else Directory.CreateDirectory(terminal.OutputDirectory);
                journal.Save(terminal);Invoke(window,"ShowBatch",terminal);batch=Get<BatchExportWindow>(window,"batchWindow");
                if(!interrupted)batch.BusyChanged+=active=>{if(active && batch.Running)batch.CancelExecution();};
                var count=transport.Events.OfType<BatchExportCompletedEvent>().Count();RunBatch();
                var terminalEvent=transport.Events.OfType<BatchExportCompletedEvent>().Last();
                check(transport.Events.OfType<BatchExportCompletedEvent>().Count()==count+1 && terminalEvent.SucceededCount==0 &&
                    terminalEvent.FailedCount==0 && terminalEvent.Outcome==(interrupted ? BatchOutcome.Interrupted : BatchOutcome.Cancelled),
                    "RUM real terminal outcome is not reported as success: "+terminalEvent.Outcome);
                batch.Close();
            }
            Ready();
            var release=pendingRelease=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);transport.Hold=release.Task;
            var pending=analytics.RecordAsync(new PhotoImportedEvent());
            var stops=transport.Stops;window.Close();Invoke(window,"FinishClose");
            check(window.IsVisible && !window.IsEnabled && !Get<bool>(window,"closeFinished") && Get<object?>(window,"engine")!=null && !pending.IsCompleted,
                "Main close retains the engine and window until in-flight analytics drains");
            release.SetResult();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            check(Get<bool>(window,"closeFinished") && Get<object?>(window,"engine")==null && transport.Stops==stops+1,
                "Deferred analytics close disposes exactly once before releasing the editor engine");
            BoundedExit(output,check);

            void RunBatch()
            {
                var terminal=false;var releasedAfterTerminal=false;var startedWithGate=false;
                void Completed(BatchJob before,BatchJob after,int failures)=>terminal=true;
                void Busy(bool active){if(active)startedWithGate=batch.Running && !window.ExportPng.IsEnabled;else releasedAfterTerminal=terminal;}
                batch.RunCompleted+=Completed;batch.BusyChanged+=Busy;
                try
                {
                    Invoke(batch,"PrimaryClicked",batch,new RoutedEventArgs());
                    check(startedWithGate,"RUM batch execution preserves the owner's busy gate");
                    InteractionChecks.PumpUntil(()=>!batch.Running);
                    check(terminal && releasedAfterTerminal,"RunCompleted precedes the owner's BusyChanged(false) release");
                }
                finally{batch.RunCompleted-=Completed;batch.BusyChanged-=Busy;}
            }
        }
        finally
        {
            pendingRelease?.TrySetResult();
            transport.Hold=null;
            window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
        }
        void Ready()=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    }
    // ─── 离线时 SDK 关闭一直不返回：主窗口最多等 ShutdownLimit 就退出，且只关闭一次 ───
    private static void BoundedExit(string output,Action<bool,string> check)
    {
        var hung=new Transport{StopHold=new TaskCompletionSource().Task};
        var analytics=new UsageAnalytics(Path.Combine(output,"offline-usage.json"),hung);
        var window=new MainWindow(analytics);TestWindowState.Isolate(window,output);
        typeof(MainWindow).GetField("usageAnalytics",Private)!.SetValue(window,analytics);
        window.Show();InteractionChecks.PumpUntil(()=>analytics.IsActive);
        check(hung.InstallIds.Count==1 && Guid.TryParse(hung.InstallIds[0],out _),"Default-on analytics starts with a private random install ID");
        var clock=System.Diagnostics.Stopwatch.StartNew();
        window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
        check(clock.Elapsed<UsageAnalytics.ShutdownLimit+TimeSpan.FromSeconds(5) && hung.Stops==1 && Get<object?>(window,"engine")==null,
            "Main window exits after the bounded wait when the SDK close hangs offline");
    }
    private static T Get<T>(object target,string field)=>(T)target.GetType().GetField(field,Private)!.GetValue(target)!;
    private static object? Invoke(object target,string method,params object?[] args)=>target.GetType().GetMethod(method,Private)!.Invoke(target,args);
    private sealed class Transport:IUsageAnalyticsTransport
    {
        internal int Starts,Stops;
        internal Task? Hold,StopHold;
        internal List<UsageEvent> Events=[];
        internal List<string> InstallIds=[];
        public bool IsAvailable=>true;
        public Task StartAsync(string installId,CancellationToken cancellationToken){Starts++;InstallIds.Add(installId);return Task.CompletedTask;}
        public async Task SendAsync(UsageEvent usageEvent,CancellationToken cancellationToken)
        { if(Hold is {} hold)await hold;Events.Add(usageEvent); }
        public Task StopAsync(CancellationToken cancellationToken){Stops++;return StopHold ?? Task.CompletedTask;}
    }
}
