using System.IO;

namespace RawLab.Windows;

internal enum ViewSourceProbeOutcome
{
    Stale,
    Initialized,
    Unchanged,
    Replaced,
    BecameUnavailable,
    UnchangedUnavailable
}

internal sealed class ViewSourceState
{
    private string? currentPath;
    private long openRevision;
    private OriginalIdentity? cachedIdentity;
    private bool dirty;
    private long generation;

    internal long Generation => generation;

    internal void Reset()
    {
        ++generation;
        currentPath = null;
        openRevision = 0;
        cachedIdentity = null;
        dirty = false;
    }

    internal void SetOpenPhoto(string? path, long revision, OriginalIdentity? identity)
    {
        ++generation;
        currentPath = path == null ? null : Path.GetFullPath(path);
        openRevision = revision;
        cachedIdentity = identity;
        dirty = identity == null && path != null;
    }

    internal OriginalIdentity? Current(string? path, long revision)
    {
        if (path == null || openRevision != revision || !PathsEqual(currentPath, path))
            return null;
        return cachedIdentity;
    }

    internal void MarkDirty(string? path, long revision)
    {
        if (path != null && openRevision == revision && PathsEqual(currentPath, path))
        {
            ++generation;
            dirty = true;
        }
    }

    internal long? BeginWatcherProbe(string path, long revision)
    {
        if (openRevision != revision || !PathsEqual(currentPath, path))
            return null;
        dirty = true;
        return ++generation;
    }

    internal bool NeedsBackgroundProbe(string? path, long revision) =>
        path != null && openRevision == revision && PathsEqual(currentPath, path) && (dirty || cachedIdentity == null);

    internal ViewSourceProbeOutcome ApplyProbeResult(
        string path, long revision, OriginalIdentity? probed, long? expectedGeneration = null)
    {
        if (openRevision != revision || !PathsEqual(currentPath, path))
            return ViewSourceProbeOutcome.Stale;
        if (expectedGeneration is { } expected && expected != generation)
            return ViewSourceProbeOutcome.Stale;

        dirty = false;
        var previous = cachedIdentity;
        if (probed == null)
        {
            if (previous != null)
            {
                ++generation;
                cachedIdentity = null;
                return ViewSourceProbeOutcome.BecameUnavailable;
            }
            cachedIdentity = null;
            return ViewSourceProbeOutcome.UnchangedUnavailable;
        }

        if (previous == null)
        {
            ++generation;
            cachedIdentity = probed;
            return ViewSourceProbeOutcome.Initialized;
        }

        if (!previous.SameFile(probed))
        {
            ++generation;
            cachedIdentity = probed;
            return ViewSourceProbeOutcome.Replaced;
        }

        if (expectedGeneration != null)
            ++generation;
        return ViewSourceProbeOutcome.Unchanged;
    }

    internal static OriginalIdentity? ResolveWorkerFrameSource(
        OriginalIdentity? workSource,
        OriginalIdentity? beforeRender,
        OriginalIdentity? afterRender,
        OriginalIdentity? latestViewSource,
        bool sameOpenFile)
    {
        if (!sameOpenFile || beforeRender == null || afterRender == null || !beforeRender.SameFile(afterRender))
            return null;
        if (workSource != null && !workSource.SameFile(afterRender))
            return null;
        if (latestViewSource == null || !latestViewSource.SameFile(afterRender))
            return null;
        return latestViewSource;
    }

    internal static OriginalIdentity? TryReadIdentity(string path, Func<string, OriginalIdentity>? read = null)
    {
        try
        {
            return (read ?? OriginalIdentity.Read)(path);
        }
        catch (Exception ex) when (PreviewFallback.IsFileIdentityFailure(ex))
        {
            return null;
        }
    }

    internal static bool PathsEqual(string? a, string? b)
    {
        if (a == null || b == null) return a == null && b == null;
        return StringComparer.OrdinalIgnoreCase.Equals(Path.GetFullPath(a), Path.GetFullPath(b));
    }
}

internal sealed class LookAvailabilityTracker
{
    private string? trackedPath;
    private bool available;
    private bool initialized;
    private long generation;
    private long probeCount;

    internal long Generation => generation;
    internal bool LastKnownAvailable => !initialized || available;
    internal long ProbeCount => Interlocked.Read(ref probeCount);

    internal void Reset()
    {
        ++generation;
        trackedPath = null;
        available = true;
        initialized = false;
    }

    internal void Invalidate(string? path = null)
    {
        if (path == null || trackedPath == null || ViewSourceState.PathsEqual(trackedPath, path))
        {
            ++generation;
            initialized = false;
        }
    }

    internal static bool ProbeExists(bool isHdrEditing, string? path) =>
        isHdrEditing || path == null || File.Exists(path);

    internal bool ApplyWorkerCheck(string? path, bool isAvailable, long? expectedGeneration = null)
    {
        if (expectedGeneration is { } expected && expected != generation)
            return false;
        trackedPath = path == null ? null : Path.GetFullPath(path);
        available = isAvailable;
        initialized = true;
        return true;
    }

    internal bool IsAvailable(bool isHdrEditing, string? path, Func<string, bool>? exists = null)
    {
        if (isHdrEditing || path == null)
            return true;

        var full = Path.GetFullPath(path);
        if (initialized && trackedPath != null && StringComparer.OrdinalIgnoreCase.Equals(trackedPath, full))
            return available;

        Interlocked.Increment(ref probeCount);
        trackedPath = full;
        available = (exists ?? File.Exists)(full);
        initialized = true;
        return available;
    }
}

internal sealed class HDRPresentationCoordinator
{
    private bool needsHideOrSync;
    private long layoutSkippedCount;
    private long presentationExecutedCount;

    internal long LayoutSkippedCount => Interlocked.Read(ref layoutSkippedCount);
    internal long PresentationExecutedCount => Interlocked.Read(ref presentationExecutedCount);

    internal static bool IsNativeOverlayActive(
        bool isLoaded,
        bool hdrEditing,
        bool hasHdrResult,
        bool sdrPreview,
        bool resultSurfaceAvailable,
        bool neutralSurfaceAvailable,
        bool geometryEditing,
        bool clipping) =>
        isLoaded && hdrEditing && hasHdrResult && !sdrPreview &&
        (resultSurfaceAvailable || neutralSurfaceAvailable) &&
        !geometryEditing && !clipping;

    internal bool ShouldRunOnLayoutUpdated(
        bool isLoaded,
        bool hdrEditing,
        bool hasHdrResult,
        bool sdrPreview,
        bool resultSurfaceAvailable,
        bool neutralSurfaceAvailable,
        bool geometryEditing,
        bool clipping)
    {
        if (!isLoaded)
        {
            Interlocked.Increment(ref layoutSkippedCount);
            return false;
        }

        if (needsHideOrSync ||
            IsNativeOverlayActive(isLoaded, hdrEditing, hasHdrResult, sdrPreview,
                resultSurfaceAvailable, neutralSurfaceAvailable, geometryEditing, clipping) ||
            (hdrEditing && hasHdrResult))
        {
            return true;
        }

        Interlocked.Increment(ref layoutSkippedCount);
        return false;
    }

    internal void RecordPresentation(
        bool isLoaded,
        bool hdrEditing,
        bool hasHdrResult,
        bool sdrPreview,
        bool resultSurfaceAvailable,
        bool neutralSurfaceAvailable,
        bool geometryEditing,
        bool clipping,
        bool timerRunning)
    {
        Interlocked.Increment(ref presentationExecutedCount);
        needsHideOrSync = isLoaded && (timerRunning ||
            (hdrEditing && hasHdrResult) ||
            IsNativeOverlayActive(isLoaded, hdrEditing, hasHdrResult, sdrPreview,
                resultSurfaceAvailable, neutralSurfaceAvailable, geometryEditing, clipping));
    }

    internal void MarkNeedsSync() => needsHideOrSync = true;
}
