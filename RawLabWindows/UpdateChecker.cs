using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace RawLab.Windows;

public sealed class UpdateChecker : INotifyPropertyChanged
{
    private sealed class Preferences
    {
        public bool Automatic { get; set; } = true;
        public double LastAttempt { get; set; }
        public string? CachedRelease { get; set; }
    }
    private static readonly HttpClient DefaultClient = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly string settingsPath;
    private readonly HttpClient client;
    private readonly Preferences preferences;
    public event PropertyChangedEventHandler? PropertyChanged;
    public string CurrentVersion { get; }
    public bool Checking { get; private set; }
    public bool CanCheck => !Checking;
    public UpdateRelease? Available { get; private set; }
    public bool HasUpdate => Available != null;
    public string AvailableLabel => Available is { } release ? $"RawLab {release.Version} 已发布" : "";
    public string Status { get; private set; } = "尚未检查更新";
    public string StorageWarning { get; private set; } = "";
    public bool Automatic
    {
        get => preferences.Automatic;
        set
        {
            var previous = preferences.Automatic;
            preferences.Automatic = value;
            if (!Save()) preferences.Automatic = previous;
            Notify();
        }
    }

    public UpdateChecker(string currentVersion, string? settingsPath = null, HttpClient? client = null)
    {
        CurrentVersion = currentVersion;
        this.settingsPath = settingsPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "updates.json");
        this.client = client ?? DefaultClient;
        try { preferences = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(this.settingsPath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { preferences = new(); }
        if (preferences.CachedRelease is { } cached)
        {
            try { Available = UpdateRelease.Parse(cached, CurrentVersion); }
            catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or KeyNotFoundException) { }
        }
        if (Available != null) Status = AvailableLabel;
    }

    public async Task CheckAsync(bool manual, CancellationToken cancellationToken = default)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (Checking || !UpdateRelease.ShouldCheck(manual, Automatic, preferences.LastAttempt, now)) return;
        Checking = true;
        Status = "正在检查更新…";
        preferences.LastAttempt = now;
        if (!Save() && !manual)
        {
            Checking = false;
            Status = "无法保存检查时间，已跳过自动检查；可手动重试";
            Notify();
            return;
        }
        Notify();
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, UpdateRelease.Endpoint);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.UserAgent.ParseAdd("RawLab-Update-Check");
            using var response = await client.SendAsync(request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync(cancellationToken);
            Available = UpdateRelease.Parse(json, CurrentVersion);
            preferences.CachedRelease = json;
            Save();
            Status = Available == null ? "未发现适用于 Windows 的新版本" : AvailableLabel;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or FormatException or InvalidOperationException or KeyNotFoundException)
        {
            Status = "检查失败，请稍后重试或访问 GitHub 仓库";
        }
        finally { Checking = false; Notify(); }
    }

    private bool Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
            File.WriteAllText(settingsPath + ".tmp", JsonSerializer.Serialize(preferences));
            File.Move(settingsPath + ".tmp", settingsPath, true);
            StorageWarning = "";
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            StorageWarning = "无法保存更新设置，请检查应用数据目录权限";
            return false;
        }
    }

    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
