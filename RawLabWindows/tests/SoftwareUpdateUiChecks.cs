using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using RawLab.Windows;

internal static class SoftwareUpdateUiChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(object value,string name)=>(T)value.GetType().GetField(name,Private)!.GetValue(value)!;
    private static object? Invoke(object value,string name,params object?[] args)=>value.GetType().GetMethod(name,Private)!.Invoke(value,args);
    private static IEnumerable<DependencyObject> Children(DependencyObject root)
    {
        yield return root;
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())foreach(var nested in Children(child))yield return nested;
    }
    private static Button Button(Window window,string id)=>Children(window).OfType<Button>().Single(button=>AutomationProperties.GetAutomationId(button)==id);
    private static void Click(Button button)=>((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    private static void Screenshot(SoftwareUpdateWindow window,string path)
    {
        ((ScrollViewer)window.Content).Background=window.Background;
        PhotoFeatureChecks.Screenshot(window,path);
    }
    internal static void Run(string repo,string input,Action<bool,string> check)
    {
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var output=Path.Combine(repo,"build","windows-update-ui",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        var lease=new UpdateRunLease(Path.Combine(output,"lock"));var rejected=false;
        try{using var second=new UpdateRunLease(Path.Combine(output,"lock"));}catch(IOException){rejected=true;}
        check(rejected,"Production run lease rejects a second data writer before editing");lease.Dispose();
        using(var released=new UpdateRunLease(Path.Combine(output,"lock"))) { }
        var photo=Path.Combine(output,"source"+Path.GetExtension(input));File.Copy(input,photo);
        Loc.Initialize("en");var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var adapter=new Adapter();var controller=new DesktopUpdateController(adapter,new(),new(Path.Combine(output,"Updates")),"0.8.2","14",false);
        var window=new MainWindow(new UsageAnalytics(),null,desktopUpdates:controller){Width=1200,Height=900};TestWindowState.Isolate(window,output);
        var store=new EditStore(Path.Combine(output,"edits"));typeof(MainWindow).GetField("editStore",Private)!.SetValue(window,store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);Ready(window);
            GateBusyWorkChecks(window,controller,adapter,check);
            Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);Ready(window);
            var session=(AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession",Private)!.GetValue(window)!;
            foreach(var draft in new[]{"1.25","-"}) {
                window.Activate();window.OrdinaryParameter.Number.Focus();window.OrdinaryParameter.Number.Text=draft;
                var saved=store.VersionedState(photo);var count=session.Transactions.Count;var state=Get<Adjustments>(window,"settings").Capture();
                Invoke(window,"ShowSoftwareUpdates",true);var dialog=Get<SoftwareUpdateWindow>(window,"softwareUpdateWindow");
                InteractionChecks.PumpUntil(()=>dialog.IsVisible);Click(Button(dialog,"updates.check"));
                InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.Available);
                check(window.OrdinaryParameter.Number.Text==draft && window.OrdinaryParameter.HasPendingInput &&
                    Get<Adjustments>(window,"settings").Capture().SameAs(state) && store.VersionedState(photo).SameAs(saved) && session.Transactions.Count==count,
                    "Opening and checking from actual update window preserves input, edits and history: "+draft);
                Click(Button(dialog,"updates.download"));InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.Downloading);
                check(controller.Gate.Blockers().Contains("draft"),"Production gate sees suspended numeric input while downloading");
                Click(Button(dialog,"updates.cancel"));InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.Available);
                dialog.Close();window.Activate();window.OrdinaryParameter.Number.Focus();
                check(window.OrdinaryParameter.Number.Text==draft && store.VersionedState(photo).SameAs(saved) && session.Transactions.Count==count,
                    "Closing and cancelling updates leaves the editor input unchanged: "+draft);
                window.OrdinaryParameter.CancelInput();
            }
            Invoke(window,"BeginTransform",TransformTool.Geometry);InteractionChecks.PumpUntil(()=>Get<TransformDraft>(window,"transform").Active);
            var transform=Get<TransformDraft>(window,"transform");var geometry=transform.Geometry with{StraightenDegrees=1.2};
            transform.Update(geometry,transform.Lens);var baseline=store.VersionedState(photo);var history=session.Transactions.Count;
            Invoke(window,"ShowSoftwareUpdates",false);var prompt=Get<SoftwareUpdateWindow>(window,"softwareUpdateWindow");
            check(transform.Active && transform.Geometry==geometry && controller.Gate.Blockers().Contains("draft"),"Update prompt preserves the real transform draft and blocks installation");
            Click(Button(prompt,"updates.check"));InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.Available);
            Click(Button(prompt,"updates.download"));InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.Downloading);
            adapter.Download.TrySetResult();InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.PackageReady);
            Click(Button(prompt,"updates.onQuit"));InteractionChecks.PumpUntil(()=>controller.State.Phase==UpdatePhase.WaitingForTasks);
            check(adapter.Installs==0 && transform.Active && store.VersionedState(photo).SameAs(baseline) && session.Transactions.Count==history,
                "Choosing installation while a transform draft exists does not apply, discard or save it");
            controller.Cancel();prompt.Close();Invoke(window,"CancelTransformDraft");Ready(window);
            Invoke(window,"ShowSoftwareUpdates",true);var settings=Get<SoftwareUpdateWindow>(window,"softwareUpdateWindow");
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"}) {
                Loc.SetPreference(language,Path.Combine(output,"language.txt"));foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                settings.FontSize=26;settings.UpdateLayout();
                check(settings.IsVisible && Button(settings,"updates.check").IsVisible && Button(settings,"updates.check").ActualWidth>0,
                    "Update settings and actions remain reachable at large text: "+language);
                Screenshot(settings,Path.Combine(output,"updates-"+language+".png"));
                var header=(TextBlock)Children(settings).OfType<Expander>().Single().Header;
                check(header.TranslatePoint(new Point(),settings).X+header.ActualWidth<=settings.ActualWidth-8,
                    "Localized support heading fits within the window at large text: "+language);
                ((ScrollViewer)settings.Content).ScrollToBottom();settings.UpdateLayout();
                Screenshot(settings,Path.Combine(output,"updates-"+language+"-actions.png"));
                ((ScrollViewer)settings.Content).ScrollToTop();settings.UpdateLayout();
            }
            settings.Close();
            Loc.SetPreference("en",Path.Combine(output,"language.txt"));foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
            var recoveryRoot=Path.Combine(output,"recovery");var recoveryStore=new UpdateStore(Path.Combine(recoveryRoot,"Updates"));
            var original=Path.Combine(recoveryRoot,"Edits","photo.json");Directory.CreateDirectory(Path.GetDirectoryName(original)!);File.WriteAllText(original,"previous edit");
            var savedBackup=new UpdateDataBackup(recoveryRoot,recoveryStore.DirectoryPath).Create("0.8.2","0.9.1","14");
            var failed=new UpdatePreferences();var token=failed.PendingUpdate.BeginCheck();
            failed.PendingUpdate.Found(new("0.9.1","19","windows","x64","stable","https://example.invalid/package.nupkg",12,null,"Offline recovery fixture"),token);
            token=failed.PendingUpdate.BeginDownload()!.Value;failed.PendingUpdate.Preparing(token);failed.PendingUpdate.Verified(token);
            failed.PendingUpdate.Choose(UpdateInstallChoice.OnQuit);failed.PendingUpdate.Admit([]);
            failed.PendingUpdate.BackupPath=savedBackup;failed.PendingUpdate.PreviousVersion="0.8.2";failed.PendingUpdate.PreviousBuild="14";
            failed.PendingUpdate.Installing(token);failed.PendingUpdate.Fail("test","Injected failed install",token);recoveryStore.Save(failed);
            File.WriteAllText(original,"new format");
            var recovery=new DesktopUpdateController(new Adapter(),new(),recoveryStore,"0.8.2","14");
            var recoveryWindow=new SoftwareUpdateWindow(recovery,new UpdateChecker("0.8.2")){Owner=window,FontSize=26};recoveryWindow.Show();recoveryWindow.UpdateLayout();
            check(Button(recoveryWindow,"updates.restore").IsEnabled && !Button(recoveryWindow,"updates.check").IsEnabled,
                "Native recovery window offers explicit restoration and blocks new checks");
            Screenshot(recoveryWindow,Path.Combine(output,"recovery-en.png"));
            ((ScrollViewer)recoveryWindow.Content).ScrollToBottom();recoveryWindow.UpdateLayout();
            Screenshot(recoveryWindow,Path.Combine(output,"recovery-en-scrolled.png"));
            Click(Button(recoveryWindow,"updates.restore"));InteractionChecks.PumpUntil(()=>recovery.RecoveryNeedsRestart);
            check(File.ReadAllText(original)=="previous edit" && recovery.RequiresRecovery && recovery.State.Phase!=UpdatePhase.Complete,
                "Native restore action preserves failure semantics and requires reopening before editing");
            InteractionChecks.PumpUntil(()=>!recovery.Recovering);recoveryWindow.Close();
            var repairStore=new UpdateStore(Path.Combine(output,"state-repair","Updates"));Directory.CreateDirectory(repairStore.DirectoryPath);
            File.WriteAllText(repairStore.StatePath,"{broken");
            var repair=new DesktopUpdateController(new Adapter(),new(),repairStore,"0.8.2","14");
            var repairWindow=new SoftwareUpdateWindow(repair,new UpdateChecker("0.8.2")){Owner=window,FontSize=26};repairWindow.Show();repairWindow.UpdateLayout();
            check(Button(repairWindow,"updates.repairState").IsEnabled,"Native corrupt-state screen offers explicit repair");
            Click(Button(repairWindow,"updates.repairState"));InteractionChecks.PumpUntil(()=>repair.RecoveryNeedsRestart);
            check(repair.RequiresRecovery && !Button(repairWindow,"updates.check").IsEnabled && File.ReadAllText(repair.StateArchive!)=="{broken",
                "Native repair action preserves damaged state and requires reopening");
            var repairedStartup=new DesktopUpdateController(new Adapter(),new(),repairStore,"0.8.2","14");
            repairedStartup.FinishStartupHealthCheck(window.UpdateDataHealthy);
            check(!repairedStartup.RequiresRecovery && !repairedStartup.RequiresStartupHealthCheck,"Real editor data health completes repair on fresh startup");
            repairWindow.Close();
            Console.WriteLine("UPDATE_UI_OUTPUT="+output);
        } finally {controller.Cancel();Invoke(window,"CancelTransformDraft");Invoke(window,"CancelParameterInputs");window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
    }
    private static void GateBusyWorkChecks(MainWindow window,DesktopUpdateController controller,Adapter adapter,Action<bool,string> check)
    {
        foreach(var name in new[]{"autoExposing","transferPreparing"}) {
            var field=typeof(MainWindow).GetField(name,Private)!;field.SetValue(window,true);
            try {
                var before=controller.State.Copy();
                check(((UpdateSessionStatus)Invoke(window,"UpdateStatus")!).TasksRunning && controller.Gate.Blockers().Contains("tasks") &&
                    controller.Gate.Prepare().Contains("tasks") && controller.State.Phase==before.Phase &&
                    controller.State.BackupPath==before.BackupPath && adapter.Installs==0,
                    "Active native work blocks update preparation before backup or install: "+name);
            } finally {field.SetValue(window,false);}
            check(!((UpdateSessionStatus)Invoke(window,"UpdateStatus")!).TasksRunning && !controller.Gate.Blockers().Contains("tasks"),
                "Completed native work releases the update gate: "+name);
        }
    }
    private sealed class Adapter:IDesktopUpdateAdapter
    {
        public string? UnavailableReason=>null;
        public int Installs;
        public TaskCompletionSource Download=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<UpdateDescriptor?> CheckAsync(CancellationToken token)=>Task.FromResult<UpdateDescriptor?>(new("0.9.1","19","windows","x64","stable","https://updates.example.invalid/RawLab-full.nupkg",12,new string('a',64),"Offline UI fixture"));
        public async Task DownloadAsync(UpdateDescriptor release,Action<int> progress,CancellationToken token){Download=new(TaskCreationOptions.RunContinuationsAsynchronously);progress(50);await Download.Task.WaitAsync(token);}
        public Task VerifyAsync(UpdateDescriptor release,CancellationToken token)=>Task.CompletedTask;
        public void Install(UpdateDescriptor release,bool restart)=>Installs++;
    }
}
