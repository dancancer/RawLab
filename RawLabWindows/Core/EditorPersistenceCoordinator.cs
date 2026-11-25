using System.IO;

namespace RawLab.Windows;

internal sealed record EditSaveSuccess(
    PhotoEditState Saved,
    string? PreviousLook,
    bool IsCurrentRevision,
    bool ClearReceiptApplied);

internal sealed record EditSaveFailure(
    Exception Error,
    bool ShouldShowNotice,
    bool IsCurrentPhoto);

internal enum ExternalReloadAction
{
    None,
    Deferred,
    AutoReload,
    BannerUpdated
}

internal sealed record ExternalReloadResult(
    ExternalReloadAction Action,
    ExternalReloadBannerState BannerState,
    PhotoEditState? AdoptedRecord = null,
    PhotoEditState? PreviousRecord = null,
    bool FromManualAccept = false);

internal sealed record ProcessingMigrationCommitResult(
    bool Applied,
    bool Migrated,
    PhotoEditState? Saved = null,
    PhotoEditState? PreviousRecord = null,
    ProcessingMigrationReceipt? Receipt = null);

// 纯 net8.0 持久化与热重载协调器：统一管理 EditStore 生命周期、AdjustmentTransferSession、
// 后台保存队列与提交队列、Open/Edit/Epoch 单调失效、外部热重载串行排空及处理迁移串行化。
internal sealed class EditorPersistenceCoordinator
{
    private readonly Func<EditStore> storeFactory;
    private readonly Action<Action>? scheduleUi;
    private readonly EditSaveQueue saveQueue = new();
    private readonly EditSaveCommitQueue commitQueue = new();

    private EditStore? store;
    private EditStore? sessionStore;
    private AdjustmentTransferSession? adjustmentSession;
    private SynchronizationContext? capturedSyncContext;

    private long openRevision;
    private long editRevision;
    private long persistenceEpoch;
    private bool deferredExternalEditsCheck;
    private bool deferredExternalReloadAccept;
    private int deferredNotificationPending;

    internal EditorPersistenceCoordinator(
        EditStore? initialStore,
        Func<EditStore> storeFactory,
        Action<Action>? scheduleUi = null)
    {
        this.store = initialStore;
        this.storeFactory = storeFactory ?? throw new ArgumentNullException(nameof(storeFactory));
        this.scheduleUi = scheduleUi;
        this.saveQueue.BecameIdle += OnSaveQueueBecameIdle;
    }

    internal event Action? DeferredExternalCheckReady;

    internal EditStore? Store => store;
    internal AdjustmentTransferSession? AdjustmentSession => adjustmentSession;
    internal PhotoEditState? CurrentRecord { get; private set; }
    internal string? CurrentPath { get; private set; }
    internal long OpenRevision => Volatile.Read(ref openRevision);
    internal long EditRevision => editRevision;
    internal long PersistenceEpoch => Volatile.Read(ref persistenceEpoch);
    internal bool EditDirty { get; private set; }
    internal bool PendingMigrationReceiptClear { get; private set; }
    internal bool HasPendingSaves => commitQueue.HasPending || saveQueue.HasPendingWork;
    internal bool HasPendingBackgroundSave => saveQueue.HasPendingWork;
    internal Task<bool>? LastPendingSaveTask => commitQueue.LastPending?.CompletionTask;
    internal bool HasDeferredExternalCheck =>
        Volatile.Read(ref deferredExternalEditsCheck) || Volatile.Read(ref deferredExternalReloadAccept);
    internal ExternalReloadBannerState ExternalReloadBanner { get; private set; } = ExternalReloadBannerState.Empty;

    internal EditStore EnsureStore()
    {
        store ??= storeFactory();
        return store;
    }

    internal AdjustmentTransferSession EnsureTransferSession()
    {
        var activeStore = EnsureStore();
        if (adjustmentSession == null || !ReferenceEquals(sessionStore, activeStore))
        {
            sessionStore = activeStore;
            adjustmentSession = new AdjustmentTransferSession(activeStore);
        }
        return adjustmentSession;
    }

    internal void RebindStore(EditStore? nextStore)
    {
        store = nextStore;
        sessionStore = null;
        adjustmentSession = null;
        Interlocked.Increment(ref persistenceEpoch);
        ClearDeferredFlags();
        ExternalReloadBanner = ExternalReloadBannerState.Empty;
    }

    internal long BeginOpen(string path, PhotoEditState record)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(record);
        var nextOpen = Interlocked.Increment(ref openRevision);
        Interlocked.Increment(ref persistenceEpoch);
        CurrentPath = path;
        CurrentRecord = record;
        EditDirty = false;
        PendingMigrationReceiptClear = false;
        ClearDeferredFlags();
        ExternalReloadBanner = ExternalReloadBannerState.Empty;
        return nextOpen;
    }

    internal void ApplyRestoredOpenState(string path, PhotoEditState record)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(record);
        Interlocked.Increment(ref persistenceEpoch);
        CurrentPath = path;
        CurrentRecord = record;
        EditDirty = false;
        PendingMigrationReceiptClear = false;
    }

    internal long AdvanceOpenRevision()
    {
        Interlocked.Increment(ref persistenceEpoch);
        return Interlocked.Increment(ref openRevision);
    }

    internal long AdvanceEditRevision() => ++editRevision;

    internal void MarkEdited(bool canPersist, bool clearMigrationReceipt = false)
    {
        ++editRevision;
        if (!canPersist || CurrentPath == null) return;
        EditDirty = true;
        if (clearMigrationReceipt) PendingMigrationReceiptClear = true;
    }

    internal void RevertGesture(bool wasDirty, bool aiChanged)
    {
        EditDirty = wasDirty || aiChanged;
        ++editRevision;
    }

    internal void DiscardDirtyState()
    {
        EditDirty = false;
        PendingMigrationReceiptClear = false;
    }

    internal void CompleteTransformCommit(PhotoEditState saved)
    {
        ArgumentNullException.ThrowIfNull(saved);
        CurrentRecord = saved;
        EditDirty = false;
        PendingMigrationReceiptClear = false;
        ++editRevision;
        Interlocked.Increment(ref persistenceEpoch);
    }

    internal Task<bool> EnqueueSaveAsync(
        Func<(SavedEdit Candidate, SavedEdit? DefaultEdit)> captureEdit,
        bool clearMigrationReceipt = false,
        Action<EditSaveSuccess>? onApplied = null,
        Action<EditSaveFailure>? onFailed = null,
        Action? onDeferredReloadReady = null)
    {
        ArgumentNullException.ThrowIfNull(captureEdit);
        CaptureSyncContext();

        if (!EditDirty || CurrentPath == null)
            return commitQueue.LastPending?.CompletionTask ?? Task.FromResult(true);

        var capturedPath = CurrentPath;
        var capturedOpenRevision = OpenRevision;
        var capturedEpoch = PersistenceEpoch;
        var capturedRevision = editRevision;
        var clearReceipt = clearMigrationReceipt || PendingMigrationReceiptClear;

        if (commitQueue.LastPending is { } existing &&
            SamePath(existing.Path, capturedPath) &&
            existing.OpenRevision == capturedOpenRevision &&
            existing.Epoch == capturedEpoch &&
            existing.Revision == capturedRevision &&
            existing.CompletionTask is { IsCompleted: false } existingTask &&
            (!clearReceipt || Volatile.Read(ref existing.ClearReceipt)))
        {
            return existingTask;
        }

        var capturedStore = EnsureStore();
        var capturedSession = EnsureTransferSession();
        var (candidate, defaultEdit) = captureEdit();
        var before = CurrentRecord ?? new PhotoEditState(candidate.Identity, null);
        var (baseline, desired) = capturedSession.PrepareEditCommit(before, candidate, defaultEdit);
        var previousLook = before.Edit?.Look;

        var commit = new PendingEditSaveCommit
        {
            Revision = capturedRevision,
            Path = capturedPath,
            OpenRevision = capturedOpenRevision,
            Epoch = capturedEpoch,
            Session = capturedSession,
            Baseline = baseline,
            PreviousLook = previousLook,
            ClearReceipt = clearReceipt
        };

        var queueTask = saveQueue.EnqueueSave(
            capturedStore,
            capturedPath,
            capturedOpenRevision,
            clearReceipt,
            effectiveClear =>
            {
                if (effectiveClear) Volatile.Write(ref commit.ClearReceipt, true);
                return capturedStore.SaveState(baseline.Identity, desired, effectiveClear);
            },
            isStale: () => Volatile.Read(ref persistenceEpoch) != capturedEpoch ||
                           Volatile.Read(ref openRevision) != capturedOpenRevision,
            epoch: capturedEpoch);

        commit.QueueTask = queueTask;
        commitQueue.Enqueue(commit);
        commit.CompletionTask = CompleteQueuedSaveAsync(commit, onApplied, onFailed, onDeferredReloadReady);
        return commit.CompletionTask;
    }

    internal async Task<bool> FlushAsync(
        Func<(SavedEdit Candidate, SavedEdit? DefaultEdit)>? captureEdit = null,
        bool pauseForInteractiveGesture = false,
        Action<EditSaveSuccess>? onApplied = null,
        Action<EditSaveFailure>? onFailed = null,
        Action? onDeferredReloadReady = null)
    {
        CaptureSyncContext();
        while (true)
        {
            if (pauseForInteractiveGesture) return true;
            if (EditDirty && CurrentPath != null)
            {
                var currentPending = commitQueue.LastPending;
                var alreadyQueued = currentPending != null &&
                    SamePath(currentPending.Path, CurrentPath) &&
                    currentPending.OpenRevision == OpenRevision &&
                    currentPending.Epoch == PersistenceEpoch &&
                    currentPending.Revision == editRevision &&
                    currentPending.CompletionTask is { IsCompleted: false };
                if (!alreadyQueued)
                {
                    if (captureEdit == null) return false;
                    try
                    {
                        if (!await EnqueueSaveAsync(captureEdit, false, onApplied, onFailed, onDeferredReloadReady))
                            return false;
                    }
                    catch (Exception error)
                    {
                        onFailed?.Invoke(new EditSaveFailure(error, true, true));
                        return false;
                    }
                    continue;
                }
            }
            if (commitQueue.FirstPending is { CompletionTask: { } pending } firstCommit)
            {
                if (!await pending &&
                    IsCurrentCommitPhoto(firstCommit) &&
                    !commitQueue.HasNewerPendingOrSucceededCommit(firstCommit))
                {
                    return false;
                }
                continue;
            }
            await saveQueue.FlushAsync();
            if (!ApplyPendingCommits(onApplied, onFailed))
            {
                NotifyDeferredReloadIfReady(onDeferredReloadReady);
                return false;
            }
            if (EditDirty && CurrentPath != null && captureEdit != null)
                continue;
            NotifyDeferredReloadIfReady(onDeferredReloadReady);
            return true;
        }
    }

    internal bool DrainPendingSynchronously(
        Action<EditSaveSuccess>? onApplied = null,
        Action<EditSaveFailure>? onFailed = null,
        Action? onDeferredReloadReady = null)
    {
        if (HasPendingSaves)
        {
            saveQueue.FlushAsync().GetAwaiter().GetResult();
            if (!ApplyPendingCommits(onApplied, onFailed))
            {
                NotifyDeferredReloadIfReady(onDeferredReloadReady);
                return false;
            }
        }
        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return true;
    }

    internal bool SaveSync(
        Func<(SavedEdit Candidate, SavedEdit? DefaultEdit)> captureEdit,
        bool clearMigrationReceipt = false,
        bool pauseForInteractiveGesture = false,
        Action<EditSaveSuccess>? onApplied = null,
        Action<EditSaveFailure>? onFailed = null,
        Action? onDeferredReloadReady = null)
    {
        ArgumentNullException.ThrowIfNull(captureEdit);
        if (pauseForInteractiveGesture) return true;
        if (!DrainPendingSynchronously(onApplied, onFailed, onDeferredReloadReady))
            return false;
        if (!EditDirty || CurrentPath == null)
            return true;

        var clearReceipt = clearMigrationReceipt || PendingMigrationReceiptClear;
        var (candidate, defaultEdit) = captureEdit();
        var result = CommitSynchronouslyCore(candidate, defaultEdit, clearReceipt, out var previousLook);
        var saved = result.Saved!;
        onApplied?.Invoke(new EditSaveSuccess(saved, previousLook, true, clearReceipt));
        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return true;
    }

    internal AdjustmentOutcome CommitSynchronously(
        SavedEdit candidate,
        SavedEdit? defaultEdit,
        bool clearMigrationReceipt = false,
        Action<EditSaveSuccess>? onApplied = null,
        Action<EditSaveFailure>? onFailed = null,
        Action? onDeferredReloadReady = null)
    {
        if (HasPendingSaves)
        {
            saveQueue.FlushAsync().GetAwaiter().GetResult();
            _ = ApplyPendingCommits(onApplied, onFailed);
        }
        var result = CommitSynchronouslyCore(candidate, defaultEdit, clearMigrationReceipt, out var previousLook);
        var saved = result.Saved!;
        onApplied?.Invoke(new EditSaveSuccess(saved, previousLook, true, clearMigrationReceipt));
        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return result;
    }

    internal PhotoEditState? AdoptSavedEdit(PhotoEditState saved, bool hasActiveDraft)
    {
        ArgumentNullException.ThrowIfNull(saved);
        if (CurrentPath == null || !SamePath(CurrentPath, saved.Identity.Path))
            return null;
        if (CurrentRecord == null || !CurrentRecord.Identity.SameFile(saved.Identity))
            throw new PhotoChangedException();
        if (EditDirty || hasActiveDraft)
            throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        var session = EnsureTransferSession();
        if (!session.IsCurrentSave(saved))
            throw new AdjustmentOperationExpiredException();

        var previous = CurrentRecord;
        CurrentRecord = saved;
        ++editRevision;
        Interlocked.Increment(ref persistenceEpoch);
        return previous;
    }

    internal ExternalReloadResult HandleExternalEditsChange(
        Func<(SavedEdit? CurrentUi, bool HasUnsavedManualDraft, (double Temperature, double Tint)? AsShot)> captureUiState,
        Action? onStoreReadAttempt = null)
    {
        ArgumentNullException.ThrowIfNull(captureUiState);
        Volatile.Write(ref deferredExternalEditsCheck, false);
        Volatile.Write(ref deferredNotificationPending, 0);

        if (CurrentPath == null)
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);

        if (HasPendingSaves)
        {
            Volatile.Write(ref deferredExternalEditsCheck, true);
            Volatile.Write(ref deferredNotificationPending, 1);
            Interlocked.MemoryBarrier();
            if (HasPendingSaves)
                return new ExternalReloadResult(ExternalReloadAction.Deferred, ExternalReloadBanner);
            Volatile.Write(ref deferredExternalEditsCheck, false);
            Volatile.Write(ref deferredNotificationPending, 0);
        }

        EditStore activeStore;
        try
        {
            activeStore = EnsureStore();
        }
        catch
        {
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);
        }

        var editsPath = Path.GetFullPath(activeStore.RegistryPath);
        var currentStamp = PathStatStamp.Capture(editsPath);
        if (activeStore.LastWriteStamp is { } lastWrite && lastWrite == currentStamp)
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);

        onStoreReadAttempt?.Invoke();

        PhotoEditState diskRecord;
        try
        {
            diskRecord = activeStore.ReadState(CurrentPath);
        }
        catch
        {
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);
        }

        var (currentUi, hasUnsavedManualDraft, asShot) = captureUiState();
        return EvaluateExternalEditsRecord(diskRecord, currentStamp, currentUi, hasUnsavedManualDraft, asShot);
    }

    internal ExternalReloadResult EvaluateExternalEditsRecord(
        PhotoEditState diskRecord,
        PathStatStamp? stamp,
        SavedEdit? currentUi,
        bool hasUnsavedManualDraft,
        (double Temperature, double Tint)? asShotCalibration)
    {
        ArgumentNullException.ThrowIfNull(diskRecord);
        if (CurrentPath == null || CurrentRecord == null)
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);

        if (HasPendingSaves)
        {
            Volatile.Write(ref deferredExternalEditsCheck, true);
            Volatile.Write(ref deferredNotificationPending, 1);
            Interlocked.MemoryBarrier();
            if (HasPendingSaves)
                return new ExternalReloadResult(ExternalReloadAction.Deferred, ExternalReloadBanner);
            Volatile.Write(ref deferredExternalEditsCheck, false);
            Volatile.Write(ref deferredNotificationPending, 0);
        }

        var evaluation = ExternalReloadBanner.Evaluate(
            CurrentRecord,
            currentUi,
            diskRecord,
            stamp,
            hasUnsavedManualDraft,
            hasPendingAsyncSave: false,
            asShotCalibration: asShotCalibration);

        ExternalReloadBanner = evaluation.NextState;

        if (evaluation.Decision == ExternalReloadDecision.AutoReload)
        {
            if (TryAdoptExternalReloadRecord(diskRecord, out var adopted, out var previous))
                return new ExternalReloadResult(ExternalReloadAction.AutoReload, ExternalReloadBanner, adopted, previous);
            return new ExternalReloadResult(ExternalReloadAction.BannerUpdated, ExternalReloadBanner);
        }

        var action = evaluation.Decision == ExternalReloadDecision.ShowBanner
            ? ExternalReloadAction.BannerUpdated
            : ExternalReloadAction.None;
        return new ExternalReloadResult(action, ExternalReloadBanner);
    }

    internal ExternalReloadResult RequestExternalReloadAccept()
    {
        if (HasPendingSaves)
        {
            Volatile.Write(ref deferredExternalReloadAccept, true);
            Volatile.Write(ref deferredExternalEditsCheck, true);
            Volatile.Write(ref deferredNotificationPending, 1);
            Interlocked.MemoryBarrier();
            if (HasPendingSaves)
                return new ExternalReloadResult(ExternalReloadAction.Deferred, ExternalReloadBanner);
            Volatile.Write(ref deferredExternalReloadAccept, false);
            Volatile.Write(ref deferredExternalEditsCheck, false);
            Volatile.Write(ref deferredNotificationPending, 0);
        }

        Volatile.Write(ref deferredExternalReloadAccept, false);
        Volatile.Write(ref deferredExternalEditsCheck, false);
        Volatile.Write(ref deferredNotificationPending, 0);

        if (!ExternalReloadBanner.TryAcceptReload(false, out var diskRecord) || diskRecord == null)
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);

        ExternalReloadBanner = ExternalReloadBanner.AcceptReload();
        EditDirty = false;
        PendingMigrationReceiptClear = false;
        ++editRevision;
        Interlocked.Increment(ref persistenceEpoch);

        if (TryAdoptExternalReloadRecord(diskRecord, out var adopted, out var previous))
            return new ExternalReloadResult(ExternalReloadAction.AutoReload, ExternalReloadBanner, adopted, previous, FromManualAccept: true);

        return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);
    }

    internal ExternalReloadResult FlushDeferredExternalReload(
        Func<(SavedEdit? CurrentUi, bool HasUnsavedManualDraft, (double Temperature, double Tint)? AsShot)> captureUiState,
        Action? onStoreReadAttempt = null)
    {
        ArgumentNullException.ThrowIfNull(captureUiState);
        if (HasPendingSaves)
            return new ExternalReloadResult(ExternalReloadAction.Deferred, ExternalReloadBanner);

        if (Volatile.Read(ref deferredExternalReloadAccept))
            return RequestExternalReloadAccept();

        if (!Volatile.Read(ref deferredExternalEditsCheck))
            return new ExternalReloadResult(ExternalReloadAction.None, ExternalReloadBanner);

        return HandleExternalEditsChange(captureUiState, onStoreReadAttempt);
    }

    internal ExternalReloadBannerState KeepManualDraft()
    {
        Volatile.Write(ref deferredExternalReloadAccept, false);
        ExternalReloadBanner = ExternalReloadBanner.KeepManualDraft();
        return ExternalReloadBanner;
    }

    internal ExternalReloadBannerState ClearExternalReloadOnSourceChange()
    {
        ClearDeferredFlags();
        ExternalReloadBanner = ExternalReloadBanner.ClearOnSourceChange();
        return ExternalReloadBanner;
    }

    internal async Task<ProcessingMigrationCommitResult> CommitProcessingMigrationAsync(
        OriginalIdentity source,
        SavedEdit before,
        SavedEdit targetEdit,
        string status,
        string path,
        Func<bool> isStillCurrent,
        Action? onDeferredReloadReady = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(targetEdit);
        ArgumentNullException.ThrowIfNull(status);
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(isStillCurrent);
        CaptureSyncContext();

        var activeStore = EnsureStore();
        var (saved, receipt) = await saveQueue.RunAsync(() =>
        {
            var committed = activeStore.CommitProcessingMigration(source, before, targetEdit, status);
            return (committed, activeStore.ReadProcessingMigration(path));
        });

        if (!isStillCurrent())
        {
            NotifyDeferredReloadIfReady(onDeferredReloadReady);
            return new ProcessingMigrationCommitResult(Applied: false, Migrated: false);
        }

        var session = EnsureTransferSession();
        var previous = CurrentRecord;
        var migrated = status == ProcessingMigrationReceipt.Migrated;
        if (migrated)
        {
            session.AdoptExternalProcessingMigration(saved);
            CurrentRecord = saved;
            EditDirty = false;
            PendingMigrationReceiptClear = false;
            ++editRevision;
            Interlocked.Increment(ref persistenceEpoch);
        }
        else
        {
            session.RememberExternalSave(saved);
            CurrentRecord = saved;
        }

        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return new ProcessingMigrationCommitResult(
            Applied: true,
            Migrated: migrated,
            Saved: saved,
            PreviousRecord: previous,
            Receipt: receipt);
    }

    internal async Task<ProcessingMigrationCommitResult> RollbackProcessingMigrationAsync(
        string path,
        Func<Task<bool>> flushPendingSavesAsync,
        Func<bool> canProceedAfterFlush,
        bool hasActiveDraft,
        Action? onDeferredReloadReady = null)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(flushPendingSavesAsync);
        ArgumentNullException.ThrowIfNull(canProceedAfterFlush);
        CaptureSyncContext();

        if (!await flushPendingSavesAsync())
            return new ProcessingMigrationCommitResult(Applied: false, Migrated: false);

        if (!canProceedAfterFlush() || CurrentRecord is not { } before)
        {
            NotifyDeferredReloadIfReady(onDeferredReloadReady);
            return new ProcessingMigrationCommitResult(Applied: false, Migrated: false);
        }

        var activeStore = EnsureStore();
        var identity = before.Identity;
        var (saved, receipt) = await saveQueue.RunAsync(() =>
        {
            var rolledBack = activeStore.RollbackProcessingMigration(identity, before);
            return (rolledBack, activeStore.ReadProcessingMigration(path));
        });

        if (!canProceedAfterFlush())
        {
            NotifyDeferredReloadIfReady(onDeferredReloadReady);
            return new ProcessingMigrationCommitResult(Applied: false, Migrated: false);
        }

        var session = EnsureTransferSession();
        session.AdoptExternalProcessingMigration(saved);
        var previous = AdoptSavedEdit(saved, hasActiveDraft);
        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return new ProcessingMigrationCommitResult(
            Applied: previous != null,
            Migrated: false,
            Saved: saved,
            PreviousRecord: previous,
            Receipt: receipt);
    }

    private AdjustmentOutcome CommitSynchronouslyCore(
        SavedEdit candidate,
        SavedEdit? defaultEdit,
        bool clearMigrationReceipt,
        out string? previousLook)
    {
        var session = EnsureTransferSession();
        var before = CurrentRecord ?? new PhotoEditState(candidate.Identity, null);
        previousLook = before.Edit?.Look;
        var result = session.CommitEdit(before, candidate, defaultEdit, clearMigrationReceipt: clearMigrationReceipt);
        if (result.Status is not (AdjustmentStatus.Applied or AdjustmentStatus.Unchanged))
            throw result.Error ?? new InvalidOperationException("Adjustment was not saved.");

        CurrentRecord = result.Saved;
        EditDirty = false;
        PendingMigrationReceiptClear = false;
        Interlocked.Increment(ref persistenceEpoch);
        return result;
    }

    private bool TryAdoptExternalReloadRecord(
        PhotoEditState diskRecord,
        out PhotoEditState? adoptedRecord,
        out PhotoEditState? previousRecord)
    {
        adoptedRecord = null;
        previousRecord = null;
        if (CurrentPath == null || CurrentRecord == null) return false;
        var outcome = EnsureTransferSession().AdoptExternalReload(CurrentRecord, diskRecord);
        if (outcome.Status != AdjustmentStatus.Applied) return false;

        previousRecord = CurrentRecord;
        var saved = outcome.Saved ?? diskRecord;
        CurrentRecord = saved;
        EditDirty = false;
        PendingMigrationReceiptClear = false;
        ++editRevision;
        Interlocked.Increment(ref persistenceEpoch);
        adoptedRecord = saved;
        return true;
    }

    private async Task<bool> CompleteQueuedSaveAsync(
        PendingEditSaveCommit commit,
        Action<EditSaveSuccess>? onApplied,
        Action<EditSaveFailure>? onFailed,
        Action? onDeferredReloadReady)
    {
        try
        {
            await commit.QueueTask;
        }
        catch
        {
            // ApplyResult observes and handles QueueTask exceptions on the UI thread.
        }
        var succeeded = commitQueue.ApplyResult(
            commit,
            IsCurrentCommitPhoto,
            IsCurrentCommitRevision,
            (c, saved, isCurrentRev) => HandleCommitApplied(c, saved, isCurrentRev, onApplied),
            (c, error, shouldShow) => HandleCommitFailed(c, error, shouldShow, onFailed));
        NotifyDeferredReloadIfReady(onDeferredReloadReady);
        return succeeded;
    }

    private bool ApplyPendingCommits(
        Action<EditSaveSuccess>? onApplied,
        Action<EditSaveFailure>? onFailed) =>
        commitQueue.ApplyPending(
            IsCurrentCommitPhoto,
            IsCurrentCommitRevision,
            (c, saved, isCurrentRev) => HandleCommitApplied(c, saved, isCurrentRev, onApplied),
            (c, error, shouldShow) => HandleCommitFailed(c, error, shouldShow, onFailed));

    private bool IsCurrentCommitPhoto(PendingEditSaveCommit commit) =>
        SamePath(CurrentPath, commit.Path) &&
        OpenRevision == commit.OpenRevision &&
        PersistenceEpoch == commit.Epoch;

    private bool IsCurrentCommitRevision(PendingEditSaveCommit commit) =>
        editRevision == commit.Revision;

    private void HandleCommitApplied(
        PendingEditSaveCommit commit,
        PhotoEditState saved,
        bool isCurrentRevision,
        Action<EditSaveSuccess>? onApplied)
    {
        CurrentRecord = saved;
        var clearApplied = false;
        if (isCurrentRevision)
        {
            EditDirty = false;
            PendingMigrationReceiptClear = false;
            clearApplied = Volatile.Read(ref commit.ClearReceipt);
        }
        onApplied?.Invoke(new EditSaveSuccess(saved, commit.PreviousLook, isCurrentRevision, clearApplied));
    }

    private void HandleCommitFailed(
        PendingEditSaveCommit commit,
        Exception error,
        bool shouldShowNotice,
        Action<EditSaveFailure>? onFailed)
    {
        onFailed?.Invoke(new EditSaveFailure(error, shouldShowNotice, IsCurrentCommitPhoto(commit)));
    }

    private void NotifyDeferredReloadIfReady(Action? onDeferredReloadReady)
    {
        Interlocked.MemoryBarrier();
        if (HasPendingSaves || !HasDeferredExternalCheck)
            return;
        if (onDeferredReloadReady != null)
        {
            onDeferredReloadReady.Invoke();
            if (HasPendingSaves || !HasDeferredExternalCheck)
                return;
        }
        if (Interlocked.Exchange(ref deferredNotificationPending, 0) == 1)
            DeferredExternalCheckReady?.Invoke();
    }

    private void OnSaveQueueBecameIdle()
    {
        if (!HasDeferredExternalCheck) return;
        DispatchToUi(() =>
        {
            if (!HasPendingSaves && HasDeferredExternalCheck &&
                Interlocked.Exchange(ref deferredNotificationPending, 0) == 1)
            {
                DeferredExternalCheckReady?.Invoke();
            }
        });
    }

    private void CaptureSyncContext()
    {
        if (scheduleUi == null && SynchronizationContext.Current is { } current)
            Volatile.Write(ref capturedSyncContext, current);
    }

    private void DispatchToUi(Action action)
    {
        if (scheduleUi != null)
        {
            scheduleUi(action);
            return;
        }
        if (Volatile.Read(ref capturedSyncContext) is { } context)
        {
            context.Post(_ => action(), null);
            return;
        }
        action();
    }

    private void ClearDeferredFlags()
    {
        Volatile.Write(ref deferredExternalEditsCheck, false);
        Volatile.Write(ref deferredExternalReloadAccept, false);
        Volatile.Write(ref deferredNotificationPending, 0);
    }

    private static bool SamePath(string? left, string? right) =>
        left != null && right != null && StringComparer.OrdinalIgnoreCase.Equals(left, right);
}
