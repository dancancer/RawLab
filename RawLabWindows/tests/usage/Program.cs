using RawLab.Windows;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    Console.WriteLine("PASS: " + message);
}

var root = Path.Combine(Path.GetTempPath(), "RawLabUsageTests-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    RumLocalConfigurationTests.Run();
    var unavailableTransport = new FakeTransport(false);
    var unavailablePath = Path.Combine(root, "unavailable.json");
    await using (var unavailable = new UsageAnalytics(unavailablePath, unavailableTransport))
    {
        Check(!unavailable.ConsentGiven && !unavailable.IsActive, "default consent is disabled");
        Check(!await unavailable.SetConsentAsync(true), "unavailable provider cannot be enabled");
        await unavailable.RecordAsync(new AppStartedEvent());
        Check(unavailableTransport.StartCalls == 0 && unavailableTransport.Events.Count == 0,
            "unavailable provider never initializes or sends");
    }

    var path = Path.Combine(root, "usage.json");
    var transport = new FakeTransport(true);
    await using (var analytics = new UsageAnalytics(path, transport))
    {
        await analytics.RecordAsync(new AppStartedEvent());
        Check(transport.Events.Count == 0, "disabled analytics drops events without caching");
        Check(await analytics.SetConsentAsync(true), "available provider accepts consent");
        await analytics.RecordAsync(new AppStartedEvent());
        await analytics.RecordAsync(new PhotoImportedEvent());
        await analytics.RecordAsync(new FilmSelectedEvent(FilmKind.None));
        await analytics.RecordAsync(new FilmSelectedEvent(FilmKind.BuiltIn));
        await analytics.RecordAsync(new FilmSelectedEvent(FilmKind.Custom));
        await analytics.RecordAsync(new ExportCompletedEvent());
        await analytics.RecordAsync(new BatchExportCompletedEvent(BatchOutcome.Partial, 3, 2));
        Check(transport.StartCalls == 1, "consented provider starts once");
        Check(transport.Events.Count == 7, "only fixed event types are delivered");
        Check(transport.Events[0] is AppStartedEvent { Name: "app_started", Group: "usage", Platform: "windows", Value: 1 },
            "app event has fixed schema");
        Check(transport.Events[2] is FilmSelectedEvent { Kind: FilmKind.None, Value: 1 }, "none film event is typed");
        Check(transport.Events[3] is FilmSelectedEvent { Kind: FilmKind.BuiltIn }, "built-in film event is typed");
        Check(transport.Events[4] is FilmSelectedEvent { Kind: FilmKind.Custom }, "custom film event is typed");
        Check(transport.Events[6] is BatchExportCompletedEvent { Outcome: BatchOutcome.Partial, Value: 3, SucceededCount: 3, FailedCount: 2 },
            "batch event carries bounded outcome counts");
        await analytics.SetConsentAsync(false);
        Check(transport.StopCalls == 1 && !analytics.IsActive, "withdrawal stops the provider immediately");
        await analytics.RecordAsync(new ExportCompletedEvent());
        Check(transport.Events.Count == 7, "withdrawal drops later events without caching");
    }

    var reopenedTransport = new FakeTransport(true);
    await using (var reopened = new UsageAnalytics(path, reopenedTransport))
    {
        Check(!reopened.ConsentGiven, "withdrawn consent persists across restart");
    }
    await using (var persisted = new UsageAnalytics(Path.Combine(root, "persisted.json"), new FakeTransport(true)))
    {
        Check(await persisted.SetConsentAsync(true), "consent can be persisted");
    }
    var persistedTransport = new FakeTransport(true);
    await using (var persisted = new UsageAnalytics(Path.Combine(root, "persisted.json"), persistedTransport))
    {
        Check(persisted.ConsentGiven, "consent survives restart");
        await persisted.RecordAsync(new AppStartedEvent());
        Check(persistedTransport.StartCalls == 1 && persistedTransport.Events.Count == 1,
            "persisted consent sends after restart");
    }

    Check(new BatchExportCompletedEvent(BatchOutcome.Partial, -1, 200_000) is
        { SucceededCount: 0, FailedCount: 100_000 }, "counts match the cross-platform bounds without breaking editing");
    Check(new BatchExportCompletedEvent(BatchOutcome.Completed, 0, 0).Value == 0,
        "zero-count batch event remains non-negative");
    Check(new FilmSelectedEvent(FilmKind.BuiltIn).Properties["kind"] == "built_in" &&
          new FilmSelectedEvent(FilmKind.Custom).Properties.Keys.Order().SequenceEqual(new[] { "kind", "platform", "schema_version" }),
        "wire payload contains only canonical safe fields");

    var startupFailureTransport = new FakeTransport(true) { ThrowOnStart = true };
    await using (var startupFailure = new UsageAnalytics(Path.Combine(root, "startup-failure.json"), startupFailureTransport))
    {
        await startupFailure.SetConsentAsync(true);
        await startupFailure.RecordAsync(new AppStartedEvent());
        await startupFailure.RecordAsync(new PhotoImportedEvent());
        Check(startupFailureTransport.StartCalls == 1 && !startupFailure.IsActive && startupFailure.Status.Contains("未能启动"),
            "startup failure is visible and is not retried on business events");
    }

    var failingTransport = new FakeTransport(true) { ThrowOnSend = true };
    await using (var failing = new UsageAnalytics(Path.Combine(root, "failing.json"), failingTransport))
    {
        await failing.SetConsentAsync(true);
        await failing.RecordAsync(new AppStartedEvent());
        await failing.RecordAsync(new PhotoImportedEvent());
        await failing.RecordAsync(new PhotoImportedEvent());
        Check(failingTransport.SendCalls == 3 && failingTransport.Events.Count == 0,
            "transport failures do not cache or retry events");
    }
    var stopFailureTransport = new FakeTransport(true) { ThrowOnStop = true };
    await using (var stopFailure = new UsageAnalytics(Path.Combine(root, "stop-failure.json"), stopFailureTransport))
    {
        await stopFailure.SetConsentAsync(true);
        await stopFailure.RecordAsync(new AppStartedEvent());
        Check(!await stopFailure.SetConsentAsync(false), "native close failure is reported to consent control");
        Check(stopFailure.Status.Contains("关闭失败"), "native close failure is visible in status");
        var stopCalls = stopFailureTransport.StopCalls;
        Check(!await stopFailure.SetConsentAsync(true) && stopFailureTransport.StopCalls == stopCalls,
            "close failure blocks re-enable without retrying native close");
    }
    var blockedPath = Path.Combine(root, "blocked.json");
    var blockedTransport = new FakeTransport(true);
    await using (var blocked = new UsageAnalytics(blockedPath, blockedTransport))
    {
        await blocked.RecordAsync(new AppStartedEvent());
        await blocked.SetConsentAsync(true);
        await blocked.RecordAsync(new PhotoImportedEvent());
        Check(blockedTransport.Events.Count(item => item is AppStartedEvent) == 1,
            "enable after startup still counts one launch");
        File.Delete(blockedPath);
        Directory.CreateDirectory(blockedPath);
        Check(!await blocked.SetConsentAsync(false), "unwritable consent reports persistence failure");
        var count = blockedTransport.Events.Count;
        await blocked.RecordAsync(new ExportCompletedEvent());
        Check(!blocked.ConsentGiven && blockedTransport.StopCalls == 1 && blockedTransport.Events.Count == count,
            "failed opt-out persistence never rolls back consent in this process");
    }
    var inFlightTransport = new FakeTransport(true);
    await using (var inFlight = new UsageAnalytics(Path.Combine(root, "in-flight.json"), inFlightTransport))
    {
        await inFlight.RecordAsync(new AppStartedEvent());
        await inFlight.SetConsentAsync(true);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        inFlightTransport.BeforeSend = release.Task;
        var photo = inFlight.RecordAsync(new PhotoImportedEvent());
        var withdrawal = inFlight.SetConsentAsync(false);
        Check(!inFlight.ConsentGiven, "withdrawal blocks new work before waiting for an in-flight request");
        await inFlight.RecordAsync(new ExportCompletedEvent());
        release.SetResult();
        await Task.WhenAll(photo, withdrawal).WaitAsync(TimeSpan.FromSeconds(5));
        Check(inFlightTransport.StopCalls == 1 && !inFlightTransport.Events.Any(item => item is ExportCompletedEvent),
            "in-flight completion cannot admit post-withdrawal events");
    }
    Console.WriteLine("PASS: Windows usage analytics contract, consent, persistence and unavailable transport");
}
finally
{
    Directory.Delete(root, true);
}

sealed class FakeTransport(bool available) : IUsageAnalyticsTransport
{
    public bool IsAvailable { get; } = available;
    public int StartCalls { get; private set; }
    public int StopCalls { get; private set; }
    public int SendCalls { get; private set; }
    public bool ThrowOnSend { get; set; }
    public bool ThrowOnStart { get; set; }
    public bool ThrowOnStop { get; set; }
    public Task? BeforeSend { get; set; }
    public List<UsageEvent> Events { get; } = [];

    public Task StartAsync(CancellationToken cancellationToken)
    {
        StartCalls++;
        if (ThrowOnStart) throw new InvalidOperationException("synthetic startup failure");
        return Task.CompletedTask;
    }

    public async Task SendAsync(UsageEvent usageEvent, CancellationToken cancellationToken)
    {
        SendCalls++;
        if (ThrowOnSend) throw new InvalidOperationException("synthetic transport failure");
        if (BeforeSend != null) await BeforeSend;
        Events.Add(usageEvent);
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        StopCalls++;
        if (ThrowOnStop) throw new InvalidOperationException("synthetic close failure");
        return Task.CompletedTask;
    }
}
