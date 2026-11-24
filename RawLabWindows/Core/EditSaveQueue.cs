using System.IO;

namespace RawLab.Windows;

internal sealed record EditSaveKey(EditStore Store, string Path, long OpenRevision);

internal sealed record EditSaveWorkResult(bool Superseded, PhotoEditState? Saved = null);

// 串行后台保存队列：将 EditStore 的磁盘锁等待与原子写移出 WPF UI 线程；
// 同一打开照片（同 Store/Path/OpenRevision）的连续未开始保存会合并为最新快照并 OR 合并回执清理标记，
// 跨照片或显式后台操作（如迁移/Flush）严格按提交顺序串行落盘。
internal sealed class EditSaveQueue
{
    private sealed class PendingRequest(
        EditSaveKey key,
        Func<bool, PhotoEditState> execute,
        bool clearMigrationReceipt,
        Func<bool>? isStale,
        TaskCompletionSource<EditSaveWorkResult> completion)
    {
        internal EditSaveKey Key { get; } = key;
        internal Func<bool, PhotoEditState> Execute { get; set; } = execute;
        internal bool ClearMigrationReceipt { get; set; } = clearMigrationReceipt;
        internal Func<bool>? IsStale { get; set; } = isStale;
        internal TaskCompletionSource<EditSaveWorkResult> Completion { get; set; } = completion;
    }

    private readonly object gate = new();
    private readonly Queue<PendingRequest> queue = new();
    private bool workerRunning;
    private TaskCompletionSource<bool>? idleTcs;

    internal event Action? BecameIdle;

    internal bool HasPendingWork
    {
        get { lock (gate) return workerRunning || queue.Count > 0; }
    }

    internal Task<EditSaveWorkResult> EnqueueSave(
        EditStore store,
        string path,
        long openRevision,
        bool clearMigrationReceipt,
        Func<bool, PhotoEditState> execute,
        Func<bool>? isStale = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(execute);

        var key = new EditSaveKey(store, Path.GetFullPath(path), openRevision);
        TaskCompletionSource<EditSaveWorkResult>? superseded = null;
        var completion = new TaskCompletionSource<EditSaveWorkResult>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (gate)
        {
            if (queue.Count > 0)
            {
                PendingRequest? last = null;
                foreach (var item in queue) last = item;
                if (last != null &&
                    ReferenceEquals(last.Key.Store, key.Store) &&
                    StringComparer.OrdinalIgnoreCase.Equals(last.Key.Path, key.Path) &&
                    last.Key.OpenRevision == key.OpenRevision)
                {
                    superseded = last.Completion;
                    last.Execute = execute;
                    last.ClearMigrationReceipt |= clearMigrationReceipt;
                    last.IsStale = isStale;
                    last.Completion = completion;
                }
            }

            if (superseded == null)
            {
                queue.Enqueue(new PendingRequest(key, execute, clearMigrationReceipt, isStale, completion));
                EnsureWorkerLocked();
            }
        }

        superseded?.TrySetResult(new EditSaveWorkResult(Superseded: true));
        return completion.Task;
    }

    internal Task<T> RunAsync<T>(Func<T> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var workCompletion = new TaskCompletionSource<EditSaveWorkResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            queue.Enqueue(new PendingRequest(
                new EditSaveKey(null!, "", -1),
                _ =>
                {
                    try
                    {
                        completion.TrySetResult(action());
                    }
                    catch (Exception error)
                    {
                        completion.TrySetException(error);
                    }
                    return null!;
                },
                false,
                null,
                workCompletion));
            EnsureWorkerLocked();
        }
        return completion.Task;
    }

    internal Task FlushAsync()
    {
        lock (gate)
        {
            if (!workerRunning && queue.Count == 0) return Task.CompletedTask;
            idleTcs ??= new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            return idleTcs.Task;
        }
    }

    private void EnsureWorkerLocked()
    {
        if (workerRunning) return;
        workerRunning = true;
        _ = Task.Run(ProcessQueue);
    }

    private void ProcessQueue()
    {
        while (true)
        {
            PendingRequest next;
            Action? idleHandlers = null;
            lock (gate)
            {
                if (queue.Count == 0)
                {
                    workerRunning = false;
                    idleTcs?.TrySetResult(true);
                    idleTcs = null;
                    idleHandlers = BecameIdle;
                    goto NotifyIdle;
                }
                next = queue.Dequeue();
            }

            try
            {
                if (next.IsStale?.Invoke() == true)
                {
                    next.Completion.TrySetResult(new EditSaveWorkResult(Superseded: true));
                }
                else
                {
                    var saved = next.Execute(next.ClearMigrationReceipt);
                    next.Completion.TrySetResult(new EditSaveWorkResult(Superseded: false, Saved: saved));
                }
            }
            catch (Exception error)
            {
                next.Completion.TrySetException(error);
            }
            continue;

        NotifyIdle:
            idleHandlers?.Invoke();
            return;
        }
    }
}

internal sealed class PendingEditSaveCommit
{
    private int applied;
    internal long Revision { get; init; }
    internal string Path { get; init; } = "";
    internal long OpenRevision { get; init; }
    internal long Epoch { get; init; }
    internal AdjustmentTransferSession Session { get; init; } = null!;
    internal PhotoEditState Baseline { get; init; } = null!;
    internal string? PreviousLook { get; init; }
    internal bool ClearReceipt;
    internal Task<EditSaveWorkResult> QueueTask { get; set; } = null!;
    internal Task<bool>? CompletionTask { get; set; }
    internal bool? AppliedResult { get; set; }
    internal bool TryClaimApply() => Interlocked.Exchange(ref applied, 1) == 0;
    internal bool IsClaimed => Volatile.Read(ref applied) != 0;
}

internal sealed class EditSaveCommitQueue
{
    private sealed class PathOpenRevisionComparer : IEqualityComparer<(string Path, long OpenRevision)>
    {
        internal static readonly PathOpenRevisionComparer Instance = new();

        public bool Equals((string Path, long OpenRevision) x, (string Path, long OpenRevision) y) =>
            x.OpenRevision == y.OpenRevision && StringComparer.OrdinalIgnoreCase.Equals(x.Path, y.Path);

        public int GetHashCode((string Path, long OpenRevision) obj) =>
            HashCode.Combine(StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Path), obj.OpenRevision);
    }

    private readonly Queue<PendingEditSaveCommit> pendingEditSaves = new();
    private readonly Dictionary<(string Path, long OpenRevision), long> latestSucceededRevisions = new(PathOpenRevisionComparer.Instance);

    internal bool HasPending
    {
        get
        {
            PruneClaimedHead();
            return pendingEditSaves.Count > 0;
        }
    }

    internal PendingEditSaveCommit? FirstPending
    {
        get
        {
            PruneClaimedHead();
            return pendingEditSaves.Count > 0 ? pendingEditSaves.Peek() : null;
        }
    }

    internal PendingEditSaveCommit? LastPending
    {
        get
        {
            PruneClaimedHead();
            PendingEditSaveCommit? last = null;
            foreach (var item in pendingEditSaves)
            {
                if (!item.IsClaimed) last = item;
            }
            return last;
        }
    }

    internal void Enqueue(PendingEditSaveCommit commit)
    {
        ArgumentNullException.ThrowIfNull(commit);
        pendingEditSaves.Enqueue(commit);
    }

    internal bool HasNewerPendingOrSucceededCommit(PendingEditSaveCommit commit)
    {
        var key = (commit.Path, commit.OpenRevision);
        if (latestSucceededRevisions.TryGetValue(key, out var succeededRevision) && succeededRevision > commit.Revision)
            return true;
        foreach (var pending in pendingEditSaves)
        {
            if (pending.OpenRevision == commit.OpenRevision &&
                StringComparer.OrdinalIgnoreCase.Equals(pending.Path, commit.Path) &&
                pending.Revision > commit.Revision)
            {
                return true;
            }
        }
        return false;
    }

    internal bool ApplyResult(
        PendingEditSaveCommit target,
        Func<PendingEditSaveCommit, bool> isCurrentPhoto,
        Func<PendingEditSaveCommit, bool> isCurrentRevision,
        Action<PendingEditSaveCommit, PhotoEditState, bool> onApplied,
        Action<PendingEditSaveCommit, Exception, bool> onFailed)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (target.IsClaimed)
        {
            PruneClaimedHead();
            return target.AppliedResult ?? true;
        }

        var foundInQueue = false;
        foreach (var item in pendingEditSaves)
        {
            if (ReferenceEquals(item, target))
            {
                foundInQueue = true;
                break;
            }
        }

        if (!foundInQueue)
            return ApplySingle(target, isCurrentPhoto, isCurrentRevision, onApplied, onFailed);

        while (pendingEditSaves.Count > 0)
        {
            var head = pendingEditSaves.Peek();
            if (head.IsClaimed)
            {
                pendingEditSaves.Dequeue();
                continue;
            }
            if (!ReferenceEquals(head, target) && !head.QueueTask.IsCompleted)
                break;
            pendingEditSaves.Dequeue();
            var result = ApplySingle(head, isCurrentPhoto, isCurrentRevision, onApplied, onFailed);
            if (ReferenceEquals(head, target))
                return result;
        }

        return ApplySingle(target, isCurrentPhoto, isCurrentRevision, onApplied, onFailed);
    }

    internal bool ApplyPending(
        Func<PendingEditSaveCommit, bool> isCurrentPhoto,
        Func<PendingEditSaveCommit, bool> isCurrentRevision,
        Action<PendingEditSaveCommit, PhotoEditState, bool> onApplied,
        Action<PendingEditSaveCommit, Exception, bool> onFailed)
    {
        var results = new List<(PendingEditSaveCommit Commit, bool Succeeded)>();
        while (pendingEditSaves.Count > 0)
        {
            var commit = pendingEditSaves.Dequeue();
            if (commit.IsClaimed) continue;
            var succeeded = ApplySingle(commit, isCurrentPhoto, isCurrentRevision, onApplied, onFailed);
            results.Add((commit, succeeded));
        }

        foreach (var (commit, succeeded) in results)
        {
            if (succeeded) continue;
            var key = (commit.Path, commit.OpenRevision);
            if (!latestSucceededRevisions.TryGetValue(key, out var succeededRevision) || succeededRevision <= commit.Revision)
                return false;
        }
        return true;
    }

    private void PruneClaimedHead()
    {
        while (pendingEditSaves.Count > 0 && pendingEditSaves.Peek().IsClaimed)
            pendingEditSaves.Dequeue();
    }

    private bool ApplySingle(
        PendingEditSaveCommit commit,
        Func<PendingEditSaveCommit, bool> isCurrentPhoto,
        Func<PendingEditSaveCommit, bool> isCurrentRevision,
        Action<PendingEditSaveCommit, PhotoEditState, bool> onApplied,
        Action<PendingEditSaveCommit, Exception, bool> onFailed)
    {
        if (!commit.TryClaimApply()) return commit.AppliedResult ?? true;
        bool succeeded;
        try
        {
            var outcome = commit.QueueTask.GetAwaiter().GetResult();
            if (outcome.Superseded)
            {
                succeeded = true;
            }
            else
            {
                var saved = outcome.Saved!;
                var result = commit.Session.CompleteEditCommit(commit.Baseline, saved);
                if (result.Status is not (AdjustmentStatus.Applied or AdjustmentStatus.Unchanged))
                    throw result.Error ?? new InvalidOperationException("Adjustment was not saved.");
                var key = (commit.Path, commit.OpenRevision);
                if (!latestSucceededRevisions.TryGetValue(key, out var previousSucceeded) || commit.Revision > previousSucceeded)
                    latestSucceededRevisions[key] = commit.Revision;
                if (isCurrentPhoto(commit))
                    onApplied(commit, result.Saved ?? saved, isCurrentRevision(commit));
                succeeded = true;
            }
        }
        catch (Exception error)
        {
            var key = (commit.Path, commit.OpenRevision);
            var hasNewerSucceeded = latestSucceededRevisions.TryGetValue(key, out var succeededRevision) &&
                succeededRevision > commit.Revision;
            var shouldShowNotice = isCurrentPhoto(commit) && isCurrentRevision(commit) && !hasNewerSucceeded;
            onFailed(commit, error, shouldShowNotice);
            succeeded = false;
        }
        commit.AppliedResult = succeeded;
        return succeeded;
    }
}
