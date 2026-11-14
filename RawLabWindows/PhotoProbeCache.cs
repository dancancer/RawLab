using System.IO;

namespace RawLab.Windows;

internal sealed class PhotoProbeCache
{
    internal delegate HDRProbeState ProbeCallback(string path, out HDRSourceInfo? info, int processingVersion);

    private readonly record struct Key(string CanonicalPath, bool CameraRaw, int ProcessingVersion);

    private sealed class KeyComparer : IEqualityComparer<Key>
    {
        public static KeyComparer Instance { get; } = new();
        public bool Equals(Key x, Key y) =>
            x.CameraRaw == y.CameraRaw &&
            x.ProcessingVersion == y.ProcessingVersion &&
            StringComparer.OrdinalIgnoreCase.Equals(x.CanonicalPath, y.CanonicalPath);

        public int GetHashCode(Key obj) => HashCode.Combine(
            StringComparer.OrdinalIgnoreCase.GetHashCode(obj.CanonicalPath),
            obj.CameraRaw,
            obj.ProcessingVersion);
    }

    private readonly record struct Entry(PathStatStamp Stat, HDRProbeState State, HDRSourceInfo? Info);

    internal static PhotoProbeCache Shared { get; } = new();

    private readonly object gate = new();
    private readonly Dictionary<Key, Entry> entries = new(KeyComparer.Instance);
    private readonly Queue<Key> evictionOrder = new();
    private readonly int capacity;
    private long missCount;
    private long hitCount;

    internal PhotoProbeCache(int capacity = 256)
    {
        this.capacity = Math.Max(16, capacity);
    }

    internal long MissCount => Interlocked.Read(ref missCount);
    internal long HitCount => Interlocked.Read(ref hitCount);

    internal HDRProbeState GetOrProbe(
        string path,
        bool cameraRaw,
        int processingVersion,
        ProbeCallback probe,
        out HDRSourceInfo? info)
    {
        var canonical = Path.GetFullPath(path);
        var stat = PathStatStamp.Capture(canonical);
        var key = new Key(canonical, cameraRaw, processingVersion);

        if (stat.Exists)
        {
            lock (gate)
            {
                if (entries.TryGetValue(key, out var cached) && cached.Stat == stat)
                {
                    Interlocked.Increment(ref hitCount);
                    info = cached.Info;
                    return cached.State;
                }
            }
        }

        Interlocked.Increment(ref missCount);
        HDRProbeState state;
        try
        {
            state = probe(canonical, out info, processingVersion);
        }
        catch
        {
            lock (gate) entries.Remove(key);
            throw;
        }

        var afterStat = PathStatStamp.Capture(canonical);
        if (afterStat.Exists && afterStat == stat)
        {
            lock (gate)
            {
                if (!entries.ContainsKey(key))
                {
                    while (entries.Count >= capacity && evictionOrder.TryDequeue(out var oldest))
                        entries.Remove(oldest);
                    evictionOrder.Enqueue(key);
                }
                entries[key] = new(stat, state, info);
            }
        }
        else
        {
            lock (gate) entries.Remove(key);
        }

        return state;
    }

    internal void Clear()
    {
        lock (gate)
        {
            entries.Clear();
            evictionOrder.Clear();
        }
    }
}
