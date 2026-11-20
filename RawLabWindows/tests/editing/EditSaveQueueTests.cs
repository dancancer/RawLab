using System.IO;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class EditSaveQueueTests
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

    private static SavedEdit MakeEdit(OriginalIdentity identity, double exposure)
    {
        var settings = new Adjustments();
        settings.Set(Parameter.Exposure, exposure);
        return new SavedEdit(identity, settings.Capture(), null);
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task EnqueueSaveRunsOffUiThreadAndKeepsUiSynchronizationContextResponsive()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-editsave-nonblocking-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoPath = Path.Combine(root, "photo.arw");
            File.WriteAllText(photoPath, "raw-fixture");
            var identity = OriginalIdentity.Read(photoPath);

            using var writeEntered = new ManualResetEventSlim(false);
            using var allowWrite = new ManualResetEventSlim(false);
            var writeThreadId = -1;
            var wroteOnThreadPool = false;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                writeThreadId = Environment.CurrentManagedThreadId;
                wroteOnThreadPool = Thread.CurrentThread.IsThreadPoolThread;
                writeEntered.Set();
                Assert.True(allowWrite.Wait(TimeSpan.FromSeconds(5)));
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var uiThreadId = Environment.CurrentManagedThreadId;
                var queue = new EditSaveQueue();
                var session = new AdjustmentTransferSession(store);
                var before = new PhotoEditState(identity, null);
                var edit = MakeEdit(identity, 0.75);
                var (baseline, desired) = session.PrepareEditCommit(before, edit);

                var saveTask = queue.EnqueueSave(store, photoPath, 1, clearMigrationReceipt: false,
                    clear => store.SaveState(baseline.Identity, desired, clear));

                Assert.True(writeEntered.Wait(TimeSpan.FromSeconds(5)));

                var uiPumpedWhileBlocked = false;
                SynchronizationContext.Current!.Post(_ => uiPumpedWhileBlocked = true, null);
                await Task.Yield();
                Assert.True(uiPumpedWhileBlocked);
                Assert.False(saveTask.IsCompleted);

                allowWrite.Set();
                var workResult = await saveTask;
                Assert.Equal(uiThreadId, Environment.CurrentManagedThreadId);
                Assert.False(workResult.Superseded);
                Assert.NotNull(workResult.Saved);

                var outcome = session.CompleteEditCommit(baseline, workResult.Saved!);
                Assert.Equal(AdjustmentStatus.Applied, outcome.Status);
                Assert.NotEqual(uiThreadId, writeThreadId);
                Assert.True(wroteOnThreadPool);
                Assert.Equal(0.75, store.ReadState(photoPath).Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task CoalescesSamePhotoSavesMergesReceiptClearAndPreservesOrderAcrossPhotos()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-editsave-coalesce-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoA = Path.Combine(root, "a.arw");
            var photoB = Path.Combine(root, "b.arw");
            File.WriteAllText(photoA, "raw-a");
            File.WriteAllText(photoB, "raw-b");
            var idA = OriginalIdentity.Read(photoA);
            var idB = OriginalIdentity.Read(photoB);

            var legacySettings = new Adjustments { Processing = ProcessingIdentity.Legacy };
            var legacyEdit = new SavedEdit(idA, legacySettings.Capture(), null);
            var migratedSettings = new Adjustments { Processing = ProcessingIdentity.Current };
            var migratedEdit = new SavedEdit(idA, migratedSettings.Capture(), null);

            using var firstWriteEntered = new ManualResetEventSlim(false);
            using var allowFirstWrite = new ManualResetEventSlim(false);
            var writeCount = 0;
            var activeWrites = 0;
            var maxConcurrentWrites = 0;
            var gateWrites = false;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                var concurrent = Interlocked.Increment(ref activeWrites);
                try
                {
                    if (concurrent > maxConcurrentWrites) maxConcurrentWrites = concurrent;
                    if (gateWrites)
                    {
                        var count = Interlocked.Increment(ref writeCount);
                        if (count == 1)
                        {
                            firstWriteEntered.Set();
                            Assert.True(allowFirstWrite.Wait(TimeSpan.FromSeconds(5)));
                        }
                    }
                    AtomicJson.Write(path, payload);
                }
                finally
                {
                    Interlocked.Decrement(ref activeWrites);
                }
            });

            _ = store.SaveState(idA, legacyEdit);
            _ = store.CommitProcessingMigration(idA, legacyEdit, migratedEdit, ProcessingMigrationReceipt.Migrated);
            Assert.NotNull(store.ReadProcessingMigration(photoA));
            gateWrites = true;

            await RunOnSerialUiContext(async () =>
            {
                var queue = new EditSaveQueue();
                var session = new AdjustmentTransferSession(store);
                var beforeA = store.ReadState(photoA);
                var e1 = MakeEdit(idA, 0.5);
                var e2 = MakeEdit(idA, 1.0);
                var e3 = MakeEdit(idA, 1.5);
                var eB = MakeEdit(idB, -0.5);

                var (b1, d1) = session.PrepareEditCommit(beforeA, e1);
                var t1 = queue.EnqueueSave(store, photoA, 1, clearMigrationReceipt: false,
                    clear => store.SaveState(b1.Identity, d1, clear));
                Assert.True(firstWriteEntered.Wait(TimeSpan.FromSeconds(5)));

                var observedClearFlags = new List<bool>();
                var (b2, d2) = session.PrepareEditCommit(beforeA, e2);
                var t2 = queue.EnqueueSave(store, photoA, 1, clearMigrationReceipt: true,
                    clear => { observedClearFlags.Add(clear); return store.SaveState(b2.Identity, d2, clear); });

                var (b3, d3) = session.PrepareEditCommit(beforeA, e3);
                var t3 = queue.EnqueueSave(store, photoA, 1, clearMigrationReceipt: false,
                    clear => { observedClearFlags.Add(clear); return store.SaveState(b3.Identity, d3, clear); });

                var beforeB = new PhotoEditState(idB, null);
                var (bB, dB) = session.PrepareEditCommit(beforeB, eB);
                var tB = queue.EnqueueSave(store, photoB, 2, clearMigrationReceipt: false,
                    clear => store.SaveState(bB.Identity, dB, clear));

                var r2 = await t2;
                Assert.True(r2.Superseded);

                allowFirstWrite.Set();
                var r1 = await t1;
                var r3 = await t3;
                var rB = await tB;
                await queue.FlushAsync();

                Assert.False(r1.Superseded);
                Assert.False(r3.Superseded);
                Assert.False(rB.Superseded);
                Assert.Equal(3, writeCount);
                Assert.Equal(1, maxConcurrentWrites);
                Assert.Equal(new[] { true }, observedClearFlags);

                Assert.Equal(AdjustmentStatus.Applied, session.CompleteEditCommit(b1, r1.Saved!).Status);
                Assert.Equal(AdjustmentStatus.Applied, session.CompleteEditCommit(b3, r3.Saved!).Status);
                Assert.Equal(AdjustmentStatus.Applied, session.CompleteEditCommit(bB, rB.Saved!).Status);

                Assert.Equal(1.5, store.ReadState(photoA).Edit!.Settings.Restore()[Parameter.Exposure]);
                Assert.Null(store.ReadProcessingMigration(photoA));
                Assert.Equal(-0.5, store.ReadState(photoB).Edit!.Settings.Restore()[Parameter.Exposure]);
                Assert.Equal(3, session.Transactions.Count);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task FailedSavePropagatesErrorAndRecoversOnSubsequentRetry()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-editsave-fault-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoPath = Path.Combine(root, "fault.arw");
            File.WriteAllText(photoPath, "raw-fault");
            var identity = OriginalIdentity.Read(photoPath);

            var failWrites = true;
            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                if (failWrites) throw new IOException("Simulated disk full");
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var queue = new EditSaveQueue();
                var session = new AdjustmentTransferSession(store);
                var before = new PhotoEditState(identity, null);
                var edit = MakeEdit(identity, 1.25);
                var (baseline, desired) = session.PrepareEditCommit(before, edit);

                var failedTask = queue.EnqueueSave(store, photoPath, 1, clearMigrationReceipt: false,
                    clear => store.SaveState(baseline.Identity, desired, clear));
                var error = await Assert.ThrowsAsync<IOException>(async () => await failedTask);
                Assert.Equal("Simulated disk full", error.Message);
                Assert.Null(store.ReadState(photoPath).Edit);

                failWrites = false;
                var retryResult = await queue.EnqueueSave(store, photoPath, 1, clearMigrationReceipt: false,
                    clear => store.SaveState(baseline.Identity, desired, clear));
                await queue.FlushAsync();
                Assert.False(retryResult.Superseded);
                Assert.Equal(AdjustmentStatus.Applied, session.CompleteEditCommit(baseline, retryResult.Saved!).Status);
                Assert.Equal(1.25, store.ReadState(photoPath).Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task SynchronousDrainAppliesPendingCommitsInFifoOrderBeforeStaleDispatcherContinuations()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-editsave-fifo-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoPath = Path.Combine(root, "photo.arw");
            File.WriteAllText(photoPath, "raw-fixture");
            var identity = OriginalIdentity.Read(photoPath);

            using var write1Entered = new ManualResetEventSlim(false);
            using var allowWrite1 = new ManualResetEventSlim(false);
            var writeCount = 0;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                var currentWrite = Interlocked.Increment(ref writeCount);
                if (currentWrite == 1)
                {
                    write1Entered.Set();
                    Assert.True(allowWrite1.Wait(TimeSpan.FromSeconds(5)));
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var queue = new EditSaveQueue();
                var commitQueue = new EditSaveCommitQueue();
                var session = new AdjustmentTransferSession(store);
                PhotoEditState? currentRecord = new PhotoEditState(identity, null);
                long currentEditRevision = 0;
                const long openRevision = 1;
                var editDirty = false;
                var saveNotice = "";
                var retryVisible = false;

                async Task<bool> CompleteAsync(PendingEditSaveCommit commit)
                {
                    try { await commit.QueueTask; } catch { }
                    return commitQueue.ApplyResult(
                        commit,
                        c => c.Path == photoPath && c.OpenRevision == openRevision,
                        c => c.Revision == currentEditRevision,
                        (c, saved, isCurrentRev) =>
                        {
                            currentRecord = saved;
                            if (isCurrentRev)
                            {
                                editDirty = false;
                                saveNotice = "调整已保存";
                                retryVisible = false;
                            }
                        },
                        (c, _, shouldShow) =>
                        {
                            if (shouldShow)
                            {
                                saveNotice = "调整未保存 · 重试";
                                retryVisible = true;
                            }
                        });
                }

                // Commit 1 starts slow write on background worker
                currentEditRevision = 1;
                editDirty = true;
                var (b1, d1) = session.PrepareEditCommit(currentRecord!, MakeEdit(identity, 0.5));
                var commit1 = new PendingEditSaveCommit
                {
                    Revision = 1,
                    Path = photoPath,
                    OpenRevision = openRevision,
                    Session = session,
                    Baseline = b1
                };
                commit1.QueueTask = queue.EnqueueSave(store, photoPath, openRevision, false,
                    clear => store.SaveState(b1.Identity, d1, clear));
                commitQueue.Enqueue(commit1);
                commit1.CompletionTask = CompleteAsync(commit1);

                Assert.True(write1Entered.Wait(TimeSpan.FromSeconds(5)));

                // Commit 2 queued behind in-flight commit 1 (cannot coalesce with commit 1)
                currentEditRevision = 2;
                editDirty = true;
                var (b2, d2) = session.PrepareEditCommit(currentRecord!, MakeEdit(identity, 1.25));
                var commit2 = new PendingEditSaveCommit
                {
                    Revision = 2,
                    Path = photoPath,
                    OpenRevision = openRevision,
                    Session = session,
                    Baseline = b2
                };
                commit2.QueueTask = queue.EnqueueSave(store, photoPath, openRevision, false,
                    clear => store.SaveState(b2.Identity, d2, clear));
                commitQueue.Enqueue(commit2);
                commit2.CompletionTask = CompleteAsync(commit2);

                // Unblock worker and synchronously flush + drain BEFORE SerialSynchronizationContext pumps continuations
                allowWrite1.Set();
                queue.FlushAsync().GetAwaiter().GetResult();
                var drainedOk = commitQueue.ApplyPending(
                    c => c.Path == photoPath && c.OpenRevision == openRevision,
                    c => c.Revision == currentEditRevision,
                    (c, saved, isCurrentRev) =>
                    {
                        currentRecord = saved;
                        if (isCurrentRev)
                        {
                            editDirty = false;
                            saveNotice = "调整已保存";
                            retryVisible = false;
                        }
                    },
                    (c, _, shouldShow) =>
                    {
                        if (shouldShow)
                        {
                            saveNotice = "调整未保存 · 重试";
                            retryVisible = true;
                        }
                    });

                Assert.True(drainedOk);
                Assert.False(editDirty);
                Assert.Equal("调整已保存", saveNotice);
                Assert.False(retryVisible);
                Assert.Equal(1.25, currentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
                Assert.Equal(2, session.Transactions.Count);

                // Pump SerialSynchronizationContext so commit1 and commit2 continuations run
                var pumped = false;
                SynchronizationContext.Current!.Post(_ => pumped = true, null);
                while (!pumped) await Task.Yield();
                await commit1.CompletionTask!;
                await commit2.CompletionTask!;

                Assert.False(editDirty);
                Assert.Equal("调整已保存", saveNotice);
                Assert.False(retryVisible);
                Assert.Equal(1.25, currentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
                Assert.True(session.IsCurrentSave(currentRecord));
                Assert.Equal(2, session.Transactions.Count);
                Assert.Null(session.Transactions[0].Parts[0].Before);
                Assert.Equal(0.5, session.Transactions[0].Parts[0].After!.Settings.Restore()[Parameter.Exposure]);
                Assert.Equal(0.5, session.Transactions[1].Parts[0].Before!.Settings.Restore()[Parameter.Exposure]);
                Assert.Equal(1.25, session.Transactions[1].Parts[0].After!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public async Task OlderFailedCommitDoesNotOverwriteNewerSucceededSaveNotice()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-editsave-failnotice-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photoPath = Path.Combine(root, "photo.arw");
            File.WriteAllText(photoPath, "raw-fixture");
            var identity = OriginalIdentity.Read(photoPath);

            using var write1Entered = new ManualResetEventSlim(false);
            using var allowWrite1 = new ManualResetEventSlim(false);
            var writeAttempt = 0;

            var store = new EditStore(Path.Combine(root, "edits"), (path, payload) =>
            {
                var attempt = Interlocked.Increment(ref writeAttempt);
                if (attempt == 1)
                {
                    write1Entered.Set();
                    Assert.True(allowWrite1.Wait(TimeSpan.FromSeconds(5)));
                    throw new IOException("Transient write failure");
                }
                AtomicJson.Write(path, payload);
            });

            await RunOnSerialUiContext(async () =>
            {
                var queue = new EditSaveQueue();
                var commitQueue = new EditSaveCommitQueue();
                var session = new AdjustmentTransferSession(store);
                PhotoEditState? currentRecord = new PhotoEditState(identity, null);
                long currentEditRevision = 0;
                const long openRevision = 1;
                var editDirty = false;
                var saveNotice = "";
                var retryVisible = false;

                bool IsPhoto(PendingEditSaveCommit c) => c.Path == photoPath && c.OpenRevision == openRevision;
                bool IsRev(PendingEditSaveCommit c) => c.Revision == currentEditRevision;
                void Applied(PendingEditSaveCommit c, PhotoEditState saved, bool isCurrentRev)
                {
                    currentRecord = saved;
                    if (isCurrentRev)
                    {
                        editDirty = false;
                        saveNotice = "调整已保存";
                        retryVisible = false;
                    }
                }
                void Failed(PendingEditSaveCommit c, Exception _, bool shouldShow)
                {
                    if (shouldShow)
                    {
                        saveNotice = "调整未保存 · 重试";
                        retryVisible = true;
                    }
                }
                async Task<bool> CompleteAsync(PendingEditSaveCommit commit)
                {
                    try { await commit.QueueTask; } catch { }
                    return commitQueue.ApplyResult(commit, IsPhoto, IsRev, Applied, Failed);
                }

                // Case A: Synchronous drain after commit 1 fails and commit 2 succeeds
                currentEditRevision = 1;
                editDirty = true;
                var (b1, d1) = session.PrepareEditCommit(currentRecord!, MakeEdit(identity, 0.5));
                var commit1 = new PendingEditSaveCommit { Revision = 1, Path = photoPath, OpenRevision = openRevision, Session = session, Baseline = b1 };
                commit1.QueueTask = queue.EnqueueSave(store, photoPath, openRevision, false, clear => store.SaveState(b1.Identity, d1, clear));
                commitQueue.Enqueue(commit1);
                commit1.CompletionTask = CompleteAsync(commit1);

                Assert.True(write1Entered.Wait(TimeSpan.FromSeconds(5)));

                currentEditRevision = 2;
                var (b2, d2) = session.PrepareEditCommit(currentRecord!, MakeEdit(identity, 1.25));
                var commit2 = new PendingEditSaveCommit { Revision = 2, Path = photoPath, OpenRevision = openRevision, Session = session, Baseline = b2 };
                commit2.QueueTask = queue.EnqueueSave(store, photoPath, openRevision, false, clear => store.SaveState(b2.Identity, d2, clear));
                commitQueue.Enqueue(commit2);
                commit2.CompletionTask = CompleteAsync(commit2);

                allowWrite1.Set();
                queue.FlushAsync().GetAwaiter().GetResult();
                var drainedOk = commitQueue.ApplyPending(IsPhoto, IsRev, Applied, Failed);

                Assert.True(drainedOk);
                Assert.False(editDirty);
                Assert.Equal("调整已保存", saveNotice);
                Assert.False(retryVisible);
                Assert.Equal(1.25, currentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);

                await commit1.CompletionTask!;
                await commit2.CompletionTask!;
                Assert.Equal("调整已保存", saveNotice);
                Assert.False(retryVisible);

                // Case B: Async continuation of older failed commit 3 arrives while newer commit 4 is in flight
                using var writeAsync1Entered = new ManualResetEventSlim(false);
                using var allowAsyncWrite1 = new ManualResetEventSlim(false);
                using var writeAsync2Entered = new ManualResetEventSlim(false);
                using var allowAsyncWrite2 = new ManualResetEventSlim(false);
                writeAttempt = 0;
                var storeAsync = new EditStore(Path.Combine(root, "edits-async"), (path, payload) =>
                {
                    var attempt = Interlocked.Increment(ref writeAttempt);
                    if (attempt == 1)
                    {
                        writeAsync1Entered.Set();
                        Assert.True(allowAsyncWrite1.Wait(TimeSpan.FromSeconds(5)));
                        throw new IOException("Transient async write failure");
                    }
                    if (attempt == 2)
                    {
                        writeAsync2Entered.Set();
                        Assert.True(allowAsyncWrite2.Wait(TimeSpan.FromSeconds(5)));
                    }
                    AtomicJson.Write(path, payload);
                });
                var sessionAsync = new AdjustmentTransferSession(storeAsync);
                PhotoEditState? asyncRecord = new PhotoEditState(identity, null);
                currentRecord = asyncRecord;
                currentEditRevision = 3;
                editDirty = true;
                var (b3, d3) = sessionAsync.PrepareEditCommit(asyncRecord, MakeEdit(identity, 0.25));
                var commit3 = new PendingEditSaveCommit { Revision = 3, Path = photoPath, OpenRevision = openRevision, Session = sessionAsync, Baseline = b3 };
                commit3.QueueTask = queue.EnqueueSave(storeAsync, photoPath, openRevision, false, clear => storeAsync.SaveState(b3.Identity, d3, clear));
                commitQueue.Enqueue(commit3);
                commit3.CompletionTask = CompleteAsync(commit3);

                Assert.True(writeAsync1Entered.Wait(TimeSpan.FromSeconds(5)));

                currentEditRevision = 4;
                var (b4, d4) = sessionAsync.PrepareEditCommit(asyncRecord, MakeEdit(identity, 1.75));
                var commit4 = new PendingEditSaveCommit { Revision = 4, Path = photoPath, OpenRevision = openRevision, Session = sessionAsync, Baseline = b4 };
                commit4.QueueTask = queue.EnqueueSave(storeAsync, photoPath, openRevision, false, clear => storeAsync.SaveState(b4.Identity, d4, clear));
                commitQueue.Enqueue(commit4);
                commit4.CompletionTask = CompleteAsync(commit4);

                allowAsyncWrite1.Set();
                Assert.True(writeAsync2Entered.Wait(TimeSpan.FromSeconds(5)));
                Assert.False(await commit3.CompletionTask!);
                Assert.False(retryVisible);
                Assert.NotEqual("调整未保存 · 重试", saveNotice);

                allowAsyncWrite2.Set();
                Assert.True(await commit4.CompletionTask!);
                Assert.False(editDirty);
                Assert.Equal("调整已保存", saveNotice);
                Assert.False(retryVisible);
                Assert.Equal(1.75, currentRecord!.Edit!.Settings.Restore()[Parameter.Exposure]);
            });
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
}
