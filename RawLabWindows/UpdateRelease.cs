using System.Text.Json;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

public sealed record UpdateRelease(string Version, string Notes, string Url)
{
    public const string Repository = "https://github.com/dancancer/RawLab";
    public const string Author = "https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e";
    public const string Endpoint = "https://api.github.com/repos/dancancer/RawLab/releases/latest";
    public const string ManualPackagePrefix = "RawLab-Windows-";
    public const string ManualPackageSuffix = "-x64.zip";
    public const string LegacyManualPackageSuffix = "-win-x64.zip";

    public static string ManualPackageFileName(string version) => ManualPackagePrefix + version + ManualPackageSuffix;

    public static bool IsManualPackageAsset(string? name)
    {
        if (string.IsNullOrEmpty(name) || !name.StartsWith(ManualPackagePrefix, StringComparison.Ordinal)) return false;
        var suffix = name.EndsWith(LegacyManualPackageSuffix, StringComparison.Ordinal)
            ? LegacyManualPackageSuffix
            : name.EndsWith(ManualPackageSuffix, StringComparison.Ordinal)
                ? ManualPackageSuffix
                : null;
        if (suffix == null || name.Length <= ManualPackagePrefix.Length + suffix.Length) return false;
        var version = name.Substring(ManualPackagePrefix.Length, name.Length - ManualPackagePrefix.Length - suffix.Length);
        return Regex.IsMatch(version, @"\A[0-9]+\.[0-9]+(?:\.[0-9]+)?\z") && System.Version.TryParse(version, out _);
    }

    public static UpdateRelease? Parse(string json, string current)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        var tag = root.GetProperty("tag_name").GetString() ?? throw new FormatException("Missing release tag");
        var latest = ParseVersion(tag);
        if (latest <= ParseVersion(current)) return null;
        if (!root.GetProperty("assets").EnumerateArray().Any(asset =>
            IsManualPackageAsset(asset.GetProperty("name").GetString()))) return null;
        var notes = root.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "";
        return new(latest.ToString(3), notes, Repository + "/releases/tag/" + tag);
    }

    private static Version ParseVersion(string value)
    {
        if (!Regex.IsMatch(value, @"\Av?[0-9]+\.[0-9]+(?:\.[0-9]+)?\z")) throw new FormatException("Invalid release version");
        var plain = value.TrimStart('v');
        if (!System.Version.TryParse(plain, out var parsed)) throw new FormatException("Invalid release version");
        return new Version(parsed.Major, parsed.Minor, Math.Max(0, parsed.Build));
    }

    public static bool ShouldCheck(bool manual, bool enabled, double last, double now) =>
        manual || (enabled && (last == 0 || now < last || now - last >= 86400));
}
