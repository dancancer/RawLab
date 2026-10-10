using System.Text.Json;
using RawLab.Windows;

internal static class FeatureRegressionChecks
{
    internal static void Run(Action<bool, string> check)
    {
        const string payload = "[{\"FileName\":\"sample.ARW\",\"DateTimeOriginal\":\"2026:10:10 12:34:56\",\"ImageWidth\":\"6000\",\"ImageHeight\":\"4000\",\"Orientation\":6,\"Make\":\"Fixture\",\"Model\":\"Camera\",\"LensModel\":\"50mm\",\"ExposureTime\":\"1/125\",\"FNumber\":2.8,\"ISO\":400,\"FocalLength\":\"50.0 mm\"}]";
        var info = PhotoInfoReader.Parse(payload, "sample.ARW");
        check(info is { DisplayWidth: 4000, DisplayHeight: 6000 },
            "EXIF overlay swaps dimensions for a rotated original");
        check(info?.FileLine.Contains("sample.ARW", StringComparison.Ordinal) == true &&
              info.CaptureLine.Contains("Camera", StringComparison.Ordinal) &&
              info.CaptureLine.Contains("1/125", StringComparison.Ordinal),
            "EXIF overlay uses structured capture fields without placeholders");
        var missing = PhotoInfoReader.Parse("[{\"FileName\":\"no-exif.ARW\"}]", "no-exif.ARW");
        check(missing?.CaptureLine.Contains("6500", StringComparison.Ordinal) != true &&
              missing?.CaptureLine.Contains("ISO", StringComparison.Ordinal) != true,
            "missing EXIF fields do not invent camera settings");
        var slow = PhotoInfoReader.Parse("[{\"FileName\":\"slow.ARW\",\"ExposureTime\":0.8}]", "slow.ARW");
        check(slow?.CaptureLine.Contains("0.8 s", StringComparison.Ordinal) == true &&
              slow.CaptureLine.Contains("1/1", StringComparison.Ordinal) == false,
            "slow shutter times remain seconds instead of rounding to 1/1");

        var settings = new Adjustments();
        var request = settings.Request("input.ARW", null, 0, "output.jpg", 2048);
        check(request.SizeMode == 4 && request.LongEdge == 2048 && request.Intent == 1 && request.PreviewLongEdge == 0,
            "limited export uses final long-edge request instead of preview sizing");
        check(ExportSize.Parse("1") == 1 && ExportSize.Parse("65535") == 65535 && ExportSize.Parse("0") == null && ExportSize.Parse("65536") == null,
            "custom export size validates the inclusive pixel bounds");

        var oldJob = JsonSerializer.Deserialize<BatchJob>("{\"Version\":1,\"Source\":\"old.ARW\",\"Items\":[]}");
        check(oldJob?.LongEdge == null, "old batch task restores with original-size export");
        Console.WriteLine("PASS: Windows EXIF overlay, final export sizing and legacy batch snapshot regressions");
    }
}
