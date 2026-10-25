using System.ComponentModel;
using System.IO;

namespace RawLab.Windows;

public sealed class DesktopUpdateController : INotifyPropertyChanged
{
    private UpdatePreferences preferences;
    private readonly IDesktopUpdateAdapter adapter;
    private readonly UpdateInstallGate gate;
    private readonly UpdateStore store;
    private readonly UpdateDataBackup backup;
    private readonly Func<DateTimeOffset> now;
    private readonly string currentVersion, currentBuild;
    private CancellationTokenSource? operation;
    private bool automaticDownload;
    private readonly bool recoveryStartup;
    private byte[]? repairSnapshot;
    private bool repairHealthFailed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? RestartRequested;
    public UpdatePreferences Preferences => preferences;
    public UpdateTaskState State => preferences.PendingUpdate;
    public UpdateInstallGate Gate => gate;
    public string CurrentVersion => currentVersion;
    public string? StorageError { get; private set; }
    public bool PreparingInstallation { get; private set; }
    public bool Recovering { get; private set; }
    public bool RecoveryNeedsRestart { get; private set; }
    public string? RecoveryError { get; private set; }
    public string? UnavailableReason => StorageError != null ? "storage" : adapter.UnavailableReason;
    public bool CanCheck => UnavailableReason == null && operation == null && !PreparingInstallation && !RequiresStartupHealthCheck && !RequiresRecovery;
    public bool CanDownload => UnavailableReason == null && State.Phase == UpdatePhase.Available;
    public bool CanCancel => State.Phase is UpdatePhase.Checking or UpdatePhase.Downloading or UpdatePhase.Verifying or
        UpdatePhase.PackageReady or UpdatePhase.WaitingForTasks or UpdatePhase.ReadyToInstall && !PreparingInstallation;
    public bool CanChooseInstall => UnavailableReason == null && State.Prepared && !PreparingInstallation;
    public bool RequiresStartupHealthCheck => preferences.StateRepairReceipt != null || State.Phase is UpdatePhase.Installing or UpdatePhase.PendingRestart;
    public bool RequiresRecovery => backup.HasPendingRecovery || Recovering || RecoveryNeedsRestart || repairHealthFailed || State.Failure?.Stage is UpdatePhase.Installing or UpdatePhase.PendingRestart;
    public bool CanRepairState => StorageError != null && repairSnapshot != null && !RecoveryNeedsRestart;
    public string? StateArchive => preferences.StateRepairReceipt is {} receipt ? store.RepairedStateArchive(receipt) : null;
    public bool CanRestorePreviousData => recoveryStartup && RequiresRecovery && !Recovering && !RecoveryNeedsRestart && StorageError == null &&
        adapter.UnavailableReason == null && State.PreviousVersion == currentVersion && State.PreviousBuild == currentBuild && State.BackupPath != null;

    public DesktopUpdateController(IDesktopUpdateAdapter adapter, UpdateInstallGate gate, UpdateStore store, string currentVersion, string currentBuild,
        bool automaticCheck = true, Func<DateTimeOffset>? now = null)
    {
        this.adapter = adapter; this.gate = gate; this.store = store; this.currentVersion = currentVersion; this.currentBuild = currentBuild;
        this.now = now ?? (() => DateTimeOffset.UtcNow); backup = new(Path.GetDirectoryName(store.DirectoryPath)!, store.DirectoryPath);
        try { preferences = store.Load(automaticCheck); }
        catch (Exception error) { preferences = new(); StorageError = error.Message; try { repairSnapshot = store.RepairableState(); } catch { } }
        if (StorageError == null && backup.HasPendingRecovery && preferences.RecoveryReceipt is {} receipt)
        {
            try { backup.FinishRecovery(receipt); } catch (Exception error) { RecoveryError = error.Message; }
        }
        recoveryStartup = RequiresStartupHealthCheck || RequiresRecovery;
        if (StorageError == null && !RequiresStartupHealthCheck)
        {
            var next = preferences.Copy(); next.PendingUpdate.RestoreAfterLaunch(currentVersion, currentBuild, false);
            if (next.PendingUpdate.Phase != State.Phase) Save(next);
        }
    }
    public void RepairState()
    {
        if (!CanRepairState || repairSnapshot == null) return;
        try
        {
            preferences = store.RepairState(repairSnapshot); StorageError = null; repairSnapshot = null; RecoveryNeedsRestart = true;
        }
        catch (Exception error) { StorageError = error.Message; repairSnapshot = null; try { repairSnapshot = store.RepairableState(); } catch { } }
        Notify();
    }
    public async Task RestorePreviousDataAsync()
    {
        if (!CanRestorePreviousData || State.BackupPath is not {} path) return;
        Recovering = true; RecoveryError = null; Notify();
        try
        {
            var target = State.Release?.Version;
            var receipt = await Task.Run(() => {
                var manifest = backup.Verify(path);
                if (manifest.PreviousVersion != currentVersion || manifest.PreviousBuild != currentBuild || manifest.TargetVersion != target)
                    throw new InvalidDataException("Backup does not match this trusted version");
                return backup.Restore(path);
            });
            var next = preferences.Copy(); next.SkippedVersion = State.Release?.Identity;
            next.AutomaticInstall = false; next.PendingUpdate = new(); next.RecoveryReceipt = receipt;
            RecoveryNeedsRestart = true;
            if (Save(next)) backup.FinishRecovery(receipt);
        }
        catch (Exception error) { RecoveryError = error.Message; }
        finally { Recovering = false; Notify(); }
    }
    public void FinishStartupHealthCheck(bool healthy)
    {
        if (!RequiresStartupHealthCheck || backup.HasPendingRecovery || RecoveryNeedsRestart) return;
        if (preferences.StateRepairReceipt != null)
        {
            if (!healthy) { repairHealthFailed = true; RecoveryError = "User data failed startup validation"; Notify(); return; }
            var repaired = preferences.Copy(); repaired.StateRepairReceipt = null; Save(repaired); return;
        }
        var backupValid=false;
        try {
            if(State.BackupPath is {} path) {var manifest=backup.Verify(path);backupValid=manifest.TargetVersion==State.Release?.Version && manifest.PreviousVersion==State.PreviousVersion && manifest.PreviousBuild==State.PreviousBuild;}
        } catch(Exception error) { RecoveryError = error.Message; }
        var next = preferences.Copy(); next.PendingUpdate.RestoreAfterLaunch(currentVersion, currentBuild, healthy && backupValid && adapter.UnavailableReason == null); Save(next);
    }
    public void SetAutomaticCheck(bool value) {
        if (StorageError != null || RequiresStartupHealthCheck || RequiresRecovery) return;
        var next = preferences.Copy(); next.AutomaticCheck = value; Save(next);
    }
    public void SetAutomaticInstall(bool value)
    {
        if (StorageError != null || RequiresStartupHealthCheck || RequiresRecovery) return;
        if (value && UnavailableReason != null) return;
        var next = preferences.Copy(); next.AutomaticInstall = value;
        var revoke = !value && (automaticDownload || State.Choice == UpdateInstallChoice.AutomaticOnQuit);
        if (revoke) next.PendingUpdate.Cancel();
        if (Save(next) && revoke) { automaticDownload = false; operation?.Cancel(); }
    }
    public async Task CheckAsync(bool manual, bool retryDownload = false)
    {
        if (!CanCheck) return;
        if (!manual && (!preferences.AutomaticCheck || State.Phase == UpdatePhase.Failed || preferences.RemindAfter > now() ||
            preferences.LastCheck is { } last && last <= now() && now() - last < TimeSpan.FromDays(1))) return;
        var next = preferences.Copy(); var attempt = next.PendingUpdate.BeginCheck(); next.LastCheck = now();
        if (!Save(next)) return;
        var cancellation = BeginOperation(); automaticDownload = !manual && preferences.AutomaticInstall;
        try
        {
            var release = await adapter.CheckAsync(cancellation.Token);
            if (!manual && release?.Identity == preferences.SkippedVersion) release = null;
            next = preferences.Copy(); if (!next.PendingUpdate.Found(release, attempt) || !Save(next)) return;
            if (release != null && (automaticDownload || retryDownload)) await DownloadAsync(automaticDownload);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Fail(error, attempt); }
        finally { EndOperation(cancellation); }
    }
    public async Task DownloadAsync(bool automatic = false)
    {
        if (!CanDownload || State.Release is not { } release) return;
        var next = preferences.Copy(); var attempt = next.PendingUpdate.BeginDownload();
        if (attempt == null || !Save(next)) return;
        var cancellation = BeginOperation(); automaticDownload = automatic;
        try
        {
            IProgress<int> progress = new Progress<int>(value => {
                var progress = preferences.Copy();
                if (progress.PendingUpdate.Received(value / 100.0, attempt.Value)) { preferences = progress; Notify(); }
            });
            await adapter.DownloadAsync(release, progress.Report, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            next = preferences.Copy(); if (!next.PendingUpdate.Preparing(attempt.Value) || !Save(next)) return;
            await adapter.VerifyAsync(release, cancellation.Token); cancellation.Token.ThrowIfCancellationRequested();
            next = preferences.Copy(); if (!next.PendingUpdate.Verified(attempt.Value)) return;
            if (automaticDownload && preferences.AutomaticInstall) next.PendingUpdate.Choose(UpdateInstallChoice.AutomaticOnQuit);
            Save(next);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Fail(error, attempt.Value); }
        finally { EndOperation(cancellation); }
    }
    public Task RetryAsync() => State.Phase == UpdatePhase.Failed ? CheckAsync(true, State.Failure?.Stage != UpdatePhase.Checking) : Task.CompletedTask;
    public void Cancel()
    {
        if (!CanCancel) return;
        operation?.Cancel(); automaticDownload = false;
        var next = preferences.Copy(); next.PendingUpdate.Cancel(); Save(next);
    }
    public void Skip()
    {
        if (State.Phase != UpdatePhase.Available || State.Release == null) return;
        var next = preferences.Copy(); next.SkippedVersion = State.Release.Identity; next.PendingUpdate=new(); Save(next);
    }
    public void RemindLater()
    {
        if (State.Phase != UpdatePhase.Available) return;
        var next = preferences.Copy(); next.RemindAfter = now().AddDays(1); next.PendingUpdate=new(); Save(next);
    }
    public async Task ChooseAsync(UpdateInstallChoice choice)
    {
        if (!CanChooseInstall) return;
        var next = preferences.Copy(); if (!next.PendingUpdate.Choose(choice)) return;
        next.PendingUpdate.Admit(gate.Blockers()); if (!Save(next)) return;
        if (choice is UpdateInstallChoice.RestartNow or UpdateInstallChoice.AfterTasks && await InstallPreparedAsync(true)) RestartRequested?.Invoke();
    }
    public async Task RefreshGateAsync()
    {
        if (!CanChooseInstall || State.Choice == UpdateInstallChoice.None) return;
        var reasons = gate.Blockers();
        if (!reasons.SequenceEqual(State.Blockers))
        {
            var next = preferences.Copy(); next.PendingUpdate.Admit(reasons); if (!Save(next)) return;
        }
        if (State.Choice == UpdateInstallChoice.AfterTasks && !reasons.Intersect(["draft", "tasks", "save", "journal"]).Any() && await InstallPreparedAsync(true))
            RestartRequested?.Invoke();
    }
    public async Task<bool> PrepareForQuitAsync()
    {
        if (PreparingInstallation || Recovering) return false;
        if (State.Phase is (UpdatePhase.Installing or UpdatePhase.PendingRestart) && State.Choice != UpdateInstallChoice.None) return true;
        if (State.Choice == UpdateInstallChoice.OnQuit || State.Choice == UpdateInstallChoice.AutomaticOnQuit && preferences.AutomaticInstall)
            return await InstallPreparedAsync(false);
        Cancel();
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (operation != null && DateTime.UtcNow < deadline) await Task.Delay(50);
        return operation == null;
    }
    private async Task<bool> InstallPreparedAsync(bool restart)
    {
        if (!CanChooseInstall || State.Choice == UpdateInstallChoice.None || State.Release is not { } release) return false;
        if (State.Choice == UpdateInstallChoice.AutomaticOnQuit && !preferences.AutomaticInstall) return false;
        var next = preferences.Copy(); if (!next.PendingUpdate.Admit(gate.Prepare())) { Save(next); return false; }
        if (!Save(next)) return false;
        var attempt = State.Attempt; PreparingInstallation = true; Notify();
        try
        {
            var path = await Task.Run(() => backup.Create(currentVersion, release.Version, currentBuild)); backup.Verify(path);
            if (State.Attempt != attempt) return false;
            next = preferences.Copy(); if (!next.PendingUpdate.Admit(gate.Prepare())) { Save(next); return false; }
            next.PendingUpdate.BackupPath = path; next.PendingUpdate.PreviousVersion = currentVersion;
            next.PendingUpdate.PreviousBuild = currentBuild; next.RecoveryReceipt = null;
            if (!next.PendingUpdate.Installing(attempt) || !Save(next)) return false;
            await Task.Run(()=>adapter.Install(release, restart));
            next = preferences.Copy(); next.PendingUpdate.AwaitingRestart(attempt); return Save(next);
        }
        catch (Exception error) { Fail(error, attempt); return false; }
        finally { PreparingInstallation = false; Notify(); }
    }
    private CancellationTokenSource BeginOperation()
    {
        operation?.Cancel(); operation = new(); Notify(); return operation;
    }
    private void EndOperation(CancellationTokenSource value)
    {
        if (ReferenceEquals(operation, value)) operation = null;
        value.Dispose(); Notify();
    }
    private void Fail(Exception error, Guid attempt)
    {
        var next = preferences.Copy(); if (next.PendingUpdate.Fail("operation", error.Message, attempt)) Save(next);
    }
    private bool Save(UpdatePreferences next)
    {
        if (StorageError != null) return false;
        try { store.Save(next); preferences = next; Notify(); return true; }
        catch (Exception error) { StorageError = error.Message; preferences.PendingUpdate.Cancel(); operation?.Cancel(); Notify(); return false; }
    }
    public void RefreshLanguage() => Notify();
    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
