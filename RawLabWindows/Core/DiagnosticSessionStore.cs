using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

public enum DiagnosticUploadFailure
{
    Empty,
    PayloadTooLarge,
    Unavailable,
}

public sealed class DiagnosticUploadException(DiagnosticUploadFailure reason) : Exception(reason.ToString())
{
    public DiagnosticUploadFailure Reason { get; } = reason;
}

public interface IDiagnosticUploadTransport
{
    Task UploadAsync(Uri endpoint, byte[] body, CancellationToken cancellationToken = default);
}

public sealed class HttpClientDiagnosticUploadTransport : IDiagnosticUploadTransport
{
    private static readonly HttpClient SharedClient = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(15),
    })
    {
        Timeout = TimeSpan.FromSeconds(20),
    };

    public async Task UploadAsync(Uri endpoint, byte[] body, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new ByteArrayContent(body),
        };
        request.Content.Headers.ContentType = new("application/json") { CharSet = "UTF-8" };
        request.Headers.TryAddWithoutValidation("x-log-apiversion", "0.6.0");
        request.Headers.TryAddWithoutValidation("x-log-bodyrawsize", body.Length.ToString());
        HttpResponseMessage response;
        try
        {
            response = await SharedClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            throw new DiagnosticUploadException(DiagnosticUploadFailure.Unavailable);
        }
        using (response)
        {
            if ((int)response.StatusCode is < 200 or >= 300)
            {
                throw new DiagnosticUploadException(DiagnosticUploadFailure.Unavailable);
            }
        }
    }
}

public sealed record DiagnosticReportPackage(
    string ReportId,
    string ManifestJson,
    string BreadcrumbsJsonl,
    string RecentErrorsJson,
    string ReadmeText,
    int BreadcrumbCount,
    int DroppedBreadcrumbs,
    string? UserNote)
{
    public byte[] ToZipBytes()
    {
        using var buffer = new MemoryStream();
        WriteZipTo(buffer);
        return buffer.ToArray();
    }

    public void ExportZip(string destinationPath)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(destinationPath));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var temporary = destinationPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                WriteZipTo(stream);
            }
            File.Move(temporary, destinationPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private void WriteZipTo(Stream output)
    {
        using var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
        void Add(string name, string text)
        {
            var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
            entry.LastWriteTime = new DateTimeOffset(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);
            using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
            writer.Write(text);
        }
        Add("manifest.json", ManifestJson);
        Add("breadcrumbs.jsonl", BreadcrumbsJsonl);
        Add("recent-errors.json", RecentErrorsJson);
        Add("README.txt", ReadmeText);
    }

    public string PreviewText
    {
        get
        {
            var truncated = BreadcrumbsJsonl.Length > 32_768
                ? BreadcrumbsJsonl[..32_768] + "\n... [preview truncated]"
                : string.IsNullOrEmpty(BreadcrumbsJsonl) ? "(empty)" : BreadcrumbsJsonl;
            return $"=== manifest.json ===\n{ManifestJson}\n=== recent-errors.json ===\n{RecentErrorsJson}\n" +
                   $"=== breadcrumbs.jsonl ({BreadcrumbCount} entries, dropped {DroppedBreadcrumbs}) ===\n{truncated}";
        }
    }
}

public static class SLSDiagnosticWebTracking
{
    public const string ProductionUrl =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/logstores/logstore-diagnostics/track";
    private const int MaxChunkBytes = 200_000;
    private const int MaxBodyBytes = 950_000;
    private static readonly Regex LogstoreRegex = new(@"^[a-z0-9][a-z0-9_-]{1,62}$", RegexOptions.Compiled);
    private static readonly Regex ReportIdRegex = new(@"^RL-\d{8}-[0-9A-F]{8}$", RegexOptions.Compiled);

    public static string GenerateReportId(DateTimeOffset now) =>
        $"RL-{now.UtcDateTime:yyyyMMdd}-{Guid.NewGuid().ToString("N")[..8].ToUpperInvariant()}";

    public static bool IsValidReportId(string? id) => !string.IsNullOrEmpty(id) && ReportIdRegex.IsMatch(id);

    public static Uri ValidateEndpoint(string? raw, bool allowLoopback = false)
    {
        var target = string.IsNullOrWhiteSpace(raw) ? ProductionUrl : raw.Trim();
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new DiagnosticUploadException(DiagnosticUploadFailure.Unavailable);
        }
        var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 3 || segments[0] != "logstores" || segments[2] != "track" || !LogstoreRegex.IsMatch(segments[1]))
        {
            throw new DiagnosticUploadException(DiagnosticUploadFailure.Unavailable);
        }
        var host = uri.Host.ToLowerInvariant();
        if (allowLoopback && uri.Scheme == "http" && (host == "127.0.0.1" || host == "localhost"))
        {
            return uri;
        }
        if (uri.Scheme != "https" || (!uri.IsDefaultPort && uri.Port != 443) ||
            !host.EndsWith(".log.aliyuncs.com", StringComparison.Ordinal) ||
            host.Length <= ".log.aliyuncs.com".Length)
        {
            throw new DiagnosticUploadException(DiagnosticUploadFailure.Unavailable);
        }
        return uri;
    }

    public static byte[] BuildPayload(
        DiagnosticReportPackage report,
        string appVersion,
        string build,
        string osVersion,
        string deviceModel)
    {
        var chunks = SplitLines(report.BreadcrumbsJsonl, MaxChunkBytes, 4);
        if (chunks.Count == 0) chunks.Add("");
        var logs = new JsonArray();
        for (var i = 0; i < chunks.Count; i++)
        {
            var item = new JsonObject
            {
                ["report_id"] = report.ReportId,
                ["schema_version"] = "1",
                ["platform"] = "windows",
                ["app_version"] = appVersion,
                ["build"] = build,
                ["os_version"] = osVersion,
                ["device_model"] = deviceModel,
                ["chunk_index"] = i.ToString(),
                ["chunk_count"] = chunks.Count.ToString(),
                ["breadcrumbs_jsonl"] = chunks[i],
            };
            if (i == 0)
            {
                item["manifest_json"] = report.ManifestJson;
                item["recent_errors_json"] = report.RecentErrorsJson;
                if (!string.IsNullOrEmpty(report.UserNote))
                {
                    item["user_note"] = report.UserNote;
                }
            }
            logs.Add(item);
        }
        var envelope = new JsonObject
        {
            ["__topic__"] = "rawlab-diagnostic-v1",
            ["__source__"] = "windows",
            ["__tags__"] = new JsonObject
            {
                ["platform"] = "windows",
                ["app_version"] = appVersion,
            },
            ["__logs__"] = logs,
        };
        var bytes = Encoding.UTF8.GetBytes(envelope.ToJsonString());
        if (bytes.Length > MaxBodyBytes)
        {
            throw new DiagnosticUploadException(DiagnosticUploadFailure.PayloadTooLarge);
        }
        return bytes;
    }

    private static List<string> SplitLines(string text, int maxBytes, int maxChunks)
    {
        var chunks = new List<string>();
        if (string.IsNullOrEmpty(text)) return chunks;
        var current = new List<string>();
        var currentBytes = 0;
        foreach (var line in text.Split('\n'))
        {
            var lineBytes = Encoding.UTF8.GetByteCount(line) + 1;
            if (current.Count > 0 && currentBytes + lineBytes > maxBytes)
            {
                chunks.Add(string.Join("\n", current));
                current.Clear();
                currentBytes = 0;
                if (chunks.Count >= maxChunks) break;
            }
            if (lineBytes <= maxBytes)
            {
                current.Add(line);
                currentBytes += lineBytes;
            }
        }
        if (current.Count > 0 && chunks.Count < maxChunks)
        {
            var tail = string.Join("\n", current);
            if (!string.IsNullOrEmpty(tail)) chunks.Add(tail);
        }
        return chunks;
    }
}

public sealed class DiagnosticSessionStore
{
    public static readonly TimeSpan DefaultLeaseDuration = TimeSpan.FromMinutes(30);
    public const int MaxBreadcrumbs = 500;
    public const int MaxBreadcrumbBytes = 450_000;
    public const int MaxRecentErrors = 64;
    private const int PreservedHeadCount = 10;

    private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "3fr", "arq", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "heic", "heif",
        "iiq", "jpeg", "jpg", "kdc", "mos", "mrw", "nef", "nrw", "orf", "pef", "png", "raf", "raw",
        "rw2", "rwl", "sr2", "srf", "srw", "tif", "tiff", "x3f",
    };

    private static readonly Regex FileUriRegex = new(@"(?i)(?:file|content)://[^\s""'<>()\[\]{}]+", RegexOptions.Compiled);
    private static readonly Regex WindowsPathRegex = new(@"(?i)(?:[a-z]:[\\/]|\\\\)[^\s""'<>()\[\]{}]+", RegexOptions.Compiled);
    private static readonly Regex PosixPathRegex = new(@"/(?:Users|home|private/var|var/mobile|var/folders|tmp|Volumes|data/user|storage/emulated)/[^\s""'<>()\[\]{}]+", RegexOptions.Compiled);
    private static readonly Regex UnsafeIdRegex = new(@"[^A-Za-z0-9._-]", RegexOptions.Compiled);

    public sealed record Snapshot(
        bool IsRecording,
        DateTimeOffset? ExpiresAt,
        string? SessionId,
        int BreadcrumbCount,
        int RecentErrorCount,
        bool RecoveredPreviousSession)
    {
        public bool HasExportableLogs => BreadcrumbCount > 0 || RecentErrorCount > 0;
    }

    private sealed record BreadcrumbEntry(
        string Timestamp,
        int Seq,
        string Level,
        string Category,
        string Stage,
        string Message,
        Dictionary<string, string> Context);

    private sealed record ErrorEntry(
        string Timestamp,
        string Operation,
        string Stage,
        string ErrorType,
        string Message,
        Dictionary<string, string> Context);

    internal static DiagnosticSessionStore Default => new(AppPaths.Default.DiagnosticsDirectory);

    public string DirectoryPath { get; }
    private readonly TimeSpan leaseDuration;
    private readonly Func<DateTimeOffset> clock;
    private readonly object gate = new();
    private long fastActiveUntilTicks;

    private bool loaded;
    private string? sessionId;
    private DateTimeOffset? startedAt;
    private DateTimeOffset? expiresAt;
    private int remainingLaunches;
    private int droppedBreadcrumbs;
    private int nextSeq = 1;
    private bool recoveredPreviousSession;
    private readonly List<BreadcrumbEntry> breadcrumbs = [];
    private readonly List<ErrorEntry> recentErrors = [];

    public DiagnosticSessionStore(
        string directory,
        TimeSpan? leaseDuration = null,
        Func<DateTimeOffset>? clock = null)
    {
        DirectoryPath = Path.GetFullPath(directory);
        this.leaseDuration = leaseDuration ?? DefaultLeaseDuration;
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    private string LeasePath => Path.Combine(DirectoryPath, "recording-lease.json");
    private string MetaPath => Path.Combine(DirectoryPath, "session-meta.json");
    private string BreadcrumbsPath => Path.Combine(DirectoryPath, "session-active.jsonl");
    private string ErrorsPath => Path.Combine(DirectoryPath, "errors.json");

    public bool IsRecording
    {
        get
        {
            var until = Interlocked.Read(ref fastActiveUntilTicks);
            return until > 0 && clock().UtcTicks < until;
        }
    }

    public Snapshot ResumeOnLaunch()
    {
        lock (gate)
        {
            EnsureLoadedLocked();
            var now = clock();
            var lease = ReadLeaseLocked();
            if (lease is { } active && now < active.ExpiresAt && active.RemainingLaunches > 0)
            {
                sessionId = active.SessionId;
                startedAt = active.StartedAt;
                expiresAt = active.ExpiresAt;
                remainingLaunches = active.RemainingLaunches - 1;
                WriteLeaseLocked(active with { RemainingLaunches = remainingLaunches });
                Interlocked.Exchange(ref fastActiveUntilTicks, active.ExpiresAt.UtcTicks);
                AppendBreadcrumbLocked(
                    "info",
                    "lifecycle",
                    "relaunch",
                    "Diagnostic recording resumed across launch",
                    new() { ["remainingLaunches"] = remainingLaunches.ToString() },
                    now);
            }
            else
            {
                if (lease != null)
                {
                    TryDelete(LeasePath);
                    if (breadcrumbs.Count > 0) recoveredPreviousSession = true;
                }
                else if (breadcrumbs.Count > 0)
                {
                    recoveredPreviousSession = true;
                }
                expiresAt = null;
                remainingLaunches = 0;
                Interlocked.Exchange(ref fastActiveUntilTicks, 0);
            }
            return SnapshotLocked(now);
        }
    }

    public Snapshot SetRecordingEnabled(bool enabled)
    {
        lock (gate)
        {
            EnsureLoadedLocked();
            var now = clock();
            if (enabled)
            {
                var freshId = SLSDiagnosticWebTracking.GenerateReportId(now);
                var until = now + leaseDuration;
                sessionId = freshId;
                startedAt = now;
                expiresAt = until;
                remainingLaunches = 1;
                droppedBreadcrumbs = 0;
                breadcrumbs.Clear();
                nextSeq = 1;
                recoveredPreviousSession = false;
                WriteLeaseLocked(new(freshId, now, until, 1));
                Interlocked.Exchange(ref fastActiveUntilTicks, until.UtcTicks);
                var (appVersion, build, osVersion, deviceModel) = EnvironmentSummary();
                AppendBreadcrumbLocked(
                    "info",
                    "lifecycle",
                    "recordingStarted",
                    "User enabled diagnostic recording",
                    new()
                    {
                        ["platform"] = "windows",
                        ["appVersion"] = appVersion,
                        ["build"] = build,
                        ["osVersion"] = osVersion,
                        ["deviceModel"] = deviceModel,
                    },
                    now);
            }
            else
            {
                if (expiresAt != null)
                {
                    AppendBreadcrumbLocked("info", "lifecycle", "recordingStopped", "User stopped diagnostic recording", [], now);
                }
                expiresAt = null;
                remainingLaunches = 0;
                Interlocked.Exchange(ref fastActiveUntilTicks, 0);
                TryDelete(LeasePath);
            }
            return SnapshotLocked(now);
        }
    }

    public void RecordBreadcrumb(
        string category,
        string stage,
        string message,
        Dictionary<string, string>? context = null,
        string level = "info")
    {
        var until = Interlocked.Read(ref fastActiveUntilTicks);
        if (until <= 0) return;
        var now = clock();
        if (now.UtcTicks >= until)
        {
            lock (gate) { EnsureLoadedLocked(); ExpireIfNeededLocked(now); }
            return;
        }
        var safeCategory = CleanIdentifier(category, "general");
        var safeStage = CleanIdentifier(stage, "step");
        var safeMessage = CleanText(message, 512);
        var safeContext = CleanContext(context);
        lock (gate)
        {
            EnsureLoadedLocked();
            ExpireIfNeededLocked(now);
            if (expiresAt == null) return;
            AppendBreadcrumbLocked(level, safeCategory, safeStage, safeMessage, safeContext, now);
        }
    }

    public void RecordError(
        string operation,
        string stage,
        Exception error,
        Dictionary<string, string>? context = null)
    {
        if (error is OperationCanceledException) return;
        var now = clock();
        var safeOp = CleanIdentifier(operation, "editor");
        var safeStage = CleanIdentifier(stage, "failure");
        var safeType = CleanIdentifier(error.GetType().FullName ?? error.GetType().Name, "Exception");
        var safeMsg = CleanText(error.Message, 512);
        var safeCtx = CleanContext(context);
        lock (gate)
        {
            EnsureLoadedLocked();
            ExpireIfNeededLocked(now);
            recentErrors.Add(new(now.UtcDateTime.ToString("O"), safeOp, safeStage, safeType, safeMsg, safeCtx));
            while (recentErrors.Count > MaxRecentErrors) recentErrors.RemoveAt(0);
            PersistErrorsLocked();
            if (expiresAt != null)
            {
                AppendBreadcrumbLocked("error", safeOp, safeStage, $"{safeType}: {safeMsg}", safeCtx, now);
            }
        }
    }

    public Snapshot GetSnapshot()
    {
        lock (gate)
        {
            EnsureLoadedLocked();
            var now = clock();
            ExpireIfNeededLocked(now);
            return SnapshotLocked(now);
        }
    }

    public DiagnosticReportPackage BuildReportPackage(string? userNote = null, bool stopActiveRecording = false)
    {
        lock (gate)
        {
            EnsureLoadedLocked();
            var now = clock();
            ExpireIfNeededLocked(now);
            if (stopActiveRecording && expiresAt != null)
            {
                AppendBreadcrumbLocked("info", "lifecycle", "recordingSealedForReport", "Diagnostic recording sealed for export/upload", [], now);
                expiresAt = null;
                remainingLaunches = 0;
                Interlocked.Exchange(ref fastActiveUntilTicks, 0);
                TryDelete(LeasePath);
            }
            if (breadcrumbs.Count == 0 && recentErrors.Count == 0)
            {
                throw new DiagnosticUploadException(DiagnosticUploadFailure.Empty);
            }
            var reportId = SLSDiagnosticWebTracking.IsValidReportId(sessionId)
                ? sessionId!
                : SLSDiagnosticWebTracking.GenerateReportId(now);
            var cleanedNote = CleanUserNote(userNote);
            var (appVersion, build, osVersion, deviceModel) = EnvironmentSummary();
            var manifest = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["reportID"] = reportId,
                ["createdAt"] = now.UtcDateTime.ToString("O"),
                ["environment"] = new JsonObject
                {
                    ["platform"] = "windows",
                    ["appVersion"] = appVersion,
                    ["build"] = build,
                    ["osVersion"] = osVersion,
                    ["deviceModel"] = deviceModel,
                },
                ["recordingActive"] = expiresAt != null,
                ["breadcrumbCount"] = breadcrumbs.Count,
                ["droppedBreadcrumbs"] = droppedBreadcrumbs,
                ["recentErrorCount"] = recentErrors.Count,
            };
            if (startedAt is { } start) manifest["sessionStartedAt"] = start.UtcDateTime.ToString("O");
            if (!string.IsNullOrEmpty(cleanedNote)) manifest["userNote"] = cleanedNote;

            var manifestJson = manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            var breadcrumbsJsonl = EncodeBreadcrumbsLocked();
            var recentErrorsJson = EncodeErrorsLocked().ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            var readme =
                $"RawLab Diagnostic Package ({reportId})\n" +
                "========================================\n" +
                "Contents:\n" +
                "- manifest.json: App/OS/device environment summary and report metadata.\n" +
                "- breadcrumbs.jsonl: Redacted step-by-step runtime events recorded while diagnostic logging was enabled.\n" +
                "- recent-errors.json: Bounded recent error codes and stages.\n\n" +
                "Privacy Notice:\n" +
                "Photo pixels, thumbnails, original file names, personal folder paths, EXIF GPS/serials, and AI prompts/keys are excluded.\n";

            return new DiagnosticReportPackage(
                reportId,
                manifestJson,
                breadcrumbsJsonl,
                recentErrorsJson,
                readme,
                breadcrumbs.Count,
                droppedBreadcrumbs,
                cleanedNote);
        }
    }

    public async Task<string> UploadAsync(
        string? userNote = null,
        IDiagnosticUploadTransport? transport = null,
        Uri? endpointOverride = null,
        CancellationToken cancellationToken = default)
    {
        var package = await Task.Run(() => BuildReportPackage(userNote, stopActiveRecording: true), cancellationToken).ConfigureAwait(false);
        var (appVersion, build, osVersion, deviceModel) = EnvironmentSummary();
        var body = SLSDiagnosticWebTracking.BuildPayload(package, appVersion, build, osVersion, deviceModel);
        var endpoint = endpointOverride ?? SLSDiagnosticWebTracking.ValidateEndpoint(
            Environment.GetEnvironmentVariable("RAWLAB_DIAGNOSTIC_UPLOAD_URL"));
        var sender = transport ?? new HttpClientDiagnosticUploadTransport();
        await sender.UploadAsync(endpoint, body, cancellationToken).ConfigureAwait(false);
        return package.ReportId;
    }

    public Snapshot ClearAll()
    {
        lock (gate)
        {
            EnsureLoadedLocked();
            sessionId = null;
            startedAt = null;
            expiresAt = null;
            remainingLaunches = 0;
            droppedBreadcrumbs = 0;
            nextSeq = 1;
            recoveredPreviousSession = false;
            breadcrumbs.Clear();
            recentErrors.Clear();
            Interlocked.Exchange(ref fastActiveUntilTicks, 0);
            TryDelete(LeasePath);
            TryDelete(MetaPath);
            TryDelete(BreadcrumbsPath);
            TryDelete(ErrorsPath);
            return SnapshotLocked(clock());
        }
    }

    public static string CleanText(string? input, int maxLength = 512)
    {
        if (string.IsNullOrEmpty(input)) return "";
        var text = input;
        var replacements = new (string Path, string Token)[]
        {
            (Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "<user>"),
            (Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "<localappdata>"),
            (AppContext.BaseDirectory, "<app>"),
            (Path.GetTempPath(), "<temp>"),
        };
        foreach (var (path, token) in replacements.Where(p => !string.IsNullOrWhiteSpace(p.Path) && p.Path.Length > 2)
                     .OrderByDescending(p => p.Path.Length))
        {
            text = text.Replace(path, token, StringComparison.OrdinalIgnoreCase)
                .Replace(path.Replace('\\', '/'), token, StringComparison.OrdinalIgnoreCase);
        }
        text = FileUriRegex.Replace(text, "<uri>");
        text = WindowsPathRegex.Replace(text, "<path>");
        text = PosixPathRegex.Replace(text, "<path>");
        return text.Length > maxLength ? text[..maxLength] + " [truncated]" : text;
    }

    public static string? CleanUserNote(string? note)
    {
        var trimmed = note?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : CleanText(trimmed, 200);
    }

    private static string CleanIdentifier(string? value, string fallback)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return fallback;
        var cut = trimmed.Length > 64 ? trimmed[..64] : trimmed;
        var safe = UnsafeIdRegex.Replace(cut, "_");
        return string.IsNullOrEmpty(safe) ? fallback : safe;
    }

    private static Dictionary<string, string> CleanContext(Dictionary<string, string>? raw)
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        if (raw == null) return output;
        foreach (var key in raw.Keys.OrderBy(k => k, StringComparer.Ordinal).Take(24))
        {
            var value = raw[key];
            var safeKey = CleanIdentifier(key, "key");
            if (safeKey == "extension")
            {
                var ext = (value ?? "").Trim().TrimStart('.').ToLowerInvariant();
                output[safeKey] = AllowedExtensions.Contains(ext) ? ext : "unknown";
            }
            else
            {
                output[safeKey] = CleanText(value, 256);
            }
        }
        return output;
    }

    private static (string AppVersion, string Build, string OsVersion, string DeviceModel) EnvironmentSummary()
    {
        var asm = typeof(DiagnosticSessionStore).Assembly;
        var version = asm.GetName().Version;
        var appVersion = version?.ToString(3) ?? "0.12.1";
        var build = version?.Revision > 0 ? version.Revision.ToString() : "24";
        var osVersion = Environment.OSVersion.Version.ToString();
        var arch = RuntimeInformation.OSArchitecture.ToString();
        return (appVersion, build, osVersion, CleanIdentifier(arch, "x64"));
    }

    private sealed record LeaseRecord(string SessionId, DateTimeOffset StartedAt, DateTimeOffset ExpiresAt, int RemainingLaunches);

    private void EnsureLoadedLocked()
    {
        if (loaded) return;
        loaded = true;
        try
        {
            if (File.Exists(MetaPath) && JsonNode.Parse(File.ReadAllText(MetaPath)) is JsonObject meta &&
                (int?)meta["schemaVersion"] == 1)
            {
                sessionId = (string?)meta["sessionID"];
                if (DateTimeOffset.TryParse((string?)meta["startedAt"], out var parsedStart)) startedAt = parsedStart;
                droppedBreadcrumbs = (int?)meta["droppedBreadcrumbs"] ?? 0;
            }
        }
        catch { }

        try
        {
            if (File.Exists(BreadcrumbsPath))
            {
                foreach (var line in File.ReadLines(BreadcrumbsPath, Encoding.UTF8))
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    if (JsonNode.Parse(line) is not JsonObject obj) continue;
                    var ctx = new Dictionary<string, string>(StringComparer.Ordinal);
                    if (obj["context"] is JsonObject ctxObj)
                    {
                        foreach (var pair in ctxObj) ctx[pair.Key] = (string?)pair.Value ?? "";
                    }
                    breadcrumbs.Add(new(
                        (string?)obj["timestamp"] ?? "",
                        (int?)obj["seq"] ?? 0,
                        (string?)obj["level"] ?? "info",
                        (string?)obj["category"] ?? "general",
                        (string?)obj["stage"] ?? "step",
                        (string?)obj["message"] ?? "",
                        ctx));
                }
                nextSeq = (breadcrumbs.Count > 0 ? breadcrumbs[^1].Seq : 0) + 1;
            }
        }
        catch { }

        try
        {
            if (File.Exists(ErrorsPath) && JsonNode.Parse(File.ReadAllText(ErrorsPath)) is JsonObject errRoot &&
                (int?)errRoot["schemaVersion"] == 1 && errRoot["events"] is JsonArray arr)
            {
                foreach (var node in arr)
                {
                    if (node is not JsonObject item) continue;
                    var ctx = new Dictionary<string, string>(StringComparer.Ordinal);
                    if (item["context"] is JsonObject ctxObj)
                    {
                        foreach (var pair in ctxObj) ctx[pair.Key] = (string?)pair.Value ?? "";
                    }
                    recentErrors.Add(new(
                        (string?)item["timestamp"] ?? "",
                        (string?)item["operation"] ?? "editor",
                        (string?)item["stage"] ?? "failure",
                        (string?)item["errorType"] ?? "Exception",
                        (string?)item["message"] ?? "",
                        ctx));
                }
            }
        }
        catch { }
    }

    private void ExpireIfNeededLocked(DateTimeOffset now)
    {
        if (expiresAt is not { } until || now < until) return;
        AppendBreadcrumbLocked("info", "lifecycle", "leaseExpired", "Diagnostic recording automatically stopped after lease window", [], now);
        expiresAt = null;
        remainingLaunches = 0;
        Interlocked.Exchange(ref fastActiveUntilTicks, 0);
        TryDelete(LeasePath);
    }

    private void AppendBreadcrumbLocked(
        string level,
        string category,
        string stage,
        string message,
        Dictionary<string, string> context,
        DateTimeOffset now)
    {
        breadcrumbs.Add(new(now.UtcDateTime.ToString("O"), nextSeq++, level, category, stage, message, context));
        TrimBreadcrumbsLocked();
        PersistSessionLocked();
    }

    private void TrimBreadcrumbsLocked()
    {
        var dropped = 0;
        while (breadcrumbs.Count > MaxBreadcrumbs)
        {
            var idx = Math.Min(PreservedHeadCount, breadcrumbs.Count - 1);
            breadcrumbs.RemoveAt(idx);
            dropped++;
        }
        while (breadcrumbs.Count > PreservedHeadCount + 1 &&
               Encoding.UTF8.GetByteCount(EncodeBreadcrumbsLocked()) > MaxBreadcrumbBytes)
        {
            breadcrumbs.RemoveAt(PreservedHeadCount);
            dropped++;
        }
        if (dropped > 0) droppedBreadcrumbs += dropped;
    }

    private string EncodeBreadcrumbsLocked()
    {
        if (breadcrumbs.Count == 0) return "";
        var sb = new StringBuilder();
        foreach (var entry in breadcrumbs)
        {
            var ctx = new JsonObject();
            foreach (var kv in entry.Context) ctx[kv.Key] = kv.Value;
            var obj = new JsonObject
            {
                ["timestamp"] = entry.Timestamp,
                ["seq"] = entry.Seq,
                ["level"] = entry.Level,
                ["category"] = entry.Category,
                ["stage"] = entry.Stage,
                ["message"] = entry.Message,
                ["context"] = ctx,
            };
            sb.Append(obj.ToJsonString());
            sb.Append('\n');
        }
        return sb.ToString();
    }

    private JsonObject EncodeErrorsLocked()
    {
        var arr = new JsonArray();
        foreach (var err in recentErrors)
        {
            var ctx = new JsonObject();
            foreach (var kv in err.Context) ctx[kv.Key] = kv.Value;
            arr.Add(new JsonObject
            {
                ["timestamp"] = err.Timestamp,
                ["operation"] = err.Operation,
                ["stage"] = err.Stage,
                ["errorType"] = err.ErrorType,
                ["message"] = err.Message,
                ["context"] = ctx,
            });
        }
        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["events"] = arr,
        };
    }

    private void PersistSessionLocked()
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            WriteAtomicText(BreadcrumbsPath, EncodeBreadcrumbsLocked());
            var meta = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["droppedBreadcrumbs"] = droppedBreadcrumbs,
            };
            if (sessionId != null) meta["sessionID"] = sessionId;
            if (startedAt is { } s) meta["startedAt"] = s.UtcDateTime.ToString("O");
            AtomicJson.Write(MetaPath, meta);
        }
        catch { }
    }

    private void PersistErrorsLocked()
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            AtomicJson.Write(ErrorsPath, EncodeErrorsLocked());
        }
        catch { }
    }

    private LeaseRecord? ReadLeaseLocked()
    {
        try
        {
            if (!File.Exists(LeasePath) || JsonNode.Parse(File.ReadAllText(LeasePath)) is not JsonObject obj ||
                (int?)obj["schemaVersion"] != 1)
                return null;
            var sid = (string?)obj["sessionID"];
            if (string.IsNullOrEmpty(sid) ||
                !DateTimeOffset.TryParse((string?)obj["startedAt"], out var started) ||
                !DateTimeOffset.TryParse((string?)obj["expiresAt"], out var expires))
                return null;
            return new LeaseRecord(sid, started, expires, (int?)obj["remainingLaunches"] ?? 0);
        }
        catch
        {
            return null;
        }
    }

    private void WriteLeaseLocked(LeaseRecord lease)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            AtomicJson.Write(LeasePath, new JsonObject
            {
                ["schemaVersion"] = 1,
                ["sessionID"] = lease.SessionId,
                ["startedAt"] = lease.StartedAt.UtcDateTime.ToString("O"),
                ["expiresAt"] = lease.ExpiresAt.UtcDateTime.ToString("O"),
                ["remainingLaunches"] = lease.RemainingLaunches,
            });
        }
        catch { }
    }

    private static void WriteAtomicText(string destination, string content)
    {
        var dir = Path.GetDirectoryName(destination);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var temp = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, content, new UTF8Encoding(false));
            File.Move(temp, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) TryDelete(temp);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private Snapshot SnapshotLocked(DateTimeOffset now) => new(
        expiresAt is { } u && now < u,
        expiresAt,
        sessionId,
        breadcrumbs.Count,
        recentErrors.Count,
        recoveredPreviousSession);
}
