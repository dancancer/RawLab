using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;

namespace RawLab.Windows;

internal readonly record struct PathStatStamp(
    bool Exists,
    string CanonicalPath,
    string ResolvedPath,
    string? LinkTarget,
    long Length,
    long ModifiedTicks,
    long CreatedTicks)
{
    internal static PathStatStamp Capture(string path)
    {
        var canonical = Path.GetFullPath(path);
        try
        {
            var info = new FileInfo(canonical);
            var linkTarget = info.LinkTarget;
            if (linkTarget != null)
            {
                var target = File.ResolveLinkTarget(canonical, returnFinalTarget: true);
                if (target is not FileInfo targetFile || !targetFile.Exists)
                    return new(false, canonical, target?.FullName ?? canonical, linkTarget, -1, 0, 0);
                return new(true, canonical, targetFile.FullName, linkTarget,
                    targetFile.Length, targetFile.LastWriteTimeUtc.Ticks, targetFile.CreationTimeUtc.Ticks);
            }

            if (!info.Exists)
                return new(false, canonical, canonical, null, -1, 0, 0);

            return new(true, canonical, canonical, null,
                info.Length, info.LastWriteTimeUtc.Ticks, info.CreationTimeUtc.Ticks);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new(false, canonical, canonical, null, -1, 0, 0);
        }
    }
}

internal sealed class FileDigestCache
{
    private readonly record struct Entry(
        OriginalIdentity Identity,
        PathStatStamp Stat,
        string Sha256Hex);

    internal static FileDigestCache Shared { get; } = new();

    private readonly object gate = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> evictionOrder = new();
    private readonly int capacity;
    private readonly Func<string, string> computeSha256Hex;
    private long computeCount;
    private long hitCount;

    internal FileDigestCache(int capacity = 512, Func<string, string>? computeSha256Hex = null)
    {
        this.capacity = Math.Max(16, capacity);
        this.computeSha256Hex = computeSha256Hex ?? HashFileHex;
    }

    internal long ComputeCount => Interlocked.Read(ref computeCount);
    internal long HitCount => Interlocked.Read(ref hitCount);

    internal (OriginalIdentity Identity, string Sha256Hex) GetDigest(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var stat = PathStatStamp.Capture(fullPath);
        if (!stat.Exists)
        {
            Invalidate(fullPath);
            throw new FileNotFoundException(Loc.Text("无法访问原始照片。"), path);
        }

        var identity = OriginalIdentity.Read(fullPath);
        lock (gate)
        {
            if (entries.TryGetValue(fullPath, out var existing) &&
                existing.Stat == stat &&
                existing.Identity.SameFile(identity))
            {
                Interlocked.Increment(ref hitCount);
                return (identity, existing.Sha256Hex);
            }
        }

        var hex = computeSha256Hex(fullPath);
        Interlocked.Increment(ref computeCount);

        var afterStat = PathStatStamp.Capture(fullPath);
        OriginalIdentity? afterIdentity = null;
        if (afterStat.Exists)
        {
            try { afterIdentity = OriginalIdentity.Read(fullPath); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception) { afterIdentity = null; }
        }

        if (afterStat == stat && afterIdentity != null && afterIdentity.SameFile(identity))
        {
            lock (gate)
            {
                if (!entries.ContainsKey(fullPath))
                {
                    while (entries.Count >= capacity && evictionOrder.TryDequeue(out var oldest))
                        entries.Remove(oldest);
                    evictionOrder.Enqueue(fullPath);
                }
                entries[fullPath] = new(identity, stat, hex);
            }
        }
        else
        {
            Invalidate(fullPath);
        }

        return (identity, hex);
    }

    internal bool MatchesSha256(string path, string expectedSha256Hex, long maximumBytes)
    {
        var fullPath = Path.GetFullPath(path);
        var stat = PathStatStamp.Capture(fullPath);
        if (!stat.Exists || stat.Length <= 0 || stat.Length > maximumBytes)
        {
            Invalidate(fullPath);
            return false;
        }

        try
        {
            var (_, sha256) = GetDigest(fullPath);
            return sha256.Equals(expectedSha256Hex, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception)
        {
            return false;
        }
    }

    internal void Invalidate(string path)
    {
        var fullPath = Path.GetFullPath(path);
        lock (gate) entries.Remove(fullPath);
    }

    internal void Clear()
    {
        lock (gate)
        {
            entries.Clear();
            evictionOrder.Clear();
        }
    }

    private static string HashFileHex(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream));
    }
}
