using System.Text.Json;
using RawLab.Windows;

internal static class UpdateReleaseAssetChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static string ReleasePayload(string tag, params string?[] assetNames) =>
        JsonSerializer.Serialize(new
        {
            tag_name = tag,
            draft = false,
            prerelease = false,
            body = "Release notes",
            assets = assetNames.Select(name => new { name }).ToArray()
        });

    internal static void Run()
    {
        Check(UpdateRelease.ManualPackageFileName("0.10.0") == "RawLab-Windows-0.10.0-x64.zip",
            "Canonical Windows manual package name matches build.ps1 output");

        foreach (var valid in new[]
        {
            "RawLab-Windows-0.10.0-x64.zip",
            "RawLab-Windows-0.9.2-x64.zip",
            "RawLab-Windows-0.9.1-x64.zip",
            "RawLab-Windows-0.9.0-x64.zip",
            "RawLab-Windows-0.8.2-win-x64.zip",
            "RawLab-Windows-0.5.0-win-x64.zip",
            "RawLab-Windows-0.2-win-x64.zip",
        })
        {
            Check(UpdateRelease.IsManualPackageAsset(valid), "Expected valid Windows manual asset: " + valid);
        }

        foreach (var invalid in new string?[]
        {
            null,
            "",
            "RawLab-Mac-0.10.0-arm64.zip",
            "RawLab-Mac-0.10.0-x86_64.zip",
            "RawLab-Android-0.10.0.apk",
            "RawLab-iOS-0.10.0.ipa",
            "RawLab.Desktop-stable-Setup.exe",
            "RawLab.Desktop-0.10.0-full.nupkg",
            "RawLab.Desktop-stable-Portable.zip",
            "windows-stable.json",
            "appcast-arm64.xml",
            "SHA256SUMS.txt",
            "RawLab-Windows-x64.zip",
            "RawLab-Windows--x64.zip",
            "RawLab-Windows-win-x64.zip",
            "RawLab-Windows--win-x64.zip",
            "RawLab-Windows-0.10.0-arm64.zip",
            "RawLab-Windows-0.10.0-linux-x64.zip",
            "RawLab-Windows-0.10.0-beta-x64.zip",
            "rawlab-windows-0.10.0-x64.zip",
            "RawLab-Windows-0.10.0-X64.ZIP",
            "RawLab-Windows-0.10.0-x64.zip.sha256",
            "../RawLab-Windows-0.10.0-x64.zip",
        })
        {
            Check(!UpdateRelease.IsManualPackageAsset(invalid), "Expected rejected asset: " + (invalid ?? "<null>"));
        }

        var v010Payload = ReleasePayload(
            "v0.10.0",
            "RawLab-Mac-0.10.0-arm64.zip",
            "RawLab-Mac-0.10.0-x86_64.zip",
            "appcast-arm64.xml",
            "appcast-x86_64.xml",
            "RawLab.Desktop-stable-Setup.exe",
            "RawLab.Desktop-0.10.0-full.nupkg",
            "RawLab-Windows-0.10.0-x64.zip",
            "windows-stable.json",
            "RawLab-Android-0.10.0.apk",
            "RawLab-iOS-0.10.0.ipa",
            "SHA256SUMS.txt");
        var v010 = UpdateRelease.Parse(v010Payload, "0.9.2");
        Check(v010 is { Version: "0.10.0", Notes: "Release notes", Url: "https://github.com/dancancer/RawLab/releases/tag/v0.10.0" },
            "v0.10.0 release payload matches current RawLab-Windows-<version>-x64.zip package");
        Check(UpdateRelease.Parse(v010Payload, "0.10.0") == null && UpdateRelease.Parse(v010Payload, "0.10.1") == null,
            "Current or newer installed version is not prompted");

        var legacyPayload = ReleasePayload("v0.8.2", "RawLab-Windows-0.8.2-win-x64.zip");
        Check(UpdateRelease.Parse(legacyPayload, "0.8.1")?.Version == "0.8.2",
            "Legacy RawLab-Windows-<version>-win-x64.zip package remains compatible");

        var mobileOnlyPayload = ReleasePayload(
            "v0.10.1",
            null,
            "RawLab-Android-0.10.1.apk",
            "RawLab-iOS-0.10.1.ipa",
            "appcast-arm64.xml",
            "appcast-x86_64.xml",
            "windows-stable.json",
            "RawLab.Desktop-stable-Setup.exe");
        Check(UpdateRelease.Parse(mobileOnlyPayload, "0.10.0") == null,
            "Release without a Windows manual ZIP asset does not prompt manual installs");

        Console.WriteLine("PASS: Windows manual-package asset matching (-x64.zip and legacy -win-x64.zip)");
    }
}
