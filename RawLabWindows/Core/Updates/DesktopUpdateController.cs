using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace RawLab.Windows;

public sealed class DesktopUpdateController : INotifyPropertyChanged
{
    public static readonly TimeSpan DailyCheckInterval = TimeSpan.FromDays(1);
    public static readonly TimeSpan InitialCheckRetryDelay = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan MaxCheckRetryDelay = TimeSpan.FromHours(4);
    private UpdatePreferences preferences;
    private readonly IDesktopUpdateAdapter adapter;
    private readonly UpdateInstallGate gate;
    private UpdateStore store;
    private UpdateDataBackup backup;
    internal UpdateStore Store => store;
    internal UpdateDataBackup Backup => backup;
    internal void IsolateForTests(UpdateStore isolatedStore, UpdateDataBackup isolatedBackup, UpdatePreferences isolatedPreferences)
    {
        store = isolatedStore;
        backup = isolatedBackup;
        preferences = isolatedPreferences;
    }
    private readonly Func<DateTimeOffset> now;
    private readonly string currentVersion, currentBuild;
    private CancellationTokenSource? operation;
    private readonly SemaphoreSlim saveGate = new(1, 1);
    private readonly object opQueueGate = new();
    private Task pendingUiOpTail = Task.CompletedTask;
    private Guid pendingProgressAttempt;
    private double pendingProgressFraction;
    private bool automaticDownload;
    private bool needsDeferredQuitRevalidation;
    private readonly bool recoveryStartup;
    private bool startupStorageBlocked;
    private bool storageBlocksEditing;
    private byte[]? repairSnapshot;
    private bool repairHealthFailed;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? RestartRequested;
    public UpdatePreferences Preferences => preferences;
    public UpdateTaskState State => preferences.PendingUpdate;
    public UpdateCheckFailure? CheckFailure => preferences.CheckFailure;
    public UpdateInstallGate Gate => gate;
    public string CurrentVersion => currentVersion;
    public string? StorageError { get; private set; }
    public bool PreparingInstallation { get; private set; }
    public bool CheckingStartupTrust { get; private set; }
    public string? StartupTrustError { get; private set; }
    public Func<Task>? RetryStartup { get; set; }
    public bool BlocksEditing => storageBlocksEditing || PreparingInstallation || RequiresStartupHealthCheck || RequiresRecovery;
    public bool Recovering { get; private set; }
    public bool RecoveryNeedsRestart { get; private set; }
    public string? RecoveryError { get; private set; }
    public string? UnavailableReason => startupStorageBlocked || storageBlocksEditing ? "storage" : adapter.UnavailableReason;
    public bool CanCheck => UnavailableReason == null && operation == null && !PreparingInstallation && !RequiresStartupHealthCheck && !RequiresRecovery;
    public bool CanDownload => UnavailableReason == null && State.Phase == UpdatePhase.Available;
    public bool CanCancel => State.Phase is UpdatePhase.Checking or UpdatePhase.Downloading or UpdatePhase.Verifying or
        UpdatePhase.PackageReady or UpdatePhase.WaitingForTasks or UpdatePhase.ReadyToInstall && !PreparingInstallation;
    public bool CanChooseInstall => UnavailableReason == null && State.Prepared && !PreparingInstallation;
    public bool RequiresStartupHealthCheck => preferences.StateRepairReceipt != null || State.Phase is UpdatePhase.Installing or UpdatePhase.PendingRestart;
    public bool RequiresRecovery => backup.HasPendingRecovery || Recovering || RecoveryNeedsRestart || repairHealthFailed || State.Failure?.Stage is UpdatePhase.Installing or UpdatePhase.PendingRestart;
    public bool CanRepairState => startupStorageBlocked && !storageBlocksEditing && StorageError != null && repairSnapshot != null && !RecoveryNeedsRestart;
    public string? StateArchive => preferences.StateRepairReceipt is {} receipt ? store.RepairedStateArchive(receipt) : null;
    public bool CanRestorePreviousData => recoveryStartup && RequiresRecovery && !Recovering && !RecoveryNeedsRestart && !startupStorageBlocked && !storageBlocksEditing &&
        adapter.UnavailableReason == null && State.PreviousVersion == currentVersion && State.PreviousBuild == currentBuild && State.BackupPath != null;

    public DesktopUpdateController(IDesktopUpdateAdapter adapter, UpdateInstallGate gate, UpdateStore store, string currentVersion, string currentBuild,
        bool automaticCheck = true, Func<DateTimeOffset>? now = null)
    {
        this.adapter = adapter; this.gate = gate; this.store = store; this.currentVersion = currentVersion; this.currentBuild = currentBuild;
        this.now = now ?? (() => DateTimeOffset.UtcNow); backup = new(Path.GetDirectoryName(store.DirectoryPath)!, store.DirectoryPath);
        try { preferences = store.Load(automaticCheck); }
        catch (Exception error) { preferences = new() { AutomaticCheck = automaticCheck }; StorageError = error.Message; startupStorageBlocked = true; try { repairSnapshot = store.RepairableState(); } catch { } }
        if (StorageError == null && backup.HasPendingRecovery && preferences.RecoveryReceipt is {} receipt)
        {
            try { backup.FinishRecovery(receipt); } catch (Exception error) { RecoveryError = error.Message; }
        }
        recoveryStartup = RequiresStartupHealthCheck || RequiresRecovery;
        if (StorageError == null && !RequiresStartupHealthCheck)
        {
            var next = preferences.Copy();
            var previousPhase = next.PendingUpdate.Phase;
            next.PendingUpdate.RestoreAfterLaunch(currentVersion, currentBuild, false);
            if (next.PendingUpdate.Phase != State.Phase)
            {
                if (previousPhase != UpdatePhase.Checking) RecordRetryableFailure(next, "interrupted");
                SaveSync(next);
            }
        }
        needsDeferredQuitRevalidation = StorageError == null && State.Phase == UpdatePhase.Available && DeferredQuitChoice;
        if (StorageError == null && !RequiresStartupHealthCheck && !RequiresRecovery && File.Exists(store.StatePath)) {
            try { backup.DiscardUnreferencedBackups(State.BackupPath, preferences.RecoveryReceipt); } catch { }
        }
    }
    public async Task FlushSavesAsync()
    {
        await WaitQueuedUiOpsAsync();
        await saveGate.WaitAsync();
        saveGate.Release();
    }
    private Task WaitQueuedUiOpsAsync()
    {
        lock (opQueueGate) return pendingUiOpTail;
    }
    private async Task EnqueueUiOpAsync(Func<Task> body)
    {
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task predecessor;
        lock (opQueueGate)
        {
            predecessor = pendingUiOpTail;
            pendingUiOpTail = tcs.Task;
        }
        try
        {
            try { await predecessor; } catch { }
            await body();
        }
        finally
        {
            tcs.TrySetResult(true);
        }
    }
    public void RepairState() => _ = RepairStateAsync();
    public Task RepairStateAsync() => EnqueueUiOpAsync(async () =>
    {
        await saveGate.WaitAsync();
        try
        {
            if (!CanRepairState || repairSnapshot is not { } snapshot) return;
            var automaticCheck = preferences.AutomaticCheck;
            var result = await Task.Run(() =>
            {
                try
                {
                    var repaired = store.RepairState(snapshot);
                    return (Repaired: (UpdatePreferences?)repaired, Error: (Exception?)null, BlocksEditing: false, NextSnapshot: (byte[]?)null);
                }
                catch (Exception error)
                {
                    var blocks = false;
                    byte[]? nextSnap = null;
                    try { if (store.Load(automaticCheck).StateRepairReceipt != null) blocks = true; } catch { }
                    try { nextSnap = store.RepairableState(); } catch { }
                    return (Repaired: (UpdatePreferences?)null, Error: error, BlocksEditing: blocks, NextSnapshot: nextSnap);
                }
            });
            if (result.Error == null)
            {
                preferences = result.Repaired!;
                startupStorageBlocked = false;
                storageBlocksEditing = false;
                StorageError = null;
                repairSnapshot = null;
                RecoveryNeedsRestart = true;
            }
            else
            {
                StorageError = result.Error.Message;
                if (result.BlocksEditing) storageBlocksEditing = true;
                repairSnapshot = result.NextSnapshot;
            }
            Notify();
        }
        finally
        {
            saveGate.Release();
        }
    });
    public async Task RestorePreviousDataAsync()
    {
        await WaitQueuedUiOpsAsync();
        string? path = null;
        string? target = null;
        await saveGate.WaitAsync();
        try
        {
            if (!CanRestorePreviousData || State.BackupPath is not { } backupPath) return;
            path = backupPath;
            target = State.Release?.Version;
            Recovering = true;
            RecoveryError = null;
        }
        finally
        {
            saveGate.Release();
        }
        Notify();
        try
        {
            await adapter.ValidateHostTrustAsync();
            var receipt = await Task.Run(() => {
                var manifest = backup.Verify(path);
                if (manifest.PreviousVersion != currentVersion || manifest.PreviousBuild != currentBuild || manifest.TargetVersion != target)
                    throw new InvalidDataException("Backup does not match this trusted version");
                return backup.Restore(path);
            });
            RecoveryNeedsRestart = true;
            if (await SaveUpdatedAsync(next =>
            {
                if (!StringComparer.OrdinalIgnoreCase.Equals(next.PendingUpdate.BackupPath, path)) return false;
                next.SkippedVersion = next.PendingUpdate.Release?.Identity;
                next.AutomaticInstall = false;
                next.PendingUpdate = new();
                next.RecoveryReceipt = receipt;
                return true;
            }, discardObsoleteBackup: false))
            {
                await Task.Run(() => { backup.FinishRecovery(receipt); try { backup.Discard(path); } catch { } });
            }
        }
        catch (Exception error) { RecoveryError = error.Message; }
        finally { Recovering = false; Notify(); }
    }
    public async Task FinishStartupHealthCheckAsync(bool healthy)
    {
        await WaitQueuedUiOpsAsync();
        string? backupPath = null;
        string? releaseVersion = null;
        string? previousVersion = null;
        string? previousBuild = null;
        var hasRepairReceipt = false;
        var shouldNotify = false;
        await saveGate.WaitAsync();
        try
        {
            if (!RequiresStartupHealthCheck || backup.HasPendingRecovery || RecoveryNeedsRestart) return;
            if (preferences.StateRepairReceipt != null)
            {
                hasRepairReceipt = true;
                if (!healthy)
                {
                    repairHealthFailed = true;
                    RecoveryError = "User data failed startup validation";
                    shouldNotify = true;
                    return;
                }
            }
            else
            {
                if (CheckingStartupTrust) return;
                CheckingStartupTrust = true;
                StartupTrustError = null;
                backupPath = State.BackupPath;
                releaseVersion = State.Release?.Version;
                previousVersion = State.PreviousVersion;
                previousBuild = State.PreviousBuild;
                shouldNotify = true;
            }
        }
        finally
        {
            saveGate.Release();
            if (shouldNotify) Notify();
        }

        if (hasRepairReceipt)
        {
            string? savedBackupPath = null;
            string? savedRecoveryReceipt = null;
            if (await SaveUpdatedAsync(next =>
            {
                if (next.StateRepairReceipt == null) return false;
                next.StateRepairReceipt = null;
                savedBackupPath = next.PendingUpdate.BackupPath;
                savedRecoveryReceipt = next.RecoveryReceipt;
                return true;
            }))
            {
                await Task.Run(() => { try { backup.DiscardUnreferencedBackups(savedBackupPath, savedRecoveryReceipt); } catch { } });
            }
            return;
        }

        var trusted = false;
        try { await adapter.ValidateHostTrustAsync(); trusted = true; }
        catch (Exception error) when (error is TemporaryUpdateTrustException or TimeoutException) {
            StartupTrustError = error.Message; CheckingStartupTrust = false; Notify(); return;
        }
        catch (Exception error) { StartupTrustError = error.Message; }
        CheckingStartupTrust = false;
        var backupValid = false;
        try {
            if (backupPath is { } path) { var manifest = backup.Verify(path); backupValid = manifest.TargetVersion == releaseVersion && manifest.PreviousVersion == previousVersion && manifest.PreviousBuild == previousBuild; }
        } catch (Exception error) { RecoveryError = error.Message; }
        await SaveUpdatedAsync(next =>
        {
            if (!RequiresStartupHealthCheck || next.StateRepairReceipt != null) return false;
            next.PendingUpdate.RestoreAfterLaunch(currentVersion, currentBuild, healthy && backupValid && trusted);
            return true;
        });
    }
    public void SetAutomaticCheck(bool value) => _ = SetAutomaticCheckAsync(value);
    public Task SetAutomaticCheckAsync(bool value) => EnqueueUiOpAsync(() => SaveUpdatedAsync(next =>
    {
        if (startupStorageBlocked || storageBlocksEditing || RequiresStartupHealthCheck || RequiresRecovery) return false;
        next.AutomaticCheck = value;
        return true;
    }));
    public async Task PerformStartupCheckAsync()
    {
        if (StorageError == null && UnavailableReason == null)
            await CheckAsync(false);
    }
    public void SetAutomaticInstall(bool value) => _ = SetAutomaticInstallAsync(value);
    public Task SetAutomaticInstallAsync(bool value) => EnqueueUiOpAsync(async () =>
    {
        var revoke = false;
        if (await SaveUpdatedAsync(next =>
        {
            if (startupStorageBlocked || storageBlocksEditing || RequiresStartupHealthCheck || RequiresRecovery) return false;
            if (value && UnavailableReason != null) return false;
            next.AutomaticInstall = value;
            revoke = !value && (automaticDownload || next.PendingUpdate.Choice == UpdateInstallChoice.AutomaticOnQuit);
            if (revoke) { DeferCheckRetry(next); next.PendingUpdate.Cancel(); }
            return true;
        }, onSaved: () =>
        {
            if (revoke) { automaticDownload = false; operation?.Cancel(); }
        }) && revoke)
        {
            automaticDownload = false;
            operation?.Cancel();
        }
    });
    public static TimeSpan CheckRetryDelay(int consecutiveFailures)
    {
        var shift = Math.Clamp(consecutiveFailures, 1, 5) - 1;
        var delay = TimeSpan.FromMinutes(InitialCheckRetryDelay.TotalMinutes * (1 << shift));
        return delay <= MaxCheckRetryDelay ? delay : MaxCheckRetryDelay;
    }
    public static string CategorizeCheckError(Exception error)
    {
        if (error is AggregateException { InnerException: { } inner }) error = inner;
        return error switch
        {
            TimeoutException or OperationCanceledException => "timeout",
            TemporaryUpdateTrustException => "trust",
            HttpRequestException or IOException => "network",
            CryptographicException => "signature",
            InvalidDataException or JsonException or FormatException => "metadata",
            _ => "operation"
        };
    }
    private bool IsCheckBackoffActive(DateTimeOffset current)
    {
        if (preferences.CheckFailure is not { } failed) return false;
        var delay = CheckRetryDelay(failed.ConsecutiveFailures);
        var retryAt = failed.RetryAfter ?? failed.FailedAt + delay;
        return retryAt - delay <= current && current < retryAt;
    }
    private bool ShouldSkipAutomaticCheck(DateTimeOffset current)
    {
        if (!preferences.AutomaticCheck ||
            State.Phase == UpdatePhase.Failed && !UpdatePresentation.IsRetryableFailure(State.Failure) ||
            preferences.RemindAfter > current) return true;
        if (preferences.CheckFailure != null) return IsCheckBackoffActive(current);
        return preferences.LastCheck is { } last && last <= current && current - last < DailyCheckInterval;
    }
    private void DeferCheckRetry(UpdatePreferences next)
    {
        if (next.PendingUpdate.Phase == UpdatePhase.Checking && next.CheckFailure is { } failed)
            next.CheckFailure = failed with { RetryAfter = now() + CheckRetryDelay(failed.ConsecutiveFailures) };
    }
    public async Task CheckAsync(bool manual, bool retryDownload = false)
    {
        await WaitQueuedUiOpsAsync();
        var attempt = Guid.Empty;
        CancellationTokenSource? cancellation = null;
        if (!await SaveUpdatedAsync(next =>
        {
            if (!CanCheck) return false;
            if (!manual && ShouldSkipAutomaticCheck(now())) return false;
            attempt = next.PendingUpdate.BeginCheck();
            return true;
        },
        preserveDeferredChoiceOnFailure: true,
        onSaved: () =>
        {
            needsDeferredQuitRevalidation = false;
            cancellation = BeginOperation(notify: false);
            automaticDownload = !manual && preferences.AutomaticInstall;
        })) return;
        try
        {
            var release = await adapter.CheckAsync(cancellation!.Token);
            UpdateDescriptor? effectiveRelease = null;
            if (!await SaveUpdatedAsync(next =>
            {
                var candidate = !manual && release?.Identity == next.SkippedVersion ? null : release;
                if (!next.PendingUpdate.Found(candidate, attempt)) return false;
                next.LastCheck = now();
                next.CheckFailure = null;
                effectiveRelease = candidate;
                return true;
            })) return;
            if (!cancellation.IsCancellationRequested && effectiveRelease != null &&
                (automaticDownload || retryDownload || DeferredQuitChoice))
            {
                await DownloadAsync(automaticDownload);
            }
        }
        catch (OperationCanceledException) when (cancellation!.IsCancellationRequested) { }
        catch (Exception error) { await FailAsync(error, attempt); }
        finally { EndOperation(cancellation!); }
    }
    public async Task DownloadAsync(bool automatic = false)
    {
        await WaitQueuedUiOpsAsync();
        Guid? attempt = null;
        UpdateDescriptor? release = null;
        CancellationTokenSource? cancellation = null;
        if (!await SaveUpdatedAsync(next =>
        {
            if (!CanDownload || next.PendingUpdate.Release is not { } currentRelease) return false;
            attempt = next.PendingUpdate.BeginDownload();
            if (attempt == null) return false;
            release = currentRelease;
            return true;
        },
        onSaved: () =>
        {
            cancellation = BeginOperation(notify: false);
            automaticDownload = automatic;
        })) return;
        try
        {
            IProgress<int> progress = new Progress<int>(value => ReportDownloadProgress(value, attempt!.Value));
            await adapter.DownloadAsync(release!, progress.Report, cancellation!.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!await SaveUpdatedAsync(next => next.PendingUpdate.Preparing(attempt!.Value))) return;
            await adapter.VerifyAsync(release!, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            await SaveUpdatedAsync(next =>
            {
                if (!next.PendingUpdate.Verified(attempt!.Value)) return false;
                if (automaticDownload && next.AutomaticInstall && next.PendingUpdate.Choice == UpdateInstallChoice.None)
                    next.PendingUpdate.Choose(UpdateInstallChoice.AutomaticOnQuit);
                return true;
            });
        }
        catch (OperationCanceledException) when (cancellation!.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (State.Phase == UpdatePhase.Verifying) await FailVerificationAsync(error, attempt!.Value);
            else await FailAsync(error, attempt!.Value);
        }
        finally { EndOperation(cancellation!); }
    }
    public Task RetryAsync() => State.Phase == UpdatePhase.Failed
        ? CheckAsync(true, State.Failure?.Stage != UpdatePhase.Checking)
        : CheckFailure != null && State.Phase is UpdatePhase.Idle or UpdatePhase.Available ? CheckAsync(true) : Task.CompletedTask;
    public void Cancel() => _ = CancelAsync();
    public Task CancelAsync()
    {
        if (CanCancel)
        {
            operation?.Cancel();
            automaticDownload = false;
        }
        return EnqueueUiOpAsync(() => SaveUpdatedAsync(next =>
        {
            if (!CanCancel) return false;
            operation?.Cancel();
            automaticDownload = false;
            DeferCheckRetry(next);
            next.PendingUpdate.Cancel();
            return true;
        }));
    }
    public void Skip() => _ = SkipAsync();
    public Task SkipAsync() => EnqueueUiOpAsync(() => SaveUpdatedAsync(next =>
    {
        if (next.PendingUpdate.Phase != UpdatePhase.Available || next.PendingUpdate.Release is not { } release) return false;
        next.SkippedVersion = release.Identity;
        next.PendingUpdate = new();
        return true;
    }));
    public void RemindLater() => _ = RemindLaterAsync();
    public Task RemindLaterAsync() => EnqueueUiOpAsync(() => SaveUpdatedAsync(next =>
    {
        if (next.PendingUpdate.Phase != UpdatePhase.Available) return false;
        next.RemindAfter = now().AddDays(1);
        next.PendingUpdate = new();
        return true;
    }));
    public async Task ChooseAsync(UpdateInstallChoice choice)
    {
        await WaitQueuedUiOpsAsync();
        if (!await SaveUpdatedAsync(next =>
        {
            if (!CanChooseInstall) return false;
            if (!next.PendingUpdate.Choose(choice)) return false;
            next.PendingUpdate.Admit(gate.Blockers());
            return true;
        })) return;
        if (choice is UpdateInstallChoice.RestartNow or UpdateInstallChoice.AfterTasks && await InstallPreparedAsync(true)) RestartRequested?.Invoke();
    }
    private bool DeferredQuitChoice => State.Choice == UpdateInstallChoice.OnQuit ||
        State.Choice == UpdateInstallChoice.AutomaticOnQuit && preferences.AutomaticInstall;
    public async Task RefreshGateAsync()
    {
        await WaitQueuedUiOpsAsync();
        if (State.Phase == UpdatePhase.Available && DeferredQuitChoice && CanCheck)
        {
            if (needsDeferredQuitRevalidation)
            {
                if (!IsCheckBackoffActive(now())) await CheckAsync(true);
                return;
            }
            if (!IsCheckBackoffActive(now())) await CheckAsync(false);
            return;
        }
        if (State.Phase == UpdatePhase.Failed && UpdatePresentation.IsRetryableFailure(State.Failure) ||
            State.Phase == UpdatePhase.Idle && CheckFailure != null) { await CheckAsync(false); return; }
        var reasons = Array.Empty<string>();
        var changed = false;
        var saved = await SaveUpdatedAsync(next =>
        {
            if (!CanChooseInstall || next.PendingUpdate.Choice == UpdateInstallChoice.None) return false;
            reasons = gate.Blockers();
            if (reasons.SequenceEqual(next.PendingUpdate.Blockers)) return false;
            next.PendingUpdate.Admit(reasons);
            changed = true;
            return true;
        });
        if (changed && !saved) return;
        if (CanChooseInstall && State.Choice == UpdateInstallChoice.AfterTasks &&
            !reasons.Intersect(["draft", "tasks", "save", "journal"]).Any() &&
            await InstallPreparedAsync(true))
            RestartRequested?.Invoke();
    }
    public async Task<bool> PrepareForQuitAsync()
    {
        await WaitQueuedUiOpsAsync();
        if (PreparingInstallation || Recovering) return false;
        if (State.Phase is (UpdatePhase.Installing or UpdatePhase.PendingRestart) && State.Choice != UpdateInstallChoice.None) return true;
        var selected = State.Choice == UpdateInstallChoice.OnQuit || State.Choice == UpdateInstallChoice.AutomaticOnQuit && preferences.AutomaticInstall;
        if (selected) {
            if (await InstallPreparedAsync(false)) { await FlushSavesAsync(); return true; }
            if (BlocksEditing) { await FlushSavesAsync(); return false; }
            operation?.Cancel(); automaticDownload = false;
            await SaveUpdatedAsync(next =>
            {
                if (StorageError != null || next.PendingUpdate.Phase == UpdatePhase.Failed) return false;
                DeferCheckRetry(next);
                next.PendingUpdate.Cancel(preservingChoice: true);
                return true;
            });
        } else await CancelAsync();
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (operation != null && DateTime.UtcNow < deadline) await Task.Delay(50);
        await FlushSavesAsync();
        return operation == null;
    }
    private async Task<bool> InstallPreparedAsync(bool restart)
    {
        var admitted = false;
        var attempt = Guid.Empty;
        UpdateDescriptor? release = null;
        var savedStep1 = await SaveUpdatedAsync(next =>
        {
            if (!CanChooseInstall || next.PendingUpdate.Choice == UpdateInstallChoice.None || next.PendingUpdate.Release is not { } currentRelease)
                return false;
            if (next.PendingUpdate.Choice == UpdateInstallChoice.AutomaticOnQuit && !next.AutomaticInstall)
                return false;
            release = currentRelease;
            admitted = next.PendingUpdate.Admit(gate.Prepare());
            attempt = next.PendingUpdate.Attempt;
            return true;
        });
        if (!savedStep1 || !admitted || release == null) return false;
        PreparingInstallation = true; Notify();
        string? path = null; var installationRecorded = false; var dispatched = false;
        try
        {
            try { await Task.Run(() => adapter.VerifyBeforeInstall(release)); }
            catch (Exception error) { await FailVerificationAsync(error, attempt); return false; }
            if (State.Attempt != attempt) return false;
            path = await Task.Run(() => backup.Create(currentVersion, release.Version, currentBuild)); backup.Verify(path);
            if (State.Attempt != attempt) return false;
            var step3Admitted = false;
            var step3Saved = await SaveUpdatedAsync(next =>
            {
                if (next.PendingUpdate.Attempt != attempt) return false;
                step3Admitted = next.PendingUpdate.Admit(gate.Prepare());
                if (!step3Admitted) return true;
                next.PendingUpdate.BackupPath = path;
                next.PendingUpdate.PreviousVersion = currentVersion;
                next.PendingUpdate.PreviousBuild = currentBuild;
                next.RecoveryReceipt = null;
                if (!next.PendingUpdate.Installing(attempt)) return false;
                // 原子替换后的保存异常无法证明磁盘未引用此备份。
                installationRecorded = true;
                return true;
            });
            if (!step3Saved || !step3Admitted) return false;
            await Task.Run(() => { adapter.Install(release, restart); dispatched = true; });
            await SaveUpdatedAsync(next => next.PendingUpdate.AwaitingRestart(attempt), keepNextOnFailure: _ => true);
            return true;
        }
        catch (Exception error) when (error is UpdatePackageRejectedException or TemporaryUpdateTrustException)
        {
            await FailVerificationAsync(error, attempt);
            return false;
        }
        catch (Exception error)
        {
            // 进程未拉起时 Install 抛出的 Win32Exception/InvalidOperationException 等启动异常退回就绪阶段的
            // 普通失败：可继续编辑、可直接重试；只有进程已拉起之后的中断才保留 Installing/RequiresRecovery 语义。
            await FailAsync(error, attempt, !dispatched && State.Phase == UpdatePhase.Installing ? UpdatePhase.ReadyToInstall : State.Phase);
            return false;
        }
        finally {
            if (!installationRecorded && path != null) { try { backup.Discard(path); } catch { } }
            PreparingInstallation = false; Notify();
        }
    }
    private CancellationTokenSource BeginOperation(bool notify = true)
    {
        operation?.Cancel();
        operation = new();
        if (notify) Notify();
        return operation;
    }
    private void EndOperation(CancellationTokenSource value)
    {
        if (ReferenceEquals(operation, value)) operation = null;
        value.Dispose(); Notify();
    }
    private void ReportDownloadProgress(int value, Guid attempt)
    {
        var fraction = value / 100.0;
        if (!double.IsFinite(fraction)) return;
        if (saveGate.Wait(0))
        {
            var changed = false;
            try
            {
                var next = preferences.Copy();
                if (next.PendingUpdate.Received(fraction, attempt))
                {
                    preferences = next;
                    changed = true;
                }
            }
            finally
            {
                saveGate.Release();
            }
            if (changed) Notify();
            return;
        }
        lock (opQueueGate)
        {
            if (pendingProgressAttempt != attempt)
            {
                pendingProgressAttempt = attempt;
                pendingProgressFraction = Math.Clamp(fraction, 0, 1);
            }
            else
            {
                pendingProgressFraction = Math.Max(pendingProgressFraction, Math.Clamp(fraction, 0, 1));
            }
        }
    }
    private void RecordRetryableFailure(UpdatePreferences next, string code, string detail = "")
    {
        if (!UpdatePresentation.IsRetryableFailure(next.PendingUpdate.Failure)) return;
        var count = (next.CheckFailure?.ConsecutiveFailures ?? 0) + 1;
        next.CheckFailure = new(now(), code, Math.Max(1, count), detail);
    }
    private Task FailVerificationAsync(Exception error, Guid attempt)
    {
        var code = VerificationFailureCode(error);
        var detail = error.Message ?? "";
        return SaveUpdatedAsync(next =>
        {
            if (!next.PendingUpdate.Fail(UpdatePhase.Verifying, code, detail, attempt)) return false;
            RecordRetryableFailure(next, code, detail);
            return true;
        });
    }
    private static string VerificationFailureCode(Exception error) => error switch
    {
        TemporaryUpdateTrustException or TimeoutException => "trust_temporary",
        UpdatePackageRejectedException rejected => rejected.Code,
        CryptographicException => "signature",
        _ => "verification"
    };
    private Task FailAsync(Exception error, Guid attempt) => FailAsync(error, attempt, State.Phase);
    private Task FailAsync(Exception error, Guid attempt, UpdatePhase stage)
    {
        var code = stage == UpdatePhase.Checking ? CategorizeCheckError(error) : "operation";
        var detail = error.Message ?? "";
        var diskPhase = UpdatePhase.Idle;
        var persistedDispatch = false;
        var optimisticRollback = false;
        UpdatePreferences? diskRecord = null;
        return SaveUpdatedAsync(next =>
        {
            // 磁盘记录停留在 Installing/PendingRestart 时 Cancel 无法回退该阶段；持久化失败必须保留内存中的失败记录。
            diskPhase = preferences.PendingUpdate.Phase;
            persistedDispatch = diskPhase is UpdatePhase.Installing or UpdatePhase.PendingRestart;
            // 拉起前启动异常会记到更轻的 ReadyToInstall：这是仅当失败记录成功落盘才成立的乐观回退。
            optimisticRollback = persistedDispatch && stage != diskPhase;
            diskRecord = optimisticRollback ? preferences.Copy() : null;
            if (!next.PendingUpdate.Fail(stage, code, detail, attempt)) return false;
            RecordRetryableFailure(next, code, detail);
            return true;
        },
        keepNextOnFailure: _ => persistedDispatch,
        onFailed: () =>
        {
            // 双故障边界：失败记录也没写进去时磁盘仍停在 Installing/PendingRestart 并绑定备份，
            // 内存回退为磁盘阶段的失败（保留 BackupPath）以维持 RequiresRecovery/BlocksEditing，
            // 避免会话内新编辑在下次启动被磁盘旧快照的强制恢复回滚（与 macOS storageBlocksEditing 门禁一致）。
            if (optimisticRollback && diskRecord!.PendingUpdate.Fail(diskPhase, code, detail, attempt))
                preferences = diskRecord;
        });
    }
    private static bool IsCriticalSave(UpdatePreferences next) =>
        next.StateRepairReceipt != null ||
        next.PendingUpdate.Phase is UpdatePhase.Installing or UpdatePhase.PendingRestart ||
        next.PendingUpdate.Failure is { Stage: UpdatePhase.Installing or UpdatePhase.PendingRestart };
    private bool ReplacedOnDisk(UpdatePreferences next, bool automaticCheck)
    {
        try
        {
            var persisted = store.Load(automaticCheck);
            var state = persisted.PendingUpdate; var expected = next.PendingUpdate;
            return persisted.StateRepairReceipt == next.StateRepairReceipt &&
                state.Phase == expected.Phase && state.Attempt == expected.Attempt &&
                state.Failure == expected.Failure && state.BackupPath == expected.BackupPath;
        }
        catch { return false; }
    }
    private void SaveSync(UpdatePreferences next, bool discardObsoleteBackup = true, bool keepNextOnFailure = false, bool preserveDeferredChoiceOnFailure = false)
    {
        if (startupStorageBlocked || storageBlocksEditing) return;
        try {
            var obsolete = preferences.PendingUpdate.BackupPath;
            store.Save(next); preferences = next; StorageError = null;
            if (discardObsoleteBackup && obsolete != null && obsolete != next.PendingUpdate.BackupPath) { try { backup.Discard(obsolete); } catch { } }
            Notify();
        }
        catch (Exception error)
        {
            StorageError = error.Message;
            if (keepNextOnFailure) preferences = next;
            else
            {
                if (IsCriticalSave(next) && ReplacedOnDisk(next, preferences.AutomaticCheck)) storageBlocksEditing = true;
                preferences.PendingUpdate.Cancel(preservingChoice: preserveDeferredChoiceOnFailure && DeferredQuitChoice);
            }
            operation?.Cancel(); Notify();
        }
    }
    private async Task<bool> SaveUpdatedAsync(
        Func<UpdatePreferences, bool> prepare,
        bool discardObsoleteBackup = true,
        Func<UpdatePreferences, bool>? keepNextOnFailure = null,
        bool preserveDeferredChoiceOnFailure = false,
        Action? onSaved = null,
        Action? onFailed = null)
    {
        await saveGate.WaitAsync();
        var shouldNotify = false;
        try
        {
            if (startupStorageBlocked || storageBlocksEditing) return false;
            var next = preferences.Copy();
            if (!prepare(next)) return false;

            var obsolete = preferences.PendingUpdate.BackupPath;
            var automaticCheck = preferences.AutomaticCheck;
            var exception = await Task.Run(() =>
            {
                try
                {
                    store.Save(next);
                    if (discardObsoleteBackup && obsolete != null && obsolete != next.PendingUpdate.BackupPath)
                    {
                        try { backup.Discard(obsolete); } catch { }
                    }
                    return (Exception?)null;
                }
                catch (Exception error)
                {
                    return error;
                }
            });
            if (exception == null)
            {
                lock (opQueueGate)
                {
                    if (pendingProgressAttempt == next.PendingUpdate.Attempt &&
                        next.PendingUpdate.Phase == UpdatePhase.Downloading)
                    {
                        next.PendingUpdate.Received(pendingProgressFraction, pendingProgressAttempt);
                    }
                    else if (pendingProgressAttempt != Guid.Empty &&
                             pendingProgressAttempt != next.PendingUpdate.Attempt)
                    {
                        pendingProgressAttempt = Guid.Empty;
                        pendingProgressFraction = 0;
                    }
                }
                preferences = next;
                StorageError = null;
                onSaved?.Invoke();
                shouldNotify = true;
                return true;
            }
            var keepNext = keepNextOnFailure?.Invoke(next) ?? false;
            var criticalReplaced = !keepNext && IsCriticalSave(next) &&
                await Task.Run(() => ReplacedOnDisk(next, automaticCheck));
            StorageError = exception.Message;
            if (keepNext) preferences = next;
            else
            {
                if (criticalReplaced) storageBlocksEditing = true;
                preferences.PendingUpdate.Cancel(preservingChoice: preserveDeferredChoiceOnFailure && DeferredQuitChoice);
            }
            operation?.Cancel();
            onFailed?.Invoke();
            shouldNotify = true;
            return false;
        }
        finally
        {
            saveGate.Release();
            if (shouldNotify) Notify();
        }
    }
    public void RefreshLanguage() => Notify();
    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
