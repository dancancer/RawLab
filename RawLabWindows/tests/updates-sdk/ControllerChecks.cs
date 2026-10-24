using RawLab.Windows;

internal static class ControllerChecks
{
    private sealed class Adapter : IDesktopUpdateAdapter
    {
        public string? UnavailableReason => null;
        public UpdateDescriptor Release = new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes");
        public int Checks, Downloads, Installs;
        public bool RejectSignature;
        public Task<UpdateDescriptor?> CheckAsync(CancellationToken token) { Checks++; return Task.FromResult<UpdateDescriptor?>(Release); }
        public Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token) { Downloads++; progress(75); return Task.CompletedTask; }
        public Task VerifyAsync(UpdateDescriptor release, CancellationToken token) => RejectSignature ? Task.FromException(new Exception("Rejected signature")) : Task.CompletedTask;
        public void Install(UpdateDescriptor release, bool restart) { Installs++; }
    }
    internal static async Task Run(Action<bool, string> check)
    {
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
            check(later.State.Phase == UpdatePhase.Failed && later.State.Failure?.Stage == UpdatePhase.Verifying, "Signature rejection remains a verification failure");
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
            later.FinishStartupHealthCheck(true);
            check(later.State.Phase == UpdatePhase.Failed && later.RecoveryError != null, "Corrupt backup routes first boot to recovery instead of crashing");
            File.WriteAllText(manifestPath, validManifest);
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
}
