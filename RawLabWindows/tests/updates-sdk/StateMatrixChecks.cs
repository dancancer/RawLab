using System.Net;
using System.Security.Cryptography;
using RawLab.Windows;

internal static class StateMatrixChecks
{
    private sealed class MatrixAdapter : IDesktopUpdateAdapter
    {
        public string? UnavailableReason => null;
        public UpdateDescriptor Release { get; set; } = new("0.9.1", "19", "windows", "x64", "stable",
            "https://updates.example.invalid/RawLab-0.9.1.nupkg", 1024, new string('a', 64), "Matrix test release");
        public Exception? CheckError { get; set; }
        public Exception? DownloadError { get; set; }
        public Exception? VerifyError { get; set; }
        public Exception? PreDispatchInstallError { get; set; }
        public Exception? InstallError { get; set; }
        public Action<ReleaseAdapterState>? OnCheck { get; set; }
        public Action? OnInstall { get; set; }
        public int Checks { get; private set; }
        public int Downloads { get; private set; }
        public int Installs { get; private set; }

        public Task ValidateHostTrustAsync() => Task.CompletedTask;

        public Task<UpdateDescriptor?> CheckAsync(CancellationToken cancellationToken)
        {
            Checks++;
            cancellationToken.ThrowIfCancellationRequested();
            if (CheckError != null) throw CheckError;
            return Task.FromResult<UpdateDescriptor?>(Release);
        }

        public Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken cancellationToken)
        {
            Downloads++;
            progress(50);
            cancellationToken.ThrowIfCancellationRequested();
            if (DownloadError != null) throw DownloadError;
            progress(100);
            return Task.CompletedTask;
        }

        public Task VerifyAsync(UpdateDescriptor release, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (VerifyError != null) throw VerifyError;
            return Task.CompletedTask;
        }

        public void VerifyBeforeInstall(UpdateDescriptor release)
        {
            if (PreDispatchInstallError != null) throw PreDispatchInstallError;
        }

        public void Install(UpdateDescriptor release, bool restart)
        {
            Installs++;
            OnInstall?.Invoke();
            if (InstallError != null) throw InstallError;
        }
    }

    private sealed record ReleaseAdapterState;

    private sealed record LaunchMatrixRow(
        UpdatePhase InitialPhase,
        string? InitialFailureCode,
        UpdatePhase? InitialFailureStage,
        string LaunchVersion,
        string LaunchBuild,
        bool Trusted,
        UpdatePhase ExpectedPhase,
        UpdatePhase? ExpectedFailureStage,
        string? ExpectedFailureCode,
        bool ExpectedStartupHealthCheck,
        bool ExpectedRecovery,
        bool ExpectedRejected,
        bool ExpectedAutoRetry);

    private static UpdateDescriptor SampleRelease => new("0.9.1", "19", "windows", "x64", "stable",
        "https://updates.example.invalid/RawLab-0.9.1.nupkg", 1024, new string('b', 64), "Notes");

    private static UpdatePreferences BuildStateInPhase(UpdatePhase phase, UpdatePhase? failureStage = null, string? failureCode = null)
    {
        var prefs = new UpdatePreferences { AutomaticCheck = true };
        var state = prefs.PendingUpdate;
        var release = SampleRelease;
        switch (phase)
        {
            case UpdatePhase.Idle:
                return prefs;
            case UpdatePhase.Checking:
                state.BeginCheck();
                return prefs;
            case UpdatePhase.Available:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                return prefs;
            }
            case UpdatePhase.Downloading:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                state.BeginDownload();
                return prefs;
            }
            case UpdatePhase.Verifying:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                var d = state.BeginDownload()!.Value;
                state.Preparing(d);
                return prefs;
            }
            case UpdatePhase.PackageReady:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                var d = state.BeginDownload()!.Value;
                state.Preparing(d);
                state.Verified(d);
                return prefs;
            }
            case UpdatePhase.WaitingForTasks:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                var d = state.BeginDownload()!.Value;
                state.Preparing(d);
                state.Verified(d);
                state.Choose(UpdateInstallChoice.AfterTasks);
                state.Admit(["draft"]);
                return prefs;
            }
            case UpdatePhase.ReadyToInstall:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                var d = state.BeginDownload()!.Value;
                state.Preparing(d);
                state.Verified(d);
                state.Choose(UpdateInstallChoice.RestartNow);
                state.Admit([]);
                return prefs;
            }
            case UpdatePhase.Installing:
            case UpdatePhase.PendingRestart:
            case UpdatePhase.Complete:
            {
                var t = state.BeginCheck();
                state.Found(release, t);
                var d = state.BeginDownload()!.Value;
                state.Preparing(d);
                state.Verified(d);
                state.Choose(UpdateInstallChoice.RestartNow);
                state.Admit([]);
                state.Installing(d);
                if (phase is UpdatePhase.PendingRestart or UpdatePhase.Complete) state.AwaitingRestart(d);
                if (phase == UpdatePhase.Complete) state.RestoreAfterLaunch(release.Version, release.Build, true);
                return prefs;
            }
            case UpdatePhase.Failed:
            {
                var stage = failureStage ?? UpdatePhase.Checking;
                var seed = BuildStateInPhase(stage);
                var s = seed.PendingUpdate;
                s.Fail(stage, failureCode ?? "operation", "injected", s.Attempt);
                return seed;
            }
            default:
                throw new ArgumentOutOfRangeException(nameof(phase));
        }
    }

    internal static async Task Run(Action<bool, string> check)
    {
        await RunStateMatrix_P1_24(check);
        await NonCheckingFailureRecoveryChecks_P1_06(check);
        await DeferredQuitTimerThrottleChecks_P1_07(check);
    }

    internal static Task RunOnly(string ticket, Action<bool, string> check) => ticket switch
    {
        "P1-24" => RunStateMatrix_P1_24(check),
        "P1-06" => NonCheckingFailureRecoveryChecks_P1_06(check),
        "P1-07" => DeferredQuitTimerThrottleChecks_P1_07(check),
        _ => throw new ArgumentException("Unknown ticket: " + ticket)
    };

    // P1-24: Table-driven matrix across UpdatePhase x Failure.Stage x Crash/Restart/Rollback
    private static async Task RunStateMatrix_P1_24(Action<bool, string> check)
    {
        var launchMatrix = new LaunchMatrixRow[]
        {
            new(UpdatePhase.Idle, null, null, "0.8.2", "14", false,
                UpdatePhase.Idle, null, null, false, false, false, false),
            new(UpdatePhase.Checking, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Checking, "interrupted", false, false, false, true),
            new(UpdatePhase.Available, null, null, "0.8.2", "14", false,
                UpdatePhase.Available, null, null, false, false, false, false),
            new(UpdatePhase.Downloading, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Downloading, "interrupted", false, false, false, true),
            new(UpdatePhase.Verifying, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Verifying, "interrupted", false, false, false, true),
            new(UpdatePhase.PackageReady, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.PackageReady, "interrupted", false, false, false, true),
            new(UpdatePhase.WaitingForTasks, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.WaitingForTasks, "interrupted", false, false, false, true),
            new(UpdatePhase.ReadyToInstall, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.ReadyToInstall, "interrupted", false, false, false, true),
            new(UpdatePhase.Installing, null, null, "0.9.1", "19", true,
                UpdatePhase.Complete, null, null, false, false, false, false),
            new(UpdatePhase.Installing, null, null, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Installing, "interrupted", false, true, false, false),
            new(UpdatePhase.PendingRestart, null, null, "0.9.1", "19", true,
                UpdatePhase.Complete, null, null, false, false, false, false),
            new(UpdatePhase.PendingRestart, null, null, "0.9.1", "19", false,
                UpdatePhase.Failed, UpdatePhase.PendingRestart, "interrupted", false, true, false, false),
            new(UpdatePhase.Complete, null, null, "0.9.1", "19", true,
                UpdatePhase.Complete, null, null, false, false, false, false),
            new(UpdatePhase.Failed, "network", UpdatePhase.Checking, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Checking, "network", false, false, false, true),
            new(UpdatePhase.Failed, "operation", UpdatePhase.Downloading, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Downloading, "operation", false, false, false, true),
            new(UpdatePhase.Failed, "trust_temporary", UpdatePhase.Verifying, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Verifying, "trust_temporary", false, false, false, true),
            new(UpdatePhase.Failed, "interrupted", UpdatePhase.Verifying, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Verifying, "interrupted", false, false, false, true),
            new(UpdatePhase.Failed, "signature", UpdatePhase.Verifying, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Verifying, "signature", false, false, true, false),
            new(UpdatePhase.Failed, "operation", UpdatePhase.ReadyToInstall, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.ReadyToInstall, "operation", false, false, false, true),
            new(UpdatePhase.Failed, "operation", UpdatePhase.Installing, "0.8.2", "14", false,
                UpdatePhase.Failed, UpdatePhase.Installing, "operation", false, true, false, false),
        };

        var root = Path.Combine(Path.GetTempPath(), "rawlab-matrix-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var row in launchMatrix)
            {
                var label = $"P1-24 matrix [{row.InitialPhase}/{row.InitialFailureStage}/{row.InitialFailureCode}@{row.LaunchVersion}]";
                var prefs = BuildStateInPhase(row.InitialPhase, row.InitialFailureStage, row.InitialFailureCode);
                var state = prefs.PendingUpdate;
                state.RestoreAfterLaunch(row.LaunchVersion, row.LaunchBuild, row.Trusted);

                var rejected = state.Failure != null && UpdatePresentation.IsRejected(state.Failure);
                var recovery = state.Failure?.Stage is UpdatePhase.Installing or UpdatePhase.PendingRestart;
                var startupHealth = state.Phase is UpdatePhase.Installing or UpdatePhase.PendingRestart;
                var failureHeading = state.Failure != null ? UpdatePresentation.FailureHeading(state.Failure, recovery) : null;
                var notice = UpdatePresentation.MainWindowNotice(prefs, null, null);
                var expectedNoticeVisible = row.ExpectedPhase is UpdatePhase.Available or UpdatePhase.Failed ||
                    row.ExpectedPhase == UpdatePhase.Idle && prefs.CheckFailure != null;

                check(state.Phase == row.ExpectedPhase &&
                    state.Failure?.Stage == row.ExpectedFailureStage &&
                    state.Failure?.Code == row.ExpectedFailureCode &&
                    startupHealth == row.ExpectedStartupHealthCheck &&
                    recovery == row.ExpectedRecovery &&
                    rejected == row.ExpectedRejected &&
                    notice.Visible == expectedNoticeVisible &&
                    (row.ExpectedPhase == UpdatePhase.Failed ? notice.HasFailure && notice.ReleaseVersion == null : true) &&
                    (row.ExpectedRejected ? failureHeading == "更新包未通过验证，已拒绝" :
                     row.ExpectedRecovery ? failureHeading == "更新未完成，请查看恢复说明" :
                     failureHeading == null),
                    label + " transition & classification");

                // Verify persisted controller restart & auto-retry cell
                var cellDir = Path.Combine(root, Guid.NewGuid().ToString("N"));
                var store = new UpdateStore(cellDir);
                var now = new DateTimeOffset(2026, 11, 14, 12, 0, 0, TimeSpan.Zero);
                var initial = BuildStateInPhase(row.InitialPhase, row.InitialFailureStage, row.InitialFailureCode);
                if (row.InitialPhase is not (UpdatePhase.Installing or UpdatePhase.PendingRestart or UpdatePhase.Complete))
                {
                    if (row.InitialFailureStage == UpdatePhase.Checking || row.ExpectedPhase == UpdatePhase.Failed)
                        prefs.LastCheck = now;
                    initial.LastCheck = now;
                    if (row.ExpectedFailureCode is not null and not "interrupted" && row.ExpectedAutoRetry)
                        initial.CheckFailure = new(now, row.ExpectedFailureCode, 1, "seeded");
                }
                else if (row.InitialPhase is UpdatePhase.Installing or UpdatePhase.PendingRestart)
                {
                    var backupDir = new UpdateDataBackup(cellDir, store.DirectoryPath).Create("0.8.2", "0.9.1", "14");
                    initial.PendingUpdate.BackupPath = backupDir;
                    initial.PendingUpdate.PreviousVersion = "0.8.2";
                    initial.PendingUpdate.PreviousBuild = "14";
                }
                else if (row.InitialPhase == UpdatePhase.Failed && row.InitialFailureStage == UpdatePhase.Installing)
                {
                    var backupDir = new UpdateDataBackup(cellDir, store.DirectoryPath).Create("0.8.2", "0.9.1", "14");
                    initial.PendingUpdate.BackupPath = backupDir;
                    initial.PendingUpdate.PreviousVersion = "0.8.2";
                    initial.PendingUpdate.PreviousBuild = "14";
                }
                store.Save(initial);

                if (row.InitialPhase is not (UpdatePhase.Installing or UpdatePhase.PendingRestart))
                {
                    var adapter = new MatrixAdapter();
                    var controller = new DesktopUpdateController(adapter, new(), store, row.LaunchVersion, row.LaunchBuild, true, () => now);
                    check(controller.State.Phase == row.ExpectedPhase &&
                        controller.State.Failure?.Stage == row.ExpectedFailureStage &&
                        controller.State.Failure?.Code == row.ExpectedFailureCode &&
                        controller.BlocksEditing == row.ExpectedRecovery &&
                        controller.RequiresRecovery == row.ExpectedRecovery,
                        label + " controller reload");

                    // Advance past backoff + daily window to confirm retry vs hold policy
                    now = now.AddDays(1).AddMinutes(1);
                    await controller.RefreshGateAsync();
                    var didRetry = adapter.Checks > 0;
                    check(didRetry == row.ExpectedAutoRetry,
                        label + $" auto-retry={didRetry} (expected {row.ExpectedAutoRetry})");
                }
            }

            // Explicit stale-token guard check across every failable phase
            foreach (var phase in new[] { UpdatePhase.Checking, UpdatePhase.Downloading, UpdatePhase.Verifying, UpdatePhase.ReadyToInstall, UpdatePhase.Installing })
            {
                var prefs = BuildStateInPhase(phase);
                var staleToken = Guid.NewGuid();
                check(!prefs.PendingUpdate.Fail(phase, "operation", "stale", staleToken) && prefs.PendingUpdate.Phase == phase,
                    $"P1-24 matrix guard: stale Attempt token rejected in {phase}");
            }

            // Terminal phases ignore late Failure calls even with matching Attempt
            foreach (var terminal in new[] { UpdatePhase.Idle, UpdatePhase.Available, UpdatePhase.Complete, UpdatePhase.Failed })
            {
                var prefs = BuildStateInPhase(terminal);
                var currentToken = prefs.PendingUpdate.Attempt;
                check(!prefs.PendingUpdate.Fail(UpdatePhase.Checking, "operation", "late", currentToken) && prefs.PendingUpdate.Phase == terminal,
                    $"P1-24 matrix guard: terminal/non-executing phase {terminal} refuses Fail transition");
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    // P1-06: Non-Checking failures record backoff, keep editing unlocked, auto-retry on RefreshGateAsync after backoff,
    // fix IsRejected("interrupted"), and verify post-restart recovery without permanent lock.
    private static async Task NonCheckingFailureRecoveryChecks_P1_06(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-p1-06-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = new DateTimeOffset(2026, 11, 14, 15, 0, 0, TimeSpan.Zero);

            // 1. Downloading failure -> backoff -> auto recovery after 15m -> survives restart too
            var dlStore = new UpdateStore(Path.Combine(root, "download-fail"));
            var dlAdapter = new MatrixAdapter { DownloadError = new HttpRequestException("connection reset") };
            var dlController = new DesktopUpdateController(dlAdapter, new(), dlStore, "0.8.2", "14", true, () => now);
            await dlController.CheckAsync(true);
            await dlController.DownloadAsync();
            check(dlController.State.Phase == UpdatePhase.Failed &&
                dlController.State.Failure?.Stage == UpdatePhase.Downloading &&
                !dlController.BlocksEditing &&
                !dlController.RequiresRecovery &&
                dlController.CheckFailure != null,
                "P1-06 Downloading failure leaves editor unlocked and records retry backoff");

            // Within 15m backoff: RefreshGateAsync must NOT hammer server
            now = now.AddMinutes(14).AddSeconds(59);
            await dlController.RefreshGateAsync();
            check(dlAdapter.Checks == 1, "P1-06 Downloading failure respects 15m backoff before auto-retry");

            // Restart into persisted Downloading failure -> at 15m RefreshGateAsync automatically recovers
            dlAdapter.DownloadError = null;
            var reopenedDl = new DesktopUpdateController(dlAdapter, new(), dlStore, "0.8.2", "14", false /* keep automaticCheck from disk */, () => now);
            now = now.AddSeconds(1);
            await reopenedDl.RefreshGateAsync();
            check(dlAdapter.Checks == 2 && reopenedDl.State.Phase == UpdatePhase.Available,
                "P1-06 Persisted Downloading failure auto-retries after backoff on RefreshGateAsync and clears Failed state");

            // 2. Crash-interrupted Verifying -> NOT classified as signature/package rejection; auto-recovers after backoff
            var verifyCrashStore = new UpdateStore(Path.Combine(root, "verify-crash"));
            var crashedVerify = BuildStateInPhase(UpdatePhase.Verifying);
            crashedVerify.LastCheck = now;
            verifyCrashStore.Save(crashedVerify);
            var verifyCrashAdapter = new MatrixAdapter();
            var crashedController = new DesktopUpdateController(verifyCrashAdapter, new(), verifyCrashStore, "0.8.2", "14", true, () => now);
            check(crashedController.State.Phase == UpdatePhase.Failed &&
                crashedController.State.Failure is { Stage: UpdatePhase.Verifying, Code: "interrupted" } &&
                !UpdatePresentation.IsRejected(crashedController.State.Failure!) &&
                UpdatePresentation.FailureHeading(crashedController.State.Failure!, crashedController.RequiresRecovery) == null &&
                crashedController.CheckFailure != null,
                "P1-06 Crash-interrupted Verifying is not misclassified as rejected and arms retry backoff");

            now = now.AddMinutes(14).AddSeconds(59);
            await crashedController.RefreshGateAsync();
            check(verifyCrashAdapter.Checks == 0, "P1-06 Crash-interrupted Verifying waits out initial backoff");
            now = now.AddSeconds(1);
            await crashedController.RefreshGateAsync();
            check(verifyCrashAdapter.Checks == 1 && crashedController.State.Phase == UpdatePhase.Available,
                "P1-06 Crash-interrupted Verifying auto-recovers once backoff expires");

            // 3. ReadyToInstall pre-dispatch failure -> auto-retries after backoff
            var readyStore = new UpdateStore(Path.Combine(root, "ready-fail"));
            var readyAdapter = new MatrixAdapter { InstallError = new InvalidOperationException("Update.exe missing") };
            var readyController = new DesktopUpdateController(readyAdapter, new(), readyStore, "0.8.2", "14", true, () => now);
            await readyController.CheckAsync(true);
            await readyController.DownloadAsync();
            await readyController.ChooseAsync(UpdateInstallChoice.RestartNow);
            check(readyController.State.Phase == UpdatePhase.Failed &&
                readyController.State.Failure?.Stage == UpdatePhase.ReadyToInstall &&
                readyController.CheckFailure != null,
                "P1-06 Pre-dispatch ReadyToInstall failure records retry backoff");
            readyAdapter.InstallError = null;
            now = now.AddMinutes(15);
            await readyController.RefreshGateAsync();
            check(readyAdapter.Checks == 2 && readyController.State.Phase == UpdatePhase.Available,
                "P1-06 Pre-dispatch ReadyToInstall failure auto-retries after backoff");

            // 4. Temporary revocation trust_temporary also respects 15m backoff rather than waiting 24h or spinning every 1s
            var trustStore = new UpdateStore(Path.Combine(root, "trust-temp"));
            var trustAdapter = new MatrixAdapter { VerifyError = new TemporaryUpdateTrustException("OCSP timeout") };
            var trustController = new DesktopUpdateController(trustAdapter, new(), trustStore, "0.8.2", "14", true, () => now);
            await trustController.CheckAsync(true);
            await trustController.DownloadAsync();
            check(trustController.State.Phase == UpdatePhase.Failed &&
                trustController.State.Failure is { Stage: UpdatePhase.Verifying, Code: "trust_temporary" } &&
                trustController.CheckFailure != null,
                "P1-06 trust_temporary records retry backoff");
            now = now.AddMinutes(14).AddSeconds(59);
            await trustController.RefreshGateAsync();
            check(trustAdapter.Checks == 1, "P1-06 trust_temporary does not spin before 15m backoff");
            trustAdapter.VerifyError = null;
            now = now.AddSeconds(1);
            await trustController.RefreshGateAsync();
            check(trustAdapter.Checks == 2 && trustController.State.Phase == UpdatePhase.Available,
                "P1-06 trust_temporary recovers automatically after 15m backoff");

            // 5. MainWindow notice surfaces EVERY Failed stage plus Idle+CheckFailure (never silently collapsed)
            foreach (var stage in new[] {
                UpdatePhase.Checking, UpdatePhase.Downloading, UpdatePhase.Verifying,
                UpdatePhase.PackageReady, UpdatePhase.WaitingForTasks, UpdatePhase.ReadyToInstall,
                UpdatePhase.Installing, UpdatePhase.PendingRestart })
            {
                var failedPrefs = BuildStateInPhase(UpdatePhase.Failed, stage, stage == UpdatePhase.Verifying ? "interrupted" : "operation");
                var banner = UpdatePresentation.MainWindowNotice(failedPrefs, null, null);
                check(banner.Visible && banner.HasFailure && banner.ReleaseVersion == null,
                    $"P1-06 MainWindow notice surfaces failure for stage {stage}");
            }
            var idleWithCheckFailure = new UpdatePreferences { CheckFailure = new(now, "network", 1, "offline") };
            var idleBanner = UpdatePresentation.MainWindowNotice(idleWithCheckFailure, null, null);
            check(idleBanner.Visible && idleBanner.HasFailure && idleBanner.ReleaseVersion == null,
                "P1-06 MainWindow notice surfaces Idle + CheckFailure");
            var cleanIdleBanner = UpdatePresentation.MainWindowNotice(new UpdatePreferences(), null, null);
            check(!cleanIdleBanner.Visible && !cleanIdleBanner.HasFailure,
                "P1-06 MainWindow notice stays collapsed when Idle without CheckFailure");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    // P1-07: RefreshGateAsync on 1-second timer with Available + DeferredQuitChoice must throttle within 24h
    // and never call CheckAsync(true) on every 1s tick.
    private static async Task DeferredQuitTimerThrottleChecks_P1_07(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-p1-07-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = new DateTimeOffset(2026, 11, 14, 16, 0, 0, TimeSpan.Zero);

            // Scenario A: Same session — user chose OnQuit, quit blocked by Draft -> Available + OnQuit, LastCheck == now.
            // Fake clock advances 1s/tick for 60s calling RefreshGateAsync() each second: must perform 0 redundant checks.
            var sameSessionStore = new UpdateStore(Path.Combine(root, "same-session"));
            var sameGate = new UpdateInstallGate();
            var owner = new object();
            var draft = true;
            sameGate.Register(owner, () => new(Draft: draft), () => true);
            var sameAdapter = new MatrixAdapter();
            var sameController = new DesktopUpdateController(sameAdapter, sameGate, sameSessionStore, "0.8.2", "14", true, () => now);
            await sameController.CheckAsync(true);
            await sameController.DownloadAsync();
            await sameController.ChooseAsync(UpdateInstallChoice.OnQuit);
            check(await sameController.PrepareForQuitAsync() &&
                sameController.State.Phase == UpdatePhase.Available &&
                sameController.State.Choice == UpdateInstallChoice.OnQuit &&
                sameAdapter.Checks == 1,
                "P1-07 Setup: blocked OnQuit quit preserves Available + OnQuit with 1 initial check");

            for (var s = 1; s <= 60; s++)
            {
                now = now.AddSeconds(1);
                await sameController.RefreshGateAsync();
            }
            check(sameAdapter.Checks <= 1,
                $"P1-07 Same-session 60x1s RefreshGateAsync ticks must throttle (actual Checks={sameAdapter.Checks})");

            // Scenario B: Reopened session with Available + OnQuit where download is cancelled/reverted back to Available:
            // advancing 60 ticks of 1s must invoke adapter CheckAsync at most once total.
            var reopenAdapter = new MatrixAdapter { DownloadError = new OperationCanceledException() };
            var reopened = new DesktopUpdateController(reopenAdapter, sameGate, sameSessionStore, "0.8.2", "14", true, () => now);
            for (var s = 1; s <= 60; s++)
            {
                now = now.AddSeconds(1);
                await reopened.RefreshGateAsync();
            }
            check(reopenAdapter.Checks <= 1,
                $"P1-07 Reopened 60x1s RefreshGateAsync ticks with Available must call CheckAsync at most once (actual Checks={reopenAdapter.Checks})");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
