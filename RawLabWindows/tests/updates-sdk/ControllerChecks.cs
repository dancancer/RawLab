using System.ComponentModel;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using RawLab.Windows;

internal static class ControllerChecks
{
    private sealed class Adapter : IDesktopUpdateAdapter
    {
        public string? UnavailableReason => null;
        public UpdateDescriptor Release = new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes");
        public int Checks, Downloads, Installs;
        public bool RejectSignature, RejectInstall, RejectCheck, NoUpdate;
        public Exception? TrustError, CheckError, InstallVerifyError, PreDispatchInstallError, LaunchError;
        public TaskCompletionSource<UpdateDescriptor?>? PendingCheck;
        public Task ValidateHostTrustAsync() => TrustError == null ? Task.CompletedTask : Task.FromException(TrustError);
        public Task<UpdateDescriptor?> CheckAsync(CancellationToken token)
        {
            Checks++;
            if (PendingCheck is { } pending) return pending.Task.WaitAsync(token);
            if (CheckError != null) return Task.FromException<UpdateDescriptor?>(CheckError);
            if (RejectCheck) return Task.FromException<UpdateDescriptor?>(new IOException("offline"));
            return Task.FromResult(NoUpdate ? null : (UpdateDescriptor?)Release);
        }
        public Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token) { Downloads++; progress(75); return Task.CompletedTask; }
        public Task VerifyAsync(UpdateDescriptor release, CancellationToken token) => RejectSignature ? Task.FromException(new CryptographicException("Rejected signature")) : Task.CompletedTask;
        public void VerifyBeforeInstall(UpdateDescriptor release) { if (InstallVerifyError != null) throw InstallVerifyError; }
        public void Install(UpdateDescriptor release, bool restart)
        {
            if (PreDispatchInstallError != null) throw PreDispatchInstallError;
            if (LaunchError != null) throw LaunchError; // Update.exe 进程在拉起前抛异常，不计数为已调度。
            Installs++;
            if (RejectInstall) throw new IOException("Injected dispatch failure");
        }
    }
    private sealed class SerialSynchronizationContext : SynchronizationContext
    {
        private readonly Queue<(SendOrPostCallback Callback, object? State)> queue = new();
        private bool finished;
        public override void Post(SendOrPostCallback d, object? state)
        {
            lock (queue) { queue.Enqueue((d, state)); Monitor.Pulse(queue); }
        }
        public override SynchronizationContext CreateCopy() => this;
        public void Complete()
        {
            lock (queue) { finished = true; Monitor.Pulse(queue); }
        }
        public void Pump()
        {
            while (true)
            {
                (SendOrPostCallback Callback, object? State) item;
                lock (queue)
                {
                    while (queue.Count == 0 && !finished) Monitor.Wait(queue);
                    if (queue.Count == 0) return;
                    item = queue.Dequeue();
                }
                item.Callback(item.State);
            }
        }
    }
    internal static Task Run(Action<bool, string> check)
    {
        var previous = SynchronizationContext.Current;
        var context = new SerialSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(context);
        try
        {
            var task = RunCore(check);
            _ = task.ContinueWith(_ => context.Complete(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            context.Pump();
            return task;
        }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
    }
    private static async Task RunCore(Action<bool, string> check)
    {
        await AutomaticCheckRetries(check);
        await StartupAndQuit(check);
        await StateRepair(check);
        await PreInstallSignatureRejectionDoesNotLockEditing(check);
        await InstallationFailureStaysEditable(check);
        await UpdateExeLaunchFailureStaysRetryable(check);
        await RuntimeSaveFailureRecovery(check);
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-controller-" + Guid.NewGuid().ToString("N"));
        try
        {
            var unsupported = new DesktopUpdateController(new UnavailableUpdateAdapter("configuration"), new(), new(Path.Combine(root, "unsupported")), "0.8.2", "14");
            check(await unsupported.PrepareForQuitAsync(), "Development build can quit without an updater wait");
            var adapter = new Adapter(); var gate = new UpdateInstallGate(); var store = new UpdateStore(Path.Combine(root, "Updates"));
            var controller = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14");
            await controller.CheckAsync(true);
            check(controller.State.Phase == UpdatePhase.Available && adapter.Downloads == 0, "Checking alone never downloads");
            controller.Skip();
            var later = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14", now: () => DateTimeOffset.UtcNow.AddDays(2));
            await later.CheckAsync(false);
            check(later.State.Phase == UpdatePhase.Idle && adapter.Downloads == 0, "Skipped version is suppressed when automatic install is off");
            await later.CheckAsync(true); adapter.RejectSignature = true; await later.DownloadAsync();
            check(later.State.Phase == UpdatePhase.Failed && later.State.Failure?.Stage == UpdatePhase.Verifying &&
                UpdatePresentation.FailureHeading(later.State.Failure!, later.RequiresRecovery) == "更新包未通过验证，已拒绝",
                "Signature rejection remains a verification failure");
            var reopened = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14");
            check(reopened.State.Failure == later.State.Failure, "Closing and reopening preserves failure");
            adapter.RejectSignature = false; await later.RetryAsync();
            check(later.State.Phase == UpdatePhase.PackageReady && adapter.Downloads == 2 && adapter.Installs == 0, "Retry rechecks and redownloads but still needs an install choice");
            check(await later.PrepareForQuitAsync() && adapter.Installs == 0, "Normal quit does not apply an unchosen package");
            await later.CheckAsync(true); await later.DownloadAsync();
            var session = new object(); var busy = true;
            gate.Register(session, () => new(TasksRunning: busy), () => true);
            await later.ChooseAsync(UpdateInstallChoice.AfterTasks);
            check(later.State.Phase == UpdatePhase.WaitingForTasks && adapter.Installs == 0, "Task-end installation waits without killing the task");
            busy = false; var restart = false; later.RestartRequested += () => restart = true;
            await later.RefreshGateAsync();
            check(adapter.Installs == 1 && restart && later.State.Phase == UpdatePhase.PendingRestart && File.Exists(Path.Combine(later.State.BackupPath!, "manifest.json")),
                "Re-admission creates a verified data backup before installer dispatch");
            var manifestPath = Path.Combine(later.State.BackupPath!, "manifest.json"); var validManifest = File.ReadAllText(manifestPath);
            File.WriteAllText(manifestPath, "{\"Format\":2,\"Files\":{}}");
            await later.FinishStartupHealthCheckAsync(true);
            check(later.State.Phase == UpdatePhase.Failed && later.RecoveryError != null, "Corrupt backup routes first boot to recovery instead of crashing");
            File.WriteAllText(manifestPath, validManifest);
            await MalformedFailureStartup(store, later.Preferences, check);
            check(!later.CanRestorePreviousData, "A process that already opened editing cannot restore cached data in place");
            var wrongVersion = new DesktopUpdateController(adapter, new(), store, "0.9.1", "19");
            check(wrongVersion.RequiresRecovery && !wrongVersion.CanCheck && !wrongVersion.CanRestorePreviousData,
                "Failed first boot cannot restore old data into the newer app or erase failure by checking again");
            var untrusted = new DesktopUpdateController(new UnavailableUpdateAdapter("identity"), new(), store, "0.8.2", "14");
            check(!untrusted.CanRestorePreviousData, "Untrusted previous app cannot restore data");
            var wrongBuild = new DesktopUpdateController(adapter, new(), store, "0.8.2", "15");
            check(!wrongBuild.CanRestorePreviousData, "Recovery binds the exact previous build");
            var recovery = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
            check(recovery.CanRestorePreviousData, "Trusted previous build offers explicit recovery before editing");
            await recovery.RestorePreviousDataAsync();
            check(recovery.RecoveryNeedsRestart && recovery.RequiresRecovery && recovery.State.Phase == UpdatePhase.Idle && recovery.Preferences.SkippedVersion == adapter.Release.Identity,
                "Recovery requires reopening and never reports the failed update complete");
            var reopenedAfterRecovery = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
            check(!reopenedAfterRecovery.RequiresRecovery && !reopenedAfterRecovery.CanRestorePreviousData, "Persisted recovery permits a fresh editor on the next launch");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    private static async Task AutomaticCheckRetries(Action<bool, string> check)
    {
        check(DesktopUpdateController.CheckRetryDelay(1) == TimeSpan.FromMinutes(15) &&
            DesktopUpdateController.CheckRetryDelay(2) == TimeSpan.FromMinutes(30) &&
            DesktopUpdateController.CheckRetryDelay(3) == TimeSpan.FromHours(1) &&
            DesktopUpdateController.CheckRetryDelay(4) == TimeSpan.FromHours(2) &&
            DesktopUpdateController.CheckRetryDelay(5) == TimeSpan.FromHours(4) &&
            DesktopUpdateController.CheckRetryDelay(9) == TimeSpan.FromHours(4),
            "Exponential check backoff caps at four hours");
        check(DesktopUpdateController.CategorizeCheckError(new HttpRequestException("dns")) == "network" &&
            DesktopUpdateController.CategorizeCheckError(new TemporaryUpdateTrustException("ocsp")) == "trust" &&
            DesktopUpdateController.CategorizeCheckError(new TaskCanceledException("feed timeout")) == "timeout" &&
            DesktopUpdateController.CategorizeCheckError(new CryptographicException("sig")) == "signature" &&
            DesktopUpdateController.CategorizeCheckError(new InvalidDataException("feed")) == "metadata",
            "Check failure categorizes transient and verification errors");

        var root = Path.Combine(Path.GetTempPath(), "rawlab-check-retry-" + Guid.NewGuid().ToString("N"));
        try
        {
            var t0 = DateTimeOffset.FromUnixTimeSeconds(1800000000);
            var now = t0;
            var store = new UpdateStore(Path.Combine(root, "primary"));
            var adapter = new Adapter { RejectCheck = true };
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", now: () => now);
            check(controller.Preferences.LastCheck == null && controller.CheckFailure == null &&
                UpdatePresentation.Status(controller.Preferences) == "尚未检查更新",
                "Fresh state distinguishes never-checked from up-to-date");

            await controller.CheckAsync(false);
            controller.Cancel();
            check(adapter.Checks == 1 && !controller.CanCancel && controller.State.Phase == UpdatePhase.Failed &&
                controller.Preferences.LastCheck == null &&
                controller.State.Failure is { Stage: UpdatePhase.Checking, Code: "network" } &&
                controller.CheckFailure is { Category: "network", ConsecutiveFailures: 1, Detail: "offline", RetryAfter: null } first && first.FailedAt == t0 &&
                UpdatePresentation.Status(controller.Preferences) == "检查失败，请稍后重试或访问 GitHub 仓库" &&
                UpdatePresentation.CheckFailureDetail(controller.Preferences)?.Contains("network", StringComparison.Ordinal) == true,
                "Failed automatic check leaves LastCheck unset, records CheckFailure, keeps Failed non-cancellable, and exposes failure in UI presentation");

            now = t0.AddMinutes(14).AddSeconds(59);
            await controller.CheckAsync(false);
            await controller.RefreshGateAsync();
            check(adapter.Checks == 1, "Failed automatic check is suppressed inside the initial 15-minute backoff window");

            now = t0.AddMinutes(15);
            adapter.CheckError = new TaskCanceledException("Feed request timed out");
            await controller.RefreshGateAsync();
            check(adapter.Checks == 2 && controller.Preferences.LastCheck == null &&
                controller.CheckFailure is { Category: "timeout", ConsecutiveFailures: 2, RetryAfter: null } second && second.FailedAt == now,
                "Failed automatic check retries after 15 minutes and records non-user feed timeout with doubled backoff");

            var retryBase = now;
            var reopened = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", now: () => now);
            now = retryBase.AddMinutes(29).AddSeconds(59);
            await reopened.CheckAsync(false);
            check(adapter.Checks == 2 && reopened.State.Phase == UpdatePhase.Failed && reopened.CheckFailure?.ConsecutiveFailures == 2,
                "Reopened controller honors the 30-minute second backoff window instead of stalling 24 hours");

            now = retryBase.AddMinutes(30);
            adapter.PendingCheck = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var inFlightRetry = reopened.RefreshGateAsync();
            check(adapter.Checks == 3 && !inFlightRetry.IsCompleted &&
                reopened.State.Phase == UpdatePhase.Checking && reopened.CanCancel,
                "Expired backoff launches an in-flight automatic retry that can be cancelled");

            now = now.AddSeconds(5);
            var cancelAt = now;
            reopened.Cancel();
            await inFlightRetry;
            adapter.PendingCheck = null;
            check(reopened.State.Phase == UpdatePhase.Idle && reopened.State.Failure == null &&
                reopened.CanCheck && !reopened.CanCancel &&
                reopened.CheckFailure is { Category: "timeout", ConsecutiveFailures: 2 } deferred &&
                deferred.FailedAt == retryBase && deferred.RetryAfter == cancelAt.AddMinutes(30) &&
                UpdatePresentation.Status(reopened.Preferences) == "检查失败，请稍后重试或访问 GitHub 仓库" &&
                UpdatePresentation.CheckFailureDetail(reopened.Preferences) != null,
                "Cancelling an in-flight check transitions to Idle without incrementing failure count, defers retry, and keeps failure visible in UI");

            now = cancelAt.AddSeconds(1);
            await reopened.RefreshGateAsync();
            now = cancelAt.AddMinutes(29).AddSeconds(59);
            reopened = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", now: () => now);
            await reopened.CheckAsync(false);
            await reopened.RefreshGateAsync();
            check(reopened.State.Phase == UpdatePhase.Idle && adapter.Checks == 3,
                "RefreshGateAsync and reopen do not immediately restart a user-cancelled retry inside the deferred backoff window");

            now = cancelAt.AddMinutes(30);
            adapter.CheckError = null; adapter.RejectCheck = false; adapter.NoUpdate = true;
            await reopened.RefreshGateAsync();
            check(adapter.Checks == 4 && reopened.State.Phase == UpdatePhase.Idle &&
                reopened.Preferences.LastCheck == now && reopened.CheckFailure == null &&
                UpdatePresentation.Status(reopened.Preferences) == "尚未发现可安装的更新" &&
                UpdatePresentation.CheckFailureDetail(reopened.Preferences) == null,
                "RefreshGateAsync retries from Idle+CheckFailure after deferred backoff expires, writes LastCheck, and clears CheckFailure");

            var successAt = now;
            foreach (var offset in new[] { TimeSpan.FromMinutes(15), TimeSpan.FromHours(4), TimeSpan.FromDays(1) - TimeSpan.FromSeconds(1) })
            {
                now = successAt + offset;
                await reopened.CheckAsync(false);
            }
            check(adapter.Checks == 4, "Successful check suppresses automatic checks across the full 24-hour window");

            adapter.NoUpdate = false;
            now = successAt.AddDays(1);
            await reopened.CheckAsync(false);
            check(adapter.Checks == 5 && reopened.State.Phase == UpdatePhase.Available && reopened.Preferences.LastCheck == now,
                "Automatic check resumes once the 24-hour post-success window elapses");

            now = now.AddMinutes(1);
            adapter.RejectCheck = true;
            await reopened.CheckAsync(true);
            check(adapter.Checks == 6 && reopened.State.Phase == UpdatePhase.Failed && reopened.CheckFailure?.ConsecutiveFailures == 1,
                "Manual check runs immediately inside the 24-hour post-success suppression window");

            adapter.PendingCheck = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var inFlightManual = reopened.CheckAsync(true);
            now = now.AddSeconds(5);
            var quitCancelled = await reopened.PrepareForQuitAsync();
            await inFlightManual;
            adapter.PendingCheck = null;
            check(quitCancelled && reopened.State.Phase == UpdatePhase.Idle && reopened.CheckFailure?.ConsecutiveFailures == 1,
                "Quitting during an in-flight check returns to Idle while preserving CheckFailure");

            now = now.AddMinutes(1);
            adapter.RejectCheck = false;
            await reopened.RefreshGateAsync();
            check(adapter.Checks == 7, "Quit-cancelled in-flight check remains suppressed for automatic RefreshGateAsync");
            await reopened.RetryAsync();
            check(adapter.Checks == 8 && reopened.CheckFailure == null &&
                reopened.State.Phase == UpdatePhase.Available && reopened.Preferences.LastCheck == now,
                "RetryAsync from Idle+CheckFailure runs immediately inside the backoff window and clears CheckFailure on success");

            var quitStore = new UpdateStore(Path.Combine(root, "deferred-quit"));
            var quitAdapter = new Adapter(); var quitGate = new UpdateInstallGate(); var gateOwner = new object(); var draft = true;
            quitGate.Register(gateOwner, () => new(Draft: draft), () => true);
            var quitController = new DesktopUpdateController(quitAdapter, quitGate, quitStore, "0.8.2", "14", now: () => now);
            await quitController.CheckAsync(true);
            await quitController.DownloadAsync();
            await quitController.ChooseAsync(UpdateInstallChoice.OnQuit);
            check(await quitController.PrepareForQuitAsync() && quitController.State.Phase == UpdatePhase.Available &&
                quitController.State.Choice == UpdateInstallChoice.OnQuit,
                "Blocked install-on-quit preserves Available release and OnQuit choice");
            draft = false; quitAdapter.RejectCheck = true;
            var quitFailAt = now;
            quitController = new DesktopUpdateController(quitAdapter, quitGate, quitStore, "0.8.2", "14", now: () => now);
            await quitController.RefreshGateAsync();
            check(quitAdapter.Checks == 2 && quitController.State.Phase == UpdatePhase.Failed &&
                quitController.CheckFailure is { ConsecutiveFailures: 1, RetryAfter: null } qf && qf.FailedAt == quitFailAt,
                "Failed revalidation of OnQuit choice records CheckFailure");
            now = quitFailAt.AddMinutes(2);
            check(await quitController.PrepareForQuitAsync(), "Quit after failed OnQuit revalidation succeeds");
            var reopenedQuit = new DesktopUpdateController(quitAdapter, quitGate, quitStore, "0.8.2", "14", now: () => now);
            check(reopenedQuit.State.Phase == UpdatePhase.Failed && reopenedQuit.State.Failure?.Stage == UpdatePhase.Checking &&
                reopenedQuit.State.Choice == UpdateInstallChoice.OnQuit &&
                reopenedQuit.CheckFailure is { RetryAfter: null } persistedQf && persistedQf.FailedAt == quitFailAt &&
                UpdatePresentation.Status(reopenedQuit.Preferences) == "检查失败，请稍后重试或访问 GitHub 仓库",
                "Reopened OnQuit check failure preserves Failed phase, OnQuit choice, and original CheckFailure timestamp");
            await reopenedQuit.CheckAsync(false);
            await reopenedQuit.RefreshGateAsync();
            now = quitFailAt.AddMinutes(14).AddSeconds(59);
            await reopenedQuit.RefreshGateAsync();
            check(quitAdapter.Checks == 2,
                "Reopening with DeferredQuitChoice respects remaining CheckFailure backoff instead of checking immediately");

            now = quitFailAt.AddMinutes(15);
            quitAdapter.PendingCheck = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var inFlightQuitRetry = reopenedQuit.RefreshGateAsync();
            now = now.AddSeconds(5);
            var quitCancelAt = now;
            check(quitAdapter.Checks == 3 && !inFlightQuitRetry.IsCompleted &&
                await reopenedQuit.PrepareForQuitAsync(),
                "Quitting during an in-flight OnQuit retry cancels the check cleanly");
            await inFlightQuitRetry;
            quitAdapter.PendingCheck = null;
            quitAdapter.RejectCheck = false;
            var reopenedDeferredQuit = new DesktopUpdateController(quitAdapter, quitGate, quitStore, "0.8.2", "14", now: () => now);
            check(reopenedDeferredQuit.State.Phase == UpdatePhase.Available &&
                reopenedDeferredQuit.State.Choice == UpdateInstallChoice.OnQuit &&
                reopenedDeferredQuit.CheckFailure is { ConsecutiveFailures: 1 } deferredQf &&
                deferredQf.RetryAfter == quitCancelAt.AddMinutes(15) &&
                UpdatePresentation.ShowsCheckFailureNotice(reopenedDeferredQuit.Preferences),
                "Quitting an in-flight OnQuit retry keeps Available phase, OnQuit choice, deferred RetryAfter, and check-failure notice");
            now = quitCancelAt.AddMinutes(14).AddSeconds(59);
            await reopenedDeferredQuit.RefreshGateAsync();
            check(quitAdapter.Checks == 3,
                "Available+DeferredQuitChoice also honors deferred RetryAfter backoff on reopen");
            now = quitCancelAt.AddMinutes(15);
            await reopenedDeferredQuit.RefreshGateAsync();
            check(quitAdapter.Checks == 4 && quitAdapter.Downloads == 2 && reopenedDeferredQuit.CheckFailure == null &&
                reopenedDeferredQuit.State.Phase == UpdatePhase.PackageReady && reopenedDeferredQuit.State.Choice == UpdateInstallChoice.OnQuit,
                "DeferredQuitChoice revalidates and redownloads once CheckFailure backoff elapses");

            static void WriteLegacyState(UpdateStore target, DateTimeOffset? lastCheck)
            {
                var node = JsonNode.Parse(JsonSerializer.Serialize(new UpdatePreferences { LastCheck = lastCheck }))!.AsObject();
                node.Remove("CheckFailure");
                Directory.CreateDirectory(target.DirectoryPath);
                File.WriteAllText(target.StatePath, node.ToJsonString());
            }
            var legacyAdapter = new Adapter();
            var legacyRecentStore = new UpdateStore(Path.Combine(root, "legacy-recent"));
            WriteLegacyState(legacyRecentStore, now.AddHours(-2));
            var legacyRecent = new DesktopUpdateController(legacyAdapter, new(), legacyRecentStore, "0.8.2", "14", now: () => now);
            await legacyRecent.CheckAsync(false);
            check(legacyRecent.StorageError == null && !legacyRecent.BlocksEditing &&
                legacyRecent.CheckFailure == null && legacyAdapter.Checks == 0,
                "Legacy state without CheckFailure loads as no-failure and preserves daily suppression");

            var legacyUncheckedStore = new UpdateStore(Path.Combine(root, "legacy-unchecked"));
            WriteLegacyState(legacyUncheckedStore, null);
            var legacyUnchecked = new DesktopUpdateController(legacyAdapter, new(), legacyUncheckedStore, "0.8.2", "14", now: () => now);
            await legacyUnchecked.CheckAsync(false);
            check(legacyUnchecked.StorageError == null && legacyAdapter.Checks == 1 && legacyUnchecked.Preferences.LastCheck == now,
                "Legacy state without CheckFailure and null LastCheck checks immediately");

            var interruptedFirstStore = new UpdateStore(Path.Combine(root, "interrupted-first"));
            var interruptedFirst = new UpdatePreferences(); interruptedFirst.PendingUpdate.BeginCheck(); interruptedFirstStore.Save(interruptedFirst);
            var reopenedInterruptedFirst = new DesktopUpdateController(legacyAdapter, new(), interruptedFirstStore, "0.8.2", "14", now: () => now);
            await reopenedInterruptedFirst.CheckAsync(false);
            check(legacyAdapter.Checks == 2 && reopenedInterruptedFirst.Preferences.LastCheck == now,
                "Interrupted initial check never wrote LastCheck and retries immediately on next launch");

            var interrupted = reopened.Preferences.Copy(); interrupted.PendingUpdate.BeginCheck(); store.Save(interrupted);
            now = now.AddDays(1).AddSeconds(1);
            reopened = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", now: () => now);
            await reopened.CheckAsync(false);
            check(adapter.Checks == 9, "Interrupted check also retries automatically the next day");
            adapter.RejectSignature = true; await reopened.DownloadAsync(); now = now.AddDays(1).AddSeconds(1);
            await reopened.CheckAsync(false);
            check(adapter.Checks == 9 && reopened.State.Failure?.Stage == UpdatePhase.Verifying, "Verification failure still waits for an explicit retry after a day");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task StartupAndQuit(Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-startup-quit-"+Guid.NewGuid());
        try {
            var adapter=new Adapter();var gate=new UpdateInstallGate();var owner=new object();var draft=true;
            gate.Register(owner,()=>new(Draft:draft),()=>true);
            var store=new UpdateStore(Path.Combine(root,"Updates"));
            var controller=new DesktopUpdateController(adapter,gate,store,"0.8.2","14");
            await controller.CheckAsync(true);await controller.DownloadAsync();await controller.ChooseAsync(UpdateInstallChoice.OnQuit);
            check(await controller.PrepareForQuitAsync() && adapter.Installs==0 && controller.State.Choice==UpdateInstallChoice.OnQuit,
                "Blocked install-on-quit returns to ordinary exit and preserves the installation choice");
            var changedStore=new UpdateStore(Path.Combine(root,"Changed"));Directory.CreateDirectory(changedStore.DirectoryPath);
            File.Copy(store.StatePath,changedStore.StatePath);
            var changedAdapter=new Adapter {Release=adapter.Release with {Version="0.9.2",Build="20",AssetUrl="https://example.invalid/new-update.nupkg"}};
            var changed=new DesktopUpdateController(changedAdapter,new(),changedStore,"0.8.2","14");
            await changed.RefreshGateAsync();
            check(changed.State.Phase==UpdatePhase.Available && changed.State.Choice==UpdateInstallChoice.None && changedAdapter.Downloads==0,
                "A changed release does not inherit a previous quit choice or its download retry");
            draft=false;
            controller=new DesktopUpdateController(adapter,gate,store,"0.8.2","14");
            await controller.RefreshGateAsync();
            check(adapter.Checks==2 && adapter.Downloads==2 && controller.State.Choice==UpdateInstallChoice.OnQuit,
                "Reopening revalidates and prepares the previously chosen package without a manual choice");
            check(await controller.PrepareForQuitAsync() && adapter.Installs==1,"The next ordinary quit uses the preserved installation choice");
            var path=controller.State.BackupPath!;
            var reopened=new DesktopUpdateController(adapter,new(),store,"0.9.1","19");
            adapter.TrustError=new TimeoutException("Injected trust timeout");
            await reopened.FinishStartupHealthCheckAsync(true);
            check(reopened.RequiresStartupHealthCheck && !reopened.RequiresRecovery && File.Exists(Path.Combine(path,"manifest.json")),
                "Temporary trust failure preserves pending installation and backup for retry");
            adapter.TrustError=null;await reopened.FinishStartupHealthCheckAsync(true);
            check(reopened.State.Phase==UpdatePhase.Complete && reopened.State.BackupPath==null && !Directory.Exists(path),
                "Successful health retry clears persisted backup reference before removing the backup");
        } finally { if(Directory.Exists(root))Directory.Delete(root,true); }
    }

    private static async Task PreInstallSignatureRejectionDoesNotLockEditing(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-signature-reject-" + Guid.NewGuid().ToString("N"));
        try
        {
            var virtualNow = DateTimeOffset.FromUnixTimeSeconds(1800000000);
            var photo = Path.Combine(root, "Edits", "photo.json"); Directory.CreateDirectory(Path.GetDirectoryName(photo)!);
            File.WriteAllText(photo, "committed edit");
            var store = new UpdateStore(Path.Combine(root, "Updates"));
            var backupsDir = Path.Combine(store.DirectoryPath, "Backups");
            bool NoBackups() => !Directory.Exists(backupsDir) || Directory.GetDirectories(backupsDir).Length == 0;
            var gate = new UpdateInstallGate(); var session = new object(); var dirty = false; var pendingEdit = "";
            gate.Register(session, () => new(Unsaved: dirty), () => { if (dirty) { File.WriteAllText(photo, pendingEdit); dirty = false; } return true; });

            var adapter = new Adapter { InstallVerifyError = new UpdatePackageRejectedException("signature", "Authenticode validation failed", new CryptographicException()) };
            var controller = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14", now: () => virtualNow);
            var restartRequested = false; controller.RestartRequested += () => restartRequested = true;
            await controller.CheckAsync(true); await controller.DownloadAsync();
            await controller.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(!restartRequested && adapter.Installs == 0 && controller.State.Phase == UpdatePhase.Failed &&
                controller.State.Failure?.Stage == UpdatePhase.Verifying && controller.State.Failure?.Code == "signature",
                "Pre-install signature failure rejects the package at Verifying stage without invoking installer");
            check(!controller.BlocksEditing && !controller.RequiresRecovery && !controller.RequiresStartupHealthCheck &&
                !controller.CanRestorePreviousData && controller.State.BackupPath == null &&
                controller.State.PreviousVersion == null && controller.State.PreviousBuild == null &&
                controller.Preferences.SkippedVersion == null && NoBackups(),
                "Pre-install signature rejection creates no backup and never locks the editor into recovery");
            check(UpdatePresentation.FailureHeading(controller.State.Failure!, controller.RequiresRecovery) == "更新包未通过验证，已拒绝" && controller.CanCheck,
                "Rejected package reports package-rejected heading and keeps update check enabled");

            dirty = true; pendingEdit = "edited on previous version after rejection";
            check(!controller.BlocksEditing && gate.Prepare().Length == 0 && File.ReadAllText(photo) == pendingEdit,
                "Previous version remains editable after an update package is rejected");

            var reopened = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14", now: () => virtualNow);
            check(!reopened.BlocksEditing && !reopened.RequiresRecovery && reopened.State.Failure == controller.State.Failure && NoBackups(),
                "Reopening after pre-install rejection keeps editing unlocked with no leftover backup");

            adapter.InstallVerifyError = null;
            await reopened.CheckAsync(true);
            check(reopened.State.Phase == UpdatePhase.Available && reopened.CanDownload, "User can check for updates again after rejection");
            await reopened.DownloadAsync();
            check(reopened.State.Phase == UpdatePhase.PackageReady && reopened.CanChooseInstall && !reopened.BlocksEditing,
                "User can download and prepare an update again after rejection");

            adapter.InstallVerifyError = new CryptographicException("Unexpected update publisher");
            await reopened.ChooseAsync(UpdateInstallChoice.OnQuit);
            check(await reopened.PrepareForQuitAsync() && adapter.Installs == 0 && !reopened.BlocksEditing && !reopened.RequiresRecovery &&
                reopened.State.Phase == UpdatePhase.Failed && reopened.State.Failure?.Stage == UpdatePhase.Verifying &&
                reopened.State.Failure?.Code == "signature" && reopened.State.Choice == UpdateInstallChoice.None && NoBackups(),
                "Install-on-quit signature rejection allows normal exit and persists rejection instead of re-arming quit install");

            adapter.InstallVerifyError = null;
            adapter.PreDispatchInstallError = new UpdatePackageRejectedException("signature", "Cached package no longer matches signed descriptor");
            await reopened.RetryAsync();
            await reopened.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapter.Installs == 0 && !reopened.BlocksEditing && !reopened.RequiresRecovery &&
                reopened.State.Phase == UpdatePhase.Failed && reopened.State.Failure?.Stage == UpdatePhase.Verifying &&
                UpdatePresentation.FailureHeading(reopened.State.Failure!, reopened.RequiresRecovery) == "更新包未通过验证，已拒绝" &&
                reopened.State.BackupPath == null && reopened.State.PreviousVersion == null && NoBackups(),
                "TOCTOU verification failure inside Install immediately discards the staged backup and avoids recovery lock");

            adapter.PreDispatchInstallError = null;
            adapter.InstallVerifyError = new TemporaryUpdateTrustException("Certificate revocation status is temporarily unavailable");
            await reopened.RetryAsync();
            await reopened.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapter.Installs == 0 && !reopened.BlocksEditing && !reopened.RequiresRecovery && NoBackups() &&
                reopened.State.Phase == UpdatePhase.Failed && reopened.State.Failure?.Stage == UpdatePhase.Verifying &&
                reopened.State.Failure?.Code == "trust_temporary" && !UpdatePresentation.IsRejected(reopened.State.Failure!) &&
                UpdatePresentation.FailureHeading(reopened.State.Failure!, reopened.RequiresRecovery) == null,
                "Temporary revocation unavailability neither installs nor marks permanent validation or recovery failure");
            adapter.InstallVerifyError = null;
            virtualNow = virtualNow.AddDays(1).AddSeconds(1);
            await reopened.RefreshGateAsync();
            check(reopened.State.Phase == UpdatePhase.Available && !reopened.BlocksEditing,
                "Temporary revocation failure remains eligible for automatic background recheck");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task InstallationFailureStaysEditable(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-install-failure-" + Guid.NewGuid().ToString("N"));
        try
        {
            var photo = Path.Combine(root, "Edits", "photo.json"); Directory.CreateDirectory(Path.GetDirectoryName(photo)!);
            File.WriteAllText(photo, "committed edit"); var bytes = File.ReadAllBytes(photo);
            var store = new UpdateStore(Path.Combine(root, "Updates"));
            var backupsDir = Path.Combine(store.DirectoryPath, "Backups");
            var adapter = new Adapter { RejectInstall = true };
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
            check(!controller.BlocksEditing, "Ordinary editing is available before installation");
            await controller.CheckAsync(true); await controller.DownloadAsync(); await controller.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapter.Installs == 1 && controller.State.Phase == UpdatePhase.Failed &&
                controller.State.Failure?.Stage == UpdatePhase.ReadyToInstall && controller.State.Failure?.Code == "operation" &&
                !controller.RequiresRecovery && !controller.RequiresStartupHealthCheck && !controller.BlocksEditing &&
                controller.CanCheck && !controller.CanRestorePreviousData,
                "A dispatch failure before proven process start falls back to a plain retryable failure that keeps the editor usable");
            check(File.ReadAllBytes(photo).SequenceEqual(bytes), "Failed dispatch preserves committed editor data");
            check(controller.State.BackupPath == null && (!Directory.Exists(backupsDir) || Directory.GetDirectories(backupsDir).Length == 0),
                "Failed dispatch discards the staged data backup instead of stranding it in recovery");
            adapter.RejectInstall = false;
            await controller.RetryAsync();
            check(controller.State.Phase == UpdatePhase.PackageReady, "A dispatch failure can be retried directly without recovery");
            var restartRequested = false; controller.RestartRequested += () => restartRequested = true;
            await controller.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapter.Installs == 2 && restartRequested && controller.State.Phase == UpdatePhase.PendingRestart,
                "Retried dispatch launches Update.exe and awaits restart");
            var completed = new DesktopUpdateController(new Adapter(), new(), store, "0.9.1", "19");
            await completed.FinishStartupHealthCheckAsync(true);
            check(completed.State.Phase == UpdatePhase.Complete && !completed.BlocksEditing && !completed.RequiresRecovery,
                "Next launch on the updated version completes the retried install");
            var orphan = new UpdateDataBackup(root, store.DirectoryPath).Create("0.8.2", "0.9.1", "14");
            var finished = new DesktopUpdateController(new Adapter(), new(), store, "0.9.1", "19");
            check(!finished.RequiresRecovery && !Directory.Exists(orphan),
                "Fresh startup retries cleanup of verified unreferenced backups");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    // WP-09（完成-27）：Update.exe 进程拉起前抛异常必须回退为普通 Failed，不进入 RequiresRecovery。
    private static async Task UpdateExeLaunchFailureStaysRetryable(Action<bool, string> check)
    {
        var cases = new (string Name, Func<Exception> Error)[]
        {
            ("Win32Exception", () => new Win32Exception(2, "Update.exe could not be started")),
            ("InvalidOperationException", () => new InvalidOperationException("Cannot start the update process"))
        };
        var root = Path.Combine(Path.GetTempPath(), "rawlab-launch-failure-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var (name, error) in cases)
            {
                var store = new UpdateStore(Path.Combine(root, name, "Updates"));
                var backupsDir = Path.Combine(store.DirectoryPath, "Backups");
                var adapter = new Adapter { LaunchError = error() };
                var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
                await controller.CheckAsync(true); await controller.DownloadAsync(); await controller.ChooseAsync(UpdateInstallChoice.RestartNow);
                check(adapter.Installs == 0 && controller.State.Phase == UpdatePhase.Failed &&
                    controller.State.Failure?.Stage == UpdatePhase.ReadyToInstall && controller.State.Failure?.Code == "operation" &&
                    !controller.RequiresRecovery && !controller.RequiresStartupHealthCheck && !controller.BlocksEditing &&
                    controller.CanCheck && !controller.CanRestorePreviousData,
                    name + " before process start stays a plain Failed state that permits editing and retry");
                check(controller.State.BackupPath == null && (!Directory.Exists(backupsDir) || Directory.GetDirectories(backupsDir).Length == 0),
                    name + " launch failure discards the staged data backup");
                var reopened = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(reopened.State.Phase == UpdatePhase.Failed && reopened.State.Failure?.Stage == UpdatePhase.ReadyToInstall &&
                    !reopened.RequiresRecovery && !reopened.BlocksEditing && reopened.CanCheck && !reopened.CanRestorePreviousData,
                    "Reopening after a " + name + " launch failure retries directly instead of locking into recovery");
                await reopened.RetryAsync();
                check(reopened.State.Phase == UpdatePhase.PackageReady, "Reopened " + name + " launch failure rechecks and reprepares the package");
                var restartRequested = false; reopened.RestartRequested += () => restartRequested = true;
                await reopened.ChooseAsync(UpdateInstallChoice.RestartNow);
                check(reopened.State.Phase == UpdatePhase.PendingRestart && restartRequested,
                    "Retrying after a " + name + " launch failure finally launches Update.exe");
                var died = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(died.RequiresStartupHealthCheck && !died.RequiresRecovery,
                    "Next startup validates the persisted PendingRestart record before judging recovery");
                await died.FinishStartupHealthCheckAsync(true);
                check(died.State.Phase == UpdatePhase.Failed && died.State.Failure?.Stage == UpdatePhase.PendingRestart &&
                    died.RequiresRecovery && !died.CanCheck && died.BlocksEditing,
                    "A proven-launched installer that died before completion still routes to RequiresRecovery for " + name);
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task StateRepair(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-controller-repair-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(Path.Combine(root, "Updates")); Directory.CreateDirectory(store.DirectoryPath);
            File.WriteAllText(store.StatePath, "{broken"); var adapter = new Adapter();
            var damaged = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
            check(damaged.StorageError != null && damaged.CanRepairState && !damaged.CanCheck, "Corrupt pre-install state offers explicit repair");
            damaged.RepairState(); damaged.SetAutomaticCheck(true); damaged.SetAutomaticInstall(true); damaged.Cancel(); await damaged.FinishStartupHealthCheckAsync(true);
            check(damaged.StorageError == null && damaged.RecoveryNeedsRestart && damaged.RequiresRecovery && !damaged.CanCheck && adapter.Installs == 0,
                "Repair cannot reopen editing or install in the current process");
            check(!damaged.Preferences.AutomaticCheck && !damaged.Preferences.AutomaticInstall && damaged.Preferences.StateRepairReceipt != null,
                "Recovery actions cannot enable automatic updates or clear the receipt");
            var unhealthy = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
            check(unhealthy.RequiresStartupHealthCheck && !unhealthy.RequiresRecovery, "Reopening repaired state requires data health validation");
            await unhealthy.FinishStartupHealthCheckAsync(false);
            check(unhealthy.RequiresRecovery && !unhealthy.CanCheck && unhealthy.Preferences.StateRepairReceipt != null,
                "Unhealthy user data remains blocked after repair");
            var healthy = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14"); await healthy.FinishStartupHealthCheckAsync(true);
            check(!healthy.RequiresStartupHealthCheck && !healthy.RequiresRecovery && healthy.CanCheck && !healthy.Preferences.AutomaticInstall,
                "Only a fresh healthy startup completes explicit state repair");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task MalformedFailureStartup(UpdateStore store, UpdatePreferences original, Action<bool, string> check)
    {
        var document = System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(original))!;
        try
        {
            foreach (var name in new[] { "missing", "null", "incomplete" })
            {
                var damaged = document.DeepClone(); var pending = damaged["PendingUpdate"]!.AsObject();
                if (name == "missing") pending.Remove("Failure");
                else if (name == "null") pending["Failure"] = null;
                else pending["Failure"] = new System.Text.Json.Nodes.JsonObject { ["Stage"] = (int)UpdatePhase.PendingRestart };
                var bytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(damaged); File.WriteAllBytes(store.StatePath, bytes);
                var reopened = new DesktopUpdateController(new Adapter(), new(), store, "0.9.1", "19");
                await reopened.FinishStartupHealthCheckAsync(true);
                check(reopened.StorageError != null && reopened.BlocksEditing && !reopened.CanCheck && !reopened.CanChooseInstall && !reopened.CanRepairState,
                    "Malformed installation failure blocks startup and state reset: " + name);
                check(File.ReadAllBytes(store.StatePath).SequenceEqual(bytes), "Blocked startup preserves the damaged failure record: " + name);
            }
        }
        finally { store.Save(original); }
    }

    private static async Task RuntimeSaveFailureRecovery(Action<bool, string> check)
    {
        static IOException SharingViolation() => new("Simulated sharing violation", unchecked((int)0x80070020));
        static UpdateTaskState SavedState(byte[] bytes) =>
            JsonSerializer.Deserialize<UpdatePreferences>(bytes)!.PendingUpdate;
        var root = Path.Combine(Path.GetTempPath(), "rawlab-save-recovery-" + Guid.NewGuid().ToString("N"));
        try
        {
            var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            Func<Exception?>? writeFault = null;
            Func<byte[], Exception?>? moveFault = null;
            int writeCalls = 0, moveCalls = 0;
            var elapsed = TimeSpan.Zero;
            var delays = new List<int>();
            var virtualNow = DateTimeOffset.FromUnixTimeSeconds(1800000000);
            UpdateStore CreateStore(string name) => new(
                Path.Combine(root, name, "Updates"),
                (temporary, bytes) =>
                {
                    writeCalls++;
                    if (writeFault?.Invoke() is { } fault) throw fault;
                    files[temporary] = bytes.ToArray();
                },
                (source, destination) =>
                {
                    moveCalls++;
                    if (moveFault?.Invoke(files[source]) is { } fault) throw fault;
                    files[destination] = files[source];
                    files.Remove(source);
                },
                delay => { delays.Add((int)delay.TotalMilliseconds); elapsed += delay; },
                () => elapsed,
                path => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null,
                path => { files.Remove(path); return true; });
            void ResetCounters() { writeCalls = 0; moveCalls = 0; delays.Clear(); }

            var store = CreateStore("a");
            var adapter = new Adapter();
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", now: () => virtualNow);
            moveFault = _ => new UnauthorizedAccessException("Injected access denied");
            ResetCounters();
            var saveThrew = false;
            try { store.Save(new()); }
            catch (UnauthorizedAccessException) { saveThrew = true; }
            check(saveThrew && writeCalls == 1 && moveCalls == 1 && delays.Count == 0 && files.Count == 0,
                "UpdateStore.Save throws non-transient UnauthorizedAccessException upward without retrying or leaking temporaries");

            controller.SetAutomaticCheck(false);
            await controller.CheckAsync(true);
            check(controller.StorageError != null && !controller.BlocksEditing && !controller.CanRepairState &&
                controller.UnavailableReason == null && controller.CanCheck &&
                controller.Preferences.AutomaticCheck && controller.State.Phase == UpdatePhase.Idle && adapter.Checks == 0,
                "Runtime state save failure does not lock editing or permanently disable update retry");

            moveFault = null;
            controller.SetAutomaticCheck(false);
            await controller.CheckAsync(true);
            check(controller.StorageError == null && !controller.BlocksEditing &&
                !controller.Preferences.AutomaticCheck && controller.State.Phase == UpdatePhase.Available &&
                !store.Load(true).AutomaticCheck,
                "Restoring writable storage clears StorageError and persists retried preferences and checks");

            await controller.DownloadAsync();
            check(controller.State.Phase == UpdatePhase.PackageReady, "Package reaches ready state before simulated sharing conflict");

            moveFault = _ => SharingViolation();
            ResetCounters();
            var sharingThrew = false;
            try { store.Save(controller.Preferences); }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { sharingThrew = true; }
            check(sharingThrew && writeCalls == 1 && moveCalls == 4 && delays.SequenceEqual(new[] { 10, 50, 200 }) && files.Count == 1,
                "Exhausted sharing-violation retries use injected clock/sleep and throw IOException from UpdateStore.Save");

            ResetCounters();
            await controller.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(delays.SequenceEqual(new[] { 10, 50, 200 }) && controller.StorageError != null && !controller.BlocksEditing &&
                adapter.Installs == 0 && controller.State.Phase == UpdatePhase.Available && controller.CanDownload &&
                await controller.PrepareForQuitAsync(),
                "Sharing-violation exhaustion during install admission aborts installation without locking editing or blocking quit");

            moveFault = null;
            await controller.DownloadAsync();
            await controller.ChooseAsync(UpdateInstallChoice.OnQuit);
            adapter.RejectInstall = true;
            moveFault = bytes => SavedState(bytes) is { Phase: UpdatePhase.Failed, Failure: { Stage: UpdatePhase.ReadyToInstall } } ? SharingViolation() : null;
            ResetCounters();
            var quitApproved = await controller.PrepareForQuitAsync();
            check(quitApproved && adapter.Installs == 1 && delays.SequenceEqual(new[] { 10, 50, 200 }) &&
                controller.StorageError != null && controller.State.Phase == UpdatePhase.Failed &&
                controller.State.Failure?.Stage == UpdatePhase.ReadyToInstall && controller.State.Choice == UpdateInstallChoice.None &&
                !controller.BlocksEditing && !controller.RequiresRecovery && !controller.RequiresStartupHealthCheck &&
                controller.CanCheck && !controller.CanDownload && !controller.CanChooseInstall && !controller.CanCancel,
                "Failed installer dispatch keeps the plain retryable failure in memory even when persisting Fail() also fails");

            moveFault = null;
            var reopenedFailed = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14", now: () => virtualNow);
            await reopenedFailed.FinishStartupHealthCheckAsync(true);
            check(reopenedFailed.BlocksEditing && reopenedFailed.RequiresRecovery && reopenedFailed.CanRestorePreviousData,
                "Persisted Installing record transitions to recoverable failure on next launch of previous version");

            var store2 = CreateStore("b");
            var adapter2 = new Adapter();
            var controller2 = new DesktopUpdateController(adapter2, new(), store2, "0.8.2", "14", now: () => virtualNow);
            var restarted = false; controller2.RestartRequested += () => restarted = true;
            await controller2.CheckAsync(true);
            await controller2.DownloadAsync();
            moveFault = bytes => SavedState(bytes).Phase == UpdatePhase.PendingRestart ? SharingViolation() : null;
            ResetCounters();
            await controller2.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapter2.Installs == 1 && restarted && delays.SequenceEqual(new[] { 10, 50, 200 }) &&
                controller2.StorageError != null && controller2.State.Phase == UpdatePhase.PendingRestart &&
                controller2.BlocksEditing && controller2.RequiresStartupHealthCheck && !controller2.RequiresRecovery &&
                !controller2.CanCheck && !controller2.CanDownload && !controller2.CanChooseInstall && !controller2.CanCancel &&
                await controller2.PrepareForQuitAsync(),
                "Successful installer dispatch transitions to PendingRestart and triggers restart even when AwaitingRestart save fails");

            moveFault = null;
            var reopenedUpdated = new DesktopUpdateController(adapter2, new(), store2, "0.9.1", "19", now: () => virtualNow);
            await reopenedUpdated.FinishStartupHealthCheckAsync(true);
            check(reopenedUpdated.StorageError == null && reopenedUpdated.State.Phase == UpdatePhase.Complete && !reopenedUpdated.BlocksEditing,
                "Next launch on target version completes health check from the persisted Installing record");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
