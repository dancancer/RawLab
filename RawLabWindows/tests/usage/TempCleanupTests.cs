using System.Diagnostics;
using System.IO;
using RawLab.Windows;

internal static class TempCleanupTests
{
    public static async Task Run(string root)
    {
        var sandbox = Path.Combine(root, "temp-cleanup");
        Directory.CreateDirectory(sandbox);
        var topLevelLinks = new List<string>();
        try
        {
            ExpiredAndOwnedPrefixRules(Path.Combine(sandbox, "prefixes"));
            ReadOnlyFilesAndDirectoriesAreDeleted(Path.Combine(sandbox, "readonly"));
            ReparsePointsAreNeverFollowed(Path.Combine(sandbox, "reparse"), topLevelLinks);
            OwnerLivenessProtectsRunningInstance(Path.Combine(sandbox, "liveness"));
            await AnalyticsCacheReusesFixedDirectory(Path.Combine(sandbox, "analytics-cache"));
            SingleExportStagingCleanup(Path.Combine(sandbox, "export-staging"));
            StartupSweepNeverThrowsOnFaultyDirectoryStub(Path.Combine(sandbox, "fault-isolation"));
            Console.WriteLine("PASS: Windows temp directory sweep, fixed RUM cache and single-export staging cleanup");
        }
        finally
        {
            foreach (var link in topLevelLinks)
            {
                try
                {
                    var info = new DirectoryInfo(link);
                    if (info.Attributes != (FileAttributes)(-1)) info.Delete(recursive: false);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
            try
            {
                if (Directory.Exists(sandbox))
                    TempCleanup.TryDeleteDirectoryTree(new DirectoryInfo(sandbox));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private static void ExpiredAndOwnedPrefixRules(string tempRoot)
    {
        Directory.CreateDirectory(tempRoot);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(30);
        var recent = now - TimeSpan.FromHours(2);

        var expiredPreview = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-0123456789abcdef0123456789abcdef", "source.ARW", expired);
        var expiredRum = CreateDirectoryWithFile(tempRoot, "rawlab-rum-0123456789abcdef0123456789abcdef", "envelope.bin", expired);
        var expiredVerify = CreateDirectoryWithFile(tempRoot, "rawlab-update-verify-0123456789abcdef0123456789abcdef", "RawLab.exe", expired);
        var freshPreview = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-fedcba9876543210fedcba9876543210", "source.ARW", recent);

        // 顶层目录最后写入时间已过期，但子目录内文件仍在保留期内：必须保留。
        var nestedFresh = Path.Combine(tempRoot, "RawLab-LUT-preview-nestedfresh000000000000000000");
        var nestedSub = Path.Combine(nestedFresh, "sub");
        Directory.CreateDirectory(nestedSub);
        var nestedFile = Path.Combine(nestedSub, "active.cube");
        File.WriteAllText(nestedFile, "cube");
        File.SetLastWriteTimeUtc(nestedFile, recent);
        Directory.SetLastWriteTimeUtc(nestedSub, recent);
        Directory.SetLastWriteTimeUtc(nestedFresh, expired);

        var foreignApp = CreateDirectoryWithFile(tempRoot, "OtherApp-temp-expired", "data.bin", expired);
        var manualZipExtract = CreateDirectoryWithFile(tempRoot, "RawLab-Windows-0.10.0-x64", "RawLab.exe", expired);
        var prefixOnly = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-", "orphan.bin", expired);
        var matchingFile = Path.Combine(tempRoot, "RawLab-LUT-preview-not-a-dir");
        File.WriteAllText(matchingFile, "file");
        File.SetLastWriteTimeUtc(matchingFile, expired);

        TempCleanup.SweepTempDirectories(tempRoot, now, TempCleanup.DefaultRetention);

        Check(!Directory.Exists(expiredPreview) && !Directory.Exists(expiredRum) && !Directory.Exists(expiredVerify),
            "expired owned temporary directories are removed");
        Check(Directory.Exists(freshPreview) && Directory.Exists(nestedFresh),
            "owned temporary directories within retention stay untouched");
        Check(Directory.Exists(foreignApp) && Directory.Exists(manualZipExtract) && Directory.Exists(prefixOnly) && File.Exists(matchingFile),
            "non-owned prefixes, manual package folders and top-level files stay untouched");
    }

    private static void ReadOnlyFilesAndDirectoriesAreDeleted(string tempRoot)
    {
        Directory.CreateDirectory(tempRoot);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(36);

        var preview = Path.Combine(tempRoot, "RawLab-LUT-preview-readonly0123456789abcdef012345");
        var nested = Path.Combine(preview, "nested");
        Directory.CreateDirectory(nested);
        var source = Path.Combine(preview, "source.ARW");
        var look = Path.Combine(nested, "look.cube");
        File.WriteAllText(source, "protected-raw");
        File.WriteAllText(look, "protected-lut");
        SetTreeLastWriteTimeUtc(preview, expired);

        File.SetAttributes(source, File.GetAttributes(source) | FileAttributes.ReadOnly);
        File.SetAttributes(look, File.GetAttributes(look) | FileAttributes.ReadOnly);
        File.SetAttributes(nested, File.GetAttributes(nested) | FileAttributes.ReadOnly);
        File.SetAttributes(preview, File.GetAttributes(preview) | FileAttributes.ReadOnly);

        TempCleanup.SweepTempDirectories(tempRoot, now, TempCleanup.DefaultRetention);

        Check(!Directory.Exists(preview),
            "expired owned temporary directories with read-only files and directories are removed");
    }

    private static void ReparsePointsAreNeverFollowed(string sandbox, List<string> topLevelLinks)
    {
        var tempRoot = Path.Combine(sandbox, "temp");
        var outside = Path.Combine(sandbox, "outside-user-data");
        Directory.CreateDirectory(tempRoot);
        Directory.CreateDirectory(outside);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(48);

        var precious = Path.Combine(outside, "precious.ARW");
        File.WriteAllText(precious, "never-delete");
        SetTreeLastWriteTimeUtc(outside, expired);
        File.SetAttributes(precious, File.GetAttributes(precious) | FileAttributes.ReadOnly);

        var topLink = Path.Combine(tempRoot, "RawLab-LUT-preview-toplink0000000000000000000");
        Check(TryCreateDirectoryLink(topLink, outside), "created top-level directory link/junction");
        topLevelLinks.Add(topLink);

        var container = Path.Combine(tempRoot, "RawLab-LUT-preview-nestedlink0000000000000000");
        Directory.CreateDirectory(container);
        var localCopy = Path.Combine(container, "source.ARW");
        File.WriteAllText(localCopy, "temp-copy");
        var nestedLink = Path.Combine(container, "linked-folder");
        Check(TryCreateDirectoryLink(nestedLink, outside), "created nested directory link/junction");
        File.SetLastWriteTimeUtc(localCopy, expired);
        Directory.SetLastWriteTimeUtc(container, expired);

        TempCleanup.SweepTempDirectories(tempRoot, now, TempCleanup.DefaultRetention);

        Check(!Directory.Exists(container), "expired owned directory containing a nested junction is removed");
        Check(File.Exists(precious) && File.ReadAllText(precious) == "never-delete" &&
              (File.GetAttributes(precious) & FileAttributes.ReadOnly) != 0,
            "reparse points are never traversed and target read-only files remain untouched");
    }

    private static void OwnerLivenessProtectsRunningInstance(string tempRoot)
    {
        Directory.CreateDirectory(tempRoot);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(48);

        var liveDir = Path.Combine(tempRoot, "RawLab-LUT-preview-liveowner00000000000000000");
        Directory.CreateDirectory(liveDir);
        File.WriteAllText(Path.Combine(liveDir, "source.ARW"), "in-use");
        TempCleanup.WriteOwnerMarker(liveDir);
        SetTreeLastWriteTimeUtc(liveDir, expired);

        var deadDir = Path.Combine(tempRoot, "RawLab-LUT-preview-deadowner00000000000000000");
        Directory.CreateDirectory(deadDir);
        File.WriteAllText(Path.Combine(deadDir, "source.ARW"), "abandoned");
        File.WriteAllText(Path.Combine(deadDir, TempCleanup.OwnerMarkerFileName), "99999999\n123456789");
        SetTreeLastWriteTimeUtc(deadDir, expired);

        var recycledDir = Path.Combine(tempRoot, "RawLab-LUT-preview-recycled000000000000000000");
        Directory.CreateDirectory(recycledDir);
        File.WriteAllText(Path.Combine(recycledDir, "source.ARW"), "recycled-pid");
        var current = TempCleanup.CurrentProcessIdentity();
        File.WriteAllText(Path.Combine(recycledDir, TempCleanup.OwnerMarkerFileName), $"{current.ProcessId}\n1");
        SetTreeLastWriteTimeUtc(recycledDir, expired);

        TempCleanup.SweepTempDirectories(
            tempRoot,
            now,
            TempCleanup.DefaultRetention,
            (pid, ticks) => pid == current.ProcessId && ticks == current.StartTicks);

        Check(Directory.Exists(liveDir) && File.Exists(Path.Combine(liveDir, "source.ARW")),
            "another live instance's temporary directory survives even past retention");
        Check(!Directory.Exists(deadDir) && !Directory.Exists(recycledDir),
            "expired temporary directories from dead or recycled PIDs are removed");

        // 也验证默认的真实操作系统进程检查路径：当前进程存活保留，不存在的 PID 删除。
        var realDead = Path.Combine(tempRoot, "RawLab-LUT-preview-realdead000000000000000000");
        Directory.CreateDirectory(realDead);
        File.WriteAllText(Path.Combine(realDead, TempCleanup.OwnerMarkerFileName), "-1\n1");
        SetTreeLastWriteTimeUtc(realDead, expired);
        TempCleanup.SweepTempDirectories(tempRoot, now, TempCleanup.DefaultRetention);
        Check(Directory.Exists(liveDir) && !Directory.Exists(realDead),
            "default OS process liveness keeps current process directory and deletes invalid/dead owner");
    }

    private static async Task AnalyticsCacheReusesFixedDirectory(string workDir)
    {
        Directory.CreateDirectory(workDir);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(30);
        var recent = now - TimeSpan.FromHours(1);
        var settingsPath = Path.Combine(workDir, "usage.json");
        var expectedCache = UsageAnalytics.CacheDirectoryFor(settingsPath);
        Check(RumConfiguration.TryProduction(new Dictionary<string, string>(), "0.10.0", out var config) && config != null,
            "production RUM configuration builds for transport test");

        var native1 = new FakeRumNative();
        string recentFile;
        string expiredFile;
        await using (var first = new UsageAnalytics(settingsPath, new RumUsageAnalyticsTransport(config!, null, native1)))
        {
            Check(first.CacheDirectory == expectedCache, "UsageAnalytics exposes deterministic fixed cache directory");
            await first.RecordAsync(new AppStartedEvent());
            Check(first.IsActive && native1.CachePaths.SequenceEqual([expectedCache]),
                "first launch passes fixed cache directory to RUM SDK");

            var sdkStore = Path.Combine(expectedCache, ".alibabacloud_rum");
            var oldRun = Path.Combine(sdkStore, "run-expired");
            var recentRun = Path.Combine(sdkStore, "run-recent");
            Directory.CreateDirectory(oldRun);
            Directory.CreateDirectory(recentRun);
            expiredFile = Path.Combine(oldRun, "failed.bin");
            recentFile = Path.Combine(recentRun, "unsent.bin");
            File.WriteAllText(expiredFile, "stale");
            File.WriteAllText(recentFile, "retry-next-launch");
            SetTreeLastWriteTimeUtc(oldRun, expired);
            File.SetAttributes(expiredFile, File.GetAttributes(expiredFile) | FileAttributes.ReadOnly);
            File.SetLastWriteTimeUtc(recentFile, recent);
            Directory.SetLastWriteTimeUtc(recentRun, recent);
            Directory.SetLastWriteTimeUtc(sdkStore, expired);

            // SDK 正在使用时，启动清扫绝不能删除正在使用的缓存目录内容。
            TempCleanup.SweepStartup(
                Path.Combine(workDir, "empty-temp"),
                expectedCache,
                Path.Combine(workDir, "empty-staging"),
                now,
                TempCleanup.DefaultRetention);
            Check(File.Exists(expiredFile) && File.Exists(recentFile),
                "startup sweep never touches an analytics cache directory currently in use");
        }

        Check(Directory.Exists(expectedCache) && File.Exists(recentFile),
            "normal SDK stop retains the fixed cache directory and recent unsent cache");

        // 第二次启动：先跑启动清扫，再启动新的 transport，验证复用同一固定目录且只清掉过期残留。
        TempCleanup.SweepStartup(
            Path.Combine(workDir, "empty-temp"),
            expectedCache,
            Path.Combine(workDir, "empty-staging"),
            now,
            TempCleanup.DefaultRetention);
        Check(!File.Exists(expiredFile) && !Directory.Exists(Path.GetDirectoryName(expiredFile)!) && File.Exists(recentFile),
            "startup sweep removes expired failed-send cache entries while keeping recent unsent cache");

        var native2 = new FakeRumNative();
        await using (var second = new UsageAnalytics(settingsPath, new RumUsageAnalyticsTransport(config!, null, native2)))
        {
            await second.RecordAsync(new AppStartedEvent());
            Check(second.IsActive && native2.CachePaths.SequenceEqual([expectedCache]) && File.Exists(recentFile),
                "subsequent launch reuses the exact same fixed cache directory instead of creating a new temp folder");

            Check(await second.SetConsentAsync(false), "turning analytics off stops the RUM transport");
            Check(Directory.Exists(expectedCache) && !File.Exists(recentFile),
                "withdrawing consent clears unsent cached events inside the fixed cache directory");
        }
    }

    private static void SingleExportStagingCleanup(string workDir)
    {
        var outputDir = Path.Combine(workDir, "user-exports");
        var leaseDir = Path.Combine(workDir, "leases");
        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(leaseDir);
        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(30);
        var recent = now - TimeSpan.FromMinutes(10);

        var userRaw = Path.Combine(outputDir, "DSC00001.ARW");
        var userJpg = Path.Combine(outputDir, "DSC00001-Provia.jpg");
        var userDotFile = Path.Combine(outputDir, ".rawlab-notes.jpg");
        var batchTemp = Path.Combine(outputDir, $".rawlab-{Guid.NewGuid():D}-{Guid.NewGuid():D}.jpg");
        foreach (var protectedFile in new[] { userRaw, userJpg, userDotFile, batchTemp })
        {
            File.WriteAllText(protectedFile, "keep");
            File.SetLastWriteTimeUtc(protectedFile, expired);
        }

        // 1) 上一进程被杀留下的单张导出 staging 文件（通过死亡进程 lease 记录在下次启动立即清理）
        var crashedTemp = TempCleanup.CreateExportStagingPath(Path.Combine(outputDir, "out.jpg"), "jpg");
        File.WriteAllText(crashedTemp, "partial-jpeg");
        File.SetLastWriteTimeUtc(crashedTemp, recent);
        File.SetAttributes(crashedTemp, File.GetAttributes(crashedTemp) | FileAttributes.ReadOnly);
        File.WriteAllText(
            Path.Combine(leaseDir, "dead.json"),
            $"{{\"StagingPath\":{System.Text.Json.JsonSerializer.Serialize(Path.GetFullPath(crashedTemp))},\"ProcessId\":-1,\"StartTicks\":1}}");

        // 2) 被篡改指向用户文件的异常 lease：必须拒绝删除用户文件并清理坏记录
        var tamperedLease = Path.Combine(leaseDir, "tampered.json");
        File.WriteAllText(
            tamperedLease,
            $"{{\"StagingPath\":{System.Text.Json.JsonSerializer.Serialize(Path.GetFullPath(userJpg))},\"ProcessId\":-1,\"StartTicks\":1}}");

        // 3) 正在运行实例持有的单张导出 staging 文件：必须保留，释放后自动清理
        var liveTemp = TempCleanup.CreateExportStagingPath(Path.Combine(outputDir, "live.png"), "png");
        File.WriteAllText(liveTemp, "in-progress-png");
        var liveLease = TempCleanup.BeginExportStaging(liveTemp, leaseDir);

        // 4) 旧版本未写 lease 的残留：仅清超过保留期的 .rawlab-<32hex>.<ext>，保留未过期的
        var legacyExpired = TempCleanup.CreateExportStagingPath(Path.Combine(outputDir, "old.dng"), "dng");
        File.WriteAllText(legacyExpired, "old-dng");
        File.SetLastWriteTimeUtc(legacyExpired, expired);
        File.SetAttributes(legacyExpired, File.GetAttributes(legacyExpired) | FileAttributes.ReadOnly);

        var legacyFresh = TempCleanup.CreateExportStagingPath(Path.Combine(outputDir, "fresh.jpg"), "jpg");
        File.WriteAllText(legacyFresh, "fresh-jpg");
        File.SetLastWriteTimeUtc(legacyFresh, recent);

        TempCleanup.SweepRecordedExportStaging(leaseDir, now, TempCleanup.DefaultRetention);
        TempCleanup.SweepExpiredExportStagingInDirectory(outputDir, now, TempCleanup.DefaultRetention, leaseDir);

        Check(!File.Exists(crashedTemp) && !File.Exists(legacyExpired) && !File.Exists(tamperedLease),
            "crashed and expired single-export staging files are removed");
        Check(File.Exists(liveTemp) && File.Exists(legacyFresh),
            "active and fresh single-export staging files are preserved");
        Check(File.Exists(userRaw) && File.Exists(userJpg) && File.Exists(userDotFile) && File.Exists(batchTemp),
            "user files and batch-export staging files in the output directory are never deleted");

        liveLease.Dispose();
        Check(!File.Exists(liveTemp), "disposing active single-export staging lease cleans its temporary file");
    }

    private static void StartupSweepNeverThrowsOnFaultyDirectoryStub(string sandbox)
    {
        var tempRoot = Path.Combine(sandbox, "failing-temp");
        var analyticsDir = Path.Combine(sandbox, "failing-analytics");
        var stagingDir = Path.Combine(sandbox, "failing-staging");
        Directory.CreateDirectory(tempRoot);
        Directory.CreateDirectory(analyticsDir);
        Directory.CreateDirectory(stagingDir);

        var now = DateTime.UtcNow;
        var expired = now - TimeSpan.FromHours(30);

        // 内层逐目录隔离：不经外层兜底直接调用 SweepTempDirectories——枚举器依次给出
        // [已过期目录, 坏重解析点目录, 已过期目录]，随后 MoveNext 抛异常。
        var firstGood = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-first00000000000000000000", "source.ARW", expired);
        var badTarget = Path.Combine(sandbox, "badlink-target");
        Directory.CreateDirectory(badTarget);
        File.WriteAllText(Path.Combine(badTarget, "precious.bin"), "keep");
        var badLink = Path.Combine(tempRoot, "RawLab-LUT-preview-badlink0000000000000000000");
        Check(TryCreateDirectoryLink(badLink, badTarget), "created faulty reparse-point directory for sweep isolation");
        var secondGood = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-second000000000000000000", "source.ARW", expired);

        IEnumerable<DirectoryInfo> IsolatedDirectoryEnumerator(string _)
        {
            yield return new DirectoryInfo(firstGood);
            yield return new DirectoryInfo(badLink);
            yield return new DirectoryInfo(secondGood);
            throw new IOException("Simulated directory enumeration failure after the isolation samples");
        }

        TempCleanup.SweepTempDirectories(tempRoot, now, TempCleanup.DefaultRetention, enumerateDirectories: IsolatedDirectoryEnumerator);
        Check(!Directory.Exists(firstGood) && !Directory.Exists(secondGood),
            "expired owned directories on both sides of a faulty entry are swept by the inner per-directory isolation");
        Check(Directory.Exists(badLink) && File.Exists(Path.Combine(badTarget, "precious.bin")),
            "the faulty reparse-point directory is skipped without following it into its target");

        // 外层兜底 + 不回滚已完成的清扫：MoveNext 中途抛 UnauthorizedAccessException 的桩
        // 经 SweepStartup 永不外抛，且异常前已处理的过期目录确实被删除。
        var survivor = CreateDirectoryWithFile(tempRoot, "RawLab-LUT-preview-survivor0000000000000000", "source.ARW", expired);
        IEnumerable<DirectoryInfo> FaultyDirectoryEnumerator(string _)
        {
            yield return new DirectoryInfo(survivor);
            throw new UnauthorizedAccessException("Simulated directory enumeration access denied");
        }

        IEnumerable<FileInfo> FaultyFileEnumerator(string _)
        {
            yield return new FileInfo(Path.Combine(stagingDir, "stub.json"));
            throw new IOException("Simulated disk I/O failure during lease enumeration");
        }

        TempCleanup.SweepStartup(
            tempRoot,
            analyticsDir,
            stagingDir,
            now,
            TempCleanup.DefaultRetention,
            enumerateDirectories: FaultyDirectoryEnumerator,
            enumerateFiles: FaultyFileEnumerator);
        Check(!Directory.Exists(survivor), "startup sweep keeps work completed before a mid-enumeration failure");

        // 致命异常必须穿透外层兜底原样外抛，而不是被静默吞掉。
        var oomEscaped = false;
        try
        {
            TempCleanup.SweepStartup(tempRoot, analyticsDir, stagingDir, now, TempCleanup.DefaultRetention,
                enumerateDirectories: static _ => throw new OutOfMemoryException("Simulated fatal memory failure"));
        }
        catch (OutOfMemoryException) { oomEscaped = true; }
        Check(oomEscaped, "startup sweep lets OutOfMemoryException escape instead of swallowing it");
    }

    private static string CreateDirectoryWithFile(string parent, string dirName, string fileName, DateTime writeUtc)
    {
        var dir = Path.Combine(parent, dirName);
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, fileName);
        File.WriteAllText(file, "fixture");
        SetTreeLastWriteTimeUtc(dir, writeUtc);
        return dir;
    }

    private static void SetTreeLastWriteTimeUtc(string directory, DateTime writeUtc)
    {
        foreach (var file in Directory.GetFiles(directory))
            File.SetLastWriteTimeUtc(file, writeUtc);
        foreach (var sub in Directory.GetDirectories(directory))
            SetTreeLastWriteTimeUtc(sub, writeUtc);
        Directory.SetLastWriteTimeUtc(directory, writeUtc);
    }

    private static bool TryCreateDirectoryLink(string linkPath, string targetPath)
    {
        try
        {
            Directory.CreateSymbolicLink(linkPath, targetPath);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (!OperatingSystem.IsWindows()) return false;
            using var mklink = Process.Start(new ProcessStartInfo("cmd.exe")
            {
                Arguments = $"/d /s /c \"mklink /J \"{linkPath}\" \"{targetPath}\"\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            if (mklink == null) return false;
            mklink.WaitForExit(5000);
            return mklink.ExitCode == 0 && new DirectoryInfo(linkPath).Attributes != (FileAttributes)(-1);
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }

    private sealed class FakeRumNative : IRumNative
    {
        public List<string> CachePaths { get; } = [];
        public int InitResult { get; set; }
        public int CloseResult { get; set; }

        public IntPtr OptionsNew() => (IntPtr)1;
        public void OptionsFree(IntPtr options) { }
        public void SetConfigAddress(IntPtr options, string configAddress) { }
        public void SetAppId(IntPtr options, string appId) { }
        public void SetAppName(IntPtr options, string appName) { }
        public void SetAppVersion(IntPtr options, string appVersion) { }
        public void SetEnv(IntPtr options, int env) { }
        public void SetUtdid(IntPtr options, string utdid) { }
        public void SetDebugLevel(IntPtr options, int level) { }
        public void SetCachePath(IntPtr options, string path) => CachePaths.Add(path);
        public void SetAutoCrashTracking(IntPtr options, int enabled) { }
        public void SetAutoCurlTracking(IntPtr options, int enabled) { }
        public void SetAutoCefTracking(IntPtr options, int enabled) { }
        public int Init(IntPtr options) => InitResult;
        public int Close() => CloseResult;
        public IntPtr CustomEventNew(string type, string name) => (IntPtr)2;
        public void CustomEventSetValue(IntPtr nativeEvent, double value) { }
        public void CustomEventSetGroup(IntPtr nativeEvent, string group) { }
        public void CustomEventAddExtra(IntPtr nativeEvent, string key, string value) { }
        public void CustomEventFree(IntPtr nativeEvent) { }
        public void CustomEventReport(IntPtr nativeEvent) { }
    }
}
