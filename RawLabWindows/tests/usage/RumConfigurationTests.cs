using RawLab.Windows;

// ┌──────────────────────────────────────────────────────────────────────┐
// │ RUM 接入参数：正式构建写死正式配置（env=PROD），环境变量只能追加验证标记；│
// │ 本地验证构建的上报目标全部来自环境变量（env=LOCAL）。                    │
// └──────────────────────────────────────────────────────────────────────┘
public static class RumConfigurationTests
{
    private const string Marker = "8a8f1e58-6c76-4c23-aee6-7dca6a0b2f4f";

    public static void Run()
    {
        Production();
        Local();
        Console.WriteLine("PASS: Windows RUM configuration validation");
    }

    private static void Production()
    {
        Check((int)RumEnvironment.Production == 1 && (int)RumEnvironment.Local == 5,
            "environment values match ALIBABACLOUD_RUM_ENV_PROD/LOCAL");
        var overrides = new Dictionary<string, string>
        {
            ["RAWLAB_RUM_APP_ID"] = "rawlab-win@local",
            ["RAWLAB_RUM_CONFIG_ADDRESS"] = "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        };
        Check(RumConfiguration.TryProduction(overrides, "0.8.0", out var production) &&
              production == new RumConfiguration("chrtja4hrt@353d8439b5164b1",
                  "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/rum/web/v2",
                  RumEnvironment.Production, "0.8.0", null),
            "production uses the fixed Windows app, PROD and the real version; env overrides are ignored");
        var asLocal = new Dictionary<string, string>
        {
            ["RAWLAB_RUM_APP_ID"] = production!.AppId,
            ["RAWLAB_RUM_CONFIG_ADDRESS"] = production.ConfigAddress,
        };
        Check(RumConfiguration.TryLocal(asLocal, "0.8.0", out _), "production target passes the same Shanghai HTTPS validation");
        Check(RumConfiguration.TryProduction(new Dictionary<string, string> { ["RAWLAB_RUM_VALIDATION_RUN"] = Marker }, "0.8.0",
                  out var marked) && marked!.ValidationRun == Marker && marked.Env == RumEnvironment.Production,
            "production keeps a UUID validation marker for the live probe");
        Check(!RumConfiguration.TryProduction(new Dictionary<string, string> { ["RAWLAB_RUM_VALIDATION_RUN"] = "not-a-uuid" }, "0.8.0", out _),
            "production refuses a malformed validation marker instead of sending unmarked probe events");
    }

    private static void Local()
    {
        var valid = new Dictionary<string, string>
        {
            ["RAWLAB_RUM_APP_ID"] = "rawlab-win@local",
            ["RAWLAB_RUM_CONFIG_ADDRESS"] = "https://proj-test.cn-shanghai.log.aliyuncs.com/rum/web/v2",
        };
        Check(RumConfiguration.TryLocal(valid, "0.8.0", out var configuration), "Shanghai local configuration is accepted");
        Check(configuration == new RumConfiguration("rawlab-win@local", valid["RAWLAB_RUM_CONFIG_ADDRESS"],
                  RumEnvironment.Local, "0.8.0", null),
            "local configuration exposes only public app values and reports env=LOCAL");
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
            var invalid = new Dictionary<string, string>(valid) { ["RAWLAB_RUM_CONFIG_ADDRESS"] = address };
            Check(!RumConfiguration.TryLocal(invalid, "0.8.0", out _), "unsafe ConfigAddress is rejected: " + address);
        }
        var marked = new Dictionary<string, string>(valid) { ["RAWLAB_RUM_VALIDATION_RUN"] = Marker };
        Check(RumConfiguration.TryLocal(marked, "0.8.0", out var markedConfiguration) &&
              markedConfiguration!.ValidationRun == Marker, "local validation marker is preserved");
        var invalidMarker = new Dictionary<string, string>(valid) { ["RAWLAB_RUM_VALIDATION_RUN"] = "not-a-uuid" };
        Check(!RumConfiguration.TryLocal(invalidMarker, "0.8.0", out _), "arbitrary validation marker is rejected");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }
}
