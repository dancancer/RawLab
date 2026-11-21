using System.IO;
using System.Security.Cryptography;
using System.Windows;
using RawLab.Windows;

internal static class DefaultIsolationChecks
{
    private sealed record Stamp(string Path, string Hash, DateTime Written);

    internal static void Run(string output, Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetFullPath(output), Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(root);
        var caseIndex = 0;
        foreach (var status in new[] { BatchStatus.Running, BatchStatus.Publishing })
        {
            // Prove these fixtures exercise the actual recovery cleanup, not inert JSON.
            var control = Create("control-" + (int)status, status);
            var recovered = control.Journal.Load()!;
            check(!File.Exists(control.Staging) && recovered.Interrupted,
                "Recovery control really cleans the private staging file: " + status);
            check(File.Exists(control.Record) && File.Exists(control.Published),
                "Recovery control retains the private journal and published output: " + status);
            Reject(status);
        }
        Reject(BatchStatus.Running, locked: true);
        Reject(BatchStatus.Publishing, malformed: true);
        Console.WriteLine("Default isolation fixtures: " + root);

        void Reject(BatchStatus status, bool locked = false, bool malformed = false)
        {
            var name = $"preserve-{status}-{locked}-{malformed}";
            var fixture = Create("case-" + caseIndex++, status);
            if (malformed) File.WriteAllText(fixture.Record, "not a batch journal");
            var before = Snapshot(fixture.Directory);
            var rejected = false;
            using (var held = locked ? new FileStream(fixture.Record, FileMode.Open, FileAccess.ReadWrite, FileShare.None) : null)
            {
                try
                {
                    TestWindowState.PreserveExistingBatch(fixture.Journal.DirectoryPath);
                }
                catch (Exception error) when (error is InvalidOperationException or IOException)
                {
                    rejected = locked || error.Message.Contains("Preserve existing batch job: " + fixture.Record, StringComparison.Ordinal);
                }
            }
            var after = Snapshot(fixture.Directory);
            check(rejected, "Default suite refuses an existing journal before initializing fixtures: " + name);
            check(before.SequenceEqual(after), "Default refusal preserves journal, staging and output bytes/timestamps: " + name);
            check(Application.Current == null, "Default refusal creates no WPF application: " + name);
        }

        (string Directory, BatchJournal Journal, string Record, string Staging, string Published) Create(string name, BatchStatus status)
        {
            var directory = Path.Combine(root, name); Directory.CreateDirectory(directory);
            var input = Path.Combine(directory, "source.arw"); File.WriteAllBytes(input, [11, 23, 47]);
            var published = Path.Combine(directory, "published.png"); File.WriteAllBytes(published, [89, 101, 127]);
            var job = BatchJob.Create(input, new Adjustments().Capture(), null, "Neutral");
            job.Format = ExportFormat.Png; job.Started = true; job.OutputDirectory = directory;
            var item = BatchItem.Create(input) with { Selected = true, Status = status, Output = published, CompletedIdentity = OriginalIdentity.Read(published) };
            job.Items = [item];
            var journal = new BatchJournal(Path.Combine(directory, "Batch")); journal.Save(job);
            var staging = job.TemporaryPath(item); File.WriteAllBytes(staging, [131, 149, 167, 181]);
            return (directory, journal, Path.Combine(journal.DirectoryPath, "job.json"), staging, published);
        }
    }

    private static Stamp[] Snapshot(string directory) => Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
        .Order(StringComparer.Ordinal).Select(path => new Stamp(path, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))), File.GetLastWriteTimeUtc(path))).ToArray();
}
