using System.ComponentModel;
using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

public interface IUsageAnalyticsTransport
{
    bool IsAvailable { get; }
    Task StartAsync(string installId, CancellationToken cancellationToken);
    Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken);
}

public sealed class UnavailableUsageAnalyticsTransport : IUsageAnalyticsTransport
{
    public bool IsAvailable => false;
    public Task StartAsync(string installId, CancellationToken cancellationToken) => Task.CompletedTask;
    public Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}

public enum FilmKind { None, BuiltIn, Custom }

public enum BatchOutcome { Completed, Partial, Cancelled, Interrupted }

public abstract record UsageEvent
{
    public int SchemaVersion => 1;
    public string Group => "usage";
    public string Platform => "windows";
    public abstract string Name { get; }
    public abstract int Value { get; }
    public IReadOnlyDictionary<string, string> Properties
    {
        get
        {
            var properties = new Dictionary<string, string> { ["schema_version"] = "1", ["platform"] = "windows" };
            if (this is FilmSelectedEvent film)
                properties["kind"] = film.Kind switch { FilmKind.None => "none", FilmKind.BuiltIn => "built_in", _ => "custom" };
            if (this is BatchExportCompletedEvent batch)
            {
                properties["outcome"] = batch.Outcome switch {
                    BatchOutcome.Completed => "completed", BatchOutcome.Partial => "partial",
                    BatchOutcome.Cancelled => "cancelled", _ => "interrupted"
                };
                properties["succeeded_count"] = batch.SucceededCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
                properties["failed_count"] = batch.FailedCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
            return properties;
        }
    }
}

public sealed record AppStartedEvent : UsageEvent
{
    public override string Name => "app_started";
    public override int Value => 1;
}

public sealed record PhotoImportedEvent : UsageEvent
{
    public override string Name => "photo_imported";
    public override int Value => 1;
}

public sealed record FilmSelectedEvent(FilmKind Kind) : UsageEvent
{
    public override string Name => "film_selected";
    public override int Value => 1;
}

public sealed record ExportCompletedEvent : UsageEvent
{
    public override string Name => "export_completed";
    public override int Value => 1;
}

public sealed record BatchExportCompletedEvent : UsageEvent
{
    public BatchExportCompletedEvent(BatchOutcome outcome, int succeededCount, int failedCount)
    {
        Outcome = outcome;
        SucceededCount = Math.Clamp(succeededCount, 0, UsageAnalytics.MaxCount);
        FailedCount = Math.Clamp(failedCount, 0, UsageAnalytics.MaxCount);
    }

    public BatchOutcome Outcome { get; }
    public int SucceededCount { get; }
    public int FailedCount { get; }
    public override string Name => "batch_export_completed";
    public override int Value => SucceededCount;

}

public sealed class UsageAnalytics : INotifyPropertyChanged, IAsyncDisposable
{
    private sealed record ConsentState(bool? Enabled);
    private readonly string settingsPath;
    private readonly UsageInstallId installId;
    private readonly IUsageAnalyticsTransport transport;
    private readonly SemaphoreSlim gate = new(1, 1);
    private volatile bool consentGiven;
    private bool started;
    private volatile bool disposed;
    private bool sessionBegan, countedLaunch, startFailed, stopFailed;
    private int consentEpoch, shutdownStarted;
    private string storageWarning = "";
    private string status = "";
    private string? startFailureStatus;

    public const int MaxCount = 100_000;
    // 退出时等待 SDK 关闭的上限：离线时原生关闭可能一直等网络，不能拖住退出
    public static readonly TimeSpan ShutdownLimit = TimeSpan.FromSeconds(3);
    public static string DefaultSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab",
#if RAWLAB_RUM_LOCAL
        "usage-local.json");
#else
        "usage.json");
#endif
    public static string DefaultInstallIdPath => InstallIdPathFor(DefaultSettingsPath);

    // 安装标识跟同意文件放在一起、同名前缀：usage.json → usage-install-id.txt，
    // 本地验证构建（usage-local.json）与测试的私有同意文件因此各有各的标识
    public static string InstallIdPathFor(string settingsPath) => Path.Combine(
        Path.GetDirectoryName(settingsPath) ?? "", Path.GetFileNameWithoutExtension(settingsPath) + "-install-id.txt");

    public event PropertyChangedEventHandler? PropertyChanged;

    public UsageAnalytics(string? settingsPath = null, IUsageAnalyticsTransport? transport = null)
    {
        this.settingsPath = settingsPath ?? DefaultSettingsPath;
        installId = new UsageInstallId(InstallIdPathFor(this.settingsPath));
        this.transport = transport ?? CreateDefaultTransport();
        consentGiven = ReadConsent();
        RefreshStatus();
    }

    public bool ConsentGiven => consentGiven;
    public bool CanEnable => transport.IsAvailable;
    public bool IsActive => consentGiven && started && !disposed;
    public string Status => status;
    public string StorageWarning => storageWarning;

    private static IUsageAnalyticsTransport CreateDefaultTransport()
    {
#if RAWLAB_RUM_SDK
        return RumUsageAnalyticsTransport.CreateDefault();
#else
        return new UnavailableUsageAnalyticsTransport();
#endif
    }

    public async Task<bool> SetConsentAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        var epoch = Interlocked.Increment(ref consentEpoch);
        if (!enabled) consentGiven = false;
        try { await gate.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return false; }
        try
        {
            if (disposed || epoch != consentEpoch || (enabled && (!transport.IsAvailable || stopFailed))) return false;
            var stopped = enabled || await StopAsync().ConfigureAwait(false);
            // 关闭统计时一并删除安装标识；重新开启后下次启动 SDK 会生成新的
            if (!enabled) installId.Delete();
            if (!SaveConsent(enabled))
            {
                consentGiven = false;
                await StopAsync().ConfigureAwait(false);
                RefreshStatus();
                return false;
            }
            if (epoch != consentEpoch) return false;
            consentGiven = enabled;
            startFailed = false;
            startFailureStatus = null;
            if (enabled) await StartIfAllowedAsync(epoch).ConfigureAwait(false);
            RefreshStatus();
            return stopped;
        }
        finally { gate.Release(); }
    }

    public void Record(UsageEvent usageEvent) => _ = RecordAsync(usageEvent);
    public void BeginSession() => _ = RecordAsync(new AppStartedEvent());

    public async Task RecordAsync(UsageEvent usageEvent, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(usageEvent);
        var epoch = consentEpoch;
        if (usageEvent is not AppStartedEvent && (!consentGiven || disposed)) return;
        try { await gate.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        try
        {
            if (disposed) return;
            if (usageEvent is AppStartedEvent)
            {
                if (sessionBegan) return;
                sessionBegan = true;
                // 上次关闭统计时若没删掉安装标识，启动时补删
                if (!consentGiven) installId.Delete();
                await StartIfAllowedAsync(epoch).ConfigureAwait(false);
                RefreshStatus();
                return;
            }
            if (epoch != consentEpoch || !consentGiven || !started) return;
            try { await transport.SendAsync(usageEvent, cancellationToken).ConfigureAwait(false); }
            catch (Exception) { }
        }
        finally { gate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref shutdownStarted, 1) != 0) return;
        disposed = true;
        Interlocked.Increment(ref consentEpoch);
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            await StopAsync().ConfigureAwait(false);
            RefreshStatus();
        }
        finally { gate.Release(); }
    }

    // ┌─ 退出用的有界关闭 ────────────────────────────────────────────────────┐
    // │ 超时只是不再等待：disposed 已挡住新事件，原生关闭继续在后台串行完成。   │
    // │ transport 只在关闭确认成功后才释放原生 options，提前退出不会留下悬空句柄；│
    // │ 进程结束时由系统回收其余资源。返回 false 表示没等到关闭完成。           │
    // └─────────────────────────────────────────────────────────────────────┘
    public async Task<bool> CloseAsync(TimeSpan limit)
    {
        try
        {
            await DisposeAsync().AsTask().WaitAsync(limit).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException) { return false; }
    }

    private async Task StartIfAllowedAsync(int epoch)
    {
        if (!sessionBegan || started || startFailed || stopFailed || !consentGiven || disposed || !transport.IsAvailable) return;
        try
        {
            var id = installId.GetOrCreate() ?? throw new IOException("The usage install ID could not be stored.");
            await transport.StartAsync(id, CancellationToken.None).ConfigureAwait(false);
            started = true;
            if (epoch != consentEpoch || !consentGiven || disposed)
            {
                await StopAsync().ConfigureAwait(false);
                return;
            }
            if (!countedLaunch)
            {
                countedLaunch = true;
                try { await transport.SendAsync(new AppStartedEvent(), CancellationToken.None).ConfigureAwait(false); }
                catch (Exception) { }
            }
        }
        catch (Exception error)
        {
            // 故障只让本进程不可用，不写入用户的同意值
            startFailed = true;
            startFailureStatus = error.Message.Contains("no retry", StringComparison.OrdinalIgnoreCase)
                ? "统计服务生命周期失败，未再尝试；请退出应用完成清理"
                : "统计服务未能启动，照片编辑不受影响。";
            status = startFailureStatus;
        }
    }

    private async Task<bool> StopAsync()
    {
        if (stopFailed) return false;
        if (!started) return true;
        try
        {
            await transport.StopAsync(CancellationToken.None).ConfigureAwait(false);
            started = false;
            return true;
        }
        catch (Exception)
        {
            stopFailed = true;
            status = "统计服务关闭失败，未再尝试关闭；请退出应用完成清理";
            return false;
        }
    }

    // ─── 没存过 → 开启；存为关闭 → 关闭；损坏或读不出 → 关闭并提示，原文件保持不动 ───
    private bool ReadConsent()
    {
        try
        {
            if (JsonSerializer.Deserialize<ConsentState>(File.ReadAllText(settingsPath))?.Enabled is bool enabled) return enabled;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        storageWarning = "无法读取统计设置，已保持关闭。";
        return false;
    }

    private bool SaveConsent(bool enabled)
    {
        if (!UsageFiles.WriteAtomically(settingsPath, JsonSerializer.Serialize(new ConsentState(enabled))))
        {
            storageWarning = "统计设置未能保存，当前进程已停止统计；重启前请检查存储权限。";
            return false;
        }
        storageWarning = "";
        return true;
    }

    private void RefreshStatus()
    {
        status = stopFailed ? "统计服务关闭失败，未再尝试关闭；请退出应用完成清理" :
            startFailed ? startFailureStatus ?? "统计服务未能启动，照片编辑不受影响。" :
            !transport.IsAvailable ? "当前构建未配置使用统计，未采集或上报。" :
            consentGiven ? "已允许使用统计；可随时关闭。" : "使用统计已关闭。";
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}

// ┌──────────────────────────────────────────────────────────────────────┐
// │ 安装标识：应用自己生成的随机 UUID v4，只作为 SDK 设备标识（utdid）传入，  │
// │ 用来统计活跃设备数；不读取任何硬件编号。首次启动 SDK 时生成，关闭统计时  │
// │ 删除，重新开启时换新。内容损坏就当作没有，重新生成。                      │
// └──────────────────────────────────────────────────────────────────────┘
internal sealed class UsageInstallId(string path)
{
    public string? GetOrCreate()
    {
        var saved = Read();
        if (saved != null) return saved;
        var created = Guid.NewGuid().ToString("D");
        return UsageFiles.WriteAtomically(path, created) ? created : null;
    }

    public void Delete() => UsageFiles.TryDelete(path);

    private string? Read()
    {
        try
        {
            var text = File.ReadAllText(path).Trim();
            return Guid.TryParseExact(text, "D", out _) && text[14] == '4' ? text : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }
}

internal static class UsageFiles
{
    // 先写临时文件再整体替换，写到一半失败不会留下半截内容
    public static bool WriteAtomically(string path, string text)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            File.WriteAllText(temporary, text);
            File.Move(temporary, path, true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
        finally { TryDelete(temporary); }
    }

    public static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
