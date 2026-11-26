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
    private static Task RunOnDedicatedSerialUiContext(Func<Task> body)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var previous = SynchronizationContext.Current;
            var context = new SerialSynchronizationContext();
            SynchronizationContext.SetSynchronizationContext(context);
            try
            {
                var task = body();
                _ = task.ContinueWith(_ => context.Complete(), CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                context.Pump();
                task.GetAwaiter().GetResult();
                completion.TrySetResult(true);
            }
            catch (Exception error)
            {
                completion.TrySetException(error);
            }
            finally
            {
                SynchronizationContext.SetSynchronizationContext(previous);
            }
        })
        {
            IsBackground = true,
            Name = "ControllerChecks.SerialUiPump"
        };
        thread.Start();
        return completion.Task;
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
        await CorruptStatePreservesOptOut(check);
        await StartupAndQuit(check);
        await StateRepair(check);
        await FutureEnumStateStaysEditable(check);
        await EvidenceComboKeepsInstallGate(check);
        await DiskBackupWithUnknownEnumIsNotDiscarded(check);
        await PreInstallSignatureRejectionDoesNotLockEditing(check);
        await InstallationFailureStaysEditable(check);
        await UpdateExeLaunchFailureStaysRetryable(check);
        await RuntimeSaveFailureRecovery(check);
        await NonBlockingSerializedSaves(check);
        await ConcurrentPreferenceTogglePreservesInFlightSaveState(check);
        await CancelDuringAvailableSaveDoesNotClobberState(check);
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-controller-" + Guid.NewGuid().ToString("N"));
        try
        {
            var unsupported = new DesktopUpdateController(new UnavailableUpdateAdapter("configuration"), new(), new(Path.Combine(root, "unsupported")), "0.8.2", "14");
            check(await unsupported.PrepareForQuitAsync(), "Development build can quit without an updater wait");
            var adapter = new Adapter(); var gate = new UpdateInstallGate(); var store = new UpdateStore(Path.Combine(root, "Updates"));
            var controller = new DesktopUpdateController(adapter, gate, store, "0.8.2", "14");
            await controller.CheckAsync(true);
            check(controller.State.Phase == UpdatePhase.Available && adapter.Downloads == 0, "Checking alone never downloads");
            await controller.SkipAsync();
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
            GC.KeepAlive(session);
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
            await controller.CancelAsync();
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
            await reopened.FlushSavesAsync();
            check(adapter.Checks == 3 && !inFlightRetry.IsCompleted &&
                reopened.State.Phase == UpdatePhase.Checking && reopened.CanCancel,
                "Expired backoff launches an in-flight automatic retry that can be cancelled");

            now = now.AddSeconds(5);
            var cancelAt = now;
            await reopened.CancelAsync();
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
            await reopened.FlushSavesAsync();
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
            await reopenedQuit.FlushSavesAsync();
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
            GC.KeepAlive(gateOwner);
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
            GC.KeepAlive(owner);
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
            GC.KeepAlive(session);
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

    private static async Task CorruptStatePreservesOptOut(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-corrupt-optout-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(Path.Combine(root, "Updates")); Directory.CreateDirectory(store.DirectoryPath);
            var corrupt = System.Text.Encoding.UTF8.GetBytes("{broken");
            File.WriteAllBytes(store.StatePath, corrupt);
            var adapter = new Adapter();
            var damaged = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", automaticCheck: false);
            await damaged.PerformStartupCheckAsync();
            check(!damaged.Preferences.AutomaticCheck && adapter.Checks == 0 &&
                File.ReadAllBytes(store.StatePath).SequenceEqual(corrupt),
                "Corrupt state.json preserves user AutomaticCheck opt-out, skips network check and leaves persisted settings untouched");

            var damagedOptIn = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", automaticCheck: true);
            await damagedOptIn.PerformStartupCheckAsync();
            check(damagedOptIn.Preferences.AutomaticCheck && adapter.Checks == 0,
                "Storage-degraded UpdateStore skips automatic startup network checks even when AutomaticCheck is enabled");

            var healthyStore = new UpdateStore(Path.Combine(root, "HealthyUpdates"));
            healthyStore.Save(new UpdatePreferences { AutomaticCheck = false });
            var healthy = new DesktopUpdateController(adapter, new(), healthyStore, "0.8.2", "14", automaticCheck: true);
            await healthy.PerformStartupCheckAsync();
            check(!healthy.Preferences.AutomaticCheck && adapter.Checks == 0,
                "Healthy UpdateStore preserves persisted AutomaticCheck opt-out and skips startup check");

            var unavailableStore = new UpdateStore(Path.Combine(root, "UnavailableUpdates"));
            var unavailable = new DesktopUpdateController(new UnavailableUpdateAdapter("installation"), new(), unavailableStore, "0.8.2", "14", automaticCheck: true);
            await unavailable.PerformStartupCheckAsync();
            await unavailable.CheckAsync(true);
            check(!unavailable.CanCheck && unavailable.State.Phase == UpdatePhase.Idle && unavailable.State.Release == null,
                "Version discovery uses single IDesktopUpdateAdapter source only without fallback polling when unavailable");
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
            await damaged.RepairStateAsync(); await damaged.SetAutomaticCheckAsync(true); await damaged.SetAutomaticInstallAsync(true); await damaged.CancelAsync(); await damaged.FinishStartupHealthCheckAsync(true);
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

    private static async Task FutureEnumStateStaysEditable(Action<bool, string> check)
    {
        // Q13 回滚兼容：旧版读到新版写入的未知枚举值（无安装证据）时降级为 Idle，编辑区保持可用；
        // 已知 Installing/PendingRestart 的锁定语义由 WP-09 用例继续把守。
        var root = Path.Combine(Path.GetTempPath(), "rawlab-future-enum-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var slot in new[] { "Phase", "Choice", "FailureStage" })
            {
                var store = new UpdateStore(Path.Combine(root, slot)); Directory.CreateDirectory(store.DirectoryPath);
                var saved = new UpdatePreferences { AutomaticCheck = true, LastCheck = DateTimeOffset.FromUnixTimeSeconds(1800000000) };
                var token = saved.PendingUpdate.BeginCheck();
                saved.PendingUpdate.Found(new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes"), token);
                var download = saved.PendingUpdate.BeginDownload()!.Value;
                saved.PendingUpdate.Preparing(download); saved.PendingUpdate.Verified(download);
                saved.PendingUpdate.Choose(UpdateInstallChoice.AfterTasks);
                // 失败阶段槽位用 Failed 基底；Phase/Choice 槽位保持 PackageReady 待装基底（评审 nit：贴合真实待装选择回滚）。
                if (slot == "FailureStage") saved.PendingUpdate.Fail("network", "dropped", download);
                var document = JsonNode.Parse(JsonSerializer.Serialize(saved))!.AsObject();
                var pending = document["PendingUpdate"]!.AsObject();
                if (slot == "Phase") pending["Phase"] = 99;
                else if (slot == "Choice") pending["Choice"] = 99;
                else pending["Failure"]!["Stage"] = 99;
                File.WriteAllBytes(store.StatePath, JsonSerializer.SerializeToUtf8Bytes(document));
                var onDisk = File.ReadAllBytes(store.StatePath);
                var adapter = new Adapter();
                var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
                check(controller.StorageError == null && !controller.BlocksEditing && !controller.RequiresStartupHealthCheck &&
                    !controller.RequiresRecovery && !controller.CanRepairState && controller.State.Phase == UpdatePhase.Idle &&
                    controller.CanCheck && controller.UnavailableReason == null,
                    "Future " + slot + " value opens the editor as idle instead of the storage gate (Q13 rollback)");
                check(File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk),
                    "Future " + slot + " startup leaves the newer state file untouched until the next save");
                await controller.CheckAsync(true);
                check(controller.State.Phase == UpdatePhase.Available && adapter.Checks == 1 &&
                    store.Load(true).PendingUpdate.Phase == UpdatePhase.Available,
                    "Future " + slot + " downgrade leaves the update state machine usable");
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task EvidenceComboKeepsInstallGate(Action<bool, string> check)
    {
        // Q13 边界（碳审 critical）：未知枚举与安装证据并存时不得进入「删备份」的降级分支——
        // 保持启动存储门禁、不触发 DiscardUnreferencedBackups、磁盘 BackupPath 保持被引用。
        var root = Path.Combine(Path.GetTempPath(), "rawlab-evidence-combo-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var name in new[] { "Installing+futureChoice", "PendingRestart+futureChoice", "Failed@Installing+futureChoice", "futurePhase+backup", "futureStage+backup" })
            {
                var directory = Path.Combine(root, name.Replace('@', '-').Replace('+', '_'));
                var store = new UpdateStore(directory); Directory.CreateDirectory(directory);
                var backup = new UpdateDataBackup(Path.GetDirectoryName(directory)!, directory).Create("0.8.2", "14");
                var saved = new UpdatePreferences { AutomaticCheck = true, LastCheck = DateTimeOffset.FromUnixTimeSeconds(1800000000) };
                var token = saved.PendingUpdate.BeginCheck();
                saved.PendingUpdate.Found(new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes"), token);
                var download = saved.PendingUpdate.BeginDownload()!.Value;
                saved.PendingUpdate.Preparing(download); saved.PendingUpdate.Verified(download);
                saved.PendingUpdate.Choose(UpdateInstallChoice.RestartNow);
                var document = JsonNode.Parse(JsonSerializer.Serialize(saved))!.AsObject();
                var pending = document["PendingUpdate"]!.AsObject();
                pending["Choice"] = 99; pending["BackupPath"] = backup; pending["PreviousVersion"] = "0.8.2"; pending["PreviousBuild"] = "14";
                if (name.StartsWith("Installing")) pending["Phase"] = (int)UpdatePhase.Installing;
                else if (name.StartsWith("PendingRestart")) pending["Phase"] = (int)UpdatePhase.PendingRestart;
                else if (name.StartsWith("Failed@")) { pending["Phase"] = (int)UpdatePhase.Failed;
                    pending["Failure"] = new JsonObject { ["Stage"] = (int)UpdatePhase.Installing, ["Code"] = "interrupted", ["Detail"] = "lost" }; }
                else if (name.StartsWith("futurePhase")) pending["Phase"] = 99;
                else { pending["Phase"] = (int)UpdatePhase.Failed;
                    pending["Failure"] = new JsonObject { ["Stage"] = 99, ["Code"] = "interrupted", ["Detail"] = "lost" }; }
                File.WriteAllBytes(store.StatePath, JsonSerializer.SerializeToUtf8Bytes(document));
                var onDisk = File.ReadAllBytes(store.StatePath);
                var adapter = new Adapter();
                var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");
                check(controller.StorageError != null && !controller.BlocksEditing && controller.UnavailableReason == "storage" && !controller.CanCheck && !controller.CanRepairState &&
                    Directory.Exists(backup) && controller.State.Phase == UpdatePhase.Idle && File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk),
                    "Unknown enum with installation evidence (" + name + ") keeps the storage update gate and preserves the backup without blocking editing (Q13 boundary)");
                var reopened = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(!reopened.BlocksEditing && reopened.UnavailableReason == "storage" && Directory.Exists(backup) && File.Exists(Path.Combine(backup, "manifest.json")) &&
                    File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk),
                    "Reopening the evidence combo (" + name + ") still refuses silent backup deletion without blocking editing");
                await Task.CompletedTask;
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static async Task DiskBackupWithUnknownEnumIsNotDiscarded(Action<bool, string> check)
    {
        // W2（#297 残留）：state.json 无 JSON BackupPath/Previous*，但磁盘存在 Backups/Recoveries/recovery-in-progress.json
        // 且 PendingUpdate 含未知枚举时，controller 启动不得降级为 Idle 并在 :74 静默删除备份。
        var root = Path.Combine(Path.GetTempPath(), "rawlab-disk-backup-gate-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var slot in new[] { "Phase", "Choice", "FailureStage" })
            {
                var dataRoot = Path.Combine(root, slot);
                var directory = Path.Combine(dataRoot, "Updates");
                var edits = Path.Combine(dataRoot, "Edits"); Directory.CreateDirectory(edits);
                File.WriteAllText(Path.Combine(edits, "photo.json"), "{\"Exposure\":0.5}");
                var store = new UpdateStore(directory); Directory.CreateDirectory(directory);
                var backup = new UpdateDataBackup(dataRoot, directory).Create("0.8.2", "0.9.1", "14");
                var saved = new UpdatePreferences { AutomaticCheck = true, LastCheck = DateTimeOffset.FromUnixTimeSeconds(1800000000) };
                var token = saved.PendingUpdate.BeginCheck();
                saved.PendingUpdate.Found(new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes"), token);
                var download = saved.PendingUpdate.BeginDownload()!.Value;
                saved.PendingUpdate.Preparing(download); saved.PendingUpdate.Verified(download);
                saved.PendingUpdate.Choose(UpdateInstallChoice.RestartNow);
                if (slot == "FailureStage") saved.PendingUpdate.Fail("network", "dropped", download);
                var document = JsonNode.Parse(JsonSerializer.Serialize(saved))!.AsObject();
                var pending = document["PendingUpdate"]!.AsObject();
                pending["BackupPath"] = null; pending["PreviousVersion"] = null; pending["PreviousBuild"] = null;
                if (slot == "Phase") pending["Phase"] = 99;
                else if (slot == "Choice") pending["Choice"] = 99;
                else pending["Failure"]!["Stage"] = 99;
                File.WriteAllBytes(store.StatePath, JsonSerializer.SerializeToUtf8Bytes(document));
                var onDisk = File.ReadAllBytes(store.StatePath);
                var controller = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(controller.StorageError != null && !controller.BlocksEditing && controller.UnavailableReason == "storage" && !controller.CanCheck && !controller.CanRepairState &&
                    Directory.Exists(backup) && File.Exists(Path.Combine(backup, "manifest.json")) && File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk),
                    "Unknown enum with disk backup evidence (" + slot + ") keeps storage gate and preserves backup on disk without blocking editing");
                var reopened = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(!reopened.BlocksEditing && reopened.UnavailableReason == "storage" && Directory.Exists(backup) && File.Exists(Path.Combine(backup, "manifest.json")) &&
                    File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk),
                    "Reopening unknown enum with disk backup (" + slot + ") still preserves backup on disk without blocking editing");
            }
            {
                var recoveryRoot = Path.Combine(root, "RecoveryDir");
                var directory = Path.Combine(recoveryRoot, "Updates");
                var store = new UpdateStore(directory); Directory.CreateDirectory(directory);
                var recoveryEntry = Path.Combine(directory, "Recoveries", Guid.NewGuid().ToString("N"), "original", "Edits");
                Directory.CreateDirectory(recoveryEntry);
                var preservedEdit = Path.Combine(recoveryEntry, "photo.json");
                File.WriteAllText(preservedEdit, "newer edit");
                var saved = new UpdatePreferences { AutomaticCheck = true };
                var document = JsonNode.Parse(JsonSerializer.Serialize(saved))!.AsObject();
                document["PendingUpdate"]!["Choice"] = 99;
                File.WriteAllBytes(store.StatePath, JsonSerializer.SerializeToUtf8Bytes(document));
                var controller = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(controller.StorageError != null && !controller.BlocksEditing && controller.UnavailableReason == "storage" && !controller.CanRepairState && File.Exists(preservedEdit),
                    "Unknown enum with Recoveries entry keeps storage gate and prevents archiving recovery data without blocking editing");
                Directory.Delete(Path.Combine(directory, "Recoveries"), true);
                File.WriteAllText(Path.Combine(directory, "recovery-in-progress.json"), "journal");
                var interrupted = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(interrupted.StorageError != null && interrupted.BlocksEditing && !interrupted.CanRepairState,
                    "Unknown enum with recovery-in-progress journal keeps storage gate");
            }
            {
                // W2 复核 Finding 2 红测：已完成恢复的历史用户在非安装未知枚举下不得被永久锁死，过期 .staging-* 应按生命周期被回收。
                var histRoot = Path.Combine(root, "HistoricalRecovery");
                var directory = Path.Combine(histRoot, "Updates");
                var edits = Path.Combine(histRoot, "Edits"); Directory.CreateDirectory(edits);
                File.WriteAllText(Path.Combine(edits, "photo.json"), "{\"Exposure\":0.2}");
                var store = new UpdateStore(directory); Directory.CreateDirectory(directory);
                var backupMgr = new UpdateDataBackup(histRoot, directory);
                var backupDir = backupMgr.Create("0.8.2", "0.9.1", "14");
                File.WriteAllText(Path.Combine(edits, "photo.json"), "{\"Exposure\":0.9}");
                var receipt = backupMgr.Restore(backupDir);
                backupMgr.FinishRecovery(receipt);
                backupMgr.Discard(backupDir);
                var expiredStaging = Path.Combine(directory, "Backups", ".staging-" + Guid.NewGuid().ToString("N"));
                var freshStaging = Path.Combine(directory, "Backups", ".staging-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(expiredStaging); Directory.CreateDirectory(freshStaging);
                File.WriteAllText(Path.Combine(expiredStaging, "part.json"), "stale");
                File.WriteAllText(Path.Combine(freshStaging, "part.json"), "fresh");
                Directory.SetLastWriteTimeUtc(expiredStaging, DateTime.UtcNow.AddDays(-2));
                var saved = new UpdatePreferences { AutomaticCheck = true, RecoveryReceipt = receipt };
                var document = JsonNode.Parse(JsonSerializer.Serialize(saved))!.AsObject();
                document["PendingUpdate"]!["Choice"] = 99;
                File.WriteAllBytes(store.StatePath, JsonSerializer.SerializeToUtf8Bytes(document));
                var controller = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14");
                check(controller.StorageError == null && !controller.BlocksEditing && controller.CanCheck &&
                    Directory.Exists(receipt) && !Directory.Exists(expiredStaging) && Directory.Exists(freshStaging),
                    "Historical completed RecoveryReceipt and expired staging directory do not lock editing on non-installation unknown enum");
            }
            await Task.CompletedTask;
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
                check(reopened.StorageError != null && !reopened.BlocksEditing && reopened.UnavailableReason == "storage" && !reopened.CanCheck && !reopened.CanChooseInstall && !reopened.CanRepairState,
                    "Malformed installation failure degrades updates without blocking editing and blocks state reset: " + name);
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

            await controller.SetAutomaticCheckAsync(false);
            await controller.CheckAsync(true);
            check(controller.StorageError != null && !controller.BlocksEditing && !controller.CanRepairState &&
                controller.UnavailableReason == null && controller.CanCheck &&
                controller.Preferences.AutomaticCheck && controller.State.Phase == UpdatePhase.Idle && adapter.Checks == 0,
                "Runtime state save failure does not lock editing or permanently disable update retry");

            moveFault = null;
            await controller.SetAutomaticCheckAsync(false);
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
            check(!quitApproved && adapter.Installs == 1 && delays.SequenceEqual(new[] { 10, 50, 200 }) &&
                controller.StorageError != null && controller.State.Phase == UpdatePhase.Failed &&
                controller.State.Failure?.Stage == UpdatePhase.Installing && controller.State.Choice == UpdateInstallChoice.None &&
                controller.BlocksEditing && controller.RequiresRecovery && !controller.RequiresStartupHealthCheck &&
                !controller.CanCheck && !controller.CanDownload && !controller.CanChooseInstall && !controller.CanCancel,
                "Failed installer dispatch keeps the disk-phase Failed(Installing) gate in memory when persisting Fail() also fails");
            check(controller.State.BackupPath != null && Directory.Exists(controller.State.BackupPath) &&
                store.Load(true).PendingUpdate.Phase == UpdatePhase.Installing && await controller.PrepareForQuitAsync(),
                "The conservative double-failure gate preserves the backup, leaves disk on Installing, and still permits quitting afterwards");

            var storeR = CreateStore("r");
            var adapterR = new Adapter();
            var controllerR = new DesktopUpdateController(adapterR, new(), storeR, "0.8.2", "14", now: () => virtualNow);
            var restartR = false; controllerR.RestartRequested += () => restartR = true;
            await controllerR.CheckAsync(true);
            await controllerR.DownloadAsync();
            adapterR.RejectInstall = true;
            moveFault = bytes => SavedState(bytes) is { Phase: UpdatePhase.Failed, Failure: { Stage: UpdatePhase.ReadyToInstall } } ? SharingViolation() : null;
            ResetCounters();
            await controllerR.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(adapterR.Installs == 1 && !restartR && controllerR.StorageError != null &&
                controllerR.State.Failure?.Stage == UpdatePhase.Installing && controllerR.BlocksEditing && controllerR.RequiresRecovery &&
                controllerR.State.BackupPath != null && Directory.Exists(controllerR.State.BackupPath) &&
                storeR.Load(true).PendingUpdate.Phase == UpdatePhase.Installing && await controllerR.PrepareForQuitAsync(),
                "A RestartNow double failure keeps editing gated with memory and disk both on the Installing backup while quit stays reachable");
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

            var postReplaceDir = Path.Combine(root, "post-replace", "Updates");
            var postReplaceStore = new UpdateStore(
                postReplaceDir,
                (temporary, bytes) => { files[temporary] = bytes.ToArray(); },
                (source, destination) =>
                {
                    var bytes = files[source];
                    files[destination] = bytes;
                    files.Remove(source);
                    if (SavedState(bytes).Phase == UpdatePhase.Installing)
                        throw new IOException("Injected post-replace sync failure");
                },
                delay => { elapsed += delay; },
                () => elapsed,
                path => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null,
                path => { files.Remove(path); return true; });
            var postReplaceAdapter = new Adapter();
            var postReplaceController = new DesktopUpdateController(postReplaceAdapter, new(), postReplaceStore, "0.8.2", "14", now: () => virtualNow);
            await postReplaceController.CheckAsync(true);
            await postReplaceController.DownloadAsync();
            await postReplaceController.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(postReplaceAdapter.Installs == 0 && postReplaceController.StorageError != null &&
                postReplaceController.BlocksEditing && postReplaceController.UnavailableReason == "storage" &&
                !postReplaceController.CanCheck && !postReplaceController.CanDownload && !postReplaceController.CanChooseInstall &&
                postReplaceStore.Load(true).PendingUpdate.Phase == UpdatePhase.Installing &&
                await postReplaceController.PrepareForQuitAsync(),
                "Post-replace Installing save failure keeps editing locked while permitting normal quit");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }

    private static Task NonBlockingSerializedSaves(Action<bool, string> check) => RunOnDedicatedSerialUiContext(async () =>
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-nonblocking-" + Guid.NewGuid().ToString("N"));
        try
        {
            check(SynchronizationContext.Current is SerialSynchronizationContext && !Thread.CurrentThread.IsThreadPoolThread,
                "NonBlockingSerializedSaves runs on a dedicated single-threaded UI pump");
            var uiThreadId = Environment.CurrentManagedThreadId;
            var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            using var writeStarted = new ManualResetEventSlim(false);
            using var allowWriteFinish = new ManualResetEventSlim(true);
            var blockNextWrite = 0;
            var activeWrites = 0;
            var maxConcurrentWrites = 0;
            var writeThreadIds = new List<int>();
            var allOnThreadPool = true;
            var gateObj = new object();

            var store = new UpdateStore(
                Path.Combine(root, "Updates"),
                (temporary, bytes) =>
                {
                    var concurrent = Interlocked.Increment(ref activeWrites);
                    lock (gateObj)
                    {
                        if (concurrent > maxConcurrentWrites) maxConcurrentWrites = concurrent;
                        writeThreadIds.Add(Environment.CurrentManagedThreadId);
                        allOnThreadPool &= Thread.CurrentThread.IsThreadPoolThread;
                    }
                    try
                    {
                        if (Interlocked.Exchange(ref blockNextWrite, 0) == 1)
                        {
                            writeStarted.Set();
                            if (!allowWriteFinish.Wait(TimeSpan.FromSeconds(5)))
                                throw new TimeoutException("Timed out waiting for blocked UpdateStore write");
                        }
                        files[temporary] = bytes.ToArray();
                    }
                    finally
                    {
                        Interlocked.Decrement(ref activeWrites);
                    }
                },
                (source, destination) =>
                {
                    files[destination] = files[source];
                    files.Remove(source);
                },
                _ => { },
                () => TimeSpan.Zero,
                path => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null,
                path => { files.Remove(path); return true; });

            var adapter = new Adapter();
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");

            writeStarted.Reset();
            allowWriteFinish.Reset();
            Volatile.Write(ref blockNextWrite, 1);
            var saveTask = controller.SetAutomaticCheckAsync(false);
            check(writeStarted.Wait(TimeSpan.FromSeconds(5)), "UpdateStore write starts in background");

            var uiCallbackRanWhileBlocked = false;
            SynchronizationContext.Current!.Post(_ => uiCallbackRanWhileBlocked = true, null);
            await Task.Yield();
            check(uiCallbackRanWhileBlocked && !saveTask.IsCompleted,
                "UI SynchronizationContext continues pumping callbacks while UpdateStore write is blocked");

            allowWriteFinish.Set();
            await saveTask;
            check(!controller.Preferences.AutomaticCheck && !store.Load(true).AutomaticCheck,
                "Background UpdateStore save persists preferences cleanly");

            await controller.CheckAsync(true);
            writeStarted.Reset();
            allowWriteFinish.Reset();
            Volatile.Write(ref blockNextWrite, 1);
            var skipTask = controller.SkipAsync();
            check(writeStarted.Wait(TimeSpan.FromSeconds(5)), "SkipAsync write starts in background");
            var uiCallbackDuringSkip = false;
            SynchronizationContext.Current!.Post(_ => uiCallbackDuringSkip = true, null);
            await Task.Yield();
            check(uiCallbackDuringSkip && !skipTask.IsCompleted,
                "UI SynchronizationContext stays unblocked during SkipAsync persistence");
            allowWriteFinish.Set();
            await skipTask;
            check(controller.State.Phase == UpdatePhase.Idle && store.Load(true).SkippedVersion == adapter.Release.Identity,
                "SkipAsync persists skipped version on disk");

            check(maxConcurrentWrites == 1 && allOnThreadPool && writeThreadIds.All(id => id != uiThreadId),
                "All UpdateStore writes execute serially off the UI thread");

            var repairDir = Path.Combine(root, "RepairUpdates");
            Directory.CreateDirectory(repairDir);
            var repairStatePath = Path.Combine(repairDir, "state.json");
            File.WriteAllText(repairStatePath, "{broken");
            var repairStore = new UpdateStore(repairDir);
            var damaged = new DesktopUpdateController(adapter, new(), repairStore, "0.8.2", "14");
            check(damaged.CanRepairState, "Corrupt disk state is repairable");
            await damaged.RepairStateAsync();
            check(damaged.StorageError == null && damaged.RecoveryNeedsRestart && damaged.Preferences.StateRepairReceipt != null,
                "RepairStateAsync repairs state off UI thread and updates controller state");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    });

    private static Task ConcurrentPreferenceTogglePreservesInFlightSaveState(Action<bool, string> check) => RunOnDedicatedSerialUiContext(async () =>
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-concurrent-toggle-" + Guid.NewGuid().ToString("N"));
        using var allowSaveFinish = new ManualResetEventSlim(true);
        try
        {
            var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            UpdatePhase? phaseToBlock = null;
            var blockEverySave = false;
            TaskCompletionSource<bool>? saveBlocked = null;

            var store = new UpdateStore(
                Path.Combine(root, "Updates"),
                (temporary, bytes) =>
                {
                    var saved = JsonSerializer.Deserialize<UpdatePreferences>(bytes)!;
                    if (blockEverySave || phaseToBlock is { } target && saved.PendingUpdate.Phase == target)
                    {
                        phaseToBlock = null;
                        blockEverySave = false;
                        Volatile.Read(ref saveBlocked)?.TrySetResult(true);
                        if (!allowSaveFinish.Wait(TimeSpan.FromSeconds(5)))
                            throw new TimeoutException("Timed out waiting for blocked UpdateStore save");
                    }
                    files[temporary] = bytes.ToArray();
                },
                (source, destination) =>
                {
                    files[destination] = files[source];
                    files.Remove(source);
                },
                _ => { },
                () => TimeSpan.Zero,
                path => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null,
                path => { files.Remove(path); return true; });

            var adapter = new Adapter();
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14", automaticCheck: true);

            // (a1) Toggling AutomaticCheck while CheckAsync is blocked saving Available preserves both
            var availableSaveBlocked = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            Volatile.Write(ref saveBlocked, availableSaveBlocked);
            allowSaveFinish.Reset();
            phaseToBlock = UpdatePhase.Available;
            var checkTask = controller.CheckAsync(true);
            check(await availableSaveBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5)), "CheckAsync blocks inside Available store.Save");
            var toggleTask = controller.SetAutomaticCheckAsync(false);
            await Task.Yield();
            check(!checkTask.IsCompleted && !toggleTask.IsCompleted,
                "SetAutomaticCheckAsync waits on saveGate while Available save is in flight");
            allowSaveFinish.Set();
            await checkTask;
            await toggleTask;
            var persistedAfterCheck = store.Load(true);
            check(!controller.Preferences.AutomaticCheck && controller.State.Phase == UpdatePhase.Available &&
                !persistedAfterCheck.AutomaticCheck && persistedAfterCheck.PendingUpdate.Phase == UpdatePhase.Available,
                "Concurrent SetAutomaticCheckAsync(false) during Available save preserves both AutomaticCheck=false and Available");

            // (a2) Toggling AutomaticCheck while DownloadAsync is blocked saving PackageReady preserves both
            await controller.SetAutomaticCheckAsync(true);
            var packageReadySaveBlocked = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            Volatile.Write(ref saveBlocked, packageReadySaveBlocked);
            allowSaveFinish.Reset();
            phaseToBlock = UpdatePhase.PackageReady;
            var downloadTask = controller.DownloadAsync();
            check(await packageReadySaveBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5)), "DownloadAsync blocks inside PackageReady store.Save");
            var toggleDuringDownload = controller.SetAutomaticCheckAsync(false);
            await Task.Yield();
            check(!downloadTask.IsCompleted && !toggleDuringDownload.IsCompleted,
                "SetAutomaticCheckAsync waits on saveGate while PackageReady save is in flight");
            allowSaveFinish.Set();
            await downloadTask;
            await toggleDuringDownload;
            var persistedAfterDownload = store.Load(true);
            check(!controller.Preferences.AutomaticCheck && controller.State.Phase == UpdatePhase.PackageReady &&
                !persistedAfterDownload.AutomaticCheck && persistedAfterDownload.PendingUpdate.Phase == UpdatePhase.PackageReady,
                "Concurrent SetAutomaticCheckAsync(false) during PackageReady save preserves both AutomaticCheck=false and PackageReady");

            // (a3) Reverse order: CheckAsync starting while SetAutomaticCheckAsync(false) is blocked in store.Save
            files.Clear();
            var controller2 = new DesktopUpdateController(new Adapter(), new(), store, "0.8.2", "14", automaticCheck: true);
            var toggleSaveBlocked = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            Volatile.Write(ref saveBlocked, toggleSaveBlocked);
            allowSaveFinish.Reset();
            blockEverySave = true;
            var toggleFirst = controller2.SetAutomaticCheckAsync(false);
            check(await toggleSaveBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5)), "SetAutomaticCheckAsync blocks inside store.Save");
            var checkSecond = controller2.CheckAsync(true);
            await Task.Yield();
            allowSaveFinish.Set();
            await toggleFirst;
            await checkSecond;
            var persistedReverse = store.Load(true);
            check(!controller2.Preferences.AutomaticCheck && controller2.State.Phase == UpdatePhase.Available &&
                !persistedReverse.AutomaticCheck && persistedReverse.PendingUpdate.Phase == UpdatePhase.Available,
                "CheckAsync starting during SetAutomaticCheckAsync(false) save preserves both AutomaticCheck=false and Available");
        }
        finally { allowSaveFinish.Set(); if (Directory.Exists(root)) Directory.Delete(root, true); }
    });

    private static Task CancelDuringAvailableSaveDoesNotClobberState(Action<bool, string> check) => RunOnDedicatedSerialUiContext(async () =>
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-cancel-race-" + Guid.NewGuid().ToString("N"));
        using var allowSaveFinish = new ManualResetEventSlim(true);
        try
        {
            var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            UpdatePhase? phaseToBlock = null;
            var saveBlocked = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

            var store = new UpdateStore(
                Path.Combine(root, "Updates"),
                (temporary, bytes) =>
                {
                    var saved = JsonSerializer.Deserialize<UpdatePreferences>(bytes)!;
                    if (phaseToBlock is { } target && saved.PendingUpdate.Phase == target)
                    {
                        phaseToBlock = null;
                        saveBlocked.TrySetResult(true);
                        if (!allowSaveFinish.Wait(TimeSpan.FromSeconds(5)))
                            throw new TimeoutException("Timed out waiting for blocked UpdateStore save");
                    }
                    files[temporary] = bytes.ToArray();
                },
                (source, destination) =>
                {
                    files[destination] = files[source];
                    files.Remove(source);
                },
                _ => { },
                () => TimeSpan.Zero,
                path => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null,
                path => { files.Remove(path); return true; });

            var adapter = new Adapter();
            var controller = new DesktopUpdateController(adapter, new(), store, "0.8.2", "14");

            // (b1) CancelAsync during CheckAsync's Available SaveAsync must not clobber Available back to Idle
            allowSaveFinish.Reset();
            phaseToBlock = UpdatePhase.Available;
            var checkTask = controller.CheckAsync(true);
            check(await saveBlocked.Task.WaitAsync(TimeSpan.FromSeconds(5)), "CheckAsync blocks inside Available store.Save");
            var cancelTask = controller.CancelAsync();
            await Task.Yield();
            allowSaveFinish.Set();
            await checkTask;
            await cancelTask;
            var persisted = store.Load(true);
            check(controller.State.Phase == UpdatePhase.Available && controller.State.Release != null &&
                persisted.PendingUpdate.Phase == UpdatePhase.Available && persisted.PendingUpdate.Release != null,
                "CancelAsync called while Available save is in flight does not clobber Available back to Idle");

            // (b2) CancelAsync during adapter.CheckAsync does not get clobbered if adapter completes concurrently
            files.Clear();
            var raceAdapter = new Adapter { PendingCheck = new(TaskCreationOptions.RunContinuationsAsynchronously) };
            var raceController = new DesktopUpdateController(raceAdapter, new(), store, "0.8.2", "14");
            var racingCheck = raceController.CheckAsync(true);
            await raceController.FlushSavesAsync();
            check(raceController.State.Phase == UpdatePhase.Checking && raceController.CanCancel,
                "In-flight CheckAsync enters Checking state before adapter completes");
            var racingCancel = raceController.CancelAsync();
            raceAdapter.PendingCheck.TrySetResult(raceAdapter.Release);
            await racingCheck;
            await racingCancel;
            var persistedRace = store.Load(true);
            check(raceController.State.Phase == UpdatePhase.Idle && persistedRace.PendingUpdate.Phase == UpdatePhase.Idle,
                "CancelAsync during Checking keeps Idle consistently when adapter result races with cancellation");
        }
        finally { allowSaveFinish.Set(); if (Directory.Exists(root)) Directory.Delete(root, true); }
    });
}
