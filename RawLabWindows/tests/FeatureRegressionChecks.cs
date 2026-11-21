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
        check(ExportSize.Parse("1") == 1 && ExportSize.Parse("65500") == 65500 && ExportSize.Parse("0") == null && ExportSize.Parse("65501") == null,
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
        var amplifyDirectory = Path.Combine(Path.GetTempPath(), "rawlab-journal-amplify-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(amplifyDirectory);
            var amplifyJournal = new BatchJournal(amplifyDirectory);
            var amplifySource = Path.Combine(amplifyDirectory, "source.arw"); File.WriteAllBytes(amplifySource, [11, 23, 47]);
            BatchJob AmplifyJob(string look, BatchStatus status)
            {
                var job = BatchJob.Create(amplifySource, new Adjustments().Capture(), null, look);
                job.Format = ExportFormat.Png; job.OutputDirectory = amplifyDirectory;
                job.Items = [BatchItem.Create(amplifySource) with { Selected = true, Status = status }];
                return job;
            }
            // 稳态写入：每任务至多首写整读一次，之后靠本进程 USN/stat 快照（Usn>0 才可信）跳过重读（撤跳过逻辑必红）。
            amplifyJournal.Save(AmplifyJob("A", BatchStatus.Waiting));
            amplifyJournal.Save(AmplifyJob("B", BatchStatus.Waiting));
            amplifyJournal.Save(AmplifyJob("C", BatchStatus.Waiting));
            check(amplifyJournal.DiskReloads == 1, "steady-state journal saves reload the disk file once, not once per write");
            // 外部改动检测：未来版本文件必须被重读并 fail-closed，而不是被静默覆盖（去掉重读必红）。
            var journalPath = Path.Combine(amplifyDirectory, "job.json");
            var futureJson = new System.Text.RegularExpressions.Regex("\"[Vv]ersion\":\\s*\\d+")
                .Replace(File.ReadAllText(journalPath), "\"Version\": 999", 1);
            File.WriteAllText(journalPath, futureJson);
            var amplifyRejected = false;
            try { amplifyJournal.Save(AmplifyJob("D", BatchStatus.Waiting)); } catch (Exception) { amplifyRejected = true; }
            check(amplifyRejected && File.ReadAllText(journalPath).Contains("999", StringComparison.Ordinal) && amplifyJournal.DiskReloads == 2,
                "an externally replaced future-version journal triggers exactly one reload and fails closed");
            // 外部损坏：下一次 Save 重读并隔离，然后正常写出（跳过逻辑不得吞掉外部损坏）。
            File.WriteAllText(journalPath, "{corrupt-amplify");
            amplifyJournal.Save(AmplifyJob("E", BatchStatus.Waiting));
            check(amplifyJournal.LastQuarantinedPath != null && amplifyJournal.DiskReloads == 3 &&
                  amplifyJournal.Load()?.LookName == "E",
                "an externally corrupted journal is quarantined on the next Save instead of being skipped");
            // 等长覆写红锚（hosted CI run 43751010759 根因）：NTFS 内核时钟以 ~15.6ms tick 印刻时戳，
            // 同 tick 原地覆写只改版本号末位 → (Length, mtime) 逐位相同。紧跟一次成功 Save 重建可信指纹、
            // 中途无 Load，跳过判定只能靠 USN/stat 快照识破：回退成 (size,mtime) 二维或去掉 USN 时本断言必红。
            amplifyJournal.Save(AmplifyJob("E", BatchStatus.Waiting));
            var sameLength = File.ReadAllText(journalPath);
            var equalFuture = new System.Text.RegularExpressions.Regex("\"[Vv]ersion\":\\s*\\d+")
                .Replace(sameLength, m => m.Value[..^1] + "9", 1);
            check(equalFuture.Length == sameLength.Length && equalFuture != sameLength,
                "the test fixture patches the journal version in place without changing the file length");
            File.WriteAllText(journalPath, equalFuture);
            var equalRejected = false;
            try { amplifyJournal.Save(AmplifyJob("G", BatchStatus.Waiting)); } catch (Exception) { equalRejected = true; }
            check(equalRejected && File.ReadAllText(journalPath) == equalFuture && amplifyJournal.DiskReloads == 5,
                "an equal-length future-version overwrite is caught by the USN stat fingerprint and fails closed without rewriting");
            File.WriteAllText(journalPath, sameLength);
            amplifyJournal.Save(AmplifyJob("G", BatchStatus.Waiting));
            // 回归：写入中途被杀留下完整旧文件与游离 tmp → 启动 Load 仍恢复 Running→Waiting 且不误判损坏。
            amplifyJournal.Save(AmplifyJob("F", BatchStatus.Running));
            File.WriteAllText(Path.Combine(amplifyDirectory, "job.json.tmp-stray"), "stray");
            var reopened = new BatchJournal(amplifyDirectory);
            var recovered = reopened.Load();
            check(recovered != null && recovered.Items[0].Status == BatchStatus.Waiting && recovered.Interrupted,
                "mid-write kill leaves the previous journal loadable with Running derived back to Waiting without false quarantine");
            reopened.Save(recovered!);
            check(reopened.DiskReloads == 1, "a reopened journal runs one full validation on its first Save and recovers the job");
        }
        finally
        {
            try { Directory.Delete(amplifyDirectory, recursive: true); } catch (IOException) { }
        }
        Console.WriteLine("PASS: Windows EXIF overlay, final export sizing and batch format regressions");
    }
}
