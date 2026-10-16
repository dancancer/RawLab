namespace RawLab.Windows;

public sealed record RumLocalConfiguration(string AppId, string ConfigAddress, string? ValidationRun)
{
    private const string ShanghaiHostSuffix = ".cn-shanghai.log.aliyuncs.com";
    private const string ConfigPath = "/rum/web/v2";

    public static bool TryLoad(out RumLocalConfiguration? configuration)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in new[] { "RAWLAB_RUM_APP_ID", "RAWLAB_RUM_CONFIG_ADDRESS", "RAWLAB_RUM_VALIDATION_RUN" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (value != null) values[name] = value;
        }
        return TryParse(values, out configuration);
    }

    public static bool TryParse(IReadOnlyDictionary<string, string> environment,
        out RumLocalConfiguration? configuration)
    {
        configuration = null;
        if (!environment.TryGetValue("RAWLAB_RUM_APP_ID", out var appId) || !IsSafeAppId(appId) ||
            !environment.TryGetValue("RAWLAB_RUM_CONFIG_ADDRESS", out var address) ||
            !IsShanghaiAddress(address)) return false;

        environment.TryGetValue("RAWLAB_RUM_VALIDATION_RUN", out var marker);
        if (!string.IsNullOrEmpty(marker) && !Guid.TryParse(marker, out _)) return false;
        configuration = new RumLocalConfiguration(appId, address, string.IsNullOrEmpty(marker) ? null : marker);
        return true;
    }

    private static bool IsSafeAppId(string value)
    {
        if (value.Length is < 3 or > 100) return false;
        return value.All(static character => char.IsAsciiLetterOrDigit(character) || character is '@' or '_' or '-');
    }

    private static bool IsShanghaiAddress(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(uri.UserInfo) || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            !string.Equals(uri.AbsolutePath, ConfigPath, StringComparison.Ordinal) ||
            !uri.Host.StartsWith("proj-", StringComparison.OrdinalIgnoreCase) ||
            !uri.Host.EndsWith(ShanghaiHostSuffix, StringComparison.OrdinalIgnoreCase)) return false;
        return uri.Port is 443 or -1;
    }
}
