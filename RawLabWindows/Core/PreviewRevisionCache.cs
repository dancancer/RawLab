using System.Diagnostics.CodeAnalysis;

namespace RawLab.Windows;

internal sealed class PreviewRevisionCache<TKey, TValue>(
    long maximumBytes,
    Func<TValue, long> measureBytes,
    int maximumEntries = 16)
    where TKey : notnull
{
    private sealed record CacheEntry(TKey Key, TValue Value, long Bytes);

    private readonly object gate = new();
    private readonly Dictionary<TKey, LinkedListNode<CacheEntry>> entries = new();
    private readonly LinkedList<CacheEntry> order = new();
    private long totalBytes;
    private long hits;
    private long misses;

    internal long TotalBytes
    {
        get { lock (gate) return totalBytes; }
    }

    internal int Count
    {
        get { lock (gate) return entries.Count; }
    }

    internal long Hits
    {
        get { lock (gate) return hits; }
    }

    internal long Misses
    {
        get { lock (gate) return misses; }
    }

    internal bool TryGet(TKey key, [MaybeNullWhen(false)] out TValue value)
    {
        lock (gate)
        {
            if (entries.TryGetValue(key, out var node))
            {
                order.Remove(node);
                order.AddLast(node);
                hits++;
                value = node.Value.Value;
                return true;
            }
            misses++;
            value = default;
            return false;
        }
    }

    internal void Set(TKey key, TValue value)
    {
        var bytes = Math.Max(0, measureBytes(value));
        if (bytes > maximumBytes) return;
        lock (gate)
        {
            if (entries.TryGetValue(key, out var existing))
            {
                totalBytes -= existing.Value.Bytes;
                order.Remove(existing);
                entries.Remove(key);
            }

            while (order.First != null &&
                   (totalBytes + bytes > maximumBytes || entries.Count >= Math.Max(1, maximumEntries)))
            {
                var oldest = order.First;
                order.RemoveFirst();
                entries.Remove(oldest.Value.Key);
                totalBytes -= oldest.Value.Bytes;
            }

            var node = order.AddLast(new CacheEntry(key, value, bytes));
            entries[key] = node;
            totalBytes += bytes;
        }
    }

    internal void Clear()
    {
        lock (gate)
        {
            entries.Clear();
            order.Clear();
            totalBytes = 0;
        }
    }
}
