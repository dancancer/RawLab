using System.Diagnostics;
using RawLab.Windows;

// ┌──────────────────────────────────────────────────────────────────────┐
// │ 默认开启的同意语义、安装标识的生命周期、退出时的有界等待               │
// │                                                                      │
// │ 只用假 transport 与临时目录，不加载 SDK、不联网。                       │
// └──────────────────────────────────────────────────────────────────────┘
internal static class UsageLifecycleTests
{
    private const string UnreadableWarning = "无法读取统计设置，已保持关闭。";

    public static async Task Run(string root)
    {
        await ConsentDefaults(root);
        await FailuresKeepConsent(root);
        await InstallIdLifecycle(root);
        await InstallIdFailures(root);
        await BoundedClose(root);
        Console.WriteLine("PASS: Windows usage default consent, install ID and bounded exit");
    }

    // ─── 没存过 → 开启；明确关闭 → 关闭；读不出 → 关闭并提示，且不改写原文件 ───
    private static async Task ConsentDefaults(string root)
    {
        var missing = Path.Combine(root, "missing.json");
        var transport = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(missing, transport))
        {
            Check(analytics.ConsentGiven && analytics.StorageWarning == "", "missing consent file means analytics is on");
            await analytics.RecordAsync(new AppStartedEvent());
            Check(analytics.IsActive && transport.StartCalls == 1 && transport.Events.Count == 1,
                "default-on consent starts the SDK once at launch");
        }
        Check(!File.Exists(missing), "default-on consent is never written on the user's behalf");

        var off = Write(root, "off.json", "{\"Enabled\":false}");
        await using (var analytics = new UsageAnalytics(off, new FakeTransport(true)))
            Check(!analytics.ConsentGiven && analytics.StorageWarning == "", "explicit opt-out stays off without a warning");

        foreach (var (name, text) in new[] { ("corrupt.json", "{not json"), ("empty.json", "{}"), ("null.json", "null") })
        {
            var path = Write(root, name, text);
            var unreadable = new FakeTransport(true);
            await using (var analytics = new UsageAnalytics(path, unreadable))
            {
                await analytics.RecordAsync(new AppStartedEvent());
                Check(!analytics.ConsentGiven && unreadable.StartCalls == 0 && analytics.StorageWarning == UnreadableWarning,
                    "unreadable consent stays off with a warning: " + name);
            }
            Check(File.ReadAllText(path) == text, "unreadable consent bytes are left untouched: " + name);
        }
    }

    // ─── 故障路径只把本进程标为不可用，绝不写入用户的同意值 ───
    private static async Task FailuresKeepConsent(string root)
    {
        var path = Path.Combine(root, "start-failure-default.json");
        await using (var analytics = new UsageAnalytics(path, new FakeTransport(true) { ThrowOnStart = true }))
        {
            await analytics.RecordAsync(new AppStartedEvent());
            Check(analytics.ConsentGiven && !analytics.IsActive && analytics.Status.Contains("未能启动"),
                "SDK start failure only marks this process unavailable");
        }
        Check(!File.Exists(path), "SDK start failure never writes the user's consent");
        var restarted = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(path, restarted))
        {
            await analytics.RecordAsync(new AppStartedEvent());
            Check(analytics.IsActive && restarted.StartCalls == 1, "a transient start failure does not disable later launches");
        }

        var exit = Write(root, "stop-failure-exit.json", "{\"Enabled\":true}");
        var stopFailure = new UsageAnalytics(exit, new FakeTransport(true) { ThrowOnStop = true });
        await stopFailure.RecordAsync(new AppStartedEvent());
        await stopFailure.DisposeAsync();
        Check(File.ReadAllText(exit) == "{\"Enabled\":true}", "SDK stop failure at exit never writes the user's consent");
    }

    // ─── 首次启动 SDK 时生成；重启沿用；关闭即删；重新开启换新 ───
    private static async Task InstallIdLifecycle(string root)
    {
        Check(Path.GetFileName(UsageAnalytics.DefaultInstallIdPath) == "usage-install-id.txt" &&
              Path.GetDirectoryName(UsageAnalytics.DefaultInstallIdPath) == Path.GetDirectoryName(UsageAnalytics.DefaultSettingsPath),
            "release install ID lives next to usage.json as usage-install-id.txt");
        var noSdk = Path.Combine(root, "no-sdk.json");
        await using (var analytics = new UsageAnalytics(noSdk, new FakeTransport(false)))
            await analytics.RecordAsync(new AppStartedEvent());
        Check(!File.Exists(UsageAnalytics.InstallIdPathFor(noSdk)), "builds without the SDK never create an install ID");

        var path = Path.Combine(root, "id.json");
        var idPath = UsageAnalytics.InstallIdPathFor(path);
        var first = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(path, first))
        {
            Check(!File.Exists(idPath), "install ID is not created before the SDK starts");
            await analytics.RecordAsync(new AppStartedEvent());
            Check(File.Exists(idPath) && IsV4(File.ReadAllText(idPath)) && first.InstallIds.SequenceEqual([File.ReadAllText(idPath)]),
                "first SDK start creates a random v4 install ID and passes it to the SDK");
        }
        var saved = File.ReadAllText(idPath);
        var second = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(path, second))
        {
            await analytics.RecordAsync(new AppStartedEvent());
            Check(second.InstallIds.SequenceEqual([saved]), "install ID is reused across restarts");
            await analytics.SetConsentAsync(false);
            Check(!File.Exists(idPath), "turning analytics off deletes the install ID");
            await analytics.SetConsentAsync(true);
            Check(second.InstallIds.Count == 2 && second.InstallIds[1] != saved && IsV4(second.InstallIds[1]) &&
                  File.ReadAllText(idPath) == second.InstallIds[1], "re-enabling generates a new install ID");
        }
    }

    // ─── 残留、损坏或写不进的安装标识 ───
    private static async Task InstallIdFailures(string root)
    {
        var stale = Write(root, "stale.json", "{\"Enabled\":false}");
        var staleId = Write(root, Path.GetFileName(UsageAnalytics.InstallIdPathFor(stale)), Guid.NewGuid().ToString());
        await using (var analytics = new UsageAnalytics(stale, new FakeTransport(true)))
            await analytics.RecordAsync(new AppStartedEvent());
        Check(!File.Exists(staleId), "launch with analytics off removes a leftover install ID");

        var damaged = Path.Combine(root, "damaged.json");
        var damagedId = Write(root, Path.GetFileName(UsageAnalytics.InstallIdPathFor(damaged)), "not-a-uuid");
        var replaced = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(damaged, replaced))
            await analytics.RecordAsync(new AppStartedEvent());
        Check(replaced.InstallIds.Count == 1 && IsV4(replaced.InstallIds[0]) && File.ReadAllText(damagedId) == replaced.InstallIds[0],
            "a damaged install ID is replaced by a new random one");

        var blocked = Path.Combine(root, "blocked-id.json");
        Directory.CreateDirectory(UsageAnalytics.InstallIdPathFor(blocked));
        var blockedTransport = new FakeTransport(true);
        await using (var analytics = new UsageAnalytics(blocked, blockedTransport))
        {
            await analytics.RecordAsync(new AppStartedEvent());
            Check(blockedTransport.StartCalls == 0 && !analytics.IsActive && analytics.Status.Contains("未能启动") && !File.Exists(blocked),
                "unwritable install ID keeps the SDK off without touching consent");
        }
    }

    // ─── 离线时 SDK 关闭可能很久：退出最多等一个上限，之后不再接收事件、也不重复关闭 ───
    private static async Task BoundedClose(string root)
    {
        Check(UsageAnalytics.ShutdownLimit >= TimeSpan.FromSeconds(1) && UsageAnalytics.ShutdownLimit <= TimeSpan.FromSeconds(5),
            "exit waits a few seconds at most for the SDK");
        var prompt = new FakeTransport(true);
        var quick = new UsageAnalytics(Write(root, "exit-quick.json", "{\"Enabled\":true}"), prompt);
        await quick.RecordAsync(new AppStartedEvent());
        Check(await quick.CloseAsync(TimeSpan.FromSeconds(5)) && prompt.StopsCompleted == 1, "prompt SDK close finishes within the limit");

        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var offline = new FakeTransport(true) { BeforeStop = hold.Task };
        var analytics = new UsageAnalytics(Write(root, "exit-offline.json", "{\"Enabled\":true}"), offline);
        await analytics.RecordAsync(new AppStartedEvent());
        var clock = Stopwatch.StartNew();
        var finished = await analytics.CloseAsync(TimeSpan.FromMilliseconds(200));
        Check(!finished && clock.Elapsed < TimeSpan.FromSeconds(3) && offline.StopCalls == 1, "a hung SDK close is abandoned after the bounded wait");
        await analytics.RecordAsync(new PhotoImportedEvent());
        Check(offline.Events.Count == 1, "no events are admitted after a timed-out close");
        hold.SetResult();
        await WaitUntil(() => offline.StopsCompleted == 1);
        await analytics.DisposeAsync();
        Check(offline.StopCalls == 1 && offline.StopsCompleted == 1, "the abandoned close still completes once in the background and is never repeated");

        var sendHold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stuck = new FakeTransport(true);
        var busy = new UsageAnalytics(Write(root, "exit-busy.json", "{\"Enabled\":true}"), stuck);
        await busy.RecordAsync(new AppStartedEvent());
        stuck.BeforeSend = sendHold.Task;
        var pending = busy.RecordAsync(new ExportCompletedEvent());
        Check(!await busy.CloseAsync(TimeSpan.FromMilliseconds(200)) && stuck.StopCalls == 0, "a hung in-flight send cannot block exit");
        sendHold.SetResult();
        await pending.WaitAsync(TimeSpan.FromSeconds(5));
        await WaitUntil(() => stuck.StopCalls == 1);
    }

    private static bool IsV4(string text) => Guid.TryParseExact(text, "D", out _) && text[14] == '4';

    private static string Write(string root, string name, string text)
    {
        var path = Path.Combine(root, name);
        File.WriteAllText(path, text);
        return path;
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("background SDK close did not finish");
            await Task.Delay(10);
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }
}
