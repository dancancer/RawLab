using System.ComponentModel;
using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

public interface IUsageAnalyticsTransport
{
    bool IsAvailable { get; }
    Task StartAsync(CancellationToken cancellationToken);
    Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken);
}

public sealed class UnavailableUsageAnalyticsTransport : IUsageAnalyticsTransport
{
    public bool IsAvailable => false;
    public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;
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
    private sealed record ConsentState(bool Enabled);
    private readonly string settingsPath;
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
    public static string DefaultSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab",
#if RAWLAB_RUM_LOCAL
        "usage-local.json");
#else
        "usage.json");
#endif

    public event PropertyChangedEventHandler? PropertyChanged;

    public UsageAnalytics(string? settingsPath = null, IUsageAnalyticsTransport? transport = null)
    {
        this.settingsPath = settingsPath ?? DefaultSettingsPath;
        this.transport = transport ?? CreateDefaultTransport();
        consentGiven = ReadConsent(this.settingsPath);
        RefreshStatus();
    }

    public bool ConsentGiven => consentGiven;
    public bool CanEnable => transport.IsAvailable;
    public bool IsActive => consentGiven && started && !disposed;
    public string Status => status;
    public string StorageWarning => storageWarning;

    private static IUsageAnalyticsTransport CreateDefaultTransport()
    {
#if RAWLAB_RUM_LOCAL
        return RumLocalUsageAnalyticsTransport.TryCreate(out var transport) && transport != null
            ? transport
            : new UnavailableUsageAnalyticsTransport();
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

    private async Task StartIfAllowedAsync(int epoch)
    {
        if (!sessionBegan || started || startFailed || stopFailed || !consentGiven || disposed || !transport.IsAvailable) return;
        try
        {
            await transport.StartAsync(CancellationToken.None).ConfigureAwait(false);
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
            startFailed = true;
            startFailureStatus = error.Message.Contains("no retry", StringComparison.OrdinalIgnoreCase)
                ? "统计服务生命周期失败，未再尝试；请退出应用完成清理"
                : "统计服务未能启动，照片编辑不受影响";
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

    private bool ReadConsent(string path)
    {
        try { return JsonSerializer.Deserialize<ConsentState>(File.ReadAllText(path))?.Enabled == true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }

    private bool SaveConsent(bool enabled)
    {
        var temporary = settingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var directory = Path.GetDirectoryName(settingsPath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            File.WriteAllText(temporary, JsonSerializer.Serialize(new ConsentState(enabled)));
            File.Move(temporary, settingsPath, true);
            storageWarning = "";
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            storageWarning = "统计设置未能保存，当前进程已停止统计；重启前请检查存储权限";
            return false;
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private void RefreshStatus()
    {
        status = stopFailed ? "统计服务关闭失败，未再尝试关闭；请退出应用完成清理" :
            startFailed ? startFailureStatus ?? "统计服务未能启动，照片编辑不受影响" :
            !transport.IsAvailable ? "当前构建未配置使用统计，未采集或上报。" :
            consentGiven ? "已允许使用统计；可随时关闭。" : "使用统计已关闭。";
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}
