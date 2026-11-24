using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
public sealed class DiagnosticSessionStoreTests
{
    [Fact]
    public void DefaultOffIdempotentResumeAndLeaseAutoExpiryBehaveDeterministically()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-diag-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = new DateTimeOffset(2026, 11, 24, 15, 0, 0, TimeSpan.Zero);
            var store1 = new DiagnosticSessionStore(root, TimeSpan.FromMinutes(30), () => now);
            Assert.False(store1.IsRecording);
            store1.RecordBreadcrumb("import", "ignored", "Should not record while off");
            Assert.Equal(0, store1.GetSnapshot().BreadcrumbCount);

            Assert.True(store1.SetRecordingEnabled(true).IsRecording);
            for (var i = 0; i < 5; i++)
            {
                Assert.True(store1.ResumeOnLaunch().IsRecording);
            }
            store1.RecordBreadcrumb("import", "open", "Opened photo", new() { ["extension"] = "arw" });
            Assert.True(store1.GetSnapshot().BreadcrumbCount >= 2);

            now = now.AddMinutes(2);
            var store2 = new DiagnosticSessionStore(root, TimeSpan.FromMinutes(30), () => now);
            for (var i = 0; i < 4; i++)
            {
                Assert.True(store2.ResumeOnLaunch().IsRecording);
            }

            now = now.AddMinutes(2);
            var store3 = new DiagnosticSessionStore(root, TimeSpan.FromMinutes(30), () => now);
            var secondRelaunch = store3.ResumeOnLaunch();
            Assert.False(secondRelaunch.IsRecording);
            Assert.True(secondRelaunch.RecoveredPreviousSession);
            Assert.True(secondRelaunch.HasExportableLogs);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task RedactionZipArchiveReadablePreviewAndFreshUploadCodesMatchContract()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-diag-zip-" + Guid.NewGuid().ToString("N"));
        try
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var realProfilePhoto = Path.Combine(userProfile, "My Pictures", "SecretVacation", "DSC0001.ARW");
            var tempPhoto = Path.Combine(Path.GetTempPath(), "import-stage", "IMG 1234.DNG");
            var spacedDrivePhoto = string.Join("\\", "D:", "My Photos", "Summer 2026", "IMG_99.CR3");

            var store = new DiagnosticSessionStore(root);
            store.SetRecordingEnabled(true);
            store.RecordBreadcrumb(
                "import",
                "open",
                $"Failed opening {realProfilePhoto} and {spacedDrivePhoto}; temp {tempPhoto} and bare_portrait.nef",
                new() { ["extension"] = "privateformat", ["bytes"] = "123456", ["source"] = realProfilePhoto },
                level: "warn");
            store.RecordError("export", "save", new IOException($"Cannot write {spacedDrivePhoto}"));

            var zipPath = Path.Combine(root, "out.zip");
            var pkg = store.BuildReportPackage($"导出 {realProfilePhoto} 中文备注正常显示", stopActiveRecording: false);
            pkg.ExportZip(zipPath);

            var combined = pkg.ManifestJson + "\n" + pkg.BreadcrumbsJsonl + "\n" + pkg.RecentErrorsJson;
            foreach (var forbidden in new[]
                     {
                         "My Pictures",
                         "SecretVacation",
                         "DSC0001",
                         "import-stage",
                         "IMG 1234",
                         "My Photos",
                         "Summer 2026",
                         "IMG_99",
                         "bare_portrait",
                         "privateformat",
                         "\\u003C",
                     })
            {
                Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
            }
            Assert.Contains("<user>", combined, StringComparison.Ordinal);
            Assert.Contains("<temp>", combined, StringComparison.Ordinal);
            Assert.Contains("<file>.nef", combined, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("中文备注正常显示", combined, StringComparison.Ordinal);
            Assert.Contains("123456", combined, StringComparison.Ordinal);

            using (var zip = ZipFile.OpenRead(zipPath))
            {
                var names = zip.Entries.Select(e => e.FullName).ToHashSet(StringComparer.Ordinal);
                Assert.Contains("manifest.json", names);
                Assert.Contains("breadcrumbs.jsonl", names);
                Assert.Contains("recent-errors.json", names);
                Assert.Contains("README.txt", names);
            }

            Assert.Throws<DiagnosticUploadException>(() =>
                SLSDiagnosticWebTracking.ValidateEndpoint("http://proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track"));
            Assert.Throws<DiagnosticUploadException>(() =>
                SLSDiagnosticWebTracking.ValidateEndpoint("https://attacker.invalid/logstores/diag/track"));

            var fake = new FakeUploadTransport();
            var firstCode = await store.UploadAsync("First upload", fake, new Uri(SLSDiagnosticWebTracking.ProductionUrl));
            Assert.True(SLSDiagnosticWebTracking.IsValidReportId(firstCode));
            Assert.False(store.IsRecording);

            store.RecordError("export", "saveRetry", new IOException("Second failure"));
            var secondCode = await store.UploadAsync("Second upload", fake, new Uri(SLSDiagnosticWebTracking.ProductionUrl));
            Assert.NotEqual(firstCode, secondCode);

            var envelope = JsonNode.Parse(Encoding.UTF8.GetString(fake.CapturedBody!))!.AsObject();
            Assert.Equal("rawlab-diagnostic-v1", (string?)envelope["__topic__"]);
            Assert.Equal("windows", (string?)envelope["__source__"]);
            Assert.Equal(secondCode, (string?)envelope["__logs__"]?[0]?["report_id"]);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FakeUploadTransport : IDiagnosticUploadTransport
    {
        public byte[]? CapturedBody { get; private set; }

        public Task UploadAsync(Uri endpoint, byte[] body, CancellationToken cancellationToken = default)
        {
            CapturedBody = body;
            return Task.CompletedTask;
        }
    }
}
