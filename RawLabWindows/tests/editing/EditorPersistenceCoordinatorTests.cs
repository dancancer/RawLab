using System.IO;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class EditorPersistenceCoordinatorTests
{
    private sealed class SerialSynchronizationContext : SynchronizationContext
    {
        private readonly Queue<(SendOrPostCallback Callback, object? State)> queue = new();
        private bool finished;

        public override void Post(SendOrPostCallback d, object? state)
        {
            lock (queue)
            {
                queue.Enqueue((d, state));
                Monitor.Pulse(queue);
            }
        }

        public override SynchronizationContext CreateCopy() => this;

        public void Complete()
        {
            lock (queue)
            {
                finished = true;
                Monitor.Pulse(queue);
            }
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

    private static Task RunOnSerialUiContext(Func<Task> body)
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
            return task;
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }

    private static SavedEdit MakeEdit(OriginalIdentity identity, double exposure, int processingVersion = 3)
    {
        var settings = new Adjustments { ExposureMode = 2, Processing = new ProcessingIdentity("rawlab", processingVersion, "standard") };
        settings.Set(Parameter.Exposure, exposure);
        return new SavedEdit(identity, settings.Capture(), null);
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task CoalescesQueuedSavesAndRunsOffUiThreadWithSerialContext()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-coalesce-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.arw");
            File.WriteAllText(photo, "raw-fixture");
            var identity = OriginalIdentity.Read(photo);

            using var firstWriteEntered = new ManualResetEventSlim(false);
            using var allowFirstWrite = new ManualResetEventSlim(false);
            var writeCount = 0;
            var writeThreadId = -1;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                writeThreadId = Environment.CurrentManagedThreadId;
                var count = Interlocked.Increment(ref writeCount);
                if (count == 1)
                {
                    firstWriteEntered.Set();
                    Assert.True(allowFirstWrite.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var uiThreadId = Environment.CurrentManagedThreadId;
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                coordinator.BeginOpen(photo, new PhotoEditState(identity, null));

                coordinator.MarkEdited(canPersist: true);
                var t1 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.5), null));
                Assert.True(firstWriteEntered.Wait(TimeSpan.FromSeconds(5)));

                // Rapid edits while Save #1 is in flight coalesce unstarted tail saves and OR ClearReceipt.
                coordinator.MarkEdited(canPersist: true, clearMigrationReceipt: true);
                var t2 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 1.0), null), clearMigrationReceipt: true);
                coordinator.MarkEdited(canPersist: true);
                var t3 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 1.5), null));

                Assert.True(await t2);
                allowFirstWrite.Set();
                Assert.True(await t1);
                Assert.True(await t3);
                Assert.True(await coordinator.FlushAsync(() => (MakeEdit(identity, 1.5), null)));

                Assert.Equal(2, writeCount);
                Assert.NotEqual(uiThreadId, writeThreadId);
                Assert.False(coordinator.EditDirty);
                Assert.False(coordinator.PendingMigrationReceiptClear);
                Assert.Equal(1.5, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task ExternalChangeDuringInFlightSaveIsDeferredUntilDrainAndDoesNotClobberNewerSave()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-defer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.png");
            File.WriteAllBytes(photo, [1, 2, 3, 4]);
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            using var firstWriteEntered = new ManualResetEventSlim(false);
            using var allowFirstWrite = new ManualResetEventSlim(false);
            var armed = false;
            var writeCount = 0;

            var store = new EditStore(editsDir, (path, payload) =>
            {
                if (Volatile.Read(ref armed) && Interlocked.Increment(ref writeCount) == 1)
                {
                    firstWriteEntered.Set();
                    Assert.True(allowFirstWrite.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });
            var externalStore = new EditStore(editsDir);

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                var initial = store.SaveState(identity, MakeEdit(identity, 0.2));
                coordinator.BeginOpen(photo, initial);

                coordinator.MarkEdited(canPersist: true);
                Volatile.Write(ref armed, true);
                var currentExposure = 0.8;
                var saveTask = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, currentExposure), null));
                Assert.True(firstWriteEntered.Wait(TimeSpan.FromSeconds(5)));

                // External change arrives while Save #1 is blocked in EditStore.
                // Coordinator must defer without reading/overwriting active UI state.
                var readAttemptedWhileInFlight = false;
                var deferredResult = coordinator.HandleExternalEditsChange(
                    () => (MakeEdit(identity, currentExposure), coordinator.EditDirty, null),
                    onStoreReadAttempt: () => readAttemptedWhileInFlight = true);

                Assert.Equal(ExternalReloadAction.Deferred, deferredResult.Action);
                Assert.True(coordinator.HasDeferredExternalCheck);
                Assert.False(readAttemptedWhileInFlight);
                Assert.Equal(0.2, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);

                allowFirstWrite.Set();
                Assert.True(await saveTask);

                // After Save #1 drains, self-write stamp matches LastWriteStamp -> no spurious AutoReload.
                var drainedSelfWrite = coordinator.FlushDeferredExternalReload(
                    () => (MakeEdit(identity, currentExposure), coordinator.EditDirty, null));
                Assert.Equal(ExternalReloadAction.None, drainedSelfWrite.Action);
                Assert.False(coordinator.HasDeferredExternalCheck);
                Assert.Equal(0.8, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);

                // Now start Save #2, block it, write an external update while Save #2 is blocked? No, write after Save #1:
                // Verify a genuine external update while another save is queued wakes up via BecameIdle / FlushDeferred.
                externalStore.SaveState(identity, MakeEdit(identity, 1.4));
                var reloaded = coordinator.HandleExternalEditsChange(
                    () => (MakeEdit(identity, currentExposure), coordinator.EditDirty, null));
                Assert.Equal(ExternalReloadAction.AutoReload, reloaded.Action);
                Assert.False(reloaded.FromManualAccept);
                Assert.Equal(1.4, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task RequestExternalReloadAcceptDuringInFlightSaveDefersUntilDrainThenApplies()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-accept-defer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.png");
            File.WriteAllBytes(photo, [5, 6, 7, 8]);
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            using var writeEntered = new ManualResetEventSlim(false);
            using var allowWrite = new ManualResetEventSlim(false);
            var store = new EditStore(editsDir, (path, payload) =>
            {
                writeEntered.Set();
                Assert.True(allowWrite.Wait(TimeSpan.FromSeconds(5)));
                AtomicJson.Write(path, payload);
            });
            var externalStore = new EditStore(editsDir);

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                var baseline = externalStore.SaveState(identity, MakeEdit(identity, 0.1));
                coordinator.BeginOpen(photo, baseline);

                // External change while user has a dirty manual draft shows banner.
                var extDisk = externalStore.SaveState(identity, MakeEdit(identity, 1.35));
                var stamp = PathStatStamp.Capture(store.RegistryPath);
                coordinator.MarkEdited(canPersist: true);
                var bannerEval = coordinator.EvaluateExternalEditsRecord(
                    extDisk,
                    stamp,
                    MakeEdit(identity, -0.4),
                    hasUnsavedManualDraft: true,
                    asShotCalibration: null);
                Assert.Equal(ExternalReloadAction.BannerUpdated, bannerEval.Action);
                Assert.True(coordinator.ExternalReloadBanner.Visible);

                // Start an async save, then user clicks Reload while save is in flight.
                var saveTask = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, -0.4), null));
                Assert.True(writeEntered.Wait(TimeSpan.FromSeconds(5)));

                var deferredAccept = coordinator.RequestExternalReloadAccept();
                Assert.Equal(ExternalReloadAction.Deferred, deferredAccept.Action);
                Assert.True(coordinator.ExternalReloadBanner.Visible);
                Assert.True(coordinator.HasDeferredExternalCheck);

                var idleTcs = new TaskCompletionSource<ExternalReloadResult>(TaskCreationOptions.RunContinuationsAsynchronously);
                coordinator.DeferredExternalCheckReady += () =>
                {
                    var res = coordinator.FlushDeferredExternalReload(
                        () => (MakeEdit(identity, -0.4), coordinator.EditDirty, null));
                    idleTcs.TrySetResult(res);
                };

                var epochBeforeDrain = coordinator.PersistenceEpoch;
                var editRevBeforeDrain = coordinator.EditRevision;
                allowWrite.Set();
                Assert.True(await saveTask);

                var applied = await idleTcs.Task.WaitAsync(TimeSpan.FromSeconds(5));
                Assert.Equal(ExternalReloadAction.AutoReload, applied.Action);
                Assert.True(applied.FromManualAccept);
                Assert.False(coordinator.ExternalReloadBanner.Visible);
                Assert.False(coordinator.EditDirty);
                Assert.True(coordinator.PersistenceEpoch > epochBeforeDrain);
                Assert.True(coordinator.EditRevision > editRevBeforeDrain);
                Assert.Equal(1.35, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
                Assert.NotNull(coordinator.AdjustmentSession!.PhotoHistoryID(photo, undo: true));
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task StaleQueuedSaveIsSupersededOnEpochBumpAndLateCompletionCannotOverwriteNewerState()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-epoch-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoA = Path.Combine(root, "a.arw");
            var photoB = Path.Combine(root, "b.arw");
            File.WriteAllText(photoA, "raw-a");
            File.WriteAllText(photoB, "raw-b");
            var idA = OriginalIdentity.Read(photoA);
            var idB = OriginalIdentity.Read(photoB);

            using var write1Entered = new ManualResetEventSlim(false);
            using var allowWrite1 = new ManualResetEventSlim(false);
            var writeCount = 0;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                if (Interlocked.Increment(ref writeCount) == 1)
                {
                    write1Entered.Set();
                    Assert.True(allowWrite1.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                var appliedNotices = new List<EditSaveSuccess>();
                coordinator.BeginOpen(photoA, new PhotoEditState(idA, null));

                // Save #1 enters EditStore and blocks.
                coordinator.MarkEdited(canPersist: true);
                var t1 = coordinator.EnqueueSaveAsync(
                    () => (MakeEdit(idA, 0.5), null),
                    onApplied: s => appliedNotices.Add(s));
                Assert.True(write1Entered.Wait(TimeSpan.FromSeconds(5)));

                // Save #2 is queued behind Save #1.
                coordinator.MarkEdited(canPersist: true);
                var t2 = coordinator.EnqueueSaveAsync(
                    () => (MakeEdit(idA, 1.25), null),
                    onApplied: s => appliedNotices.Add(s));

                // Switching photo (BeginOpen) bumps OpenRevision & PersistenceEpoch!
                var recordB = new PhotoEditState(idB, MakeEdit(idB, -0.75));
                coordinator.BeginOpen(photoB, recordB);
                coordinator.MarkEdited(canPersist: true); // Dirty in new epoch must NOT be cleared by stale Save #1!

                allowWrite1.Set();
                Assert.True(await t1);
                Assert.True(await t2);

                // Save #2 must have been superseded BEFORE touching EditStore (writeCount stays 1).
                Assert.Equal(1, writeCount);
                // Late Save #1 completion must NOT clobber photoB's record, EditDirty, or emit onApplied.
                Assert.Empty(appliedNotices);
                Assert.True(coordinator.EditDirty);
                Assert.Same(recordB, coordinator.CurrentRecord);
                Assert.Equal(-0.75, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task ExternalChangeDuringProcessingMigrationWaitsForQueueDrain()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-migration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.arw");
            File.WriteAllText(photo, "raw-migration");
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            using var migrationEntered = new ManualResetEventSlim(false);
            using var allowMigration = new ManualResetEventSlim(false);
            var store = new EditStore(editsDir, (path, payload) =>
            {
                if (System.Text.Json.JsonSerializer.Serialize(payload).Contains("\"version\":3", StringComparison.Ordinal))
                {
                    migrationEntered.Set();
                    Assert.True(allowMigration.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });
            var externalStore = new EditStore(editsDir);

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                var legacyEdit = MakeEdit(identity, 0.25, processingVersion: 2);
                var initial = externalStore.SaveState(identity, legacyEdit);
                coordinator.BeginOpen(photo, initial);

                var migratedEdit = MakeEdit(identity, 0.30, processingVersion: 3);
                var migrationTask = coordinator.CommitProcessingMigrationAsync(
                    identity,
                    legacyEdit,
                    migratedEdit,
                    ProcessingMigrationReceipt.Migrated,
                    photo,
                    isStillCurrent: () => true);

                Assert.True(migrationEntered.Wait(TimeSpan.FromSeconds(5)));

                // External check while migration is running in saveQueue must defer!
                var deferred = coordinator.HandleExternalEditsChange(
                    () => (migratedEdit, coordinator.EditDirty, null));
                Assert.Equal(ExternalReloadAction.Deferred, deferred.Action);
                Assert.True(coordinator.HasDeferredExternalCheck);

                allowMigration.Set();
                var migrationOutcome = await migrationTask;
                Assert.True(migrationOutcome.Applied);
                Assert.True(migrationOutcome.Migrated);
                Assert.Equal(3, coordinator.CurrentRecord!.Edit!.Settings.Processing.Version);

                var drained = coordinator.FlushDeferredExternalReload(
                    () => (migratedEdit, coordinator.EditDirty, null));
                Assert.Equal(ExternalReloadAction.None, drained.Action);
                Assert.False(coordinator.HasDeferredExternalCheck);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task SyncDrainAppliesQueuedCommitsInOrderBeforeCommitSynchronouslyAndReset()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-syncdrain-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.arw");
            File.WriteAllText(photo, "raw-sync");
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            using var write1Entered = new ManualResetEventSlim(false);
            using var allowWrite1 = new ManualResetEventSlim(false);
            var armed = false;
            var writeCount = 0;

            var store = new EditStore(editsDir, (path, payload) =>
            {
                if (Volatile.Read(ref armed) && Interlocked.Increment(ref writeCount) == 1)
                {
                    write1Entered.Set();
                    Assert.True(allowWrite1.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                var legacy = MakeEdit(identity, 0.1, processingVersion: 2);
                var initial = store.SaveState(identity, legacy);
                store.CommitProcessingMigration(identity, legacy, MakeEdit(identity, 0.1, processingVersion: 3), ProcessingMigrationReceipt.Migrated);
                Assert.NotNull(store.ReadProcessingMigration(photo));

                coordinator.BeginOpen(photo, store.ReadState(photo));
                writeCount = 0;
                Volatile.Write(ref armed, true);

                // Queue Save #1 (in flight) and Save #2 (queued).
                coordinator.MarkEdited(canPersist: true);
                var t1 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.5), null));
                Assert.True(write1Entered.Wait(TimeSpan.FromSeconds(5)));

                coordinator.MarkEdited(canPersist: true);
                var t2 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 1.1), null));

                // Deferred external reload check latched while queue busy.
                Assert.Equal(
                    ExternalReloadAction.Deferred,
                    coordinator.HandleExternalEditsChange(() => (MakeEdit(identity, 1.1), coordinator.EditDirty, null)).Action);

                allowWrite1.Set();
                var deferredNotified = false;
                // CommitSynchronously with clearMigrationReceipt:true must drain t1 + t2 in FIFO order BEFORE committing reset.
                var resetOutcome = coordinator.CommitSynchronously(
                    MakeEdit(identity, 0.0),
                    defaultEdit: null,
                    clearMigrationReceipt: true,
                    onDeferredReloadReady: () => deferredNotified = true);

                Assert.Equal(AdjustmentStatus.Applied, resetOutcome.Status);
                Assert.True(deferredNotified);
                Assert.False(coordinator.EditDirty);
                Assert.Null(store.ReadProcessingMigration(photo));
                Assert.Equal(0.0, coordinator.CurrentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);

                Assert.True(await t1);
                Assert.True(await t2);
                Assert.Equal(3, coordinator.AdjustmentSession!.Transactions.Count);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task DeferredExternalCheckReadyFiresInHeadlessContextAndWhenScheduleUiOutracesCompletion()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-race1bc-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.arw");
            File.WriteAllText(photo, "raw-race1");
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            // Race1B: headless context (SynchronizationContext.Current == null) and onDeferredReloadReady == null.
            for (var i = 0; i < 20; i++)
            {
                var iterEditsDir = Path.Combine(root, $"edits-1b-{i}");
                using var writeEntered = new ManualResetEventSlim(false);
                using var allowWrite = new ManualResetEventSlim(false);
                var store = new EditStore(iterEditsDir, (path, payload) =>
                {
                    writeEntered.Set();
                    Assert.True(allowWrite.Wait(TimeSpan.FromSeconds(5)));
                    AtomicJson.Write(path, payload);
                });
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                coordinator.BeginOpen(photo, new PhotoEditState(identity, null));
                var readyTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                coordinator.DeferredExternalCheckReady += () =>
                {
                    _ = coordinator.FlushDeferredExternalReload(() => (MakeEdit(identity, 0.4), coordinator.EditDirty, null));
                    readyTcs.TrySetResult(true);
                };

                coordinator.MarkEdited(canPersist: true);
                var saveTask = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.4), null));
                Assert.True(writeEntered.Wait(TimeSpan.FromSeconds(5)));
                Assert.Equal(
                    ExternalReloadAction.Deferred,
                    coordinator.HandleExternalEditsChange(() => (MakeEdit(identity, 0.4), coordinator.EditDirty, null)).Action);

                allowWrite.Set();
                Assert.True(await saveTask);
                Assert.True(await readyTcs.Task.WaitAsync(TimeSpan.FromSeconds(5)));
                Assert.False(coordinator.HasDeferredExternalCheck);
            }

            // Race1C: scheduleUi outraces CompleteQueuedSaveAsync's continuation before commitQueue drains.
            for (var i = 0; i < 20; i++)
            {
                var race1cEditsDir = Path.Combine(root, $"edits-1c-{i}");
                using var writeEntered = new ManualResetEventSlim(false);
                using var allowWrite = new ManualResetEventSlim(false);
                var store = new EditStore(race1cEditsDir, (path, payload) =>
                {
                    writeEntered.Set();
                    Assert.True(allowWrite.Wait(TimeSpan.FromSeconds(5)));
                    AtomicJson.Write(path, payload);
                });
                await RunOnSerialUiContext(async () =>
                {
                    var coordinator = new EditorPersistenceCoordinator(store, () => store, scheduleUi: action => action());
                    coordinator.BeginOpen(photo, new PhotoEditState(identity, null));
                    var readyCount = 0;
                    var readyTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    coordinator.DeferredExternalCheckReady += () =>
                    {
                        Interlocked.Increment(ref readyCount);
                        _ = coordinator.FlushDeferredExternalReload(() => (MakeEdit(identity, 0.7), coordinator.EditDirty, null));
                        readyTcs.TrySetResult(true);
                    };

                    coordinator.MarkEdited(canPersist: true);
                    var saveTask = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.7), null));
                    Assert.True(writeEntered.Wait(TimeSpan.FromSeconds(5)));
                    Assert.Equal(
                        ExternalReloadAction.Deferred,
                        coordinator.HandleExternalEditsChange(() => (MakeEdit(identity, 0.7), coordinator.EditDirty, null)).Action);

                    allowWrite.Set();
                    Assert.True(await saveTask);
                    Assert.True(await readyTcs.Task.WaitAsync(TimeSpan.FromSeconds(5)));
                    Assert.Equal(1, Volatile.Read(ref readyCount));
                    Assert.False(coordinator.HasDeferredExternalCheck);
                });
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task EpochBumpWithoutOpenRevisionBumpDoesNotCoalesceClearMigrationReceiptAcrossEpochs()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-race2d-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.arw");
            File.WriteAllText(photo, "raw-race2d");
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "edits");

            using var firstWriteEntered = new ManualResetEventSlim(false);
            using var allowFirstWrite = new ManualResetEventSlim(false);
            var armed = false;
            var writeCount = 0;

            var store = new EditStore(editsDir, (path, payload) =>
            {
                if (Volatile.Read(ref armed) && Interlocked.Increment(ref writeCount) == 1)
                {
                    firstWriteEntered.Set();
                    Assert.True(allowFirstWrite.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });

            var legacy = MakeEdit(identity, 0.1, processingVersion: 2);
            var migrated = MakeEdit(identity, 0.1, processingVersion: 3);
            store.SaveState(identity, legacy);
            var migratedState = store.CommitProcessingMigration(identity, legacy, migrated, ProcessingMigrationReceipt.Migrated);
            Assert.NotNull(store.ReadProcessingMigration(photo));

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(store, () => store);
                coordinator.BeginOpen(photo, migratedState);
                var initialOpenRev = coordinator.OpenRevision;
                Volatile.Write(ref armed, true);

                // Save #1 blocks in worker.
                coordinator.MarkEdited(canPersist: true);
                var t1 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.5), null));
                Assert.True(firstWriteEntered.Wait(TimeSpan.FromSeconds(5)));

                // Save #2 queued at tail in Epoch E with clearMigrationReceipt: true.
                coordinator.MarkEdited(canPersist: true, clearMigrationReceipt: true);
                var t2 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 0.8), null), clearMigrationReceipt: true);

                // Bump PersistenceEpoch without bumping OpenRevision (e.g., ApplyRestoredOpenState / CompleteTransformCommit).
                coordinator.ApplyRestoredOpenState(photo, migratedState);
                Assert.Equal(initialOpenRev, coordinator.OpenRevision);
                Assert.False(coordinator.PendingMigrationReceiptClear);

                // Save #3 in Epoch E+1 with clearMigrationReceipt: false must NOT coalesce into Save #2.
                coordinator.MarkEdited(canPersist: true, clearMigrationReceipt: false);
                var t3 = coordinator.EnqueueSaveAsync(() => (MakeEdit(identity, 1.2), null), clearMigrationReceipt: false);

                allowFirstWrite.Set();
                Assert.True(await t1);
                Assert.True(await t2);
                Assert.True(await t3);
                Assert.True(await coordinator.FlushAsync(() => (MakeEdit(identity, 1.2), null)));

                Assert.NotNull(store.ReadProcessingMigration(photo));
                Assert.Equal(1.2, store.ReadState(photo).Edit!.Settings.Restore()[Parameter.Exposure]);

                // Also verify CompleteTransformCommit epoch bump without OpenRevision bump stops coalescing.
                var armed2 = false;
                var writeCount2 = 0;
                using var write4Entered = new ManualResetEventSlim(false);
                using var allowWrite4 = new ManualResetEventSlim(false);
                var store2 = new EditStore(Path.Combine(root, "edits2"), (path, payload) =>
                {
                    if (Volatile.Read(ref armed2) && Interlocked.Increment(ref writeCount2) == 1)
                    {
                        write4Entered.Set();
                        Assert.True(allowWrite4.Wait(TimeSpan.FromSeconds(5)));
                    }
                    AtomicJson.Write(path, payload);
                });
                store2.SaveState(identity, legacy);
                var migrated2 = store2.CommitProcessingMigration(identity, legacy, migrated, ProcessingMigrationReceipt.Migrated);
                var coord2 = new EditorPersistenceCoordinator(store2, () => store2);
                coord2.BeginOpen(photo, migrated2);
                Volatile.Write(ref armed2, true);
                coord2.MarkEdited(canPersist: true);
                var t4 = coord2.EnqueueSaveAsync(() => (MakeEdit(identity, 0.3), null));
                Assert.True(write4Entered.Wait(TimeSpan.FromSeconds(5)));
                coord2.MarkEdited(canPersist: true, clearMigrationReceipt: true);
                var t5 = coord2.EnqueueSaveAsync(() => (MakeEdit(identity, 0.6), null), clearMigrationReceipt: true);
                coord2.CompleteTransformCommit(migrated2);
                coord2.MarkEdited(canPersist: true, clearMigrationReceipt: false);
                var t6 = coord2.EnqueueSaveAsync(() => (MakeEdit(identity, 0.9), null), clearMigrationReceipt: false);
                allowWrite4.Set();
                Assert.True(await t4);
                Assert.True(await t5);
                Assert.True(await t6);
                Assert.True(await coord2.FlushAsync(() => (MakeEdit(identity, 0.9), null)));
                Assert.NotNull(store2.ReadProcessingMigration(photo));
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task ObsoleteFailedSaveFromPreviousPhotoOrStoreDoesNotPoisonFlushOrSaveSync()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-coord-race2ef-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoA = Path.Combine(root, "a.arw");
            var photoB = Path.Combine(root, "b.arw");
            File.WriteAllText(photoA, "raw-a");
            File.WriteAllText(photoB, "raw-b");
            var idA = OriginalIdentity.Read(photoA);
            var idB = OriginalIdentity.Read(photoB);

            // Race2E: Photo A save throws IOException after BeginOpen(photoB).
            using var aEntered = new ManualResetEventSlim(false);
            using var allowAFail = new ManualResetEventSlim(false);
            var storeA = new EditStore(Path.Combine(root, "editsA"), (path, payload) =>
            {
                if (System.Text.Json.JsonSerializer.Serialize(payload).Contains("a.arw", StringComparison.OrdinalIgnoreCase))
                {
                    aEntered.Set();
                    Assert.True(allowAFail.Wait(TimeSpan.FromSeconds(5)));
                    throw new IOException("Simulated Photo A failure");
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(storeA, () => storeA);
                coordinator.BeginOpen(photoA, new PhotoEditState(idA, null));
                coordinator.MarkEdited(canPersist: true);
                var failures = new List<EditSaveFailure>();
                var failedTaskA = coordinator.EnqueueSaveAsync(
                    () => (MakeEdit(idA, 0.5), null),
                    onFailed: f => failures.Add(f));
                Assert.True(aEntered.Wait(TimeSpan.FromSeconds(5)));

                coordinator.BeginOpen(photoB, new PhotoEditState(idB, null));
                coordinator.MarkEdited(canPersist: true);
                allowAFail.Set();

                Assert.True(await coordinator.FlushAsync(() => (MakeEdit(idB, 1.1), null)));
                Assert.False(await failedTaskA);
                Assert.Single(failures);
                Assert.False(failures[0].IsCurrentPhoto);
                Assert.False(failures[0].ShouldShowNotice);
                Assert.Equal(1.1, storeA.ReadState(photoB).Edit!.Settings.Restore()[Parameter.Exposure]);
            });

            // Race2F: Broken store save throws IOException after RebindStore(healthyStore), followed by SaveSync.
            using var brokenEntered = new ManualResetEventSlim(false);
            using var allowBrokenFail = new ManualResetEventSlim(false);
            var brokenStore = new EditStore(Path.Combine(root, "editsBroken"), (path, payload) =>
            {
                brokenEntered.Set();
                Assert.True(allowBrokenFail.Wait(TimeSpan.FromSeconds(5)));
                throw new IOException("Simulated broken store failure");
            });
            var healthyStore = new EditStore(Path.Combine(root, "editsHealthy"));

            await RunOnSerialUiContext(async () =>
            {
                var coordinator = new EditorPersistenceCoordinator(brokenStore, () => healthyStore);
                coordinator.BeginOpen(photoA, new PhotoEditState(idA, null));
                coordinator.MarkEdited(canPersist: true);
                var failedBrokenTask = coordinator.EnqueueSaveAsync(() => (MakeEdit(idA, 0.4), null));
                Assert.True(brokenEntered.Wait(TimeSpan.FromSeconds(5)));

                coordinator.RebindStore(healthyStore);
                coordinator.MarkEdited(canPersist: true);
                allowBrokenFail.Set();

                Assert.True(coordinator.SaveSync(() => (MakeEdit(idA, 1.8), null)));
                Assert.False(await failedBrokenTask);
                Assert.False(coordinator.EditDirty);
                Assert.Equal(1.8, healthyStore.ReadState(photoA).Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
}
