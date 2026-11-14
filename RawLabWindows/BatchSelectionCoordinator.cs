using System.Diagnostics;

namespace RawLab.Windows;

internal sealed record BatchSelectionCoordinatorHooks<TRow, TThumbnail>(
    Func<CollectionPhoto, bool, string?, TRow> CreateRow,
    Action<int, TRow> InsertRow,
    Action<TRow> RemoveRow,
    Action<int, int, TRow> MoveRow,
    Action<TRow, bool> UpdateSelection,
    Action<TRow, string?> UpdateFailure,
    Action<TRow, string> UpdatePath,
    Action<TRow, TThumbnail?> UpdateThumbnail,
    Func<string, CancellationToken, Task<TThumbnail?>> DecodeThumbnailAsync,
    Func<CollectionPhoto, string?> ValidatePhoto,
    Action<Action> PostToUi,
    Action? OnFailuresChanged = null,
    Action? OnBackgroundValidationCompleted = null);

/// <summary>
/// Reconciles batch-selection rows incrementally by photo ID, caches decoded thumbnails by file
/// identity, bounds concurrent decodes, cancels obsolete work, and validates file identities off the UI thread.
/// </summary>
internal sealed class BatchSelectionCoordinator<TRow, TThumbnail> : IDisposable where TRow : class
{
    private sealed class RowState(TRow row, CollectionPhoto photo, bool selected, string? failure)
    {
        public TRow Row { get; } = row;
        public CollectionPhoto Photo { get; set; } = photo;
        public bool Selected { get; set; } = selected;
        public string? Failure { get; set; } = failure;
        public OriginalIdentity? ThumbnailIdentity { get; set; }
        public bool ThumbnailLoaded { get; set; }
        public TThumbnail? Thumbnail { get; set; }
        public CancellationTokenSource? ThumbnailCts { get; set; }
    }

    private readonly BatchSelectionCoordinatorHooks<TRow, TThumbnail> hooks;
    private readonly SemaphoreSlim decodeGate;
    private readonly Dictionary<string, RowState> rowsById = new(StringComparer.Ordinal);
    private readonly List<string> orderedIds = [];
    private readonly Dictionary<string, (OriginalIdentity Identity, TThumbnail? Thumbnail)> thumbnailCache = new(StringComparer.Ordinal);
    private readonly Dictionary<int, Task> activeBackgroundTasks = [];
    private readonly object gate = new();
    private readonly CancellationTokenSource disposeCts = new();
    private CancellationTokenSource? validationCts;
    private long validationGeneration;
    private int nextTaskId;
    private bool disposed;

    internal BatchSelectionCoordinator(
        BatchSelectionCoordinatorHooks<TRow, TThumbnail> hooks,
        int maxThumbnailConcurrency = 2)
    {
        this.hooks = hooks;
        decodeGate = new SemaphoreSlim(Math.Max(1, maxThumbnailConcurrency));
    }

    internal void Refresh(BatchSelectionSession session)
    {
        if (disposed) return;
        SyncSnapshot(session.Photos, session.Selected, session.Failures);
        StartValidation(session);
    }

    internal void SyncSnapshot(
        IReadOnlyList<CollectionPhoto> photos,
        IReadOnlySet<string> selected,
        IReadOnlyDictionary<string, string> failures)
    {
        if (disposed) return;

        var incomingIds = new HashSet<string>(photos.Count, StringComparer.Ordinal);
        for (var i = 0; i < photos.Count; i++) incomingIds.Add(photos[i].ID);

        for (var i = orderedIds.Count - 1; i >= 0; i--)
        {
            var id = orderedIds[i];
            if (incomingIds.Contains(id)) continue;
            orderedIds.RemoveAt(i);
            thumbnailCache.Remove(id);
            if (rowsById.Remove(id, out var removed))
            {
                CancelThumbnail(removed);
                hooks.RemoveRow(removed.Row);
            }
        }

        for (var targetIndex = 0; targetIndex < photos.Count; targetIndex++)
        {
            var photo = photos[targetIndex];
            var isSelected = selected.Contains(photo.ID);
            var failure = failures.GetValueOrDefault(photo.ID);

            if (!rowsById.TryGetValue(photo.ID, out var state))
            {
                var row = hooks.CreateRow(photo, isSelected, failure);
                state = new RowState(row, photo, isSelected, failure);
                rowsById[photo.ID] = state;
                orderedIds.Insert(targetIndex, photo.ID);
                hooks.InsertRow(targetIndex, row);
            }
            else
            {
                var currentIndex = orderedIds.IndexOf(photo.ID);
                if (currentIndex != targetIndex)
                {
                    orderedIds.RemoveAt(currentIndex);
                    orderedIds.Insert(targetIndex, photo.ID);
                    hooks.MoveRow(currentIndex, targetIndex, state.Row);
                }

                if (!string.Equals(state.Photo.Path, photo.Path, StringComparison.Ordinal))
                {
                    hooks.UpdatePath(state.Row, photo.Path);
                }
                if (state.Selected != isSelected)
                {
                    state.Selected = isSelected;
                    hooks.UpdateSelection(state.Row, isSelected);
                }
                if (!string.Equals(state.Failure, failure, StringComparison.Ordinal))
                {
                    state.Failure = failure;
                    hooks.UpdateFailure(state.Row, failure);
                }
                state.Photo = photo;
            }

            ReconcileThumbnail(state);
        }
    }

    private void ReconcileThumbnail(RowState state)
    {
        if (state.Failure != null)
        {
            CancelThumbnail(state);
            return;
        }

        var identity = state.Photo.Identity;
        if (state.ThumbnailLoaded && state.ThumbnailIdentity == identity) return;

        if (thumbnailCache.TryGetValue(state.Photo.ID, out var cached) && cached.Identity == identity)
        {
            CancelThumbnail(state);
            state.ThumbnailIdentity = identity;
            state.ThumbnailLoaded = true;
            state.Thumbnail = cached.Thumbnail;
            hooks.UpdateThumbnail(state.Row, cached.Thumbnail);
            return;
        }

        if (state.ThumbnailCts != null && state.ThumbnailIdentity == identity) return;

        CancelThumbnail(state);
        state.ThumbnailLoaded = false;
        state.ThumbnailIdentity = identity;

        var cts = CancellationTokenSource.CreateLinkedTokenSource(disposeCts.Token);
        state.ThumbnailCts = cts;
        var path = state.Photo.Path;
        var photoId = state.Photo.ID;
        var taskId = Interlocked.Increment(ref nextTaskId);

        lock (gate)
        {
            var task = DecodeThumbnailCoreAsync(taskId, state, photoId, path, identity, cts);
            if (!task.IsCompleted) activeBackgroundTasks[taskId] = task;
        }
    }

    private async Task DecodeThumbnailCoreAsync(
        int taskId,
        RowState state,
        string photoId,
        string path,
        OriginalIdentity identity,
        CancellationTokenSource cts)
    {
        var token = cts.Token;
        var acquired = false;
        try
        {
            await decodeGate.WaitAsync(token).ConfigureAwait(false);
            acquired = true;
            token.ThrowIfCancellationRequested();
            var thumbnail = await hooks.DecodeThumbnailAsync(path, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            PostIfNotDisposed(() =>
            {
                if (disposed || token.IsCancellationRequested ||
                    !rowsById.TryGetValue(photoId, out var current) ||
                    !ReferenceEquals(current, state) ||
                    current.ThumbnailIdentity != identity)
                    return;
                current.ThumbnailCts = null;
                current.ThumbnailLoaded = true;
                current.Thumbnail = thumbnail;
                thumbnailCache[photoId] = (identity, thumbnail);
                hooks.UpdateThumbnail(current.Row, thumbnail);
            });
        }
        catch (OperationCanceledException)
        {
            PostIfNotDisposed(() =>
            {
                if (ReferenceEquals(state.ThumbnailCts, cts)) state.ThumbnailCts = null;
            });
        }
        catch (Exception ex) when (PreviewFallback.ShouldDegrade(ex))
        {
            Trace.WriteLine($"Batch thumbnail fallback for {path}: {ex.Message}");
            PostIfNotDisposed(() =>
            {
                if (disposed || !ReferenceEquals(state.ThumbnailCts, cts) ||
                    !rowsById.TryGetValue(photoId, out var current) ||
                    current.ThumbnailIdentity != identity)
                    return;
                current.ThumbnailCts = null;
                current.ThumbnailLoaded = true;
                current.Thumbnail = default;
                thumbnailCache[photoId] = (identity, default);
            });
        }
        finally
        {
            if (acquired) decodeGate.Release();
            cts.Dispose();
            lock (gate) activeBackgroundTasks.Remove(taskId);
        }
    }

    private void StartValidation(BatchSelectionSession session)
    {
        CancelValidation();
        if (disposed) return;

        var generation = ++validationGeneration;
        var snapshot = session.Photos.ToArray();
        if (snapshot.Length == 0)
        {
            hooks.OnBackgroundValidationCompleted?.Invoke();
            return;
        }

        var cts = CancellationTokenSource.CreateLinkedTokenSource(disposeCts.Token);
        validationCts = cts;
        var token = cts.Token;
        var taskId = Interlocked.Increment(ref nextTaskId);

        lock (gate)
        {
            var task = Task.Run(() =>
            {
                try
                {
                    var updates = new List<(string ID, OriginalIdentity Identity, string? Error)>(snapshot.Length);
                    foreach (var photo in snapshot)
                    {
                        if (token.IsCancellationRequested) return;
                        updates.Add((photo.ID, photo.Identity, hooks.ValidatePhoto(photo)));
                    }
                    if (token.IsCancellationRequested || disposed) return;
                    PostIfNotDisposed(() =>
                    {
                        try
                        {
                            if (disposed || token.IsCancellationRequested || generation != validationGeneration) return;
                            if (session.ApplyFailureUpdates(updates))
                            {
                                SyncSnapshot(session.Photos, session.Selected, session.Failures);
                                hooks.OnFailuresChanged?.Invoke();
                            }
                        }
                        finally
                        {
                            hooks.OnBackgroundValidationCompleted?.Invoke();
                        }
                    });
                }
                catch (OperationCanceledException) { }
                catch (Exception ex) when (PreviewFallback.ShouldDegrade(ex))
                {
                    Trace.WriteLine($"Batch validation fallback: {ex.Message}");
                }
                finally
                {
                    cts.Dispose();
                    lock (gate) activeBackgroundTasks.Remove(taskId);
                }
            }, CancellationToken.None);
            if (!task.IsCompleted) activeBackgroundTasks[taskId] = task;
        }
    }

    private void PostIfNotDisposed(Action action)
    {
        if (disposed) return;
        try { hooks.PostToUi(action); }
        catch (OperationCanceledException) { }
    }

    private void CancelValidation()
    {
        var cts = validationCts;
        validationCts = null;
        if (cts == null) return;
        try { cts.Cancel(); }
        catch (ObjectDisposedException) { }
    }

    private static void CancelThumbnail(RowState state)
    {
        var cts = state.ThumbnailCts;
        state.ThumbnailCts = null;
        if (cts == null) return;
        try { cts.Cancel(); }
        catch (ObjectDisposedException) { }
    }

    internal void CancelPending()
    {
        CancelValidation();
        foreach (var state in rowsById.Values) CancelThumbnail(state);
    }

    internal Task RefreshAndWaitForIdleAsync(BatchSelectionSession session, Func<int> drainUi)
    {
        Refresh(session);
        return WaitForPendingAsync(drainUi);
    }

    internal async Task WaitForPendingAsync(Func<int> drainUi)
    {
        while (true)
        {
            drainUi();
            Task[] snapshot;
            lock (gate) snapshot = activeBackgroundTasks.Values.ToArray();
            if (snapshot.Length == 0)
            {
                if (drainUi() == 0) break;
                continue;
            }
            await Task.WhenAll(snapshot).ConfigureAwait(false);
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        CancelPending();
        try { disposeCts.Cancel(); }
        catch (ObjectDisposedException) { }
        rowsById.Clear();
        orderedIds.Clear();
        thumbnailCache.Clear();
    }
}
