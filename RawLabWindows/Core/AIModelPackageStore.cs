using System.Diagnostics;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace RawLab.Windows;

internal sealed class AIModelPackageStore
{
    internal const string ModelOverrideEnvironmentVariable = "RAWLAB_AI_MODEL_OVERRIDE";
    internal const ulong DefaultDiskSpaceMarginBytes = 64UL * 1024 * 1024;
    private const int MaxRedirects = 10;
    private const int DiskFullHResult = unchecked((int)0x80070070);
    private const int HandleDiskFullHResult = unchecked((int)0x80070027);
    private static readonly TimeSpan DefaultRequestInactivityTimeout = TimeSpan.FromSeconds(60);

    internal static string BundledModelDirectory => Path.Combine(AppContext.BaseDirectory, "AI", "DualDn");

    private static readonly Lazy<AIModelPackageDescriptor?> DefaultBundledDescriptor =
        new(() => AIModelCatalog.BundledDescriptor(AIModelCatalog.WindowsX64Platform));

    internal static AIModelPackageDescriptor? BundledDescriptor => DefaultBundledDescriptor.Value;

    internal static string? ExplicitOverrideDirectory { get; set; }

    internal static string? ResolvedOverrideDirectory
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(ExplicitOverrideDirectory))
                return Path.GetFullPath(ExplicitOverrideDirectory.Trim());
            var env = Environment.GetEnvironmentVariable(ModelOverrideEnvironmentVariable);
            return string.IsNullOrWhiteSpace(env) ? null : Path.GetFullPath(env.Trim());
        }
    }

    internal static AIModelPackageStore CreateForAppPaths(AppPaths? appPaths = null, AIModelPackageDescriptor? descriptor = null) =>
        new((appPaths ?? AppPaths.Default).DualDnModelDirectory, descriptor ?? BundledDescriptor, allowLoopbackHttp: false);

    internal static AIModelDirectorySource? ResolveDefaultModelSource(AppPaths? appPaths = null) =>
        CreateForAppPaths(appPaths).ResolveModelDirectory(ResolvedOverrideDirectory, BundledModelDirectory);

    internal static string? ResolveDefaultModelDirectory(AppPaths? appPaths = null) =>
        ResolveDefaultModelSource(appPaths)?.DirectoryPath;

    internal string StorageRoot { get; }
    internal AIModelPackageDescriptor? Descriptor { get; }
    internal ulong DiskSpaceMarginBytes { get; }

    private readonly bool allowLoopbackHttp;
    private readonly Func<string, ulong> availableSpaceProvider;
    private readonly Action? onBeforeUnpack;
    private readonly Action? onBeforeCommit;
    private readonly Func<HttpClient>? httpClientFactory;
    private readonly TimeSpan requestInactivityTimeout;

    internal AIModelPackageStore(
        string storageRoot,
        AIModelPackageDescriptor? descriptor,
        bool allowLoopbackHttp = false,
        ulong diskSpaceMarginBytes = DefaultDiskSpaceMarginBytes,
        Func<string, ulong>? availableSpaceProvider = null,
        Action? onBeforeUnpack = null,
        Action? onBeforeCommit = null,
        Func<HttpClient>? httpClientFactory = null,
        TimeSpan? requestInactivityTimeout = null)
    {
        StorageRoot = Path.GetFullPath(storageRoot);
        Descriptor = descriptor;
        this.allowLoopbackHttp = allowLoopbackHttp;
        DiskSpaceMarginBytes = diskSpaceMarginBytes;
        this.availableSpaceProvider = availableSpaceProvider ?? VolumeAvailableBytes;
        this.onBeforeUnpack = onBeforeUnpack;
        this.onBeforeCommit = onBeforeCommit;
        this.httpClientFactory = httpClientFactory;
        this.requestInactivityTimeout = requestInactivityTimeout ?? DefaultRequestInactivityTimeout;
    }

    internal string? InstalledDirectoryPath =>
        Descriptor == null ? null : Path.Combine(StorageRoot, Descriptor.ManifestSha256);

    /// <summary>
    /// 快速结构检查（供启动和界面状态查询，不在 UI 线程重算数百 MB SHA-256；
    /// 安装时已全量校验 SHA-256，核心创建 AI session 时仍执行最终 SHA-256 校验）。
    /// </summary>
    internal string? InstalledPackageDirectory()
    {
        if (Descriptor == null || InstalledDirectoryPath is not { } candidate) return null;
        return MatchesInstalledStructure(candidate, Descriptor) ? candidate : null;
    }

    /// <summary>
    /// 模型目录选择顺序：显式开发/测试覆盖 -> 已下载的当前 digest 包 -> 应用内预置包。
    /// </summary>
    internal AIModelDirectorySource? ResolveModelDirectory(string? overrideDirectory = null, string? bundledDirectory = null)
    {
        if (!string.IsNullOrWhiteSpace(overrideDirectory))
            return new AIModelDirectorySource(AIModelDirectoryKind.Override, Path.GetFullPath(overrideDirectory));
        if (InstalledPackageDirectory() is { } downloaded)
            return new AIModelDirectorySource(AIModelDirectoryKind.Downloaded, downloaded);
        if (!string.IsNullOrWhiteSpace(bundledDirectory) && HasManifestFile(bundledDirectory))
            return new AIModelDirectorySource(AIModelDirectoryKind.Bundled, Path.GetFullPath(bundledDirectory));
        return null;
    }

    internal void CheckDiskSpace(AIModelPackageDescriptor descriptor)
    {
        ulong required;
        try { checked { required = descriptor.ArchiveBytes + descriptor.UnpackedBytes + DiskSpaceMarginBytes; } }
        catch (OverflowException)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Required disk space overflow");
        }
        var probe = NearestExistingDirectory(StorageRoot);
        ulong available;
        try { available = availableSpaceProvider(probe); }
        catch (AIModelPackageException) { throw; }
        catch (Exception ex)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.FileSystemError, ex.Message, innerException: ex);
        }
        if (available < required)
            throw new AIModelPackageException(AIModelPackageErrorCode.InsufficientDiskSpace, requiredBytes: required, availableBytes: available);
    }

    /// <summary>
    /// 下载、校验并原子安装模型包。仅由用户显式触发调用，绝不在启动或更新后自动调用。
    /// </summary>
    internal async Task<string> DownloadAndInstallAsync(
        CancellationToken cancellationToken = default,
        Action<AIModelInstallPhase>? onProgress = null)
    {
        if (Descriptor is not { } descriptor)
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "AI model catalog unavailable");
        descriptor.Validate(allowLoopbackHttp);
        ThrowIfCancelled(cancellationToken);

        var downloadUri = descriptor.ValidateDownloadUri(allowLoopbackHttp);
        CheckDiskSpace(descriptor);
        ThrowIfCancelled(cancellationToken);

        try { Directory.CreateDirectory(StorageRoot); }
        catch (Exception ex) { throw MapFileSystemError(ex); }

        // 清理上次异常退出或强杀遗留的临时下载/暂存目录。
        CleanupStaleTempItems();

        var token = Guid.NewGuid().ToString("N");
        var partPath = Path.Combine(StorageRoot, $".download-{token}.part");
        var stagingDir = Path.Combine(StorageRoot, $".staging-{token}");

        try
        {
            onProgress?.Invoke(new AIModelInstallPhase(AIModelInstallPhaseKind.Downloading, 0, descriptor.ArchiveBytes));
            await StreamDownloadAsync(
                downloadUri,
                partPath,
                descriptor.ArchiveBytes,
                cancellationToken,
                completed => onProgress?.Invoke(new AIModelInstallPhase(AIModelInstallPhaseKind.Downloading, completed, descriptor.ArchiveBytes)))
                .ConfigureAwait(false);

            ThrowIfCancelled(cancellationToken);
            onProgress?.Invoke(new AIModelInstallPhase(AIModelInstallPhaseKind.Verifying));

            // 先验归档字节数，再验归档 SHA-256；任一不符立即终止，绝不解压或解析归档。
            VerifyArchiveFile(partPath, descriptor, cancellationToken);

            ThrowIfCancelled(cancellationToken);
            onProgress?.Invoke(new AIModelInstallPhase(AIModelInstallPhaseKind.Installing));

            onBeforeUnpack?.Invoke();

            ExtractArchive(partPath, stagingDir, descriptor, cancellationToken);

            ThrowIfCancelled(cancellationToken);
            VerifyAndNormalizeStagingTree(stagingDir, descriptor, cancellationToken);

            ThrowIfCancelled(cancellationToken);
            onBeforeCommit?.Invoke();

            var destination = Path.Combine(StorageRoot, descriptor.ManifestSha256);
            CommitStagingDirectory(stagingDir, destination);
            CleanupOlderPackages(keepingDigest: descriptor.ManifestSha256);
            return destination;
        }
        finally
        {
            TryDeleteFileSafe(partPath);
            TryDeleteDirectorySafe(stagingDir);
        }
    }

    internal void RemoveInstalledPackages()
    {
        if (!Directory.Exists(StorageRoot)) return;
        FileSystemInfo[] items;
        try { items = new DirectoryInfo(StorageRoot).GetFileSystemInfos(); }
        catch (Exception ex)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.RemoveFailed, ex.Message, innerException: ex);
        }
        foreach (var item in items)
        {
            var name = item.Name;
            if (name.StartsWith(".download-", StringComparison.Ordinal) ||
                name.StartsWith(".staging-", StringComparison.Ordinal) ||
                name.StartsWith(".replacing-", StringComparison.Ordinal))
                continue;
            try
            {
                if (item is DirectoryInfo dir)
                {
                    if (TempCleanup.IsReparsePoint(dir)) dir.Delete(recursive: false);
                    else DeleteDirectoryStrict(dir);
                }
                else
                {
                    ClearReadOnlyAttribute(item);
                    item.Delete();
                }
            }
            catch (Exception ex)
            {
                throw new AIModelPackageException(AIModelPackageErrorCode.RemoveFailed, ex.Message, innerException: ex);
            }
        }
    }

    // MARK: - Verification & Extraction Helpers (internal for direct defense-in-depth tests)

    internal static void VerifyArchiveFile(string archivePath, AIModelPackageDescriptor descriptor, CancellationToken cancellationToken)
    {
        var info = new FileInfo(archivePath);
        if (!info.Exists || TempCleanup.IsReparsePoint(info))
            throw new AIModelPackageException(AIModelPackageErrorCode.FileSystemError, "Downloaded archive missing");
        var actualSize = (ulong)Math.Max(0L, info.Length);
        if (actualSize != descriptor.ArchiveBytes)
            throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveSizeMismatch, expectedBytes: descriptor.ArchiveBytes, actualBytes: actualSize);
        var digest = ComputeSha256Hex(archivePath, cancellationToken);
        if (!CryptographicOperations.FixedTimeEquals(
            Convert.FromHexString(digest),
            Convert.FromHexString(descriptor.ArchiveSha256)))
            throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveDigestMismatch);
    }

    internal static void ExtractArchive(
        string archivePath,
        string stagingDir,
        AIModelPackageDescriptor descriptor,
        CancellationToken cancellationToken)
    {
        try { Directory.CreateDirectory(stagingDir); }
        catch (Exception ex) { throw MapFileSystemError(ex); }

        var expectedByPath = descriptor.Entries.ToDictionary(e => e.Path, StringComparer.Ordinal);
        var seenInArchive = new HashSet<string>(StringComparer.Ordinal);
        var stagingFull = Path.GetFullPath(stagingDir);
        var stagingPrefix = stagingFull.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

        try
        {
            using var fileStream = new FileStream(archivePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.SequentialScan);
            using var gzipStream = new GZipStream(fileStream, CompressionMode.Decompress, leaveOpen: false);
            using var tarReader = new TarReader(gzipStream, leaveOpen: false);

            var buffer = new byte[256 * 1024];
            TarEntry? entry;
            while ((entry = tarReader.GetNextEntry(copyData: false)) != null)
            {
                ThrowIfCancelled(cancellationToken);

                var entryType = entry.EntryType;
                if (entryType == TarEntryType.SymbolicLink)
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Archive contains symlink: {entry.Name}");
                if (entryType == TarEntryType.HardLink)
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Archive contains hard link: {entry.Name}");
                if (entryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile or TarEntryType.Directory))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Unsupported archive entry type {entryType}: {entry.Name}");
                if (!string.IsNullOrEmpty(entry.LinkName))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Archive member has link target: {entry.Name}");

                var normalized = entry.Name;
                if (entryType == TarEntryType.Directory && normalized.Length > 1 && normalized.EndsWith('/'))
                    normalized = normalized[..^1];
                if (!AIModelPackageDescriptor.IsSafeRelativePath(normalized))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Unsafe archive entry path: {entry.Name}");
                if (!expectedByPath.TryGetValue(normalized, out var expected))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Unexpected archive member: {normalized}");
                if (!seenInArchive.Add(normalized))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Duplicate archive member: {normalized}");

                var targetPath = Path.GetFullPath(Path.Combine(stagingFull, normalized.Replace('/', Path.DirectorySeparatorChar)));
                if (!targetPath.StartsWith(stagingPrefix, StringComparison.OrdinalIgnoreCase))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Archive entry escapes staging directory: {normalized}");

                if (expected.Kind == AIModelArchiveEntryKind.Directory)
                {
                    if (entryType != TarEntryType.Directory)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Expected directory at {normalized}");
                    if (entry.Length != 0)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Directory member has non-zero length: {normalized}");
                    Directory.CreateDirectory(targetPath);
                    EnsureNoReparsePointsInPath(stagingFull, targetPath);
                    continue;
                }

                if (entryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Expected regular file at {normalized}");
                if (entry.Length < 0 || (ulong)entry.Length != expected.Bytes)
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Member size mismatch at {normalized}: {entry.Length} != {expected.Bytes}");

                var parentDir = Path.GetDirectoryName(targetPath)!;
                Directory.CreateDirectory(parentDir);
                EnsureNoReparsePointsInPath(stagingFull, parentDir);

                using var output = new FileStream(targetPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 256 * 1024);
                ulong written = 0;
                if (entry.DataStream != null)
                {
                    int read;
                    while ((read = entry.DataStream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        ThrowIfCancelled(cancellationToken);
                        written += (ulong)read;
                        if (written > expected.Bytes)
                            throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Extracted member exceeds expected size: {normalized}");
                        output.Write(buffer, 0, read);
                    }
                }
                if (written != expected.Bytes)
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Extracted member size mismatch at {normalized}: {written} != {expected.Bytes}");
                output.Flush();
            }
        }
        catch (AIModelPackageException) { throw; }
        catch (OperationCanceledException) { throw new AIModelPackageException(AIModelPackageErrorCode.Cancelled); }
        catch (IOException ex) when (IsDiskFull(ex)) { throw new AIModelPackageException(AIModelPackageErrorCode.DiskFull, innerException: ex); }
        catch (Exception ex) when (ex is InvalidDataException or EndOfStreamException or FormatException)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveExtractionFailed, ex.Message, innerException: ex);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw MapFileSystemError(ex);
        }

        if (seenInArchive.Count != expectedByPath.Count)
            throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, "Archive is missing expected members");
    }

    internal static void VerifyAndNormalizeStagingTree(
        string stagingDir,
        AIModelPackageDescriptor descriptor,
        CancellationToken cancellationToken)
    {
        var expectedByPath = descriptor.Entries.ToDictionary(e => e.Path, StringComparer.Ordinal);
        var visited = new HashSet<string>(StringComparer.Ordinal);

        void Walk(DirectoryInfo directory, string relativePrefix)
        {
            ThrowIfCancelled(cancellationToken);
            if (TempCleanup.IsReparsePoint(directory))
                throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Staging directory is a symlink/reparse point: {relativePrefix}");

            FileSystemInfo[] children;
            try { children = directory.GetFileSystemInfos(); }
            catch (Exception ex) { throw MapFileSystemError(ex); }
            Array.Sort(children, (a, b) => StringComparer.Ordinal.Compare(a.Name, b.Name));

            foreach (var child in children)
            {
                ThrowIfCancelled(cancellationToken);
                var relPath = string.IsNullOrEmpty(relativePrefix) ? child.Name : $"{relativePrefix}/{child.Name}";
                if (TempCleanup.IsReparsePoint(child))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Extracted tree contains symlink: {relPath}");
                if (!expectedByPath.TryGetValue(relPath, out var expected))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Extracted tree contains unexpected item: {relPath}");
                if (!visited.Add(relPath))
                    throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Duplicate extracted item: {relPath}");

                if (expected.Kind == AIModelArchiveEntryKind.Directory)
                {
                    if (child is not DirectoryInfo subDir)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Expected directory at {relPath}");
                    ClearReadOnlyAttribute(subDir);
                    Walk(subDir, relPath);
                }
                else
                {
                    if (child is not FileInfo file)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Expected regular file at {relPath}");
                    if (WindowsFileIdentity.TryGetLinkCount(file.FullName, out var linkCount) && linkCount != 1)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Extracted file is a hard link: {relPath}");
                    var actualSize = (ulong)Math.Max(0L, file.Length);
                    if (actualSize != expected.Bytes)
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Size mismatch at {relPath}: {actualSize} != {expected.Bytes}");
                    if (expected.Sha256 == null)
                        throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Missing expected sha256 for {relPath}");
                    var actualDigest = ComputeSha256Hex(file.FullName, cancellationToken);
                    if (!CryptographicOperations.FixedTimeEquals(
                        Convert.FromHexString(actualDigest),
                        Convert.FromHexString(expected.Sha256)))
                        throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"SHA-256 mismatch at {relPath}");
                    ClearReadOnlyAttribute(file);
                }
            }
        }

        Walk(new DirectoryInfo(stagingDir), "");
        if (visited.Count != expectedByPath.Count)
            throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, "Missing expected items in staging tree");
    }

    // MARK: - Private Helpers

    private async Task StreamDownloadAsync(
        Uri initialUri,
        string partPath,
        ulong expectedBytes,
        CancellationToken cancellationToken,
        Action<ulong> onBytesWritten)
    {
        using var client = httpClientFactory != null
            ? httpClientFactory()
            : new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };

        using var response = await SendWithValidatedRedirectsAsync(client, initialUri, cancellationToken).ConfigureAwait(false);

        if (response.StatusCode != HttpStatusCode.OK)
        {
            var statusCode = (int)response.StatusCode;
            throw statusCode == 404
                ? new AIModelPackageException(AIModelPackageErrorCode.HttpNotFound, httpStatusCode: 404)
                : new AIModelPackageException(AIModelPackageErrorCode.HttpStatus, httpStatusCode: statusCode);
        }

        if (response.Content.Headers.ContentLength is { } contentLength && contentLength >= 0 && (ulong)contentLength != expectedBytes)
            throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveSizeMismatch, expectedBytes: expectedBytes, actualBytes: (ulong)contentLength);

        FileStream? output = null;
        try
        {
            output = new FileStream(partPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 256 * 1024, FileOptions.Asynchronous);
            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[64 * 1024];
            ulong received = 0;
            ulong lastReported = 0;
            var clock = Stopwatch.StartNew();
            var lastReportMs = 0L;

            while (true)
            {
                ThrowIfCancelled(cancellationToken);
                int read;
                using (var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
                {
                    readTimeout.CancelAfter(requestInactivityTimeout);
                    try
                    {
                        read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), readTimeout.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw new AIModelPackageException(AIModelPackageErrorCode.Cancelled);
                    }
                    catch (OperationCanceledException ex)
                    {
                        throw new AIModelPackageException(AIModelPackageErrorCode.NetworkTimeout, innerException: ex);
                    }
                }

                if (read == 0) break;
                var nextTotal = received + (ulong)read;
                if (nextTotal > expectedBytes)
                    throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveSizeMismatch, expectedBytes: expectedBytes, actualBytes: nextTotal);

                await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                received = nextTotal;

                var nowMs = clock.ElapsedMilliseconds;
                if (lastReported == 0 || received == expectedBytes || received - lastReported >= 256 * 1024 || nowMs - lastReportMs >= 100)
                {
                    lastReported = received;
                    lastReportMs = nowMs;
                    onBytesWritten(received);
                }
            }

            await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            output.Flush(flushToDisk: true);
            await output.DisposeAsync().ConfigureAwait(false);
            output = null;

            ThrowIfCancelled(cancellationToken);
            if (received != expectedBytes)
                throw new AIModelPackageException(AIModelPackageErrorCode.ArchiveSizeMismatch, expectedBytes: expectedBytes, actualBytes: received);
            if (lastReported != received) onBytesWritten(received);
        }
        catch (AIModelPackageException) { throw; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.Cancelled);
        }
        catch (OperationCanceledException ex)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.NetworkTimeout, innerException: ex);
        }
        catch (HttpRequestException ex)
        {
            throw MapNetworkError(ex);
        }
        catch (IOException ex)
        {
            if (IsDiskFull(ex)) throw new AIModelPackageException(AIModelPackageErrorCode.DiskFull, innerException: ex);
            if (ex.InnerException is SocketException) throw new AIModelPackageException(AIModelPackageErrorCode.NetworkUnavailable, ex.Message, innerException: ex);
            throw new AIModelPackageException(AIModelPackageErrorCode.NetworkError, ex.Message, innerException: ex);
        }
        finally
        {
            if (output != null)
            {
                try { await output.DisposeAsync().ConfigureAwait(false); }
                catch (IOException) { }
            }
        }
    }

    private async Task<HttpResponseMessage> SendWithValidatedRedirectsAsync(
        HttpClient client,
        Uri initialUri,
        CancellationToken cancellationToken)
    {
        var current = AIModelPackageDescriptor.ValidateUri(initialUri, allowLoopbackHttp);
        for (var redirects = 0; ; redirects++)
        {
            ThrowIfCancelled(cancellationToken);
            using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            requestTimeout.CancelAfter(requestInactivityTimeout);
            HttpResponseMessage response;
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                request.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true, NoStore = true };
                response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, requestTimeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw new AIModelPackageException(AIModelPackageErrorCode.Cancelled);
            }
            catch (OperationCanceledException ex)
            {
                throw new AIModelPackageException(AIModelPackageErrorCode.NetworkTimeout, innerException: ex);
            }
            catch (HttpRequestException ex)
            {
                throw MapNetworkError(ex);
            }

            if ((int)response.StatusCode is not (301 or 302 or 303 or 307 or 308))
                return response;

            var location = response.Headers.Location;
            response.Dispose();
            if (redirects >= MaxRedirects || location == null)
                throw new AIModelPackageException(AIModelPackageErrorCode.NetworkError, "Too many or incomplete redirects");

            var next = location.IsAbsoluteUri ? location : new Uri(current, location);
            current = AIModelPackageDescriptor.ValidateUri(next, allowLoopbackHttp);
        }
    }

    private void CommitStagingDirectory(string stagingDir, string destination)
    {
        string? backupDir = null;
        try
        {
            if (Directory.Exists(destination))
            {
                backupDir = Path.Combine(StorageRoot, $".replacing-{Guid.NewGuid():N}");
                Directory.Move(destination, backupDir);
            }
            Directory.Move(stagingDir, destination);
        }
        catch (Exception ex)
        {
            if (backupDir != null && Directory.Exists(backupDir) && !Directory.Exists(destination))
            {
                try { Directory.Move(backupDir, destination); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            throw MapFileSystemError(ex);
        }
        if (backupDir != null) TryDeleteDirectorySafe(backupDir);
    }

    private void CleanupStaleTempItems()
    {
        if (!Directory.Exists(StorageRoot)) return;
        FileSystemInfo[] items;
        try { items = new DirectoryInfo(StorageRoot).GetFileSystemInfos(); }
        catch (Exception) { return; }
        foreach (var item in items)
        {
            var name = item.Name;
            if (!name.StartsWith(".download-", StringComparison.Ordinal) &&
                !name.StartsWith(".staging-", StringComparison.Ordinal) &&
                !name.StartsWith(".replacing-", StringComparison.Ordinal))
                continue;
            if (item is DirectoryInfo dir) TryDeleteDirectorySafe(dir.FullName);
            else TryDeleteFileSafe(item.FullName);
        }
    }

    private void CleanupOlderPackages(string keepingDigest)
    {
        if (!Directory.Exists(StorageRoot)) return;
        FileSystemInfo[] items;
        try { items = new DirectoryInfo(StorageRoot).GetFileSystemInfos(); }
        catch (Exception) { return; }
        foreach (var item in items)
        {
            var name = item.Name;
            if (string.Equals(name, keepingDigest, StringComparison.OrdinalIgnoreCase)) continue;
            if (name.StartsWith(".download-", StringComparison.Ordinal) ||
                name.StartsWith(".staging-", StringComparison.Ordinal))
                continue;
            if (item is DirectoryInfo dir) TryDeleteDirectorySafe(dir.FullName);
            else TryDeleteFileSafe(item.FullName);
        }
    }

    internal static string ComputeSha256Hex(string path, CancellationToken cancellationToken)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[1024 * 1024];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                ThrowIfCancelled(cancellationToken);
                hash.AppendData(buffer, 0, read);
            }
            return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        }
        catch (AIModelPackageException) { throw; }
        catch (Exception ex) { throw MapFileSystemError(ex); }
    }

    private static bool MatchesInstalledStructure(string directory, AIModelPackageDescriptor descriptor)
    {
        var rootInfo = new DirectoryInfo(directory);
        if (!rootInfo.Exists || TempCleanup.IsReparsePoint(rootInfo)) return false;
        foreach (var entry in descriptor.Entries)
        {
            var itemPath = Path.Combine(directory, entry.Path.Replace('/', Path.DirectorySeparatorChar));
            if (entry.Kind == AIModelArchiveEntryKind.Directory)
            {
                var dir = new DirectoryInfo(itemPath);
                if (!dir.Exists || TempCleanup.IsReparsePoint(dir)) return false;
            }
            else
            {
                var file = new FileInfo(itemPath);
                if (!file.Exists || TempCleanup.IsReparsePoint(file)) return false;
                if ((ulong)Math.Max(0L, file.Length) != entry.Bytes) return false;
                if (WindowsFileIdentity.TryGetLinkCount(file.FullName, out var linkCount) && linkCount != 1)
                    return false;
            }
        }
        return true;
    }

    private static bool HasManifestFile(string directory)
    {
        var manifest = Path.Combine(directory, "manifest.json");
        return File.Exists(manifest);
    }

    private static void EnsureNoReparsePointsInPath(string rootDir, string path)
    {
        var rootFull = Path.GetFullPath(rootDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var current = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        while (!string.Equals(current, rootFull, StringComparison.OrdinalIgnoreCase))
        {
            var info = new DirectoryInfo(current);
            if (info.Exists && TempCleanup.IsReparsePoint(info))
                throw new AIModelPackageException(AIModelPackageErrorCode.MemberVerificationFailed, $"Reparse point detected along extraction path: {current}");
            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
    }

    private static string NearestExistingDirectory(string path)
    {
        var current = Path.GetFullPath(path);
        while (!Directory.Exists(current))
        {
            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
        return current;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceExW(
        string lpDirectoryName,
        out ulong lpFreeBytesAvailableToCaller,
        out ulong lpTotalNumberOfBytes,
        out ulong lpTotalNumberOfFreeBytes);

    internal static ulong VolumeAvailableBytes(string directory)
    {
        if (OperatingSystem.IsWindows())
        {
            if (GetDiskFreeSpaceExW(directory, out var available, out _, out _))
                return available;
        }
        var root = Path.GetPathRoot(Path.GetFullPath(directory));
        if (string.IsNullOrEmpty(root))
            throw new AIModelPackageException(AIModelPackageErrorCode.FileSystemError, "Unable to query available disk space");
        var drive = new DriveInfo(root);
        return (ulong)Math.Max(0L, drive.AvailableFreeSpace);
    }

    private static void DeleteDirectoryStrict(DirectoryInfo directory)
    {
        foreach (var entry in directory.GetFileSystemInfos())
        {
            if (TempCleanup.IsReparsePoint(entry))
            {
                if (entry is DirectoryInfo linkDir) linkDir.Delete(recursive: false);
                else entry.Delete();
                continue;
            }
            if (entry is DirectoryInfo subDir) DeleteDirectoryStrict(subDir);
            else
            {
                ClearReadOnlyAttribute(entry);
                entry.Delete();
            }
        }
        ClearReadOnlyAttribute(directory);
        directory.Delete(recursive: false);
    }

    private static void ClearReadOnlyAttribute(FileSystemInfo entry)
    {
        var attributes = entry.Attributes;
        if (attributes == (FileAttributes)(-1) || (attributes & FileAttributes.ReadOnly) == 0) return;
        var cleared = attributes & ~FileAttributes.ReadOnly;
        entry.Attributes = cleared == 0 ? FileAttributes.Normal : cleared;
    }

    private static void TryDeleteFileSafe(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return;
            if (!TempCleanup.IsReparsePoint(info)) ClearReadOnlyAttribute(info);
            info.Delete();
        }
        catch (Exception) { }
    }

    private static void TryDeleteDirectorySafe(string path)
    {
        if (!Directory.Exists(path)) return;
        TempCleanup.TryDeleteDirectoryTree(new DirectoryInfo(path));
    }

    private static void ThrowIfCancelled(CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
            throw new AIModelPackageException(AIModelPackageErrorCode.Cancelled);
    }

    private static bool IsDiskFull(Exception ex) =>
        ex is IOException && (ex.HResult == DiskFullHResult || ex.HResult == HandleDiskFullHResult);

    internal static AIModelPackageException MapFileSystemError(Exception ex)
    {
        if (ex is AIModelPackageException pkg) return pkg;
        if (IsDiskFull(ex)) return new AIModelPackageException(AIModelPackageErrorCode.DiskFull, innerException: ex);
        return new AIModelPackageException(AIModelPackageErrorCode.FileSystemError, ex.Message, innerException: ex);
    }

    private static AIModelPackageException MapNetworkError(HttpRequestException ex)
    {
        if (ex.HttpRequestError is HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError or HttpRequestError.ProxyTunnelError
            || ex.InnerException is SocketException)
            return new AIModelPackageException(AIModelPackageErrorCode.NetworkUnavailable, ex.Message, innerException: ex);
        return new AIModelPackageException(AIModelPackageErrorCode.NetworkError, ex.Message, innerException: ex);
    }
}
