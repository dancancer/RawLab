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
    long CreatedTicks,
    long ChangeTicks = 0,
    long Usn = 0,
    string? FileId = null)
{
    internal static PathStatStamp Capture(string path, Func<string, OriginalIdentity>? readIdentity = null)
    {
        var canonical = Path.GetFullPath(path);
        try
        {
            var info = new FileInfo(canonical);
            var linkTarget = info.LinkTarget;
            string resolvedPath;
            long length;
            long modifiedTicks;
            long createdTicks;
            if (linkTarget != null)
            {
                var target = File.ResolveLinkTarget(canonical, returnFinalTarget: true);
                if (target is not FileInfo targetFile || !targetFile.Exists)
                    return new(false, canonical, target?.FullName ?? canonical, linkTarget, -1, 0, 0);
                resolvedPath = targetFile.FullName;
                length = targetFile.Length;
                modifiedTicks = targetFile.LastWriteTimeUtc.Ticks;
                createdTicks = targetFile.CreationTimeUtc.Ticks;
            }
            else
            {
                if (!info.Exists)
                    return new(false, canonical, canonical, null, -1, 0, 0);
                resolvedPath = canonical;
                length = info.Length;
                modifiedTicks = info.LastWriteTimeUtc.Ticks;
                createdTicks = info.CreationTimeUtc.Ticks;
            }

            long changeTicks = 0;
            long usn = 0;
            string? fileId = null;
            if (OperatingSystem.IsWindows())
            {
                if (!WindowsFileIdentity.TryReadStat(resolvedPath, out var winStat))
                    return new(false, canonical, resolvedPath, linkTarget, -1, 0, 0);
                length = winStat.Length;
                modifiedTicks = winStat.ModifiedTicks;
                createdTicks = winStat.CreatedTicks;
                changeTicks = winStat.ChangeTicks;
                usn = winStat.Usn;
                fileId = winStat.FileId;
            }

            if (readIdentity != null)
                fileId = readIdentity(canonical).FileID ?? fileId;

            return new(true, canonical, resolvedPath, linkTarget, length, modifiedTicks, createdTicks, changeTicks, usn, fileId);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception or System.Security.SecurityException)
        {
            return new(false, canonical, canonical, null, -1, 0, 0);
        }
    }
}

internal sealed class FileDigestCache
{
    internal const long SmallFileDirectHashBytes = 64 * 1024;

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
    private readonly Func<string, OriginalIdentity> readIdentity;
    private readonly long smallFileDirectHashBytes;
    private long computeCount;
    private long hitCount;

    internal FileDigestCache(
        int capacity = 512,
        Func<string, string>? computeSha256Hex = null,
        Func<string, OriginalIdentity>? readIdentity = null,
        long smallFileDirectHashBytes = SmallFileDirectHashBytes)
    {
        this.capacity = Math.Max(16, capacity);
        this.computeSha256Hex = computeSha256Hex ?? HashFileHex;
        this.readIdentity = readIdentity ?? OriginalIdentity.Read;
        this.smallFileDirectHashBytes = Math.Max(0, smallFileDirectHashBytes);
    }

    internal long ComputeCount => Interlocked.Read(ref computeCount);
    internal long HitCount => Interlocked.Read(ref hitCount);

    internal (OriginalIdentity Identity, string Sha256Hex) GetDigest(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var stat = PathStatStamp.Capture(fullPath, readIdentity == OriginalIdentity.Read ? null : readIdentity);
        if (!stat.Exists)
        {
            Invalidate(fullPath);
            throw new FileNotFoundException(Loc.Text("无法访问原始照片。"), path);
        }

        var identity = readIdentity(fullPath);
        if (stat.Length <= smallFileDirectHashBytes)
        {
            var directHex = computeSha256Hex(fullPath);
            Interlocked.Increment(ref computeCount);
            Invalidate(fullPath);
            return (identity, directHex);
        }

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

        var afterStat = PathStatStamp.Capture(fullPath, readIdentity == OriginalIdentity.Read ? null : readIdentity);
        OriginalIdentity? afterIdentity = null;
        if (afterStat.Exists)
        {
            try { afterIdentity = readIdentity(fullPath); }
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
        var stat = PathStatStamp.Capture(fullPath, readIdentity == OriginalIdentity.Read ? null : readIdentity);
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
