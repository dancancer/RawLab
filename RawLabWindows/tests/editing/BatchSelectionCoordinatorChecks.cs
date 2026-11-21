using System.Collections.Concurrent;
using System.IO;
using RawLab.Windows;

static class BatchSelectionCoordinatorChecks
{
    private sealed class FakeRow(string id, string path, bool selected, string? failure)
    {
        public string Id { get; } = id;
        public string Path { get; set; } = path;
        public bool Selected { get; set; } = selected;
        public string? Failure { get; set; } = failure;
        public string? Thumbnail { get; set; }
    }

    private sealed class UiPump
    {
        private readonly ConcurrentQueue<Action> queue = new();
        public int ThreadId { get; } = Environment.CurrentManagedThreadId;

        public void Post(Action action) => queue.Enqueue(action);

        public int Drain()
        {
            var count = 0;
            while (queue.TryDequeue(out var action))
            {
                action();
                count++;
            }
            return count;
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    public static void Run()
    {
        Run300PhotoIncrementalAndFocusSwitchTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunConcurrencyAndCancellationTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunIdentityChangeAndNullCacheTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunEnqueuedDecodeAfterFailureDoesNotPublishTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunEnqueuedHealthyCancelDoesNotPublishTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunIdentityFlipABAStaleCallbackTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        RunEnqueuedValidationAfterCancelPendingDoesNotMutateSessionTest().WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        Console.WriteLine("PASS: P2-20 batch selection incremental rows, cached thumbnails, cancellation and off-UI validation");
    }

    private static async Task Run300PhotoIncrementalAndFocusSwitchTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-batch-coord-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            const int initialCount = 300;
            var paths = new string[initialCount];
            for (var i = 0; i < initialCount; i++)
            {
                paths[i] = Path.Combine(root, $"photo-{i:D3}.arw");
                File.WriteAllText(paths[i], $"raw-{i}");
            }

            var session = new BatchSelectionSession();
            session.Add(paths);
            Check(session.Photos.Count == initialCount, "300 distinct photos added to collection");

            var ui = new UiPump();
            var container = new List<FakeRow>();
            var rowsCreated = 0;
            var rowsRemoved = 0;
            var rowsMoved = 0;
            var selectionUpdates = 0;
            var failureUpdates = 0;
            var thumbnailUpdates = 0;
            var decodeCalls = 0;
            var activeDecodes = 0;
            var maxActiveDecodes = 0;
            var uiThreadValidations = 0;
            var backgroundValidations = 0;
            var failPhotoId = session.Photos[42].ID;
            var simulatePhoto42Failure = false;
            var validationCompletion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var pendingDecodes = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var decodedCount = 0;

            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (photo, selected, failure) =>
                    {
                        Interlocked.Increment(ref rowsCreated);
                        return new FakeRow(photo.ID, photo.Path, selected, failure);
                    },
                    InsertRow: (index, row) => container.Insert(index, row),
                    RemoveRow: row =>
                    {
                        Interlocked.Increment(ref rowsRemoved);
                        container.Remove(row);
                    },
                    MoveRow: (from, to, row) =>
                    {
                        Interlocked.Increment(ref rowsMoved);
                        container.RemoveAt(from);
                        container.Insert(to, row);
                    },
                    UpdateSelection: (row, selected) =>
                    {
                        selectionUpdates++;
                        row.Selected = selected;
                    },
                    UpdateFailure: (row, failure) =>
                    {
                        failureUpdates++;
                        row.Failure = failure;
                    },
                    UpdatePath: (row, path) => row.Path = path,
                    UpdateThumbnail: (row, thumb) =>
                    {
                        thumbnailUpdates++;
                        row.Thumbnail = thumb;
                    },
                    DecodeThumbnailAsync: (path, ct) => Task.Run(() =>
                    {
                        ct.ThrowIfCancellationRequested();
                        var active = Interlocked.Increment(ref activeDecodes);
                        lock (container)
                        {
                            if (active > maxActiveDecodes) maxActiveDecodes = active;
                        }
                        try
                        {
                            Interlocked.Increment(ref decodeCalls);
                            return (string?)("thumb:" + Path.GetFileName(path));
                        }
                        finally
                        {
                            Interlocked.Decrement(ref activeDecodes);
                            if (Interlocked.Increment(ref decodedCount) == initialCount)
                                pendingDecodes.TrySetResult();
                        }
                    }, ct),
                    ValidatePhoto: photo =>
                    {
                        if (Environment.CurrentManagedThreadId == ui.ThreadId)
                            Interlocked.Increment(ref uiThreadValidations);
                        else
                            Interlocked.Increment(ref backgroundValidations);
                        return simulatePhoto42Failure && photo.ID == failPhotoId ? "Missing on disk" : null;
                    },
                    PostToUi: ui.Post,
                    OnBackgroundValidationCompleted: () => validationCompletion.TrySetResult()),
                maxThumbnailConcurrency: 2);

            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(rowsCreated == 300 && rowsRemoved == 0 && rowsMoved == 0 && container.Count == 300,
                $"Initial refresh created 300 rows incrementally (created={rowsCreated}, count={container.Count})");
            Check(decodeCalls == 300 && maxActiveDecodes <= 2,
                $"Initial load decoded 300 thumbnails with concurrency cap <= 2 (decodes={decodeCalls}, maxActive={maxActiveDecodes})");
            Check(uiThreadValidations == 0 && backgroundValidations == 300,
                $"Initial validation ran off UI thread (ui={uiThreadValidations}, bg={backgroundValidations})");
            Check(container.All(r => r.Thumbnail == "thumb:" + Path.GetFileName(r.Path)),
                "Every row received its decoded thumbnail");

            var originalRows = container.ToArray();
            var baselineThumbUpdates = thumbnailUpdates;
            selectionUpdates = 0;
            failureUpdates = 0;

            // Simulate 10 window focus activations on 300-photo collection.
            for (var focus = 0; focus < 10; focus++)
                await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);

            Check(rowsCreated == 300 && rowsRemoved == 0 && rowsMoved == 0,
                "Repeated focus activations do not rebuild or clear existing rows");
            Check(container.Zip(originalRows).All(pair => ReferenceEquals(pair.First, pair.Second)),
                "All 300 row objects are reference-identical after 10 focus switches");
            Check(decodeCalls == 300 && thumbnailUpdates == baselineThumbUpdates,
                $"Repeated focus activations perform zero additional thumbnail decodes (decodes={decodeCalls})");
            Check(selectionUpdates == 0 && failureUpdates == 0,
                "Repeated unchanged refreshes produce zero redundant field updates");
            Check(uiThreadValidations == 0,
                "UI thread performed zero per-row file identity checks across focus switches");

            // Selection toggles update only changed rows and trigger zero decodes.
            session.Select(session.Photos[0].ID, false);
            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(selectionUpdates == 1 && !container[0].Selected && decodeCalls == 300 && rowsCreated == 300,
                $"Single deselection updated only 1 row without decoding (selectionUpdates={selectionUpdates}, decodes={decodeCalls})");

            selectionUpdates = 0;
            session.SelectAll(false);
            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(selectionUpdates == 299 && container.All(r => !r.Selected) && decodeCalls == 300 && rowsCreated == 300,
                $"SelectAll(false) updated only the 299 changed rows with zero decodes (selectionUpdates={selectionUpdates})");

            // Add 3 new photos and remove 2 existing photos.
            var removedIdA = session.Photos[10].ID;
            var removedIdB = session.Photos[200].ID;
            session.Remove(removedIdA);
            session.Remove(removedIdB);
            var added = new string[3];
            for (var i = 0; i < 3; i++)
            {
                added[i] = Path.Combine(root, $"added-{i}.arw");
                File.WriteAllText(added[i], $"new-{i}");
            }
            session.Add(added);

            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(rowsCreated == 303 && rowsRemoved == 2 && container.Count == 301,
                $"Add 3 / remove 2 created only 3 rows and removed 2 (created={rowsCreated}, removed={rowsRemoved}, count={container.Count})");
            Check(decodeCalls == 303,
                $"Thumbnail decode count equals newly added rows (expected=303, actual={decodeCalls})");
            Check(container.Select(r => r.Id).SequenceEqual(session.Photos.Select(p => p.ID)),
                "Visual row order matches collection order after add/remove");
            foreach (var kept in originalRows)
            {
                if (kept.Id == removedIdA || kept.Id == removedIdB) continue;
                Check(container.Any(current => ReferenceEquals(current, kept)),
                    $"Surviving row {kept.Id} kept identical reference across add/remove");
            }

            // Background validation discovers 1 failed photo and updates ONLY that row.
            failureUpdates = 0;
            simulatePhoto42Failure = true;
            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(failureUpdates == 1 && session.Failures.TryGetValue(failPhotoId, out var err) && err == "Missing on disk",
                $"Background validation updated only the 1 failed row (failureUpdates={failureUpdates})");
            Check(container.Single(r => r.Id == failPhotoId).Failure == "Missing on disk" && uiThreadValidations == 0,
                "Failed row displays error and UI thread did zero file opens");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static async Task RunConcurrencyAndCancellationTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-batch-cancel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var paths = Enumerable.Range(0, 4).Select(i =>
            {
                var p = Path.Combine(root, $"c-{i}.arw");
                File.WriteAllText(p, $"c-{i}");
                return p;
            }).ToArray();

            var session = new BatchSelectionSession();
            session.Add(paths);
            var ui = new UiPump();
            var rows = new Dictionary<string, FakeRow>();
            var started = new ConcurrentDictionary<string, TaskCompletionSource>();
            var gates = new ConcurrentDictionary<string, TaskCompletionSource<string?>>();
            var tokens = new ConcurrentDictionary<string, CancellationToken>();
            foreach (var p in paths)
            {
                started[p] = new(TaskCreationOptions.RunContinuationsAsynchronously);
                gates[p] = new(TaskCreationOptions.RunContinuationsAsynchronously);
            }

            var inFlight = 0;
            var maxInFlight = 0;
            var decodeInvocations = new ConcurrentBag<string>();

            var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (photo, selected, failure) =>
                    {
                        var row = new FakeRow(photo.ID, photo.Path, selected, failure);
                        rows[photo.ID] = row;
                        return row;
                    },
                    InsertRow: (_, _) => { },
                    RemoveRow: row => rows.Remove(row.Id),
                    MoveRow: (_, _, _) => { },
                    UpdateSelection: (row, s) => row.Selected = s,
                    UpdateFailure: (row, f) => row.Failure = f,
                    UpdatePath: (row, p) => row.Path = p,
                    UpdateThumbnail: (row, t) => row.Thumbnail = t,
                    DecodeThumbnailAsync: async (path, ct) =>
                    {
                        tokens[path] = ct;
                        decodeInvocations.Add(path);
                        var nowActive = Interlocked.Increment(ref inFlight);
                        if (nowActive > maxInFlight) maxInFlight = nowActive;
                        started[path].TrySetResult();
                        try
                        {
                            using var reg = ct.Register(() => gates[path].TrySetCanceled(ct));
                            return await gates[path].Task.ConfigureAwait(false);
                        }
                        finally
                        {
                            Interlocked.Decrement(ref inFlight);
                        }
                    },
                    ValidatePhoto: _ => null,
                    PostToUi: ui.Post),
                maxThumbnailConcurrency: 2);

            coordinator.Refresh(session);
            // Wait deterministically for exactly 2 concurrent decodes to enter DecodeThumbnailAsync.
            await Task.WhenAll(started[paths[0]].Task, started[paths[1]].Task).WaitAsync(TimeSpan.FromSeconds(5));
            Check(maxInFlight <= 2 && decodeInvocations.Count == 2,
                $"Semaphore bounds active thumbnail decodes to 2 (active={maxInFlight}, started={decodeInvocations.Count})");

            // Remove in-flight photo[0] and queued photo[2] on refresh -> both must cancel.
            session.Remove(session.Photos[2].ID);
            session.Remove(session.Photos[0].ID);
            coordinator.Refresh(session);

            Check(tokens[paths[0]].IsCancellationRequested,
                "Removing an in-flight photo immediately cancels its thumbnail decode token");

            // Complete photo[1] and wait for queued photo[3] to start (while cancelled photo[2] must be skipped!).
            gates[paths[1]].TrySetResult("thumb-1");
            await started[paths[3]].Task.WaitAsync(TimeSpan.FromSeconds(5));
            gates[paths[3]].TrySetResult("thumb-3");

            await coordinator.WaitForPendingAsync(ui.Drain).WaitAsync(TimeSpan.FromSeconds(5));
            Check(!decodeInvocations.Contains(paths[2]),
                "Cancelled queued photo[2] was never decoded after removal");
            Check(rows[session.Photos[0].ID].Thumbnail == "thumb-1" &&
                  rows[session.Photos[1].ID].Thumbnail == "thumb-3",
                "Surviving photos received their decoded thumbnails cleanly");

            // Closing/disposing cancels pending validation/decode without touching rows afterward.
            coordinator.Dispose();
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static async Task RunIdentityChangeAndNullCacheTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-batch-null-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "no-preview.arw");
            File.WriteAllText(path, "v1");
            var session = new BatchSelectionSession();
            session.Add([path]);

            var ui = new UiPump();
            var decodes = 0;
            var rows = new List<FakeRow>();
            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (p, s, f) => new FakeRow(p.ID, p.Path, s, f),
                    InsertRow: (i, r) => rows.Insert(i, r),
                    RemoveRow: r => rows.Remove(r),
                    MoveRow: (from, to, r) => { rows.RemoveAt(from); rows.Insert(to, r); },
                    UpdateSelection: (r, s) => r.Selected = s,
                    UpdateFailure: (r, f) => r.Failure = f,
                    UpdatePath: (r, p) => r.Path = p,
                    UpdateThumbnail: (r, t) => r.Thumbnail = t,
                    DecodeThumbnailAsync: (_, _) =>
                    {
                        Interlocked.Increment(ref decodes);
                        return Task.FromResult<string?>(null);
                    },
                    ValidatePhoto: _ => null,
                    PostToUi: ui.Post));

            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            await coordinator.RefreshAndWaitForIdleAsync(session, ui.Drain);
            Check(decodes == 1, $"Null fallback thumbnail result is cached per identity without re-decoding (decodes={decodes})");

            // Simulate modified file identity on a removed+readded entry with same ID: must decode once more.
            var modifiedIdentity = session.Photos[0].Identity with { Length = session.Photos[0].Identity.Length + 10 };
            var replacedPhoto = session.Photos[0] with { Identity = modifiedIdentity };
            var fakeSessionPhotos = new[] { replacedPhoto };
            coordinator.SyncSnapshot(fakeSessionPhotos, session.Selected, session.Failures);
            await coordinator.WaitForPendingAsync(ui.Drain).WaitAsync(TimeSpan.FromSeconds(5));
            Check(decodes == 2, $"Changed file identity invalidates cached null thumbnail and decodes once (decodes={decodes})");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    // REPRO-A: Decode finishes on background thread and queues UI callback; row becomes Failure before Drain.
    private static async Task RunEnqueuedDecodeAfterFailureDoesNotPublishTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-repro-a-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "a.arw");
            File.WriteAllText(path, "v1");
            var session = new BatchSelectionSession();
            session.Add([path]);
            var photoId = session.Photos[0].ID;

            var ui = new UiPump();
            var rows = new List<FakeRow>();
            var thumbUpdatesAfterFailure = 0;
            var trackAfterFailure = false;
            var decodeDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (p, s, f) => new FakeRow(p.ID, p.Path, s, f),
                    InsertRow: (i, r) => rows.Insert(i, r),
                    RemoveRow: r => rows.Remove(r),
                    MoveRow: (_, _, _) => { },
                    UpdateSelection: (r, s) => r.Selected = s,
                    UpdateFailure: (r, f) => r.Failure = f,
                    UpdatePath: (r, p) => r.Path = p,
                    UpdateThumbnail: (r, t) =>
                    {
                        if (trackAfterFailure) Interlocked.Increment(ref thumbUpdatesAfterFailure);
                        r.Thumbnail = t;
                    },
                    DecodeThumbnailAsync: (_, _) =>
                    {
                        decodeDone.TrySetResult();
                        return Task.FromResult<string?>("decoded-thumb");
                    },
                    ValidatePhoto: _ => null,
                    PostToUi: ui.Post));

            coordinator.Refresh(session);
            await decodeDone.Task.WaitAsync(TimeSpan.FromSeconds(5));
            // Wait until background finally completes WITHOUT draining the queued UI callback.
            await coordinator.WaitForPendingAsync(() => 0).WaitAsync(TimeSpan.FromSeconds(5));

            coordinator.SyncSnapshot(
                session.Photos,
                session.Selected,
                new Dictionary<string, string> { [photoId] = "Corrupt or missing" });
            trackAfterFailure = true;
            ui.Drain();

            Check(rows.Single().Failure == "Corrupt or missing",
                $"Row retains Failure marker after drain (failure={rows.Single().Failure})");
            Check(rows.Single().Thumbnail == null && thumbUpdatesAfterFailure == 0,
                $"Enqueued decode must not publish thumbnail after row marked Failure (thumb={rows.Single().Thumbnail}, updates={thumbUpdatesAfterFailure})");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    // Healthy row with decode callback queued before CancelPending() (e.g. Closing) must not publish after Drain.
    private static async Task RunEnqueuedHealthyCancelDoesNotPublishTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-repro-healthy-cancel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "h.arw");
            File.WriteAllText(path, "h");
            var session = new BatchSelectionSession();
            session.Add([path]);

            var ui = new UiPump();
            var rows = new List<FakeRow>();
            var thumbUpdates = 0;
            var decodeDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (p, s, f) => new FakeRow(p.ID, p.Path, s, f),
                    InsertRow: (i, r) => rows.Insert(i, r),
                    RemoveRow: r => rows.Remove(r),
                    MoveRow: (_, _, _) => { },
                    UpdateSelection: (r, s) => r.Selected = s,
                    UpdateFailure: (r, f) => r.Failure = f,
                    UpdatePath: (r, p) => r.Path = p,
                    UpdateThumbnail: (r, t) =>
                    {
                        thumbUpdates++;
                        r.Thumbnail = t;
                    },
                    DecodeThumbnailAsync: (_, _) =>
                    {
                        decodeDone.TrySetResult();
                        return Task.FromResult<string?>("stale-after-cancel");
                    },
                    ValidatePhoto: _ => null,
                    PostToUi: ui.Post));

            coordinator.Refresh(session);
            await decodeDone.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await coordinator.WaitForPendingAsync(() => 0).WaitAsync(TimeSpan.FromSeconds(5));

            coordinator.CancelPending();
            ui.Drain();

            Check(thumbUpdates == 0 && rows.Single().Thumbnail == null,
                $"Queued decode callback must not publish after CancelPending() (updates={thumbUpdates}, thumb={rows.Single().Thumbnail})");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    // Identity flip A -> B -> A while first A decode callback is queued must not clobber second A's live CTS or publish A1.
    private static async Task RunIdentityFlipABAStaleCallbackTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-aba-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "flip.arw");
            File.WriteAllText(path, "v1");
            var session = new BatchSelectionSession();
            session.Add([path]);
            var photoA = session.Photos[0];
            var identityA = photoA.Identity;
            var identityB = identityA with { Length = identityA.Length + 5 };
            var photoB = photoA with { Identity = identityB };

            var ui = new UiPump();
            var rows = new List<FakeRow>();
            var attempt = 0;
            var secondDecodeGate = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var secondDecodeStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var secondDecodeToken = CancellationToken.None;

            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (p, s, f) => new FakeRow(p.ID, p.Path, s, f),
                    InsertRow: (i, r) => rows.Insert(i, r),
                    RemoveRow: r => rows.Remove(r),
                    MoveRow: (_, _, _) => { },
                    UpdateSelection: (r, s) => r.Selected = s,
                    UpdateFailure: (r, f) => r.Failure = f,
                    UpdatePath: (r, p) => r.Path = p,
                    UpdateThumbnail: (r, t) => r.Thumbnail = t,
                    DecodeThumbnailAsync: async (_, ct) =>
                    {
                        var current = Interlocked.Increment(ref attempt);
                        if (current == 1) return "thumb-A1";
                        if (current == 2)
                        {
                            // Wait for B cancellation if reached.
                            var tcs = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                            using var reg = ct.Register(() => tcs.TrySetCanceled(ct));
                            return await tcs.Task.ConfigureAwait(false);
                        }
                        secondDecodeToken = ct;
                        secondDecodeStarted.TrySetResult();
                        return await secondDecodeGate.Task.ConfigureAwait(false);
                    },
                    ValidatePhoto: _ => null,
                    PostToUi: ui.Post));

            // Start A (#1) and let it finish background decode without draining UI.
            coordinator.SyncSnapshot([photoA], session.Selected, session.Failures);
            await coordinator.WaitForPendingAsync(() => 0).WaitAsync(TimeSpan.FromSeconds(5));

            // Flip A -> B -> A before draining queued A (#1) callback.
            coordinator.SyncSnapshot([photoB], session.Selected, session.Failures);
            coordinator.SyncSnapshot([photoA], session.Selected, session.Failures);
            await secondDecodeStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));

            // Drain stale A1 callback while A (#3) is still in-flight: must NOT publish thumb-A1 or clear live CTS!
            ui.Drain();
            Check(rows.Single().Thumbnail == null,
                $"Stale A1 callback must not publish after A->B->A flip (thumb={rows.Single().Thumbnail})");

            // Prove A (#3)'s CTS was NOT cleared by stale A1 callback by marking Failure and cancelling A (#3).
            coordinator.SyncSnapshot([photoA], session.Selected, new Dictionary<string, string> { [photoA.ID] = "Late error" });
            Check(secondDecodeToken.IsCancellationRequested,
                "Second A decode token remains linked and cancellable after stale A1 callback drained");
            secondDecodeGate.TrySetResult("thumb-A2");
            await coordinator.WaitForPendingAsync(ui.Drain).WaitAsync(TimeSpan.FromSeconds(5));
            Check(rows.Single().Thumbnail == null, "Canceled second A decode never publishes after failure");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    // REPRO-B: Validation completes and enqueues UI callback; CancelPending() called before Drain must block session write-through.
    private static async Task RunEnqueuedValidationAfterCancelPendingDoesNotMutateSessionTest()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-repro-b-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "b.arw");
            File.WriteAllText(path, "v1");
            var session = new BatchSelectionSession();
            session.Add([path]);

            var ui = new UiPump();
            var rows = new List<FakeRow>();
            var failuresChanged = 0;

            using var coordinator = new BatchSelectionCoordinator<FakeRow, string>(
                new BatchSelectionCoordinatorHooks<FakeRow, string>(
                    CreateRow: (p, s, f) => new FakeRow(p.ID, p.Path, s, f),
                    InsertRow: (i, r) => rows.Insert(i, r),
                    RemoveRow: r => rows.Remove(r),
                    MoveRow: (_, _, _) => { },
                    UpdateSelection: (r, s) => r.Selected = s,
                    UpdateFailure: (r, f) => r.Failure = f,
                    UpdatePath: (r, p) => r.Path = p,
                    UpdateThumbnail: (r, t) => r.Thumbnail = t,
                    DecodeThumbnailAsync: (_, _) => Task.FromResult<string?>("thumb"),
                    ValidatePhoto: _ => "Missing on disk",
                    PostToUi: ui.Post,
                    OnFailuresChanged: () => failuresChanged++));

            coordinator.Refresh(session);
            // Wait for background validation & decode to enqueue UI callbacks and exit finally WITHOUT draining UI.
            await coordinator.WaitForPendingAsync(() => 0).WaitAsync(TimeSpan.FromSeconds(5));

            coordinator.CancelPending();
            ui.Drain();

            Check(session.Failures.Count == 0 && failuresChanged == 0 && rows.Single().Failure == null,
                $"CancelPending before Drain must prevent queued validation mutating session (failures={session.Failures.Count}, changed={failuresChanged})");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }
}
