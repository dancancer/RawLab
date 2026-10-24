using System.IO;
using System.Text.Json;
using System.Runtime.InteropServices;
using RawLab.Windows;

internal static class FeatureRegressionChecks
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string fileName, string existingFileName, IntPtr securityAttributes);

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
        var precise = new PhotoInfo("precise.ARW",null,null,null,null,null,null,null,"1.23456 s","f/2.34567","400.12345","35.6789 mm");
        var preciseText=precise.CaptureLine;
        check(preciseText.Contains("1.23 s") && preciseText.Contains("f/2.35") && preciseText.Contains("400.12") && preciseText.Contains("35.68 mm"),
            "Editor metadata limits numeric values to two decimals, including values with units");
        var unknown=new PhotoInfo("unknown.ARW",null,null,null,null,null,null,null,"bulb s","f/unknown","ISO","mm");
        check(unknown.CaptureLine.Contains("bulb s") && unknown.CaptureLine.Contains("f/unknown") && unknown.CaptureLine.Contains("mm"),
            "Unrecognized metadata keeps its original text and units");
        var language=Loc.Language;
        try {
            Loc.Initialize("de");
            check(precise.CaptureLine.Contains("1,23 s") && precise.CaptureLine.Contains("f/2,35") && precise.CaptureLine.Contains("35,68 mm"),
                "Metadata number separators follow the selected interface language");
        } finally {Loc.Initialize(language);}
        var slow = PhotoInfoReader.Parse("[{\"FileName\":\"slow.ARW\",\"ExposureTime\":0.8}]", "slow.ARW");
        check(slow?.CaptureLine.Contains("0.8 s", StringComparison.Ordinal) == true &&
              slow.CaptureLine.Contains("1/1", StringComparison.Ordinal) == false,
            "slow shutter times remain seconds instead of rounding to 1/1");

        var settings = new Adjustments();
        var request = settings.Request("input.ARW", null, 0, "output.jpg", 2048);
        check(request.SizeMode == 4 && request.LongEdge == 2048 && request.Intent == 1 && request.PreviewLongEdge == 0,
            "limited export uses final long-edge request instead of preview sizing");
        var dngRequest = settings.Request("input.ARW", null, 0, "output.DNG", 2048);
        check(dngRequest.OutputFormat == 4 && dngRequest.OutputTarget == 0 && dngRequest.Intent == 1,
            "rendered DNG uses the native file format without changing final sizing");
        check(ExportFormat.Jpeg.AcceptsPath("output.JPG") && ExportFormat.Jpeg.AcceptsPath("output.jpeg") &&
              !ExportFormat.Jpeg.AcceptsPath("output.png") && ExportFormat.Png.AcceptsPath("output.PnG") &&
              ExportFormat.RenderedDng.AcceptsPath("output.DnG") && !ExportFormat.RenderedDng.AcceptsPath("output.jpg"),
            "single-export format validation accepts only the selected extension");
        check(ExportSize.Parse("1") == 1 && ExportSize.Parse("65535") == 65535 && ExportSize.Parse("0") == null && ExportSize.Parse("65536") == null,
            "custom export size validates the inclusive pixel bounds");

        var oldJob = JsonSerializer.Deserialize<BatchJob>("{\"Version\":1,\"Source\":\"old.ARW\",\"Items\":[]}");
        check(oldJob?.LongEdge == null, "old batch task restores with original-size export");
        var legacyPng = JsonSerializer.Deserialize<BatchJob>("{\"Version\":1,\"Png\":true,\"Source\":\"old.ARW\",\"Items\":[]}");
        check(legacyPng?.Format == ExportFormat.Png && legacyPng.Suffix == "png", "legacy PNG batch task restores its format");
        var dngJob = BatchJob.Create("source.ARW", settings.Capture(), null, "中性");
        dngJob.Format = ExportFormat.RenderedDng;
        var journalDirectory = Path.Combine(Path.GetTempPath(), "rawlab-dng-" + Guid.NewGuid().ToString("N"));
        try
        {
            var journal = new BatchJournal(journalDirectory);
            journal.Save(dngJob);
            var restoredDng = journal.Load();
            check(dngJob.Version == 2 && dngJob.Copy().Format == ExportFormat.RenderedDng &&
                  restoredDng?.Format == ExportFormat.RenderedDng && restoredDng.Suffix == "dng",
                "rendered DNG batch format persists with its suffix");
        }
        finally
        {
            try { Directory.Delete(journalDirectory, recursive: true); } catch (IOException) { }
        }

        var identityDirectory = Path.Combine(Path.GetTempPath(), "rawlab-identity-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(identityDirectory);
            var sourcePath = Path.Combine(identityDirectory, "raw-source-long-name.ARW");
            var aliasPath = Path.Combine(identityDirectory, "raw-alias.DNG");
            File.WriteAllBytes(sourcePath, [1, 2, 3]);
            if (OperatingSystem.IsWindows() && CreateHardLink(aliasPath, sourcePath, IntPtr.Zero))
            {
                using var sourceLock = WindowsFileIdentity.OpenReadLock(sourcePath);
                check(WindowsFileIdentity.IsSameFile(sourceLock, aliasPath),
                    "final output identity rejects an alias of the source RAW");
            }
            else Console.WriteLine("SKIP source-alias identity check: hard links unavailable");
        }
        finally
        {
            try { Directory.Delete(identityDirectory, recursive: true); } catch (IOException) { }
        }
        Console.WriteLine("PASS: Windows EXIF overlay, final export sizing and batch format regressions");
    }
}
