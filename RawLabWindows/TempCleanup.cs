using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

internal sealed class ExportStagingLease : IDisposable
{
    private readonly string stagingPath;
    private string? leasePath;

    internal ExportStagingLease(string stagingPath, string? leasePath)
    {
        this.stagingPath = stagingPath;
        this.leasePath = leasePath;
    }

    public void Dispose()
    {
        var recordedLease = Interlocked.Exchange(ref leasePath, null);
        TempCleanup.TryDeleteExportStagingFile(stagingPath);
        TempCleanup.TryDeleteFileIfOrdinary(recordedLease);
    }
}

// ┌──────────────────────────────────────────────────────────────────────┐
// │ Windows 临时目录、统计固定缓存与单张导出 staging 文件的生命周期清理   │
// │                                                                      │
// │ 1. 系统临时目录：仅扫描本应用明确拥有的目录前缀，保留期内一律不动；   │
// │    超出保留期后，若有 .rawlab-owner 标记且所属进程仍存活则继续保留；  │
// │    旧版无进程标记的残留目录无法反查所属实例，统一按保留期边界清扫。   │
// │ 2. 重解析点保护：顶层或子级符号链接 / NTFS junction 一律不递归跟随。  │
// │ 3. 只读清理：删除本应用拥有的过期文件与目录前先移除 ReadOnly 属性。   │
// └──────────────────────────────────────────────────────────────────────┘
internal static class TempCleanup
{
    internal static readonly TimeSpan DefaultRetention = TimeSpan.FromHours(24);
    internal const string OwnerMarkerFileName = ".rawlab-owner";
    internal static readonly string[] OwnedTempDirectoryPrefixes =
    [
        "RawLab-LUT-preview-",
        "rawlab-rum-",
        "rawlab-update-verify-",
    ];

    private static readonly string[] ExportStagingExtensions = [".jpg", ".png", ".dng"];
    private const int MaxTraversalDepth = 16;

    private sealed record ExportStagingRecord(string StagingPath, int ProcessId, long StartTicks);

    internal static string DefaultExportStagingDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RawLab", "Cache", "ExportStaging");

    internal static void SweepStartup()
    {
        try
        {
            SweepStartup(
                Path.GetTempPath(),
                UsageAnalytics.DefaultCacheDirectory,
                DefaultExportStagingDirectory,
                DateTime.UtcNow,
                DefaultRetention);
        }
        catch (Exception error) when (error is not (OutOfMemoryException or StackOverflowException))
        {
            Trace.WriteLine($"TempCleanup.SweepStartup: caught unhandled startup sweep exception: {error.Message}");
        }
    }

    internal static void SweepStartup(
        string tempRoot,
        string analyticsCacheDirectory,
        string exportStagingDirectory,
        DateTime utcNow,
        TimeSpan retention,
        Func<int, long, bool>? isProcessAlive = null,
        Func<string, IEnumerable<DirectoryInfo>>? enumerateDirectories = null,
        Func<string, IEnumerable<FileInfo>>? enumerateFiles = null)
    {
        try
        {
            SweepTempDirectories(tempRoot, utcNow, retention, isProcessAlive, enumerateDirectories);
        }
        catch (Exception error) when (error is not (OutOfMemoryException or StackOverflowException))
        {
            Trace.WriteLine($"TempCleanup.SweepStartup: SweepTempDirectories failed: {error.Message}");
        }

        try
        {
            SweepExpiredAnalyticsCache(analyticsCacheDirectory, utcNow, retention, isProcessAlive);
        }
        catch (Exception error) when (error is not (OutOfMemoryException or StackOverflowException))
        {
            Trace.WriteLine($"TempCleanup.SweepStartup: SweepExpiredAnalyticsCache failed: {error.Message}");
        }

        try
        {
            SweepRecordedExportStaging(exportStagingDirectory, utcNow, retention, isProcessAlive, enumerateFiles);
        }
        catch (Exception error) when (error is not (OutOfMemoryException or StackOverflowException))
        {
            Trace.WriteLine($"TempCleanup.SweepStartup: SweepRecordedExportStaging failed: {error.Message}");
        }
    }

    internal static bool HasOwnedTempPrefix(string directoryName)
    {
        if (string.IsNullOrEmpty(directoryName)) return false;
        foreach (var prefix in OwnedTempDirectoryPrefixes)
        {
            if (directoryName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && directoryName.Length > prefix.Length)
                return true;
        }
        return false;
    }

    internal static void SweepTempDirectories(
        string tempRoot,
        DateTime utcNow,
        TimeSpan retention,
        Func<int, long, bool>? isProcessAlive = null,
        Func<string, IEnumerable<DirectoryInfo>>? enumerateDirectories = null)
    {
        if (string.IsNullOrWhiteSpace(tempRoot) || !Directory.Exists(tempRoot)) return;
        DirectoryInfo rootInfo;
        try { rootInfo = new DirectoryInfo(tempRoot); }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return; }
        try { if (IsReparsePoint(rootInfo)) return; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Trace.WriteLine($"TempCleanup: skipping root {tempRoot}: {error.Message}"); return; }

        IEnumerable<DirectoryInfo> directories;
        try { directories = enumerateDirectories != null ? enumerateDirectories(tempRoot) : rootInfo.EnumerateDirectories(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Trace.WriteLine($"TempCleanup: enumeration failed for {tempRoot}: {error.Message}"); return; }

        using var enumerator = directories.GetEnumerator();
        while (true)
        {
            DirectoryInfo directory;
            try
            {
                if (!enumerator.MoveNext()) break;
                directory = enumerator.Current;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Trace.WriteLine($"TempCleanup: directory enumeration failed in {tempRoot}: {error.Message}");
                break;
            }

            try
            {
                if (!HasOwnedTempPrefix(directory.Name)) continue;
                if (IsReparsePoint(directory)) continue;
                if (!TryGetLatestWriteTimeUtc(directory, 0, out var latestWriteUtc)) continue;
                if (utcNow - latestWriteUtc < retention) continue;
                // 有进程标记时核实 PID 与启动时间，避免误删跨天运行的另一实例；
                // 旧版残留目录没有进程标记，无法可靠关联进程，只按保留期清扫。
                if (IsTrackedOwnerAlive(directory, isProcessAlive)) continue;
                TryDeleteDirectoryTree(directory);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Trace.WriteLine($"TempCleanup: skipping directory {directory.FullName}: {error.Message}");
            }
        }
    }

    internal static void SweepExpiredAnalyticsCache(
        string cacheDirectory,
        DateTime utcNow,
        TimeSpan retention,
        Func<int, long, bool>? isProcessAlive = null)
    {
        if (string.IsNullOrWhiteSpace(cacheDirectory) || !Directory.Exists(cacheDirectory)) return;
        if (UsageAnalytics.IsCacheInUse(cacheDirectory)) return;

        DirectoryInfo root;
        try { root = new DirectoryInfo(cacheDirectory); }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return; }
        try
        {
            if (IsReparsePoint(root)) return;
            if (IsTrackedOwnerAlive(root, isProcessAlive)) return;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Trace.WriteLine($"TempCleanup: skipping cache {cacheDirectory}: {error.Message}");
            return;
        }

        TryDeleteFileIfOrdinary(Path.Combine(cacheDirectory, OwnerMarkerFileName));
        PruneExpiredChildren(root, utcNow, retention, depth: 0);
    }

    internal static void ClearAnalyticsCache(string cacheDirectory, Func<int, long, bool>? isProcessAlive = null)
    {
        if (string.IsNullOrWhiteSpace(cacheDirectory) || !Directory.Exists(cacheDirectory)) return;
        if (UsageAnalytics.IsCacheInUse(cacheDirectory)) return;

        DirectoryInfo root;
        try { root = new DirectoryInfo(cacheDirectory); }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return; }
        if (IsReparsePoint(root)) return;
        if (IsTrackedOwnerAlive(root, isProcessAlive)) return;

        try
        {
            foreach (var entry in root.EnumerateFileSystemInfos())
            {
                try
                {
                    var attributes = entry.Attributes;
                    if (attributes == (FileAttributes)(-1)) continue;
                    if ((attributes & FileAttributes.ReparsePoint) != 0 || entry.LinkTarget != null) continue;
                    if (entry is DirectoryInfo subdirectory) TryDeleteDirectoryTree(subdirectory, depth: 1);
                    else if (entry is FileInfo file) { ClearReadOnly(file, attributes); file.Delete(); }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    internal static string CreateExportStagingPath(string destination, string suffix) =>
        Path.Combine(Path.GetDirectoryName(destination)!, ".rawlab-" + Guid.NewGuid().ToString("N") + "." + suffix);

    // 仅匹配单张导出自己的 .rawlab-<32位小写hex>.(jpg|png|dng)，排除用户文件与批量导出的双 GUID 临时文件。
    internal static bool IsExportStagingFileName(string fileName)
    {
        if (string.IsNullOrEmpty(fileName) || !fileName.StartsWith(".rawlab-", StringComparison.Ordinal))
            return false;
        var extension = Path.GetExtension(fileName);
        if (!ExportStagingExtensions.Any(ext => ext.Equals(extension, StringComparison.OrdinalIgnoreCase)))
            return false;
        var stemLength = fileName.Length - ".rawlab-".Length - extension.Length;
        if (stemLength != 32) return false;
        var stem = fileName.AsSpan(".rawlab-".Length, 32);
        foreach (var ch in stem)
        {
            var isLowerHex = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
            if (!isLowerHex) return false;
        }
        return true;
    }

    internal static ExportStagingLease BeginExportStaging(string stagingPath, string leaseDirectory)
    {
        string? leasePath = null;
        try
        {
            var fullStaging = Path.GetFullPath(stagingPath);
            if (IsExportStagingFileName(Path.GetFileName(fullStaging)))
            {
                var identity = CurrentProcessIdentity();
                Directory.CreateDirectory(leaseDirectory);
                if (!IsReparsePoint(new DirectoryInfo(leaseDirectory)))
                {
                    var candidate = Path.Combine(leaseDirectory, Guid.NewGuid().ToString("N") + ".json");
                    var json = JsonSerializer.Serialize(new ExportStagingRecord(fullStaging, identity.ProcessId, identity.StartTicks));
                    File.WriteAllText(candidate, json);
                    leasePath = candidate;
                }
            }
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { }
        return new ExportStagingLease(stagingPath, leasePath);
    }

    internal static void SweepRecordedExportStaging(
        string leaseDirectory,
        DateTime utcNow,
        TimeSpan retention,
        Func<int, long, bool>? isProcessAlive = null,
        Func<string, IEnumerable<FileInfo>>? enumerateFiles = null)
    {
        if (string.IsNullOrWhiteSpace(leaseDirectory) || !Directory.Exists(leaseDirectory)) return;
        DirectoryInfo root;
        try { root = new DirectoryInfo(leaseDirectory); }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return; }
        try { if (IsReparsePoint(root)) return; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Trace.WriteLine($"TempCleanup: skipping lease directory {leaseDirectory}: {error.Message}"); return; }

        var checkAlive = isProcessAlive ?? IsProcessAlive;
        IEnumerable<FileInfo> leases;
        try { leases = enumerateFiles != null ? enumerateFiles(leaseDirectory) : root.EnumerateFiles("*.json"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Trace.WriteLine($"TempCleanup: lease enumeration failed for {leaseDirectory}: {error.Message}"); return; }

        using var enumerator = leases.GetEnumerator();
        while (true)
        {
            FileInfo lease;
            try
            {
                if (!enumerator.MoveNext()) break;
                lease = enumerator.Current;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Trace.WriteLine($"TempCleanup: lease enumeration error in {leaseDirectory}: {error.Message}");
                break;
            }

            try
            {
                if (IsReparsePoint(lease)) continue;
                ExportStagingRecord? record;
                try { record = JsonSerializer.Deserialize<ExportStagingRecord>(File.ReadAllText(lease.FullName)); }
                catch (JsonException)
                {
                    TryDeleteFileIfOrdinary(lease.FullName);
                    continue;
                }
                if (record == null || string.IsNullOrWhiteSpace(record.StagingPath) || !Path.IsPathFullyQualified(record.StagingPath) ||
                    !IsExportStagingFileName(Path.GetFileName(record.StagingPath)))
                {
                    TryDeleteFileIfOrdinary(lease.FullName);
                    continue;
                }
                if (checkAlive(record.ProcessId, record.StartTicks)) continue;

                var parent = Path.GetDirectoryName(record.StagingPath);
                if (string.IsNullOrEmpty(parent) || !Directory.Exists(parent))
                {
                    // 外接盘尚未挂载时保留保留期内的记录以便下次重连清扫；过期后再移除记录本身。
                    if (utcNow - lease.LastWriteTimeUtc >= retention)
                        TryDeleteFileIfOrdinary(lease.FullName);
                    continue;
                }

                if (TryDeleteExportStagingFile(record.StagingPath) || !File.Exists(record.StagingPath))
                    TryDeleteFileIfOrdinary(lease.FullName);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Trace.WriteLine($"TempCleanup: skipping lease file {lease.FullName}: {error.Message}");
            }
        }
    }

    internal static void SweepExpiredExportStagingInDirectory(
        string outputDirectory,
        DateTime utcNow,
        TimeSpan retention,
        string? leaseDirectory = null,
        Func<int, long, bool>? isProcessAlive = null)
    {
        if (string.IsNullOrWhiteSpace(outputDirectory) || !Directory.Exists(outputDirectory)) return;
        DirectoryInfo directory;
        try { directory = new DirectoryInfo(outputDirectory); }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return; }
        if (IsReparsePoint(directory)) return;

        var livePaths = CollectLiveExportStagingPaths(leaseDirectory, isProcessAlive);
        IEnumerable<FileInfo> files;
        try { files = directory.EnumerateFiles(".rawlab-*"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }

        foreach (var file in files)
        {
            try
            {
                if (!IsExportStagingFileName(file.Name)) continue;
                var attributes = file.Attributes;
                if (attributes == (FileAttributes)(-1)) continue;
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || file.LinkTarget != null) continue;
                if (livePaths.Contains(Path.GetFullPath(file.FullName))) continue;
                if (utcNow - file.LastWriteTimeUtc < retention) continue;
                ClearReadOnly(file, attributes);
                file.Delete();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    internal static bool TryDeleteExportStagingFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !IsExportStagingFileName(Path.GetFileName(path))) return false;
        try
        {
            var parent = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(parent) || !Directory.Exists(parent)) return false;
            if (IsReparsePoint(new DirectoryInfo(parent))) return false;
            var file = new FileInfo(path);
            var attributes = file.Attributes;
            if (attributes == (FileAttributes)(-1)) return true;
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || file.LinkTarget != null) return false;
            ClearReadOnly(file, attributes);
            file.Delete();
            return true;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    internal static void WriteOwnerMarker(string directory)
    {
        try
        {
            var dirInfo = new DirectoryInfo(directory);
            if (!dirInfo.Exists || IsReparsePoint(dirInfo)) return;
            var identity = CurrentProcessIdentity();
            var marker = Path.Combine(directory, OwnerMarkerFileName);
            var markerInfo = new FileInfo(marker);
            if (markerInfo.Attributes != (FileAttributes)(-1) && IsReparsePoint(markerInfo)) return;
            File.WriteAllText(
                marker,
                identity.ProcessId.ToString(CultureInfo.InvariantCulture) + "\n" +
                identity.StartTicks.ToString(CultureInfo.InvariantCulture));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    internal static void RemoveOwnerMarker(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory)) return;
        TryDeleteFileIfOrdinary(Path.Combine(directory, OwnerMarkerFileName));
    }

    internal static (int ProcessId, long StartTicks) CurrentProcessIdentity()
    {
        try
        {
            using var current = Process.GetCurrentProcess();
            return (current.Id, current.StartTime.ToUniversalTime().Ticks);
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or PlatformNotSupportedException)
        {
            return (Environment.ProcessId, 0L);
        }
    }

    internal static bool IsTrackedOwnerAlive(DirectoryInfo directory, Func<int, long, bool>? isProcessAlive = null)
    {
        try
        {
            var marker = new FileInfo(Path.Combine(directory.FullName, OwnerMarkerFileName));
            var attributes = marker.Attributes;
            if (attributes == (FileAttributes)(-1)) return false;
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || marker.LinkTarget != null) return false;
            var lines = File.ReadAllText(marker.FullName).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (lines.Length == 0 || !int.TryParse(lines[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid))
                return false;
            var startTicks = lines.Length > 1 && long.TryParse(lines[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
                ? parsed : 0L;
            return (isProcessAlive ?? IsProcessAlive)(pid, startTicks);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    internal static bool IsProcessAlive(int processId, long startTicks)
    {
        if (processId <= 0) return false;
        if (processId == Environment.ProcessId)
        {
            var current = CurrentProcessIdentity();
            return startTicks <= 0 || current.StartTicks <= 0 || current.StartTicks == startTicks;
        }

        Process process;
        try { process = Process.GetProcessById(processId); }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }

        using (process)
        {
            try
            {
                if (process.HasExited) return false;
                if (startTicks > 0)
                    return process.StartTime.ToUniversalTime().Ticks == startTicks;
                return string.Equals(process.ProcessName, "RawLab", StringComparison.OrdinalIgnoreCase);
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            catch (Win32Exception)
            {
                // 无权限读取其它会话进程信息时保守视为仍存活，绝不冒险删除在用目录。
                return true;
            }
            catch (PlatformNotSupportedException)
            {
                return true;
            }
        }
    }

    internal static bool IsReparsePoint(FileSystemInfo info)
    {
        try
        {
            info.Refresh();
            var attributes = info.Attributes;
            if (attributes == (FileAttributes)(-1)) return false;
            return (attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget != null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Trace.WriteLine($"TempCleanup: failed to read reparse point attributes for {info.FullName}: {error.Message}");
            return true;
        }
    }

    internal static void TryDeleteDirectoryTree(DirectoryInfo directory, int depth = 0)
    {
        if (depth > MaxTraversalDepth) return;
        try
        {
            directory.Refresh();
            var dirAttributes = directory.Attributes;
            if (dirAttributes == (FileAttributes)(-1)) return;
            if ((dirAttributes & FileAttributes.ReparsePoint) != 0 || directory.LinkTarget != null)
            {
                // 顶层候选目录若本身是重解析点绝不触碰；子级重解析点只删链接自身，绝不进入目标目录。
                if (depth > 0) directory.Delete(recursive: false);
                return;
            }

            IEnumerable<FileSystemInfo> entries;
            try { entries = directory.EnumerateFileSystemInfos(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return; }

            using var enumerator = entries.GetEnumerator();
            while (true)
            {
                FileSystemInfo entry;
                try
                {
                    if (!enumerator.MoveNext()) break;
                    entry = enumerator.Current;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                {
                    Trace.WriteLine($"TempCleanup: entry enumeration failed in {directory.FullName}: {error.Message}");
                    break;
                }

                try
                {
                    var attributes = entry.Attributes;
                    if (attributes == (FileAttributes)(-1)) continue;
                    if ((attributes & FileAttributes.ReparsePoint) != 0 || entry.LinkTarget != null)
                    {
                        if (entry is DirectoryInfo linkDirectory) linkDirectory.Delete(recursive: false);
                        else entry.Delete();
                        continue;
                    }
                    if (entry is DirectoryInfo subdirectory)
                    {
                        TryDeleteDirectoryTree(subdirectory, depth + 1);
                    }
                    else if (entry is FileInfo file)
                    {
                        ClearReadOnly(file, attributes);
                        file.Delete();
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
            }

            directory.Refresh();
            dirAttributes = directory.Attributes;
            if (dirAttributes == (FileAttributes)(-1)) return;
            ClearReadOnly(directory, dirAttributes);
            directory.Delete(recursive: false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    internal static void TryDeleteFileIfOrdinary(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            var file = new FileInfo(path);
            var attributes = file.Attributes;
            if (attributes == (FileAttributes)(-1)) return;
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || file.LinkTarget != null) return;
            ClearReadOnly(file, attributes);
            file.Delete();
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { }
    }

    private static HashSet<string> CollectLiveExportStagingPaths(string? leaseDirectory, Func<int, long, bool>? isProcessAlive)
    {
        var live = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(leaseDirectory) || !Directory.Exists(leaseDirectory)) return live;
        try
        {
            var root = new DirectoryInfo(leaseDirectory);
            if (IsReparsePoint(root)) return live;
            var checkAlive = isProcessAlive ?? IsProcessAlive;
            foreach (var lease in root.EnumerateFiles("*.json"))
            {
                try
                {
                    if (IsReparsePoint(lease)) continue;
                    var record = JsonSerializer.Deserialize<ExportStagingRecord>(File.ReadAllText(lease.FullName));
                    if (record != null && !string.IsNullOrWhiteSpace(record.StagingPath) &&
                        Path.IsPathFullyQualified(record.StagingPath) &&
                        checkAlive(record.ProcessId, record.StartTicks))
                    {
                        live.Add(Path.GetFullPath(record.StagingPath));
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        return live;
    }

    private static bool TryGetLatestWriteTimeUtc(DirectoryInfo directory, int depth, out DateTime latestWriteUtc)
    {
        latestWriteUtc = default;
        if (depth > MaxTraversalDepth) return false;
        directory.Refresh();
        var dirAttributes = directory.Attributes;
        if (dirAttributes == (FileAttributes)(-1)) return false;
        if ((dirAttributes & FileAttributes.ReparsePoint) != 0 || directory.LinkTarget != null) return false;

        latestWriteUtc = directory.LastWriteTimeUtc;
        foreach (var entry in directory.EnumerateFileSystemInfos())
        {
            var attributes = entry.Attributes;
            if (attributes == (FileAttributes)(-1)) continue;
            if ((attributes & FileAttributes.ReparsePoint) != 0 || entry.LinkTarget != null) continue;
            if (entry is DirectoryInfo subdirectory)
            {
                if (!TryGetLatestWriteTimeUtc(subdirectory, depth + 1, out var childLatest)) return false;
                if (childLatest > latestWriteUtc) latestWriteUtc = childLatest;
            }
            else
            {
                var writeUtc = entry.LastWriteTimeUtc;
                if (writeUtc > latestWriteUtc) latestWriteUtc = writeUtc;
            }
        }
        return true;
    }

    private static bool PruneExpiredChildren(DirectoryInfo directory, DateTime utcNow, TimeSpan retention, int depth)
    {
        if (depth > MaxTraversalDepth) return true;
        IEnumerable<FileSystemInfo> entries;
        try { entries = directory.EnumerateFileSystemInfos(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return true; }

        var hasRemainingEntries = false;
        using var enumerator = entries.GetEnumerator();
        while (true)
        {
            FileSystemInfo entry;
            try
            {
                if (!enumerator.MoveNext()) break;
                entry = enumerator.Current;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Trace.WriteLine($"TempCleanup: entry enumeration failed in {directory.FullName}: {error.Message}");
                hasRemainingEntries = true;
                break;
            }

            try
            {
                var attributes = entry.Attributes;
                if (attributes == (FileAttributes)(-1)) continue;
                if ((attributes & FileAttributes.ReparsePoint) != 0 || entry.LinkTarget != null)
                {
                    hasRemainingEntries = true;
                    continue;
                }
                if (entry is DirectoryInfo subdirectory)
                {
                    // 删除子项会刷新父目录的 LastWriteTimeUtc，故先记录子目录自身原本的最后写入时间。
                    var subLastWriteUtc = subdirectory.LastWriteTimeUtc;
                    var childHasRemaining = PruneExpiredChildren(subdirectory, utcNow, retention, depth + 1);
                    subdirectory.Refresh();
                    var subAttributes = subdirectory.Attributes;
                    if (subAttributes == (FileAttributes)(-1)) continue;
                    if (!childHasRemaining && utcNow - subLastWriteUtc >= retention)
                    {
                        ClearReadOnly(subdirectory, subAttributes);
                        subdirectory.Delete(recursive: false);
                    }
                    else
                    {
                        hasRemainingEntries = true;
                    }
                }
                else if (entry is FileInfo file)
                {
                    if (utcNow - file.LastWriteTimeUtc >= retention)
                    {
                        ClearReadOnly(file, attributes);
                        file.Delete();
                    }
                    else
                    {
                        hasRemainingEntries = true;
                    }
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                hasRemainingEntries = true;
            }
        }
        return hasRemainingEntries;
    }

    private static void ClearReadOnly(FileSystemInfo entry, FileAttributes attributes)
    {
        if ((attributes & FileAttributes.ReadOnly) == 0) return;
        var cleared = attributes & ~FileAttributes.ReadOnly;
        entry.Attributes = cleared == 0 ? FileAttributes.Normal : cleared;
    }
}
