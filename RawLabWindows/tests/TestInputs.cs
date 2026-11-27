using System.IO;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

internal static class TestInputs
{
    internal static void Check(bool success, string message) => Assert.True(success, message);

    internal static string Repo()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_REPO");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "RawLabWindows", "RawLabWindows.csproj")))
                return dir.FullName;
        }
        throw new DirectoryNotFoundException("Cannot locate repository root; set RAWLAB_TEST_REPO.");
    }

    internal static string Raw()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_RAW");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        var fallback = Path.Combine(Repo(), "lutools", "examples", "DJI_20250602164503_0444_D.DNG");
        if (File.Exists(fallback)) return fallback;
        throw new FileNotFoundException("RAW fixture not found; set RAWLAB_TEST_RAW.");
    }

    internal static string DenoiseRaw()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_DENOISE_RAW");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        return Path.Combine(Repo(), "build", "windows-fixtures", "denoise.dng");
    }

    internal static string Cli()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_CLI");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        return Path.Combine(Repo(), "build", "RawLab-Windows", "sony2fuji.exe");
    }

    internal static string Results(string subdir)
    {
        var root = Environment.GetEnvironmentVariable("RAWLAB_TEST_RESULTS");
        if (string.IsNullOrWhiteSpace(root)) root = Path.Combine(Repo(), "build", "windows-v08-results");
        var path = Path.Combine(Path.GetFullPath(root), subdir);
        Directory.CreateDirectory(path);
        return path;
    }

    internal static string AiWindowRaw()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_AI_RAW");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.GetFullPath(configured);
        return Path.Combine(Repo(), "lutools", "tests", "fixtures", "bayer-demosaic.dng");
    }

    internal static string[] OptionalRasters()
    {
        var configured = Environment.GetEnvironmentVariable("RAWLAB_TEST_RASTER");
        return !string.IsNullOrWhiteSpace(configured) ? [Path.GetFullPath(configured)] : [];
    }
}
