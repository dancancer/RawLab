using System.IO;

namespace RawLab.Windows;

internal sealed class HDRSourceLease(HDRPairOwner owner, Action release) : IDisposable
{
    private Action? cleanup = release;
    internal HDRPairOwner Owner => owner;
    public void Dispose() => Interlocked.Exchange(ref cleanup, null)?.Invoke();
}

// 只缓存不可变的解码源；所有 RenderEngine 共用预算，正在使用的 owner 由 lease 保活。
// 解码在 Gate 锁外进行，并按 key 去重（single-flight），避免阻塞其他键的读取、释放与清理。
internal static class HDRSourceCache
{
    internal delegate HDRPairOwner DecodeDelegate(
        string path,
        HDRIntent intent,
        uint edge,
        HDRSourceInfo info,
        Native.Session? session,
        HDRCameraDevelopmentSettings? development,
        bool cameraAIEnabled,
        string? temporaryRoot,
        string? cameraProfileDirectory);

    private const ulong Budget = 128UL * 1024 * 1024;

    private sealed record CacheKey(
        string Path,
        string Identity,
        uint Edge,
        HDRCameraDevelopmentSettings? Development,
        string? LensDatabase,
        string? CameraAIKey)
    {
        internal bool MatchesBase(CacheKey other) =>
            StringComparer.OrdinalIgnoreCase.Equals(Path, other.Path) &&
            StringComparer.Ordinal.Equals(Identity, other.Identity) &&
            EqualityComparer<HDRCameraDevelopmentSettings>.Default.Equals(Development, other.Development) &&
            StringComparer.Ordinal.Equals(LensDatabase, other.LensDatabase) &&
            StringComparer.Ordinal.Equals(CameraAIKey, other.CameraAIKey);
    }

    private sealed class CacheKeyComparer : IEqualityComparer<CacheKey>
    {
        public bool Equals(CacheKey? x, CacheKey? y)
        {
            if (ReferenceEquals(x, y)) return true;
            if (x is null || y is null) return false;
            return x.Edge == y.Edge && x.MatchesBase(y);
        }

        public int GetHashCode(CacheKey obj)
        {
            var hash = new HashCode();
            hash.Add(obj.Path, StringComparer.OrdinalIgnoreCase);
            hash.Add(obj.Identity, StringComparer.Ordinal);
            hash.Add(obj.Edge);
            hash.Add(obj.Development);
            hash.Add(obj.LensDatabase, StringComparer.Ordinal);
            hash.Add(obj.CameraAIKey, StringComparer.Ordinal);
            return hash.ToHashCode();
        }
    }

    private sealed class InFlightDecode(CacheKey key, ulong generation)
    {
        internal readonly CacheKey Key = key;
        internal readonly ulong Generation = generation;
        internal readonly TaskCompletionSource<Entry> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Waiters = 1;
    }

    private sealed class Entry(
        string path,
        string identity,
        uint edge,
        HDRCameraDevelopmentSettings? development,
        string? lensDatabase,
        string? cameraAIKey,
        HDRPairOwner owner,
        ulong bytes)
    {
        internal readonly string Path = path, Identity = identity;
        internal readonly uint Edge = edge;
        internal readonly HDRCameraDevelopmentSettings? Development = development;
        internal readonly string? LensDatabase = lensDatabase;
        internal readonly string? CameraAIKey = cameraAIKey;
        internal readonly HDRPairOwner Owner = owner;
        internal readonly ulong Bytes = bytes;
        internal int Users;
        internal bool Retained;
    }

    private static readonly object Gate = new();
    private static readonly LinkedList<Entry> Entries = new();
    private static readonly Dictionary<CacheKey, InFlightDecode> InFlight = new(new CacheKeyComparer());
    private static ulong bytes;
    private static ulong generation;

    internal static ulong CachedBytes { get { lock (Gate) return bytes; } }

    internal static HDRSourceLease Acquire(
        string path,
        HDRSourceInfo info,
        bool final,
        uint edge,
        Native.Session? session = null,
        HDRCameraDevelopmentSettings? development = null,
        string? lensDatabase = null,
        string? cameraAIKey = null,
        string? temporaryRoot = null,
        string? cameraProfileDirectory = null,
        DecodeDelegate? decode = null)
    {
        var decodeFn = decode ?? DefaultDecode;
        if (final)
        {
            Clear();
            var owner = decodeFn(path, HDRIntent.Final, 0, info, session, development, cameraAIKey != null, temporaryRoot, cameraProfileDirectory);
            return new(owner, owner.Dispose);
        }

        var canonical = Path.GetFullPath(path);
        var identity = info.CacheIdentity;
        if (development is { IsDefault: true }) development = null;
        lensDatabase = development is { LensActive: true } ? lensDatabase : null;
        var key = new CacheKey(canonical, identity, edge, development, lensDatabase, cameraAIKey);

        while (true)
        {
            InFlightDecode? waitTarget = null;
            InFlightDecode? leader = null;

            lock (Gate)
            {
                for (var node = Entries.First; node != null;)
                {
                    var next = node.Next;
                    var value = node.Value;
                    if (!StringComparer.OrdinalIgnoreCase.Equals(value.Path, canonical)) { node = next; continue; }
                    if (value.Identity != identity) { Remove(node); node = next; continue; }
                    if (value.Edge < edge || value.Development != development || value.LensDatabase != lensDatabase ||
                        value.CameraAIKey != cameraAIKey) { node = next; continue; }
                    development?.CameraProfile?.RequireAsset(cameraProfileDirectory);
                    Entries.Remove(node);
                    Entries.AddFirst(node);
                    return Lease(value);
                }

                if (InFlight.TryGetValue(key, out var exact) && exact.Generation == generation)
                {
                    waitTarget = exact;
                }
                else
                {
                    foreach (var candidate in InFlight.Values)
                    {
                        if (candidate.Generation == generation && candidate.Key.Edge >= edge && candidate.Key.MatchesBase(key))
                        {
                            waitTarget = candidate;
                            break;
                        }
                    }
                }

                if (waitTarget != null)
                {
                    waitTarget.Waiters++;
                }
                else
                {
                    leader = new InFlightDecode(key, generation);
                    InFlight[key] = leader;
                }
            }

            if (waitTarget != null)
            {
                Entry waitedEntry;
                try
                {
                    waitedEntry = waitTarget.Completion.Task.GetAwaiter().GetResult();
                }
                catch (OperationCanceledException)
                {
                    // Leader may have been cancelled via its own session token; retry independently.
                    continue;
                }

                try
                {
                    development?.CameraProfile?.RequireAsset(cameraProfileDirectory);
                    return new(waitedEntry.Owner, () => Release(waitedEntry));
                }
                catch
                {
                    Release(waitedEntry);
                    throw;
                }
            }

            HDRPairOwner decoded;
            try
            {
                decoded = decodeFn(path, HDRIntent.Preview, edge, info, session, development, cameraAIKey != null, temporaryRoot, cameraProfileDirectory);
            }
            catch (OperationCanceledException oce)
            {
                RemoveInFlight(leader!);
                leader!.Completion.TrySetCanceled(oce.CancellationToken);
                throw;
            }
            catch (Exception ex)
            {
                RemoveInFlight(leader!);
                leader!.Completion.TrySetException(ex);
                throw;
            }

            Entry entry;
            lock (Gate)
            {
                RemoveInFlightLocked(leader!);
                entry = new Entry(
                    canonical,
                    identity,
                    edge,
                    development,
                    lensDatabase,
                    cameraAIKey,
                    decoded,
                    decoded.Pair.Hdr.SizeBytes + decoded.Pair.Sdr.SizeBytes)
                {
                    Users = leader!.Waiters
                };

                if (leader.Generation == generation)
                {
                    for (var node = Entries.First; node != null;)
                    {
                        var next = node.Next;
                        var value = node.Value;
                        if (StringComparer.OrdinalIgnoreCase.Equals(value.Path, canonical) && value.Identity != identity)
                            Remove(node);
                        node = next;
                    }

                    if (entry.Bytes <= Budget)
                    {
                        while (bytes + entry.Bytes > Budget && Entries.Last != null) Remove(Entries.Last);
                        Entries.AddFirst(entry);
                        entry.Retained = true;
                        bytes += entry.Bytes;
                    }
                }
            }

            leader!.Completion.TrySetResult(entry);
            return new(entry.Owner, () => Release(entry));
        }
    }

    private static HDRPairOwner DefaultDecode(
        string path,
        HDRIntent intent,
        uint edge,
        HDRSourceInfo info,
        Native.Session? session,
        HDRCameraDevelopmentSettings? development,
        bool cameraAIEnabled,
        string? temporaryRoot,
        string? cameraProfileDirectory) =>
        HDRNative.Decode(path, intent, edge, info, session, development, cameraAIEnabled, temporaryRoot, cameraProfileDirectory);

    private static void RemoveInFlight(InFlightDecode target)
    {
        lock (Gate) RemoveInFlightLocked(target);
    }

    private static void RemoveInFlightLocked(InFlightDecode target)
    {
        if (InFlight.TryGetValue(target.Key, out var current) && ReferenceEquals(current, target))
            InFlight.Remove(target.Key);
    }

    private static void Release(Entry value)
    {
        lock (Gate)
        {
            value.Users--;
            if (!value.Retained && value.Users == 0) value.Owner.Dispose();
        }
    }

    private static HDRSourceLease Lease(Entry value)
    {
        value.Users++;
        return new(value.Owner, () => Release(value));
    }

    private static void Remove(LinkedListNode<Entry> node)
    {
        Entries.Remove(node);
        var value = node.Value;
        bytes -= value.Bytes;
        value.Retained = false;
        if (value.Users == 0) value.Owner.Dispose();
    }

    internal static void Clear()
    {
        lock (Gate)
        {
            generation++;
            InFlight.Clear();
            while (Entries.Last != null) Remove(Entries.Last);
        }
    }
}
