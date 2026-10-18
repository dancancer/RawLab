using System.Reflection;
using System.Security.Cryptography;
using RawLab.Windows;

// ┌──────────────────────────────────────────────────────────────────────┐
// │ Windows 实网验证探针                                                  │
// │                                                                      │
// │ 用与正式包相同的统计代码和正式配置（env=PROD），发送 5 条带               │
// │ validation_run 标记的合成事件。同意值与安装标识放在私有临时目录，        │
// │ 不读写用户的 RawLab 配置。发送前要求操作者确认用量上限与直连网络；        │
// │ 云端是否入库由 readback 回读确认，探针本身不下结论。                     │
// └──────────────────────────────────────────────────────────────────────┘
if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess) return Fail("Run the probe on Windows x64.");
if (Environment.GetEnvironmentVariable("RAWLAB_RUM_LIMIT_VERIFIED") != "1" ||
    Environment.GetEnvironmentVariable("RAWLAB_RUM_NETWORK") != "china-telecom")
    return Fail("Sending requires RAWLAB_RUM_LIMIT_VERIFIED=1 and RAWLAB_RUM_NETWORK=china-telecom.");
var version = typeof(UsageAnalytics).Assembly.GetName().Version?.ToString(3) ?? "";
if (!RumConfiguration.TryProduction(RumConfiguration.ProcessEnvironment(), version, out var configuration) ||
    configuration?.ValidationRun == null)
    return Fail("Set RAWLAB_RUM_VALIDATION_RUN to a fresh UUID; the production target is built in.");
if (!SdkMatchesPin()) return Fail("alibabacloud_rum.dll next to the probe is missing or not the pinned 0.4.4 x64 Release build.");

var home = Path.Combine(Path.GetTempPath(), "rawlab-rum-probe-" + Guid.NewGuid().ToString("N"));
var analytics = new UsageAnalytics(Path.Combine(home, "usage.json"), new RumUsageAnalyticsTransport(configuration));
var status = await SendFiveEvents(analytics, configuration, version);
var closed = await analytics.CloseAsync(TimeSpan.FromSeconds(20));
RemovePrivateHome(home);
if (status != 0) return status;
if (!closed) return Fail("The SDK close did not finish within 20 seconds; no clean-exit claim.");
Console.WriteLine("PASS: Windows production RUM probe waited 15 seconds and closed the SDK.");
return 0;

// ─── app_started 会启动 SDK；没启动就不再发其余 4 条，也不声称已提交 ───
static async Task<int> SendFiveEvents(UsageAnalytics analytics, RumConfiguration configuration, string version)
{
    if (!await analytics.SetConsentAsync(true)) return Fail("Probe consent could not be enabled.");
    await analytics.RecordAsync(new AppStartedEvent());
    if (!analytics.IsActive) return Fail("The SDK did not start; nothing was submitted. Status: " + analytics.Status);
    foreach (var usageEvent in new UsageEvent[] { new PhotoImportedEvent(), new FilmSelectedEvent(FilmKind.BuiltIn),
                 new ExportCompletedEvent(), new BatchExportCompletedEvent(BatchOutcome.Completed, 1, 0) })
        await analytics.RecordAsync(usageEvent);
    Console.WriteLine($"validation_run: {configuration.ValidationRun}");
    Console.WriteLine($"SUBMITTED: five fixed events (env=PROD, app {configuration.AppId}, version {version}) " +
                      $"for validation_run={configuration.ValidationRun}; cloud receipt not verified.");
    await Task.Delay(TimeSpan.FromSeconds(15));
    return 0;
}

// ─── 只加载与构建时固定哈希一致的 SDK ───
static bool SdkMatchesPin()
{
    var pin = typeof(UsageAnalytics).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .Single(attribute => attribute.Key == "RawLabRumDllSha256").Value;
    var dll = Path.Combine(AppContext.BaseDirectory, "alibabacloud_rum.dll");
    return File.Exists(dll) &&
           string.Equals(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(dll))), pin, StringComparison.OrdinalIgnoreCase);
}

static void RemovePrivateHome(string home)
{
    try { if (Directory.Exists(home)) Directory.Delete(home, recursive: true); }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
}

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 2;
}
