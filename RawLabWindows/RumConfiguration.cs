namespace RawLab.Windows;

// 取值与 alibabacloud_rum.h 的 alibabacloud_rum_env_t 一致
public enum RumEnvironment { Production = 1, Local = 5 }

// ┌──────────────────────────────────────────────────────────────────────┐
// │ Windows 版 RUM 接入参数（AppID 与 ConfigAddress 是公开参数，不是凭证）   │
// │  - 正式：上报目标写死，env=PROD；环境变量只能追加合成验证标记             │
// │  - 本地验证：上报目标全部来自环境变量，env=LOCAL，只接受上海 SLS 的 HTTPS │
// │ 验证标记必须是 UUID；格式不对就整体不可用，不发出没有标记的探针事件。     │
// └──────────────────────────────────────────────────────────────────────┘
public sealed record RumConfiguration(string AppId, string ConfigAddress, RumEnvironment Env, string AppVersion,
    string? ValidationRun)
{
    public const string ProductionAppId = "chrtja4hrt@353d8439b5164b1";
    public const string ProductionConfigAddress =
        "https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/rum/web/v2";
    private const string AppIdVariable = "RAWLAB_RUM_APP_ID";
    private const string AddressVariable = "RAWLAB_RUM_CONFIG_ADDRESS";
    private const string MarkerVariable = "RAWLAB_RUM_VALIDATION_RUN";
    private const string ShanghaiHostSuffix = ".cn-shanghai.log.aliyuncs.com";
    private const string ConfigPath = "/rum/web/v2";

    public static IReadOnlyDictionary<string, string> ProcessEnvironment()
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in new[] { AppIdVariable, AddressVariable, MarkerVariable })
            if (System.Environment.GetEnvironmentVariable(name) is { } value) values[name] = value;
        return values;
    }

    public static bool TryProduction(IReadOnlyDictionary<string, string> environment, string appVersion,
        out RumConfiguration? configuration) =>
        TryCreate(ProductionAppId, ProductionConfigAddress, RumEnvironment.Production, appVersion, environment, out configuration);

    public static bool TryLocal(IReadOnlyDictionary<string, string> environment, string appVersion,
        out RumConfiguration? configuration)
    {
        configuration = null;
        return environment.TryGetValue(AppIdVariable, out var appId) && environment.TryGetValue(AddressVariable, out var address) &&
               TryCreate(appId, address, RumEnvironment.Local, appVersion, environment, out configuration);
    }

    private static bool TryCreate(string appId, string address, RumEnvironment env, string appVersion,
        IReadOnlyDictionary<string, string> environment, out RumConfiguration? configuration)
    {
        environment.TryGetValue(MarkerVariable, out var marker);
        var valid = IsSafeAppId(appId) && IsShanghaiAddress(address) && (string.IsNullOrEmpty(marker) || Guid.TryParse(marker, out _));
        configuration = valid ? new RumConfiguration(appId, address, env, appVersion, string.IsNullOrEmpty(marker) ? null : marker) : null;
        return valid;
    }

    private static bool IsSafeAppId(string value) =>
        value.Length is >= 3 and <= 100 &&
        value.All(static character => char.IsAsciiLetterOrDigit(character) || character is '@' or '_' or '-');

    private static bool IsShanghaiAddress(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
        string.IsNullOrEmpty(uri.UserInfo) && uri.Query.Length == 0 && uri.Fragment.Length == 0 &&
        string.Equals(uri.AbsolutePath, ConfigPath, StringComparison.Ordinal) &&
        uri.Host.StartsWith("proj-", StringComparison.OrdinalIgnoreCase) &&
        uri.Host.EndsWith(ShanghaiHostSuffix, StringComparison.OrdinalIgnoreCase) &&
        uri.Port is 443 or -1;
}
