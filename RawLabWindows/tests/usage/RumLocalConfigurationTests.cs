using RawLab.Windows;

public static class RumLocalConfigurationTests
{
    public static void Run()
    {
        var valid = new Dictionary<string, string>
        {
            ["RAWLAB_RUM_APP_ID"] = "rawlab-win@local",
            ["RAWLAB_RUM_CONFIG_ADDRESS"] =
                "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        };

        Check(RumLocalConfiguration.TryParse(valid, out var configuration),
            "Shanghai local configuration is accepted");
        Check(configuration!.AppId == "rawlab-win@local" &&
              configuration.ConfigAddress == valid["RAWLAB_RUM_CONFIG_ADDRESS"] &&
              configuration.ValidationRun == null,
            "configuration exposes only public app values by default");

        foreach (var address in new[]
        {
            "http://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
            "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2?token=secret",
            "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2#secret",
            "https://other.example.com/rum/web/v2",
            "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v1",
            "https://user:password@proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        })
        {
            var invalid = new Dictionary<string, string>(valid)
            {
                ["RAWLAB_RUM_CONFIG_ADDRESS"] = address,
            };
            Check(!RumLocalConfiguration.TryParse(invalid, out _),
                "unsafe ConfigAddress is rejected: " + address);
        }

        var marked = new Dictionary<string, string>(valid)
        {
            ["RAWLAB_RUM_VALIDATION_RUN"] = "8a8f1e58-6c76-4c23-aee6-7dca6a0b2f4f",
        };
        Check(RumLocalConfiguration.TryParse(marked, out var markedConfiguration) &&
              markedConfiguration!.ValidationRun == marked["RAWLAB_RUM_VALIDATION_RUN"],
            "local validation marker is preserved");

        var invalidMarker = new Dictionary<string, string>(valid)
        {
            ["RAWLAB_RUM_VALIDATION_RUN"] = "not-a-uuid",
        };
        Check(!RumLocalConfiguration.TryParse(invalidMarker, out _),
            "arbitrary validation marker is rejected");

        Console.WriteLine("PASS: Windows local RUM configuration validation");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }
}
