using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal enum AIModelArchiveEntryKind
{
    File,
    Directory,
}

internal sealed record AIModelArchiveEntry(
    string Path,
    AIModelArchiveEntryKind Kind,
    ulong Bytes,
    string? Sha256 = null);

internal sealed record AIModelPackageDescriptor(
    int SchemaVersion,
    string Platform,
    string Url,
    string ArchiveName,
    string ArchiveSha256,
    ulong ArchiveBytes,
    string ManifestSha256,
    ulong UnpackedBytes,
    IReadOnlyList<AIModelArchiveEntry> Entries)
{
    internal Uri ValidateDownloadUri(bool allowLoopbackHttp = false)
    {
        if (string.IsNullOrWhiteSpace(Url) || !Uri.TryCreate(Url, UriKind.Absolute, out var parsed))
            throw new AIModelPackageException(AIModelPackageErrorCode.InsecureUrl);
        return ValidateUri(parsed, allowLoopbackHttp);
    }

    internal static Uri ValidateUri(Uri parsed, bool allowLoopbackHttp)
    {
        var scheme = parsed.Scheme.ToLowerInvariant();
        var host = parsed.Host;
        if (string.IsNullOrEmpty(host) || !string.IsNullOrEmpty(parsed.UserInfo))
            throw new AIModelPackageException(AIModelPackageErrorCode.InsecureUrl);
        if (scheme == "https") return parsed;
        if (allowLoopbackHttp && scheme == "http" && IsLoopbackHost(host)) return parsed;
        throw new AIModelPackageException(AIModelPackageErrorCode.InsecureUrl);
    }

    internal static bool IsLoopbackHost(string host)
    {
        var lower = host.ToLowerInvariant();
        return lower is "127.0.0.1" or "localhost" or "::1" or "[::1]";
    }

    internal void Validate(bool allowLoopbackHttp = false)
    {
        if (SchemaVersion != 1)
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Unsupported schemaVersion: {SchemaVersion}");
        if (string.IsNullOrEmpty(Platform))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Missing platform");
        _ = ValidateDownloadUri(allowLoopbackHttp);
        if (string.IsNullOrEmpty(ArchiveName) || ArchiveName.Contains('/') || ArchiveName.Contains('\\') ||
            ArchiveName is "." or "..")
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Invalid archiveName: {ArchiveName}");
        if (!IsValidSha256Hex(ArchiveSha256))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Invalid archiveSha256");
        if (!IsValidSha256Hex(ManifestSha256))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Invalid manifestSha256");
        if (ArchiveBytes == 0 || UnpackedBytes == 0 || Entries.Count == 0)
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Invalid sizes or empty entries");

        var seenExact = new HashSet<string>(StringComparer.Ordinal);
        var seenCaseInsensitive = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        ulong totalFileBytes = 0;
        AIModelArchiveEntry? manifestEntry = null;

        foreach (var entry in Entries)
        {
            if (!IsSafeRelativePath(entry.Path))
                throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Unsafe catalog entry path: {entry.Path}");
            if (!seenExact.Add(entry.Path))
                throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Duplicate catalog entry: {entry.Path}");
            if (!seenCaseInsensitive.Add(entry.Path))
                throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Case-colliding catalog entry: {entry.Path}");

            if (entry.Kind == AIModelArchiveEntryKind.Directory)
            {
                if (entry.Bytes != 0 || entry.Sha256 != null)
                    throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Invalid directory entry: {entry.Path}");
            }
            else
            {
                if (entry.Sha256 == null || !IsValidSha256Hex(entry.Sha256))
                    throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Missing or invalid file sha256: {entry.Path}");
                try { checked { totalFileBytes += entry.Bytes; } }
                catch (OverflowException)
                {
                    throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Unpacked byte count overflow");
                }
                if (entry.Path == "manifest.json") manifestEntry = entry;
            }
        }

        if (totalFileBytes != UnpackedBytes)
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Unpacked byte sum mismatch: {totalFileBytes} != {UnpackedBytes}");
        if (manifestEntry == null || !string.Equals(manifestEntry.Sha256, ManifestSha256, StringComparison.Ordinal))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, "Catalog manifest.json entry does not match manifestSha256");
    }

    internal static bool IsValidSha256Hex(string? value)
    {
        if (value == null || value.Length != 64) return false;
        foreach (var c in value)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    internal static bool IsSafeRelativePath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.StartsWith('/') || path.EndsWith('/') ||
            path.Contains('\\') || path.Contains(':'))
            return false;
        foreach (var ch in path)
        {
            if (ch < 0x20 || ch == 0x7F) return false;
        }
        var parts = path.Split('/');
        if (parts.Length == 0) return false;
        foreach (var part in parts)
        {
            if (part.Length == 0 || part is "." or "..") return false;
        }
        return true;
    }
}

internal sealed class AIModelCatalog
{
    internal const string MacOSArm64Platform = "macos-arm64";
    internal const string WindowsX64Platform = "windows-x64";

    internal int SchemaVersion { get; }
    internal IReadOnlyDictionary<string, AIModelPackageDescriptor> Platforms { get; }

    internal AIModelCatalog(int schemaVersion, IReadOnlyDictionary<string, AIModelPackageDescriptor> platforms)
    {
        SchemaVersion = schemaVersion;
        Platforms = platforms;
    }

    private sealed class CatalogDto
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; }
        [JsonPropertyName("platforms")] public Dictionary<string, DescriptorDto>? Platforms { get; set; }
    }

    private sealed class DescriptorDto
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; }
        [JsonPropertyName("platform")] public string? Platform { get; set; }
        [JsonPropertyName("url")] public string? Url { get; set; }
        [JsonPropertyName("archiveName")] public string? ArchiveName { get; set; }
        [JsonPropertyName("archiveSha256")] public string? ArchiveSha256 { get; set; }
        [JsonPropertyName("archiveBytes")] public ulong ArchiveBytes { get; set; }
        [JsonPropertyName("manifestSha256")] public string? ManifestSha256 { get; set; }
        [JsonPropertyName("unpackedBytes")] public ulong UnpackedBytes { get; set; }
        [JsonPropertyName("entries")] public List<EntryDto>? Entries { get; set; }
    }

    private sealed class EntryDto
    {
        [JsonPropertyName("path")] public string? Path { get; set; }
        [JsonPropertyName("kind")] public string? Kind { get; set; }
        [JsonPropertyName("bytes")] public ulong Bytes { get; set; }
        [JsonPropertyName("sha256")] public string? Sha256 { get; set; }
    }

    internal static AIModelCatalog Load(string path)
    {
        CatalogDto? dto;
        try
        {
            var json = File.ReadAllText(path);
            dto = JsonSerializer.Deserialize<CatalogDto>(json);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, ex.Message, innerException: ex);
        }
        if (dto == null || dto.SchemaVersion != 1 || dto.Platforms == null)
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Unsupported catalog schemaVersion: {dto?.SchemaVersion}");

        var platforms = new Dictionary<string, AIModelPackageDescriptor>(StringComparer.Ordinal);
        foreach (var (key, item) in dto.Platforms)
        {
            if (item == null)
                throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Null platform descriptor: {key}");
            var entries = new List<AIModelArchiveEntry>();
            if (item.Entries != null)
            {
                foreach (var entry in item.Entries)
                {
                    if (entry == null || string.IsNullOrEmpty(entry.Path))
                        throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Invalid entry in {key}");
                    var kind = entry.Kind switch
                    {
                        "file" => AIModelArchiveEntryKind.File,
                        "directory" => AIModelArchiveEntryKind.Directory,
                        _ => throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Unknown entry kind: {entry.Kind}")
                    };
                    entries.Add(new AIModelArchiveEntry(entry.Path, kind, entry.Bytes, entry.Sha256));
                }
            }
            platforms[key] = new AIModelPackageDescriptor(
                item.SchemaVersion,
                item.Platform ?? "",
                item.Url ?? "",
                item.ArchiveName ?? "",
                item.ArchiveSha256 ?? "",
                item.ArchiveBytes,
                item.ManifestSha256 ?? "",
                item.UnpackedBytes,
                entries);
        }
        return new AIModelCatalog(dto.SchemaVersion, platforms);
    }

    internal AIModelPackageDescriptor DescriptorFor(string platform, bool allowLoopbackHttp = false)
    {
        if (!Platforms.TryGetValue(platform, out var descriptor))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Missing platform descriptor: {platform}");
        if (!string.Equals(descriptor.Platform, platform, StringComparison.Ordinal))
            throw new AIModelPackageException(AIModelPackageErrorCode.InvalidCatalog, $"Platform key mismatch: {platform} != {descriptor.Platform}");
        descriptor.Validate(allowLoopbackHttp);
        return descriptor;
    }

    internal static AIModelPackageDescriptor? BundledDescriptor(
        string platform = WindowsX64Platform,
        string? baseDirectory = null,
        string? fallbackRepositoryPath = null)
    {
        var appBase = baseDirectory ?? AppContext.BaseDirectory;
        var candidates = new List<string>
        {
            Path.Combine(appBase, "ai-model-catalog.json"),
            Path.Combine(appBase, "ai-models", "catalog.json"),
        };
        if (!string.IsNullOrEmpty(fallbackRepositoryPath)) candidates.Add(fallbackRepositoryPath);
        candidates.Add(Path.Combine("Shared", "ai-models", "catalog.json"));

        foreach (var candidate in candidates)
        {
            if (!File.Exists(candidate)) continue;
            try
            {
                var catalog = Load(candidate);
                return catalog.DescriptorFor(platform, allowLoopbackHttp: false);
            }
            catch (AIModelPackageException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return null;
    }
}

internal enum AIModelDirectoryKind
{
    Override,
    Downloaded,
    Bundled,
}

internal sealed record AIModelDirectorySource(AIModelDirectoryKind Kind, string DirectoryPath);

internal enum AIModelPackageErrorCode
{
    InvalidCatalog,
    InsecureUrl,
    NetworkUnavailable,
    NetworkTimeout,
    HttpNotFound,
    HttpStatus,
    NetworkError,
    InsufficientDiskSpace,
    DiskFull,
    ArchiveSizeMismatch,
    ArchiveDigestMismatch,
    MemberVerificationFailed,
    ArchiveExtractionFailed,
    Cancelled,
    FileSystemError,
    RemoveFailed,
}

internal sealed class AIModelPackageException : Exception
{
    internal AIModelPackageErrorCode Code { get; }
    internal int? HttpStatusCode { get; }
    internal ulong? RequiredBytes { get; }
    internal ulong? AvailableBytes { get; }
    internal ulong? ExpectedBytes { get; }
    internal ulong? ActualBytes { get; }
    internal string? Detail { get; }

    internal AIModelPackageException(
        AIModelPackageErrorCode code,
        string? detail = null,
        int? httpStatusCode = null,
        ulong? requiredBytes = null,
        ulong? availableBytes = null,
        ulong? expectedBytes = null,
        ulong? actualBytes = null,
        Exception? innerException = null)
        : base(BuildMessage(code, detail, httpStatusCode, requiredBytes, expectedBytes, actualBytes), innerException)
    {
        Code = code;
        Detail = detail;
        HttpStatusCode = httpStatusCode;
        RequiredBytes = requiredBytes;
        AvailableBytes = availableBytes;
        ExpectedBytes = expectedBytes;
        ActualBytes = actualBytes;
    }

    internal string LocalizedMessage => Code switch
    {
        AIModelPackageErrorCode.NetworkUnavailable => Loc.Text("无法连接网络，请检查网络后重试。"),
        AIModelPackageErrorCode.NetworkTimeout => Loc.Text("下载超时，请检查网络后重试。"),
        AIModelPackageErrorCode.HttpNotFound => Loc.Text("服务器上暂未找到模型文件（HTTP 404），请稍后重试或更新应用。"),
        AIModelPackageErrorCode.HttpStatus => Loc.Format("下载失败（HTTP {0}），请稍后重试。", (HttpStatusCode ?? 0).ToString(CultureInfo.InvariantCulture)),
        AIModelPackageErrorCode.InsufficientDiskSpace => Loc.Format("磁盘可用空间不足，至少需要约 {0} MB。", FormatMegabytes(RequiredBytes ?? 0)),
        AIModelPackageErrorCode.DiskFull => Loc.Text("磁盘可用空间不足，请清理空间后重试。"),
        AIModelPackageErrorCode.ArchiveSizeMismatch => Loc.Text("下载的模型文件大小与校验信息不符，已清除临时文件，请重试。"),
        AIModelPackageErrorCode.ArchiveDigestMismatch => Loc.Text("下载的模型文件校验失败，已清除临时文件，请重试。"),
        AIModelPackageErrorCode.MemberVerificationFailed or AIModelPackageErrorCode.ArchiveExtractionFailed => Loc.Text("模型压缩包校验失败，已清除临时文件，请重试。"),
        AIModelPackageErrorCode.InsecureUrl => Loc.Text("模型下载地址不安全，已阻止下载。"),
        AIModelPackageErrorCode.Cancelled => Loc.Text("已取消下载 AI 降噪模型。"),
        AIModelPackageErrorCode.RemoveFailed => Loc.Text("无法删除已下载的模型文件，请重试。"),
        _ => Loc.Text("下载或安装模型失败，请重试。"),
    };

    internal static string FormatMegabytes(ulong bytes)
    {
        var mb = Math.Max(1UL, (bytes + 500_000UL) / 1_000_000UL);
        return mb.ToString(CultureInfo.InvariantCulture);
    }

    internal static string FormatProgressMegabytes(ulong bytes)
    {
        var mb = (bytes + 500_000UL) / 1_000_000UL;
        return mb.ToString(CultureInfo.InvariantCulture);
    }

    private static string BuildMessage(
        AIModelPackageErrorCode code,
        string? detail,
        int? httpStatusCode,
        ulong? requiredBytes,
        ulong? expectedBytes,
        ulong? actualBytes) => code switch
    {
        AIModelPackageErrorCode.NetworkUnavailable => "Network unavailable",
        AIModelPackageErrorCode.NetworkTimeout => "Download timed out",
        AIModelPackageErrorCode.HttpNotFound => "Model archive not found (HTTP 404)",
        AIModelPackageErrorCode.HttpStatus => $"Download failed (HTTP {httpStatusCode ?? 0})",
        AIModelPackageErrorCode.InsufficientDiskSpace => $"Insufficient free disk space (requires ~{FormatMegabytes(requiredBytes ?? 0)} MB)",
        AIModelPackageErrorCode.DiskFull => "Disk is full",
        AIModelPackageErrorCode.ArchiveSizeMismatch => $"Archive size mismatch ({actualBytes ?? 0} != {expectedBytes ?? 0})",
        AIModelPackageErrorCode.ArchiveDigestMismatch => "Archive SHA-256 mismatch",
        AIModelPackageErrorCode.MemberVerificationFailed => $"Archive member verification failed: {detail}",
        AIModelPackageErrorCode.ArchiveExtractionFailed => $"Archive extraction failed: {detail}",
        AIModelPackageErrorCode.InsecureUrl => "Insecure model download URL",
        AIModelPackageErrorCode.Cancelled => "Model download cancelled",
        AIModelPackageErrorCode.RemoveFailed => $"Failed to remove model package: {detail}",
        AIModelPackageErrorCode.InvalidCatalog => $"Invalid model catalog: {detail}",
        AIModelPackageErrorCode.NetworkError => $"Network error: {detail}",
        AIModelPackageErrorCode.FileSystemError => $"File system error: {detail}",
        _ => detail ?? code.ToString(),
    };
}

internal enum AIModelPackageStatus
{
    Unavailable,
    NotInstalled,
    Downloading,
    Verifying,
    Installing,
    Cancelled,
    Failed,
    Installed,
}

internal sealed record AIModelPackageState(
    AIModelPackageStatus Status,
    ulong CompletedBytes = 0,
    ulong DownloadBytes = 0,
    ulong UnpackedBytes = 0,
    AIModelDirectorySource? InstalledSource = null,
    AIModelPackageException? Error = null)
{
    internal bool IsBusy => Status is AIModelPackageStatus.Downloading or AIModelPackageStatus.Verifying or AIModelPackageStatus.Installing;
    internal bool IsInstalled => Status == AIModelPackageStatus.Installed;
    internal bool IsDownloadedInstalled => Status == AIModelPackageStatus.Installed && InstalledSource?.Kind == AIModelDirectoryKind.Downloaded;

    internal static AIModelPackageState Unavailable() => new(AIModelPackageStatus.Unavailable);
    internal static AIModelPackageState NotInstalled(ulong downloadBytes, ulong unpackedBytes) =>
        new(AIModelPackageStatus.NotInstalled, DownloadBytes: downloadBytes, UnpackedBytes: unpackedBytes);
    internal static AIModelPackageState Downloading(ulong completedBytes, ulong totalBytes, ulong unpackedBytes = 0) =>
        new(AIModelPackageStatus.Downloading, CompletedBytes: completedBytes, DownloadBytes: totalBytes, UnpackedBytes: unpackedBytes);
    internal static AIModelPackageState Verifying(ulong downloadBytes = 0, ulong unpackedBytes = 0) =>
        new(AIModelPackageStatus.Verifying, DownloadBytes: downloadBytes, UnpackedBytes: unpackedBytes);
    internal static AIModelPackageState Installing(ulong downloadBytes = 0, ulong unpackedBytes = 0) =>
        new(AIModelPackageStatus.Installing, DownloadBytes: downloadBytes, UnpackedBytes: unpackedBytes);
    internal static AIModelPackageState Cancelled(ulong downloadBytes, ulong unpackedBytes) =>
        new(AIModelPackageStatus.Cancelled, DownloadBytes: downloadBytes, UnpackedBytes: unpackedBytes);
    internal static AIModelPackageState Failed(AIModelPackageException error, ulong downloadBytes, ulong unpackedBytes) =>
        new(AIModelPackageStatus.Failed, DownloadBytes: downloadBytes, UnpackedBytes: unpackedBytes, Error: error);
    internal static AIModelPackageState Installed(AIModelDirectorySource source, ulong unpackedBytes) =>
        new(AIModelPackageStatus.Installed, UnpackedBytes: unpackedBytes, InstalledSource: source);
}

internal enum AIModelInstallPhaseKind
{
    Downloading,
    Verifying,
    Installing,
}

internal readonly record struct AIModelInstallPhase(
    AIModelInstallPhaseKind Kind,
    ulong CompletedBytes = 0,
    ulong TotalBytes = 0);
