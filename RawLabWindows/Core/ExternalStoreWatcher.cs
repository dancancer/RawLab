using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace RawLab.Windows;

internal enum ExternalReloadDecision
{
    None,
    AutoReload,
    ShowBanner
}

internal sealed record ExternalReloadEvaluation(
    ExternalReloadDecision Decision,
    ExternalReloadBannerState NextState);

internal sealed class ExternalReloadBannerState
{
    internal static readonly ExternalReloadBannerState Empty = new(
        visible: false,
        pendingRecord: null,
        pendingStamp: null,
        dismissedStamps: Array.Empty<PathStatStamp>());

    internal bool Visible { get; }
    internal PhotoEditState? PendingRecord { get; }
    internal PathStatStamp? PendingStamp { get; }
    private readonly HashSet<PathStatStamp> dismissedStamps;

    private ExternalReloadBannerState(
        bool visible,
        PhotoEditState? pendingRecord,
        PathStatStamp? pendingStamp,
        IEnumerable<PathStatStamp> dismissedStamps)
    {
        Visible = visible;
        PendingRecord = pendingRecord;
        PendingStamp = pendingStamp;
        this.dismissedStamps = new HashSet<PathStatStamp>(dismissedStamps);
    }

    private static SavedEdit? NormalizeForComparison(SavedEdit? edit, (double Temperature, double Tint)? asShotCalibration) =>
        edit == null ? null : edit with { Settings = edit.Settings.WithAsShotCalibration(asShotCalibration) };

    internal ExternalReloadEvaluation Evaluate(
        PhotoEditState currentCommitted,
        SavedEdit? currentUiEdit,
        PhotoEditState diskRecord,
        PathStatStamp? stamp,
        bool hasUnsavedManualDraft,
        bool hasPendingAsyncSave = false,
        (double Temperature, double Tint)? asShotCalibration = null)
    {
        if (!currentCommitted.Identity.SameFile(diskRecord.Identity))
            return new(ExternalReloadDecision.None, this);

        if (hasPendingAsyncSave)
            return new(ExternalReloadDecision.None, this);

        var comparableCommitted = NormalizeForComparison(currentCommitted.Edit, asShotCalibration);
        var comparableUi = NormalizeForComparison(currentUiEdit, asShotCalibration);
        var comparableDisk = NormalizeForComparison(diskRecord.Edit, asShotCalibration);

        if (!hasUnsavedManualDraft)
        {
            var uiMatchesDisk = SavedEdit.Same(comparableUi, comparableDisk);
            var committedMatchesDisk = SavedEdit.Same(comparableCommitted, comparableDisk);
            if (uiMatchesDisk && committedMatchesDisk)
            {
                return new(ExternalReloadDecision.None,
                    new(false, null, null, dismissedStamps));
            }
            return new(ExternalReloadDecision.AutoReload,
                new(false, null, null, dismissedStamps));
        }

        if (SavedEdit.Same(comparableCommitted, comparableDisk))
            return new(ExternalReloadDecision.None, this);

        if (stamp is { } s && dismissedStamps.Contains(s) && !Visible)
            return new(ExternalReloadDecision.None, this);

        return new(ExternalReloadDecision.ShowBanner,
            new(true, diskRecord.Copy(), stamp, dismissedStamps));
    }

    internal bool TryAcceptReload(bool hasPendingAsyncSave, out PhotoEditState? pendingRecord)
    {
        if (hasPendingAsyncSave || PendingRecord == null)
        {
            pendingRecord = null;
            return false;
        }
        pendingRecord = PendingRecord;
        return true;
    }

    internal ExternalReloadBannerState KeepManualDraft()
    {
        var nextDismissed = new HashSet<PathStatStamp>(dismissedStamps);
        if (PendingStamp is { } stamp)
            nextDismissed.Add(stamp);
        return new(false, null, null, nextDismissed);
    }

    internal ExternalReloadBannerState AcceptReload() =>
        new(false, null, null, Array.Empty<PathStatStamp>());

    internal ExternalReloadBannerState ClearOnSourceChange() => Empty;
}

internal sealed class ExternalStoreWatcher : IDisposable
{
    private readonly object gate = new();
    private readonly string[] targetPaths;
    private readonly int debounceMs;
    private readonly Action<string> onChanged;
    private readonly Dictionary<string, FileSystemWatcher> watchers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, PathStatStamp> lastStamps = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> dirtyTargets = new(StringComparer.OrdinalIgnoreCase);
    private Timer? debounceTimer;
    private bool disposed;

    internal ExternalStoreWatcher(
        IEnumerable<string> paths,
        Action<string> onChanged,
        int debounceMs = 50)
    {
        targetPaths = paths
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        this.onChanged = onChanged;
        this.debounceMs = Math.Max(10, debounceMs);

        lock (gate)
        {
            foreach (var target in targetPaths)
                lastStamps[target] = PathStatStamp.Capture(target);
            RefreshWatchersLocked();
        }
    }

    internal void Refresh()
    {
        lock (gate)
        {
            if (disposed) return;
            RefreshWatchersLocked();
        }
    }

    private void RefreshWatchersLocked()
    {
        var desiredDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var target in targetPaths)
        {
            var existing = NearestExistingDirectory(Path.GetDirectoryName(target));
            if (existing != null)
                desiredDirs.Add(existing);
        }

        foreach (var stale in watchers.Keys.Where(dir => !desiredDirs.Contains(dir)).ToArray())
        {
            watchers[stale].Dispose();
            watchers.Remove(stale);
        }

        foreach (var dir in desiredDirs)
        {
            if (watchers.ContainsKey(dir)) continue;
            try
            {
                var watcher = new FileSystemWatcher(dir)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                                   NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime
                };
                watcher.Changed += OnWatcherEvent;
                watcher.Created += OnWatcherEvent;
                watcher.Deleted += OnWatcherEvent;
                watcher.Renamed += OnWatcherRenamed;
                watcher.Error += OnWatcherError;
                watcher.EnableRaisingEvents = true;
                watchers[dir] = watcher;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or System.ComponentModel.Win32Exception)
            {
            }
        }
    }

    private static string? NearestExistingDirectory(string? directory)
    {
        var current = directory;
        while (!string.IsNullOrEmpty(current))
        {
            if (Directory.Exists(current))
                return Path.GetFullPath(current);
            current = Path.GetDirectoryName(current);
        }
        return null;
    }

    private void OnWatcherEvent(object sender, FileSystemEventArgs args) =>
        ScheduleCheck(args.FullPath);

    private void OnWatcherRenamed(object sender, RenamedEventArgs args)
    {
        ScheduleCheck(args.OldFullPath);
        ScheduleCheck(args.FullPath);
    }

    private void OnWatcherError(object sender, ErrorEventArgs args)
    {
        lock (gate)
        {
            if (disposed) return;
            foreach (var pair in watchers.Where(pair => ReferenceEquals(pair.Value, sender)).ToArray())
            {
                pair.Value.Dispose();
                watchers.Remove(pair.Key);
            }
            lastStamps.Clear();
            RefreshWatchersLocked();
        }
        ScheduleCheck(null);
    }

    internal void SimulateErrorForTests()
    {
        FileSystemWatcher? first;
        lock (gate) first = watchers.Values.FirstOrDefault();
        if (first != null)
            OnWatcherError(first, new ErrorEventArgs(new IOException("Simulated buffer overflow")));
        else
            ScheduleCheck(null);
    }

    private void ScheduleCheck(string? changedPath)
    {
        lock (gate)
        {
            if (disposed) return;
            RefreshWatchersLocked();
            if (string.IsNullOrEmpty(changedPath))
            {
                foreach (var target in targetPaths) dirtyTargets.Add(target);
            }
            else
            {
                var normalized = Path.GetFullPath(changedPath);
                foreach (var target in targetPaths)
                {
                    if (StringComparer.OrdinalIgnoreCase.Equals(normalized, target) ||
                        normalized.StartsWith(target + ".", StringComparison.OrdinalIgnoreCase) ||
                        IsAncestorDirectory(normalized, target))
                    {
                        dirtyTargets.Add(target);
                    }
                }
            }
            if (dirtyTargets.Count == 0) return;

            debounceTimer ??= new Timer(_ => FlushChanges(), null, Timeout.Infinite, Timeout.Infinite);
            try { debounceTimer.Change(debounceMs, Timeout.Infinite); }
            catch (ObjectDisposedException) { }
        }
    }

    private static bool IsAncestorDirectory(string candidateDir, string targetFile)
    {
        var dir = Path.GetDirectoryName(targetFile);
        while (!string.IsNullOrEmpty(dir))
        {
            if (StringComparer.OrdinalIgnoreCase.Equals(dir, candidateDir))
                return true;
            dir = Path.GetDirectoryName(dir);
        }
        return false;
    }

    private void FlushChanges()
    {
        var changed = new List<string>();
        lock (gate)
        {
            if (disposed) return;
            RefreshWatchersLocked();
            var candidates = dirtyTargets.ToArray();
            dirtyTargets.Clear();
            foreach (var target in candidates)
            {
                var current = PathStatStamp.Capture(target);
                if (!lastStamps.TryGetValue(target, out var previous) || current != previous)
                {
                    lastStamps[target] = current;
                    changed.Add(target);
                }
            }
        }

        foreach (var target in changed)
        {
            try { onChanged(target); }
            catch { }
        }
    }

    public void Dispose()
    {
        FileSystemWatcher[] activeWatchers;
        Timer? timer;
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            activeWatchers = watchers.Values.ToArray();
            watchers.Clear();
            dirtyTargets.Clear();
            timer = debounceTimer;
            debounceTimer = null;
        }
        timer?.Dispose();
        foreach (var watcher in activeWatchers) watcher.Dispose();
    }
}
