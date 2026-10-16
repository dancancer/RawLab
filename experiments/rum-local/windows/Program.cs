using RawLab.Windows;

if (!string.Equals(Path.GetFileName(UsageAnalytics.DefaultSettingsPath), "usage-local.json", StringComparison.Ordinal))
{
    Console.Error.WriteLine("Local RUM builds must use usage-local.json and must not read the normal consent file.");
    return 2;
}

var environment = new Dictionary<string, string>(StringComparer.Ordinal)
{
    ["RAWLAB_RUM_APP_ID"] = Environment.GetEnvironmentVariable("RAWLAB_RUM_APP_ID") ?? "",
    ["RAWLAB_RUM_CONFIG_ADDRESS"] = Environment.GetEnvironmentVariable("RAWLAB_RUM_CONFIG_ADDRESS") ?? "",
    ["RAWLAB_RUM_VALIDATION_RUN"] = Environment.GetEnvironmentVariable("RAWLAB_RUM_VALIDATION_RUN") ?? "",
};

if (Environment.GetEnvironmentVariable("RAWLAB_RUM_LIMIT_VERIFIED") != "1" ||
    Environment.GetEnvironmentVariable("RAWLAB_RUM_NETWORK") != "china-telecom")
{
    Console.Error.WriteLine("--send requires RAWLAB_RUM_LIMIT_VERIFIED=1 and RAWLAB_RUM_NETWORK=china-telecom.");
    return 2;
}

if (!RumLocalConfiguration.TryParse(environment, out var configuration) || configuration?.ValidationRun == null)
{
    Console.Error.WriteLine("Set the public Shanghai PC values and a UUID RAWLAB_RUM_VALIDATION_RUN.");
    return 2;
}

var settingsPath = Path.Combine(Path.GetTempPath(), "rawlab-rum-settings-" + Guid.NewGuid().ToString("N"));
var transport = new RumLocalUsageAnalyticsTransport(configuration);
try
{
    await using var analytics = new UsageAnalytics(settingsPath, transport);
    if (!await analytics.SetConsentAsync(true))
    {
        Console.Error.WriteLine("Local RUM consent could not be enabled.");
        return 1;
    }

    await analytics.RecordAsync(new AppStartedEvent());
    await analytics.RecordAsync(new PhotoImportedEvent());
    await analytics.RecordAsync(new FilmSelectedEvent(FilmKind.BuiltIn));
    await analytics.RecordAsync(new ExportCompletedEvent());
    await analytics.RecordAsync(new BatchExportCompletedEvent(BatchOutcome.Completed, 1, 0));
    Console.WriteLine($"validation_run: {configuration.ValidationRun}");
    Console.WriteLine($"SUBMITTED: five fixed events were handed to the SDK for validation_run={configuration.ValidationRun}; cloud receipt not verified.");
    await Task.Delay(TimeSpan.FromSeconds(15));
    Console.WriteLine("PASS: Windows local RUM waited 15 seconds before close.");
    return 0;
}
finally
{
    try { if (File.Exists(settingsPath)) File.Delete(settingsPath); }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }
}
