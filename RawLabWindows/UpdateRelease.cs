using System.Text.Json;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

public sealed record UpdateRelease(string Version, string Notes, string Url)
{
    public const string Repository = "https://github.com/dancancer/RawLab";
    public const string Author = "https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e";
    public const string Endpoint = "https://api.github.com/repos/dancancer/RawLab/releases/latest";

    public static UpdateRelease? Parse(string json, string current)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        var tag = root.GetProperty("tag_name").GetString() ?? throw new FormatException("Missing release tag");
        var latest = ParseVersion(tag);
        if (latest <= ParseVersion(current)) return null;
        if (!root.GetProperty("assets").EnumerateArray().Any(asset =>
            asset.GetProperty("name").GetString() is { } name &&
            name.StartsWith("RawLab-Windows-", StringComparison.Ordinal) && name.EndsWith("win-x64.zip", StringComparison.Ordinal))) return null;
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
