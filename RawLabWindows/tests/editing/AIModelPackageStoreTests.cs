using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
public sealed class AIModelPackageStoreTests : IDisposable
{
    private readonly string tempRoot;

    public AIModelPackageStoreTests()
    {
        tempRoot = Path.Combine(Path.GetTempPath(), "rlaim-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(tempRoot);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(tempRoot))
                TempCleanup.TryDeleteDirectoryTree(new DirectoryInfo(tempRoot));
        }
        catch (Exception) { }
    }

    // MARK: - Catalog & HTTPS-Only

    [Fact]
    public void ShippedCatalogLoadsAndValidatesBothPlatforms()
    {
        var repoRoot = LocateRepoRoot();
        var catalogPath = Path.Combine(repoRoot, "Shared", "ai-models", "catalog.json");
        var catalog = AIModelCatalog.Load(catalogPath);
        Assert.Equal(1, catalog.SchemaVersion);

        var win = catalog.DescriptorFor(AIModelCatalog.WindowsX64Platform);
        Assert.Equal("rawlab-ai-windows-x64-86fb75845dc5.tar.gz", win.ArchiveName);
        Assert.Equal("https://github.com/dancancer/RawLab/releases/download/assets-v1/rawlab-ai-windows-x64-86fb75845dc5.tar.gz", win.Url);
        Assert.Equal(294_125_075UL, win.ArchiveBytes);
        Assert.Equal(333_603_381UL, win.UnpackedBytes);
        Assert.Equal("86fb75845dc5f270c3aac4d53d2c75413eba5049ecdc87e11c09e3f068291748", win.ArchiveSha256);
        Assert.Equal("7bfabad6667ee02aad9722493b2cec9dd9dc0d2db3f8fef5b86e8432fbd6e890", win.ManifestSha256);
        Assert.Equal(7, win.Entries.Count);

        var mac = catalog.DescriptorFor(AIModelCatalog.MacOSArm64Platform);
        Assert.Equal("rawlab-ai-macos-arm64-049e6acf5d19.tar.gz", mac.ArchiveName);
        Assert.Equal(588_218_971UL, mac.ArchiveBytes);
        Assert.Equal(652_138_326UL, mac.UnpackedBytes);
        Assert.Equal(28, mac.Entries.Count);

        // Bundled copy next to the built app/test output also loads and validates cleanly
        var bundled = AIModelCatalog.BundledDescriptor(AIModelCatalog.WindowsX64Platform);
        Assert.NotNull(bundled);
        Assert.Equal(win.ArchiveSha256, bundled!.ArchiveSha256);
    }

    [Fact]
    public void HttpsOnlyEnforcementRejectsInsecureUrls()
    {
        var fixture = MakeSyntheticArchive("https-check");
        var loopbackDesc = fixture.Descriptor("http://127.0.0.1:8080/model.tar.gz");
        var ex1 = Assert.Throws<AIModelPackageException>(() => loopbackDesc.ValidateDownloadUri(allowLoopbackHttp: false));
        Assert.Equal(AIModelPackageErrorCode.InsecureUrl, ex1.Code);
        _ = loopbackDesc.ValidateDownloadUri(allowLoopbackHttp: true);

        var remoteHttp = fixture.Descriptor("http://example.com/model.tar.gz");
        var ex2 = Assert.Throws<AIModelPackageException>(() => remoteHttp.ValidateDownloadUri(allowLoopbackHttp: true));
        Assert.Equal(AIModelPackageErrorCode.InsecureUrl, ex2.Code);

        var fileUrl = fixture.Descriptor("file:///C:/temp/model.tar.gz");
        var ex3 = Assert.Throws<AIModelPackageException>(() => fileUrl.ValidateDownloadUri(allowLoopbackHttp: true));
        Assert.Equal(AIModelPackageErrorCode.InsecureUrl, ex3.Code);
    }

    // MARK: - Download, Install, Restart, Upgrade, Remove, Resolution Order, Stale Cleanup

    [Fact]
    public async Task DownloadInstallRestartAndRemoveWork()
    {
        var fixture = MakeSyntheticArchive("valid-v1");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store");
        var desc = fixture.Descriptor(server.Url("/" + fixture.ArchiveName));
        var store = new AIModelPackageStore(
            storage,
            desc,
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        Assert.Null(store.InstalledPackageDirectory());

        var phases = new List<AIModelInstallPhaseKind>();
        var phasesGate = new object();
        var installed = await store.DownloadAndInstallAsync(onProgress: phase =>
        {
            lock (phasesGate) phases.Add(phase.Kind);
        });

        Assert.Equal(Path.GetFullPath(Path.Combine(storage, desc.ManifestSha256)), Path.GetFullPath(installed));
        Assert.Contains(AIModelInstallPhaseKind.Downloading, phases);
        Assert.Contains(AIModelInstallPhaseKind.Verifying, phases);
        Assert.Contains(AIModelInstallPhaseKind.Installing, phases);
        Assert.Equal(Path.GetFullPath(installed), Path.GetFullPath(store.InstalledPackageDirectory()!));
        AssertNoStrayTempFiles(storage);

        // Fresh store instance simulates restart and finds installed package without network
        var restarted = new AIModelPackageStore(storage, desc, allowLoopbackHttp: false);
        Assert.Equal(Path.GetFullPath(installed), Path.GetFullPath(restarted.InstalledPackageDirectory()!));

        // Remove installed package
        restarted.RemoveInstalledPackages();
        Assert.Null(restarted.InstalledPackageDirectory());
        Assert.False(Directory.Exists(installed));
    }

    [Fact]
    public async Task StaleCrashTempFilesCleanedUpAtStartOfInstall()
    {
        var fixture = MakeSyntheticArchive("stale-cleanup");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-stale");
        Directory.CreateDirectory(storage);
        var stalePart = Path.Combine(storage, ".download-crashed.part");
        var staleStaging = Path.Combine(storage, ".staging-crashed");
        var staleReplacing = Path.Combine(storage, ".replacing-crashed");
        var staleRemoving = Path.Combine(storage, ".removing-crashed");
        File.WriteAllText(stalePart, "leftover");
        Directory.CreateDirectory(staleStaging);
        File.WriteAllText(Path.Combine(staleStaging, "junk.bin"), "leftover");
        Directory.CreateDirectory(staleReplacing);
        File.WriteAllText(Path.Combine(staleReplacing, "old.bin"), "leftover");
        Directory.CreateDirectory(staleRemoving);
        File.WriteAllText(Path.Combine(staleRemoving, "removing.bin"), "leftover");

        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var installed = await store.DownloadAndInstallAsync();
        Assert.Equal(Path.GetFullPath(installed), Path.GetFullPath(store.InstalledPackageDirectory()!));
        Assert.False(File.Exists(stalePart));
        Assert.False(Directory.Exists(staleStaging));
        Assert.False(Directory.Exists(staleReplacing));
        Assert.False(Directory.Exists(staleRemoving));
        AssertNoStrayTempFiles(storage);
    }

    [Fact]
    public async Task SecondDigestCountsAsNotInstalledAndRemovesOlderAfterInstall()
    {
        var first = MakeSyntheticArchive("v1", manifestExtra: "v1");
        var second = MakeSyntheticArchive("v2", manifestExtra: "v2");
        Assert.NotEqual(first.ManifestSha256, second.ManifestSha256);

        var storage = Path.Combine(tempRoot, "store-upgrade");
        using var server1 = new LoopbackHttpServer(ServerMode.File(first.ArchivePath));
        var store1 = new AIModelPackageStore(
            storage,
            first.Descriptor(server1.Url("/v1.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);
        var dir1 = await store1.DownloadAndInstallAsync();
        Assert.True(Directory.Exists(dir1));

        using var server2 = new LoopbackHttpServer(ServerMode.File(second.ArchivePath));
        var store2 = new AIModelPackageStore(
            storage,
            second.Descriptor(server2.Url("/v2.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);
        Assert.Null(store2.InstalledPackageDirectory());

        var dir2 = await store2.DownloadAndInstallAsync();
        Assert.Equal(Path.GetFullPath(dir2), Path.GetFullPath(store2.InstalledPackageDirectory()!));
        Assert.True(Directory.Exists(dir2));
        Assert.False(Directory.Exists(dir1));
        AssertNoStrayTempFiles(storage);
    }

    [Fact]
    public async Task ResolutionOrderOverrideThenDownloadedThenBundledAndPreviewKeyResolver()
    {
        var fixture = MakeSyntheticArchive("order");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-order");
        var overrideDir = Path.Combine(tempRoot, "override");
        var bundledDir = Path.Combine(tempRoot, "bundled");
        Directory.CreateDirectory(overrideDir);
        Directory.CreateDirectory(bundledDir);
        File.WriteAllText(Path.Combine(bundledDir, "manifest.json"), "{}");

        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        Assert.Equal(new AIModelDirectorySource(AIModelDirectoryKind.Override, Path.GetFullPath(overrideDir)),
            store.ResolveModelDirectory(overrideDir, bundledDir));
        Assert.Equal(new AIModelDirectorySource(AIModelDirectoryKind.Bundled, Path.GetFullPath(bundledDir)),
            store.ResolveModelDirectory(null, bundledDir));
        Assert.Null(store.ResolveModelDirectory(null, null));

        var downloadedDir = await store.DownloadAndInstallAsync();
        Assert.Equal(new AIModelDirectorySource(AIModelDirectoryKind.Override, Path.GetFullPath(overrideDir)),
            store.ResolveModelDirectory(overrideDir, bundledDir));
        Assert.Equal(new AIModelDirectorySource(AIModelDirectoryKind.Downloaded, Path.GetFullPath(downloadedDir)),
            store.ResolveModelDirectory(null, bundledDir));

        // EditedPhotoPreviewKey uses the resolved AI model directory for manifest fingerprinting
        var aiSettings = new Adjustments { AIDenoiseEnabled = true }.Capture();
        var paths = EditedPhotoPreviewKey.ResourcePaths(aiSettings, null, aiModelDirectory: downloadedDir).ToArray();
        Assert.Contains(Path.Combine(downloadedDir, "manifest.json"), paths);

        // Removing downloaded model falls back to bundled and causes reads on vanished dir to fail cleanly
        store.RemoveInstalledPackages();
        Assert.Equal(new AIModelDirectorySource(AIModelDirectoryKind.Bundled, Path.GetFullPath(bundledDir)),
            store.ResolveModelDirectory(null, bundledDir));
        Assert.ThrowsAny<IOException>(() =>
            EditedPhotoPreviewKey.ResourceFingerprint(aiSettings, null, new FileDigestCache(), aiModelDirectory: downloadedDir));
    }

    // MARK: - Archive Size & Digest Rejection Before Any Decompression

    [Fact]
    public async Task WrongArchiveSizeRejectedWithoutParsing()
    {
        var fixture = MakeSyntheticArchive("wrong-size");
        var truncatedPath = Path.Combine(tempRoot, "truncated.bin");
        var original = File.ReadAllBytes(fixture.ArchivePath);
        File.WriteAllBytes(truncatedPath, original[..Math.Max(1, original.Length - 5)]);

        using var server = new LoopbackHttpServer(ServerMode.File(truncatedPath));
        var storage = Path.Combine(tempRoot, "store-size");
        var unpackCalled = false;
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: () => unpackCalled = true);

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.ArchiveSizeMismatch, ex.Code);
        Assert.False(unpackCalled, "Must not decompress or parse when archive size is wrong");
        AssertNothingInstalledOrLeftOver(store, storage);
    }

    [Fact]
    public async Task DeclaredContentLengthMatchingButShortBodyFailsCleanly()
    {
        var fixture = MakeSyntheticArchive("short-body");
        var original = File.ReadAllBytes(fixture.ArchivePath);
        var shortBody = original[..Math.Max(1, original.Length / 2)];

        using var server = new LoopbackHttpServer(ServerMode.Custom((int)fixture.ArchiveBytes, shortBody));
        var storage = Path.Combine(tempRoot, "store-short-body");
        var unpackCalled = false;
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: () => unpackCalled = true);

        await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        Assert.False(unpackCalled, "Must not unpack a short body");
        AssertNothingInstalledOrLeftOver(store, storage);
    }

    [Fact]
    public async Task BodyLongerThanDescribedFailsCleanly()
    {
        var fixture = MakeSyntheticArchive("long-body");
        var original = File.ReadAllBytes(fixture.ArchivePath);
        var longerBody = new byte[original.Length + 256];
        Buffer.BlockCopy(original, 0, longerBody, 0, original.Length);
        Array.Fill(longerBody, (byte)0xEE, original.Length, 256);

        using var server = new LoopbackHttpServer(ServerMode.Custom(null, longerBody));
        var storage = Path.Combine(tempRoot, "store-long-body");
        var unpackCalled = false;
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: () => unpackCalled = true);

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.ArchiveSizeMismatch, ex.Code);
        Assert.False(unpackCalled, "Must not unpack an oversized body");
        AssertNothingInstalledOrLeftOver(store, storage);
    }

    [Fact]
    public async Task WrongArchiveDigestRejectedWithoutParsing()
    {
        var fixture = MakeSyntheticArchive("wrong-digest");
        var garbagePath = Path.Combine(tempRoot, "garbage.bin");
        var garbage = new byte[fixture.ArchiveBytes];
        Array.Fill(garbage, (byte)0x5A);
        File.WriteAllBytes(garbagePath, garbage);

        using var server = new LoopbackHttpServer(ServerMode.File(garbagePath));
        var storage = Path.Combine(tempRoot, "store-digest");
        var unpackCalled = false;
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: () => unpackCalled = true);

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.ArchiveDigestMismatch, ex.Code);
        Assert.False(unpackCalled, "Must not decompress or parse when archive SHA-256 is wrong");
        AssertNothingInstalledOrLeftOver(store, storage);
    }

    // MARK: - Hostile Archives (Catalog Archive Digest Matches the Hostile Archive)

    [Fact]
    public async Task HostileArchivePathTraversalBlocked()
    {
        var parent = Path.Combine(tempRoot, "traversal-parent");
        Directory.CreateDirectory(parent);
        var storage = Path.Combine(parent, "store");
        var escapeOne = Path.Combine(storage, "escaped-traversal.txt");
        var escapeTwo = Path.Combine(parent, "escaped-traversal.txt");

        var hostile = MakeHostileArchive(HostileKind.PathTraversal, "../escaped-traversal.txt");
        await AssertHostileArchiveRejected(hostile, storage);
        Assert.False(File.Exists(escapeOne));
        Assert.False(File.Exists(escapeTwo));
    }

    [Fact]
    public async Task HostileArchiveAbsolutePathBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-abs");
        var absTarget = Path.Combine(tempRoot, "escaped-absolute.txt");
        var hostile = MakeHostileArchive(HostileKind.AbsolutePath, absTarget.Replace('\\', '/'));
        await AssertHostileArchiveRejected(hostile, storage);
        Assert.False(File.Exists(absTarget));
    }

    [Fact]
    public async Task HostileArchiveSymlinkBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-symlink");
        var hostile = MakeHostileArchive(HostileKind.SymlinkAtDescribedPath);
        await AssertHostileArchiveRejected(hostile, storage);
    }

    [Fact]
    public async Task HostileArchiveSymlinkWriteThroughBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-sym-escape");
        var escapeTarget = Path.Combine(tempRoot, "sym-escaped.txt");
        var hostile = MakeHostileArchive(HostileKind.SymlinkWriteThrough, tempRoot.Replace('\\', '/'));
        await AssertHostileArchiveRejected(hostile, storage);
        Assert.False(File.Exists(escapeTarget));
    }

    [Fact]
    public async Task HostileArchiveHardLinkAtDescribedPathBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-hardlink");
        var hostile = MakeHostileArchive(HostileKind.HardLinkAtDescribedPath);
        var ex = await AssertHostileArchiveRejected(hostile, storage);
        Assert.Equal(AIModelPackageErrorCode.MemberVerificationFailed, ex.Code);
        Assert.Contains("hard link", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task HostileArchiveExtraMemberBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-extra");
        var hostile = MakeHostileArchive(HostileKind.ExtraMember);
        await AssertHostileArchiveRejected(hostile, storage);
    }

    [Fact]
    public async Task HostileArchiveWrongMemberSizeBlocked()
    {
        var storage = Path.Combine(tempRoot, "store-wrong-member-size");
        var hostile = MakeHostileArchive(HostileKind.WrongMemberSize);
        await AssertHostileArchiveRejected(hostile, storage);
    }

    [Fact]
    public void StagingTreeVerificationDefenseInDepthRejectsTamperingAndLinks()
    {
        var fixture = MakeSyntheticArchive("defense");
        var desc = fixture.Descriptor("https://example.com/m.tar.gz");

        string MakeCleanStaging()
        {
            var dir = Path.Combine(tempRoot, "staging-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path.Combine(dir, "weights"));
            foreach (var (rel, content) in fixture.FileContents)
                File.WriteAllBytes(Path.Combine(dir, rel.Replace('/', Path.DirectorySeparatorChar)), content);
            return dir;
        }

        var clean = MakeCleanStaging();
        AIModelPackageStore.VerifyAndNormalizeStagingTree(clean, desc, CancellationToken.None);

        var extra = MakeCleanStaging();
        File.WriteAllText(Path.Combine(extra, "extra.txt"), "surprise");
        Assert.Throws<AIModelPackageException>(() =>
            AIModelPackageStore.VerifyAndNormalizeStagingTree(extra, desc, CancellationToken.None));

        var tampered = MakeCleanStaging();
        var manifestPath = Path.Combine(tampered, "manifest.json");
        var bytes = File.ReadAllBytes(manifestPath);
        bytes[0] ^= 0xFF;
        File.WriteAllBytes(manifestPath, bytes);
        Assert.Throws<AIModelPackageException>(() =>
            AIModelPackageStore.VerifyAndNormalizeStagingTree(tampered, desc, CancellationToken.None));

        if (OperatingSystem.IsWindows())
        {
            var hardlinked = MakeCleanStaging();
            var target = Path.Combine(hardlinked, "DualDn-LICENSE.txt");
            var externalLink = Path.Combine(tempRoot, "external-hardlink-" + Guid.NewGuid().ToString("N"));
            Assert.True(CreateHardLinkW(externalLink, target, IntPtr.Zero), "CreateHardLinkW should create a test hard link");
            var hlEx = Assert.Throws<AIModelPackageException>(() =>
                AIModelPackageStore.VerifyAndNormalizeStagingTree(hardlinked, desc, CancellationToken.None));
            Assert.Contains("hard link", hlEx.Message, StringComparison.OrdinalIgnoreCase);

            var reparse = MakeCleanStaging();
            var linkPath = Path.Combine(reparse, "DualDn-LICENSE.txt");
            File.Delete(linkPath);
            var createdReparse = false;
            try
            {
                File.CreateSymbolicLink(linkPath, Path.Combine(reparse, "manifest.json"));
                createdReparse = true;
            }
            catch (UnauthorizedAccessException)
            {
                // Without Developer Mode/admin, use a directory junction at a described directory path
                var weightsDir = Path.Combine(reparse, "weights");
                Directory.Delete(weightsDir, recursive: true);
                var targetDir = Path.Combine(tempRoot, "junction-target-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(targetDir);
                File.WriteAllBytes(Path.Combine(targetDir, "weight.bin"), fixture.FileContents["weights/weight.bin"]);
                var psi = new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{weightsDir}\" \"{targetDir}\"")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                using var proc = Process.Start(psi)!;
                proc.WaitForExit(10_000);
                createdReparse = proc.ExitCode == 0;
            }
            Assert.True(createdReparse, "Should create either a symlink or directory junction for reparse-point check");
            Assert.Throws<AIModelPackageException>(() =>
                AIModelPackageStore.VerifyAndNormalizeStagingTree(reparse, desc, CancellationToken.None));
        }
    }

    // MARK: - Cancel, Disk Space, HTTP 404, Redirect Downgrade, State Machine

    [Fact]
    public async Task CancelMidDownloadLeavesNoPartialOrTempFiles()
    {
        var fixture = MakeSyntheticArchive("cancel", weightBytes: 64 * 1024);
        using var server = new LoopbackHttpServer(ServerMode.StalledFile(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-cancel");
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        using var cts = new CancellationTokenSource();
        using var wroteNonZero = new ManualResetEventSlim();
        ulong maxWritten = 0;

        var task = store.DownloadAndInstallAsync(cts.Token, phase =>
        {
            if (phase.Kind == AIModelInstallPhaseKind.Downloading && phase.CompletedBytes > 0)
            {
                Interlocked.Exchange(ref maxWritten, phase.CompletedBytes);
                wroteNonZero.Set();
            }
        });

        Assert.True(wroteNonZero.Wait(TimeSpan.FromSeconds(10)), "Client should write non-zero bytes before cancel");
        Assert.True(Volatile.Read(ref maxWritten) > 0);
        cts.Cancel();

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => task);
        Assert.Equal(AIModelPackageErrorCode.Cancelled, ex.Code);
        AssertNothingInstalledOrLeftOver(store, storage);
    }

    [Fact]
    public async Task CancelDuringFinalCommitShowsTruthfulInstalledState()
    {
        var fixture = MakeSyntheticArchive("cancel-commit");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-cancel-commit");
        var desc = fixture.Descriptor(server.Url("/m.tar.gz"));

        AIModelPackageManager? manager = null;
        var store = new AIModelPackageStore(
            storage,
            desc,
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            onBeforeCommit: () => manager?.CancelDownload());

        manager = new AIModelPackageManager(store, isRuntimeSupported: () => true);
        var changeCallbacks = 0;
        var settled = new TaskCompletionSource<AIModelPackageState>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.InstallStateChanged += () => Interlocked.Increment(ref changeCallbacks);
        manager.StateChanged += state =>
        {
            if (state.IsDownloadedInstalled) settled.TrySetResult(state);
        };

        manager.StartDownload();
        var finalState = await settled.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.True(finalState.IsDownloadedInstalled);
        Assert.True(manager.State.IsDownloadedInstalled);
        Assert.NotNull(store.InstalledPackageDirectory());
        Assert.Equal(1, Volatile.Read(ref changeCallbacks));
        AssertNoStrayTempFiles(storage);
    }

    [Fact]
    public async Task DiskSpaceRefusalStopsBeforeNetworkRequest()
    {
        var fixture = MakeSyntheticArchive("disk-full");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-disk");
        var store = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server.Url("/m.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024,
            availableSpaceProvider: _ => 100);

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.InsufficientDiskSpace, ex.Code);
        Assert.Equal(0, server.RequestCount);
        Assert.Null(store.InstalledPackageDirectory());
        Assert.False(Directory.Exists(storage));
    }

    [Fact]
    public async Task Http404AndInsecureRedirectHandledCleanly()
    {
        var fixture = MakeSyntheticArchive("http-errors");
        var storage = Path.Combine(tempRoot, "store-http");

        using var server404 = new LoopbackHttpServer(ServerMode.Status(404));
        var store404 = new AIModelPackageStore(
            storage,
            fixture.Descriptor(server404.Url("/missing.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var ex404 = await Assert.ThrowsAsync<AIModelPackageException>(() => store404.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.HttpNotFound, ex404.Code);
        Assert.Contains("404", ex404.Message);
        AssertNoStrayTempFiles(storage);

        using var serverRedirect = new LoopbackHttpServer(ServerMode.Redirect("http://example.com/downgrade.tar.gz"));
        var storeRedirect = new AIModelPackageStore(
            storage,
            fixture.Descriptor(serverRedirect.Url("/redirect.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var exRedirect = await Assert.ThrowsAsync<AIModelPackageException>(() => storeRedirect.DownloadAndInstallAsync());
        Assert.Equal(AIModelPackageErrorCode.InsecureUrl, exRedirect.Code);
        AssertNoStrayTempFiles(storage);
    }

    [Fact]
    public async Task ManagerDoesNotAutoDownloadAndSupportsFailedRetryAndRemove()
    {
        var fixture = MakeSyntheticArchive("manager");
        using var server = new LoopbackHttpServer(ServerMode.Status(503));

        var storage = Path.Combine(tempRoot, "store-manager");
        var desc = fixture.Descriptor(server.Url("/m.tar.gz"));
        var store = new AIModelPackageStore(
            storage,
            desc,
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var manager = new AIModelPackageManager(store, isRuntimeSupported: () => true);
        Assert.Equal(AIModelPackageState.NotInstalled(desc.ArchiveBytes, desc.UnpackedBytes), manager.State);
        Assert.Equal(0, server.RequestCount);

        var changeCallbacks = 0;
        manager.InstallStateChanged += () => Interlocked.Increment(ref changeCallbacks);

        var failedTcs = new TaskCompletionSource<AIModelPackageState>(TaskCreationOptions.RunContinuationsAsynchronously);
        var installedTcs = new TaskCompletionSource<AIModelPackageState>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.StateChanged += state =>
        {
            if (state.Status == AIModelPackageStatus.Failed) failedTcs.TrySetResult(state);
            else if (state.IsDownloadedInstalled) installedTcs.TrySetResult(state);
        };

        // First attempt returns 503 -> Failed
        manager.StartDownload();
        var failedState = await failedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(AIModelPackageStatus.Failed, failedState.Status);
        Assert.Equal(AIModelPackageErrorCode.HttpStatus, failedState.Error?.Code);
        Assert.Equal(503, failedState.Error?.HttpStatusCode);
        Assert.Equal(1, server.RequestCount);
        Assert.Equal(0, Volatile.Read(ref changeCallbacks));
        AssertNoStrayTempFiles(storage);

        // Retry after server recovers -> Installed
        server.SetMode(ServerMode.File(fixture.ArchivePath));
        manager.StartDownload();
        var installedState = await installedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(installedState.IsDownloadedInstalled);
        Assert.Equal(2, server.RequestCount);
        Assert.Equal(1, Volatile.Read(ref changeCallbacks));

        // Remove -> NotInstalled
        manager.RemoveDownloadedModel();
        Assert.Equal(AIModelPackageState.NotInstalled(desc.ArchiveBytes, desc.UnpackedBytes), manager.State);
        Assert.Equal(2, Volatile.Read(ref changeCallbacks));

        // Non-AI runtime stays Unavailable
        var unsupported = new AIModelPackageManager(store, isRuntimeSupported: () => false);
        Assert.Equal(AIModelPackageStatus.Unavailable, unsupported.State.Status);
    }

    [Fact]
    public async Task HardwareUnavailableHidesDownloadRefusesStartDownloadAndAllowsRemovingInstalled()
    {
        var fixture = MakeSyntheticArchive("hw-gate");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-hw-gate");
        var desc = fixture.Descriptor(server.Url("/hw.tar.gz"));
        var store = new AIModelPackageStore(
            storage,
            desc,
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        // 1. Hardware unavailable from launch: manager reports Unavailable (download hidden) and direct StartDownload sends 0 requests.
        var hardwareAvailable = false;
        var manager = new AIModelPackageManager(
            store,
            isRuntimeSupported: () => true,
            isHardwareAvailable: () => hardwareAvailable);
        Assert.Equal(AIModelPackageStatus.Unavailable, manager.State.Status);
        manager.StartDownload();
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(AIModelPackageStatus.Unavailable, manager.State.Status);
        Assert.Equal(0, server.RequestCount);

        // 2. Hardware flips from available (NotInstalled) to unavailable before click: direct StartDownload refuses with 0 requests and transitions to Unavailable.
        hardwareAvailable = true;
        manager.Refresh();
        Assert.Equal(AIModelPackageStatus.NotInstalled, manager.State.Status);
        hardwareAvailable = false;
        manager.StartDownload();
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(AIModelPackageStatus.Unavailable, manager.State.Status);
        Assert.Equal(0, server.RequestCount);

        // 3. Install while hardware is available, then lose GPU: installed models remain visible/removable; once removed, state returns to Unavailable and StartDownload still refuses.
        hardwareAvailable = true;
        manager.Refresh();
        var installedTcs = new TaskCompletionSource<AIModelPackageState>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.StateChanged += state =>
        {
            if (state.IsDownloadedInstalled) installedTcs.TrySetResult(state);
        };
        manager.StartDownload();
        var installed = await installedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(installed.IsDownloadedInstalled);
        Assert.Equal(1, server.RequestCount);
        Assert.NotNull(store.InstalledPackageDirectory());

        hardwareAvailable = false;
        manager.Refresh();
        Assert.True(manager.State.IsDownloadedInstalled);

        manager.RemoveDownloadedModel();
        Assert.Null(store.InstalledPackageDirectory());
        Assert.Equal(AIModelPackageStatus.Unavailable, manager.State.Status);

        manager.StartDownload();
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, server.RequestCount);
    }

    [Fact]
    public async Task RemoveRefusesAtomicallyWhenModelFileIsOpenAndKeepsPackageInstalled()
    {
        var fixture = MakeSyntheticArchive("locked-remove");
        using var server = new LoopbackHttpServer(ServerMode.File(fixture.ArchivePath));

        var storage = Path.Combine(tempRoot, "store-locked-remove");
        var desc = fixture.Descriptor(server.Url("/locked.tar.gz"));
        var store = new AIModelPackageStore(
            storage,
            desc,
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var manager = new AIModelPackageManager(
            store,
            isRuntimeSupported: () => true,
            isHardwareAvailable: () => true);

        var installedTcs = new TaskCompletionSource<AIModelPackageState>(TaskCreationOptions.RunContinuationsAsynchronously);
        manager.StateChanged += state =>
        {
            if (state.IsDownloadedInstalled) installedTcs.TrySetResult(state);
        };
        manager.StartDownload();
        _ = await installedTcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(1, server.RequestCount);

        var installedDir = store.InstalledPackageDirectory();
        Assert.NotNull(installedDir);
        var lockedEntry = desc.Entries.Last(e => e.Kind == AIModelArchiveEntryKind.File && !string.Equals(e.Path, "manifest.json", StringComparison.OrdinalIgnoreCase));
        var lockedFile = Path.Combine(installedDir!, lockedEntry.Path.Replace('/', Path.DirectorySeparatorChar));
        Assert.True(File.Exists(lockedFile));

        // Hold one model file open without FileShare.Delete (matching a native reader such as std::ifstream).
        using (var readerHandle = new FileStream(lockedFile, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            // Direct store removal must fail without deleting any file in the package.
            var ex = Assert.Throws<AIModelPackageException>(() => store.RemoveInstalledPackages());
            Assert.Equal(AIModelPackageErrorCode.RemoveFailed, ex.Code);

            // Manager removal must also leave the package intact and installed with the failure reported, never a download-retry state.
            manager.RemoveDownloadedModel();
            Assert.Equal(AIModelPackageStatus.Installed, manager.State.Status);
            Assert.True(manager.State.IsDownloadedInstalled);
            Assert.Equal(AIModelPackageErrorCode.RemoveFailed, manager.State.Error?.Code);

            // Resolver still returns the intact installed directory and every catalog file still matches its hash.
            Assert.Equal(
                new AIModelDirectorySource(AIModelDirectoryKind.Downloaded, installedDir!),
                store.ResolveModelDirectory());
            foreach (var entry in desc.Entries.Where(e => e.Kind == AIModelArchiveEntryKind.File))
            {
                var path = Path.Combine(installedDir!, entry.Path.Replace('/', Path.DirectorySeparatorChar));
                Assert.True(File.Exists(path), $"File was unexpectedly deleted during failed removal: {entry.Path}");
                Assert.Equal(entry.Sha256, AIModelPackageStore.ComputeSha256Hex(path, CancellationToken.None));
            }

            // Calling StartDownload in this state must not issue any download request.
            manager.StartDownload();
            await manager.ActiveCompletion.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(1, server.RequestCount);
            GC.KeepAlive(readerHandle);
        }

        // Once the handle is released, removal succeeds completely with no leftovers.
        manager.RemoveDownloadedModel();
        Assert.Null(store.InstalledPackageDirectory());
        Assert.Equal(AIModelPackageState.NotInstalled(desc.ArchiveBytes, desc.UnpackedBytes), manager.State);
        Assert.Null(manager.State.Error);
        AssertNoStrayTempFiles(storage);
    }

    // MARK: - Helpers

    private async Task<AIModelPackageException> AssertHostileArchiveRejected(SyntheticArchive hostile, string storage)
    {
        using var server = new LoopbackHttpServer(ServerMode.File(hostile.ArchivePath));
        var store = new AIModelPackageStore(
            storage,
            hostile.Descriptor(server.Url("/hostile.tar.gz")),
            allowLoopbackHttp: true,
            diskSpaceMarginBytes: 1024);

        var ex = await Assert.ThrowsAsync<AIModelPackageException>(() => store.DownloadAndInstallAsync());
        AssertNothingInstalledOrLeftOver(store, storage);
        return ex;
    }

    private static void AssertNothingInstalledOrLeftOver(AIModelPackageStore store, string storage)
    {
        Assert.Null(store.InstalledPackageDirectory());
        AssertNoStrayTempFiles(storage);
        if (Directory.Exists(storage))
            Assert.Empty(Directory.GetFileSystemEntries(storage));
    }

    private static void AssertNoStrayTempFiles(string directory)
    {
        if (!Directory.Exists(directory)) return;
        foreach (var path in Directory.GetFileSystemEntries(directory))
        {
            var name = Path.GetFileName(path);
            Assert.False(name.StartsWith(".download-", StringComparison.Ordinal), "Stray .part file left behind: " + name);
            Assert.False(name.StartsWith(".staging-", StringComparison.Ordinal), "Stray staging dir left behind: " + name);
            Assert.False(name.StartsWith(".replacing-", StringComparison.Ordinal), "Stray backup dir left behind: " + name);
            Assert.False(name.StartsWith(".removing-", StringComparison.Ordinal), "Stray removing dir left behind: " + name);
        }
    }

    private static string LocateRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Shared", "ai-models", "catalog.json")))
                return dir.FullName;
        }
        throw new DirectoryNotFoundException("Cannot locate repository root containing Shared/ai-models/catalog.json");
    }

    private sealed record SyntheticArchive(
        string ArchivePath,
        string ArchiveName,
        ulong ArchiveBytes,
        string ArchiveSha256,
        string ManifestSha256,
        ulong UnpackedBytes,
        IReadOnlyList<AIModelArchiveEntry> Entries,
        Dictionary<string, byte[]> FileContents)
    {
        internal AIModelPackageDescriptor Descriptor(string url) => new(
            SchemaVersion: 1,
            Platform: AIModelCatalog.WindowsX64Platform,
            Url: url,
            ArchiveName: ArchiveName,
            ArchiveSha256: ArchiveSha256,
            ArchiveBytes: ArchiveBytes,
            ManifestSha256: ManifestSha256,
            UnpackedBytes: UnpackedBytes,
            Entries: Entries);
    }

    private enum HostileKind
    {
        PathTraversal,
        AbsolutePath,
        SymlinkAtDescribedPath,
        SymlinkWriteThrough,
        HardLinkAtDescribedPath,
        ExtraMember,
        WrongMemberSize,
    }

    private SyntheticArchive MakeSyntheticArchive(string label, string manifestExtra = "v1", int weightBytes = 4096)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["DualDn-LICENSE.txt"] = Encoding.UTF8.GetBytes("CC BY-NC 4.0 license text\n"),
            ["Restormer-LICENSE.txt"] = Encoding.UTF8.GetBytes("Academic Public License text\n"),
            ["manifest.json"] = Encoding.UTF8.GetBytes($"{{\"version\":1,\"tag\":\"{manifestExtra}\"}}\n"),
            ["weights/weight.bin"] = Enumerable.Repeat((byte)0x2A, weightBytes).ToArray(),
        };
        var dirs = new[] { "weights" };
        var archiveName = $"synthetic-{label}.tar.gz";
        var archivePath = Path.Combine(tempRoot, archiveName);

        var tarMembers = new List<TarRecord>();
        foreach (var d in dirs) tarMembers.Add(TarRecord.Directory(d));
        foreach (var (rel, data) in files.OrderBy(p => p.Key, StringComparer.Ordinal))
            tarMembers.Add(TarRecord.File(rel, data));
        WriteTarGz(archivePath, tarMembers);

        var entries = BuildEntries(files, dirs);
        var archiveBytes = File.ReadAllBytes(archivePath);
        return new SyntheticArchive(
            archivePath,
            archiveName,
            (ulong)archiveBytes.Length,
            Sha256Hex(archiveBytes),
            Sha256Hex(files["manifest.json"]),
            entries.Aggregate(0UL, (sum, e) => sum + e.Bytes),
            entries,
            files);
    }

    private SyntheticArchive MakeHostileArchive(HostileKind kind, string? param = null)
    {
        var manifest = Encoding.UTF8.GetBytes("{\"version\":1,\"hostile\":true}\n");
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["DualDn-LICENSE.txt"] = kind == HostileKind.HardLinkAtDescribedPath ? manifest : Encoding.UTF8.GetBytes("CC BY-NC 4.0\n"),
            ["Restormer-LICENSE.txt"] = Encoding.UTF8.GetBytes("Restormer Academic\n"),
            ["manifest.json"] = manifest,
        };
        var entries = BuildEntries(files, []);

        var members = new List<TarRecord>();
        switch (kind)
        {
            case HostileKind.PathTraversal:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.File("DualDn-LICENSE.txt", files["DualDn-LICENSE.txt"]));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                members.Add(TarRecord.File(param!, Encoding.UTF8.GetBytes("escaped")));
                break;
            case HostileKind.AbsolutePath:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.File("DualDn-LICENSE.txt", files["DualDn-LICENSE.txt"]));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                members.Add(TarRecord.File(param!, Encoding.UTF8.GetBytes("escaped")));
                break;
            case HostileKind.SymlinkAtDescribedPath:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.Symlink("DualDn-LICENSE.txt", "manifest.json"));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                break;
            case HostileKind.SymlinkWriteThrough:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.File("DualDn-LICENSE.txt", files["DualDn-LICENSE.txt"]));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                members.Add(TarRecord.Symlink("out", param!));
                members.Add(TarRecord.File("out/sym-escaped.txt", Encoding.UTF8.GetBytes("pwned")));
                break;
            case HostileKind.HardLinkAtDescribedPath:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.HardLink("DualDn-LICENSE.txt", "manifest.json"));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                break;
            case HostileKind.ExtraMember:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.File("DualDn-LICENSE.txt", files["DualDn-LICENSE.txt"]));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                members.Add(TarRecord.File("unexpected.bin", Encoding.UTF8.GetBytes("surprise")));
                break;
            case HostileKind.WrongMemberSize:
                members.Add(TarRecord.File("manifest.json", files["manifest.json"]));
                members.Add(TarRecord.File("DualDn-LICENSE.txt", Encoding.UTF8.GetBytes("tampered longer license text\n")));
                members.Add(TarRecord.File("Restormer-LICENSE.txt", files["Restormer-LICENSE.txt"]));
                break;
        }

        var archiveName = $"hostile-{kind}-{Guid.NewGuid():N}.tar.gz";
        var archivePath = Path.Combine(tempRoot, archiveName);
        WriteTarGz(archivePath, members);
        var archiveBytes = File.ReadAllBytes(archivePath);
        return new SyntheticArchive(
            archivePath,
            archiveName,
            (ulong)archiveBytes.Length,
            Sha256Hex(archiveBytes),
            Sha256Hex(manifest),
            entries.Aggregate(0UL, (sum, e) => sum + e.Bytes),
            entries,
            files);
    }

    private static List<AIModelArchiveEntry> BuildEntries(Dictionary<string, byte[]> files, IEnumerable<string> dirs)
    {
        var list = new List<AIModelArchiveEntry>();
        foreach (var d in dirs) list.Add(new AIModelArchiveEntry(d, AIModelArchiveEntryKind.Directory, 0, null));
        foreach (var (rel, data) in files)
            list.Add(new AIModelArchiveEntry(rel, AIModelArchiveEntryKind.File, (ulong)data.Length, Sha256Hex(data)));
        list.Sort((a, b) => StringComparer.Ordinal.Compare(a.Path, b.Path));
        return list;
    }

    private static string Sha256Hex(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private sealed record TarRecord(string Name, byte TypeFlag, byte[] Content, string LinkName)
    {
        internal static TarRecord File(string name, byte[] content) => new(name, (byte)'0', content, "");
        internal static TarRecord Directory(string name) => new(name, (byte)'5', [], "");
        internal static TarRecord Symlink(string name, string target) => new(name, (byte)'2', [], target);
        internal static TarRecord HardLink(string name, string target) => new(name, (byte)'1', [], target);
    }

    private static void WriteTarGz(string path, IReadOnlyList<TarRecord> records)
    {
        using var file = File.Create(path);
        using var gzip = new GZipStream(file, CompressionLevel.Optimal, leaveOpen: false);
        foreach (var rec in records)
        {
            var header = new byte[512];
            var nameBytes = Encoding.UTF8.GetBytes(rec.Name);
            if (nameBytes.Length <= 100)
            {
                WriteAscii(header, 0, 100, rec.Name);
            }
            else
            {
                var split = rec.Name.LastIndexOf('/');
                if (split <= 0) throw new InvalidOperationException($"TAR name too long without separator: {rec.Name}");
                WriteAscii(header, 345, 155, rec.Name[..split]);
                WriteAscii(header, 0, 100, rec.Name[(split + 1)..]);
            }
            WriteOctal(header, 100, 8, rec.TypeFlag == (byte)'5' ? 0755UL : 0644UL);
            WriteOctal(header, 108, 8, 0);
            WriteOctal(header, 116, 8, 0);
            WriteOctal(header, 124, 12, (ulong)rec.Content.Length);
            WriteOctal(header, 136, 12, 0);
            Array.Fill(header, (byte)' ', 148, 8);
            header[156] = rec.TypeFlag;
            if (!string.IsNullOrEmpty(rec.LinkName)) WriteAscii(header, 157, 100, rec.LinkName);
            WriteAscii(header, 257, 6, "ustar");
            header[263] = (byte)'0';
            header[264] = (byte)'0';
            var checksum = 0;
            for (var i = 0; i < 512; i++) checksum += header[i];
            var octal = Convert.ToString(checksum, 8).PadLeft(6, '0');
            WriteAscii(header, 148, 6, octal);
            header[154] = 0;
            header[155] = (byte)' ';

            gzip.Write(header, 0, header.Length);
            if (rec.Content.Length > 0)
            {
                gzip.Write(rec.Content, 0, rec.Content.Length);
                var pad = (512 - (rec.Content.Length % 512)) % 512;
                if (pad > 0) gzip.Write(new byte[pad], 0, pad);
            }
        }
        gzip.Write(new byte[1024], 0, 1024);
    }

    private static void WriteAscii(byte[] buffer, int offset, int maxLen, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.Length > maxLen) throw new InvalidOperationException($"TAR field too long ({bytes.Length} > {maxLen}): {text}");
        Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
    }

    private static void WriteOctal(byte[] buffer, int offset, int length, ulong value)
    {
        var text = Convert.ToString((long)value, 8).PadLeft(length - 1, '0');
        var bytes = Encoding.ASCII.GetBytes(text);
        Buffer.BlockCopy(bytes, 0, buffer, offset, Math.Min(bytes.Length, length - 1));
        buffer[offset + length - 1] = 0;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

    // MARK: - Loopback HTTP Test Server (Port 0, Zero Sleeps)

    private sealed record ServerMode(
        string Kind,
        string? FilePath = null,
        int StatusCode = 200,
        string? RedirectLocation = null,
        int? DeclaredLength = null,
        byte[]? CustomBody = null)
    {
        internal static ServerMode File(string path) => new("file", FilePath: path);
        internal static ServerMode StalledFile(string path) => new("stalled", FilePath: path);
        internal static ServerMode Status(int code) => new("status", StatusCode: code);
        internal static ServerMode Redirect(string location) => new("redirect", RedirectLocation: location);
        internal static ServerMode Custom(int? declaredLength, byte[] body) => new("custom", DeclaredLength: declaredLength, CustomBody: body);
    }

    private sealed class LoopbackHttpServer : IDisposable
    {
        private readonly TcpListener listener;
        private readonly CancellationTokenSource shutdown = new();
        private readonly object modeGate = new();
        private readonly Task acceptLoop;
        private ServerMode mode;
        private int requestCount;

        internal int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
        internal int RequestCount => Volatile.Read(ref requestCount);
        internal string Url(string path) => $"http://127.0.0.1:{Port}{path}";

        internal LoopbackHttpServer(ServerMode initialMode)
        {
            mode = initialMode;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            acceptLoop = Task.Run(AcceptAsync);
        }

        internal void SetMode(ServerMode next)
        {
            lock (modeGate) mode = next;
        }

        private async Task AcceptAsync()
        {
            while (!shutdown.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(shutdown.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
                catch (SocketException) { break; }
                catch (ObjectDisposedException) { break; }
                _ = Task.Run(() => HandleClientAsync(client));
            }
        }

        private async Task HandleClientAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    using var stream = client.GetStream();
                    var headerBuf = new byte[4096];
                    var total = 0;
                    while (total < headerBuf.Length)
                    {
                        var n = await stream.ReadAsync(headerBuf.AsMemory(total, headerBuf.Length - total), shutdown.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        total += n;
                        if (Encoding.ASCII.GetString(headerBuf, 0, total).Contains("\r\n\r\n", StringComparison.Ordinal))
                            break;
                    }
                    Interlocked.Increment(ref requestCount);

                    ServerMode current;
                    lock (modeGate) current = mode;

                    switch (current.Kind)
                    {
                        case "file":
                        {
                            var body = await System.IO.File.ReadAllBytesAsync(current.FilePath!, shutdown.Token).ConfigureAwait(false);
                            var headers = $"HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(headers), shutdown.Token).ConfigureAwait(false);
                            await stream.WriteAsync(body, shutdown.Token).ConfigureAwait(false);
                            break;
                        }
                        case "stalled":
                        {
                            var body = await System.IO.File.ReadAllBytesAsync(current.FilePath!, shutdown.Token).ConfigureAwait(false);
                            var headers = $"HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(headers), shutdown.Token).ConfigureAwait(false);
                            var firstChunk = Math.Min(4096, Math.Max(1, body.Length / 4));
                            await stream.WriteAsync(body.AsMemory(0, firstChunk), shutdown.Token).ConfigureAwait(false);
                            await stream.FlushAsync(shutdown.Token).ConfigureAwait(false);
                            // Wait without polling/sleep until client disconnects or server stops
                            var drain = new byte[1];
                            try { _ = await stream.ReadAsync(drain, shutdown.Token).ConfigureAwait(false); }
                            catch (Exception) { }
                            break;
                        }
                        case "status":
                        {
                            var headers = $"HTTP/1.1 {current.StatusCode} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(headers), shutdown.Token).ConfigureAwait(false);
                            break;
                        }
                        case "redirect":
                        {
                            var headers = $"HTTP/1.1 302 Found\r\nLocation: {current.RedirectLocation}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(headers), shutdown.Token).ConfigureAwait(false);
                            break;
                        }
                        case "custom":
                        {
                            var lengthLine = current.DeclaredLength.HasValue ? $"Content-Length: {current.DeclaredLength.Value}\r\n" : "";
                            var headers = $"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n{lengthLine}Connection: close\r\n\r\n";
                            await stream.WriteAsync(Encoding.ASCII.GetBytes(headers), shutdown.Token).ConfigureAwait(false);
                            if (current.CustomBody is { Length: > 0 } body)
                                await stream.WriteAsync(body, shutdown.Token).ConfigureAwait(false);
                            break;
                        }
                    }
                    await stream.FlushAsync(shutdown.Token).ConfigureAwait(false);
                }
                catch (Exception) { }
            }
        }

        public void Dispose()
        {
            shutdown.Cancel();
            try { listener.Stop(); } catch (Exception) { }
            try { acceptLoop.Wait(TimeSpan.FromSeconds(2)); } catch (Exception) { }
            shutdown.Dispose();
        }
    }
}
