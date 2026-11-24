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
    public void DefaultOffLeaseRelaunchAndAutoExpiryBehaveDeterministically()
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
            store1.RecordBreadcrumb("import", "open", "Opened photo", new() { ["extension"] = "arw" });
            Assert.True(store1.GetSnapshot().BreadcrumbCount >= 2);

            now = now.AddMinutes(2);
            var store2 = new DiagnosticSessionStore(root, TimeSpan.FromMinutes(30), () => now);
            Assert.True(store2.ResumeOnLaunch().IsRecording);

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
    public async Task RedactionZipArchiveAndSlsUploadPayloadMatchContract()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-diag-zip-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new DiagnosticSessionStore(root);
            store.SetRecordingEnabled(true);
            store.RecordBreadcrumb(
                "import",
                "open",
                @"Failed opening C:\Users\Alice\Pictures\Secret\DSC0001.ARW and file:///Users/bob/photo.cr3",
                new() { ["extension"] = "privateformat", ["bytes"] = "123456" },
                level: "warn");
            store.RecordError("export", "save", new IOException(@"Cannot write D:\Private\out.jpg"));

            var zipPath = Path.Combine(root, "out.zip");
            var pkg = store.BuildReportPackage(@"导出 C:\Users\Alice\Desktop\test.arw 报错", stopActiveRecording: false);
            pkg.ExportZip(zipPath);

            var combined = pkg.ManifestJson + "\n" + pkg.BreadcrumbsJsonl + "\n" + pkg.RecentErrorsJson;
            Assert.DoesNotContain("Alice", combined, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("DSC0001", combined, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("privateformat", combined, StringComparison.OrdinalIgnoreCase);
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
            var uploadedCode = await store.UploadAsync("Repro note", fake,
                new Uri(SLSDiagnosticWebTracking.ProductionUrl));
            Assert.True(SLSDiagnosticWebTracking.IsValidReportId(uploadedCode));
            Assert.False(store.IsRecording);
            Assert.NotNull(fake.CapturedBody);

            var envelope = JsonNode.Parse(Encoding.UTF8.GetString(fake.CapturedBody!))!.AsObject();
            Assert.Equal("rawlab-diagnostic-v1", (string?)envelope["__topic__"]);
            Assert.Equal("windows", (string?)envelope["__source__"]);
            Assert.Equal(uploadedCode, (string?)envelope["__logs"]?[0]?["report_id"]
                ?? (string?)envelope["__logs__"]?[0]?["report_id"]);
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
