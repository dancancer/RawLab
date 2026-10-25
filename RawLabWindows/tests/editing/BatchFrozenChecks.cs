using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

static class BatchFrozenChecks
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-frozen-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var inputs = Enumerable.Range(0, 3).Select(i => Path.Combine(root, $"{i}.raw")).ToArray();
            foreach (var input in inputs) File.WriteAllText(input, input);
            var output = Path.Combine(root, "output"); Directory.CreateDirectory(output);
            var job = BatchJob.Create(inputs[0], new Adjustments().Capture(), null, "Neutral");
            job.OutputDirectory = output;
            job.Items = inputs.Select(input => BatchItem.Create(input) with { Selected = true }).ToList();
            var json = JsonSerializer.SerializeToNode(job)!;
            json["settings_mode"] = "per_target_frozen";
            var rejected = false;
            try { new BatchJournal(Path.Combine(root, "invalid")).Save(json.Deserialize<BatchJob>()!); }
            catch (Exception) { rejected = true; }
            Check(rejected, "Per-target mode must not silently become a uniform legacy job");
            json["Version"] = 3;
            for (var i = 0; i < inputs.Length; i++)
            {
                var settings = new Adjustments(); settings.Set(Parameter.Exposure, (i + 1) * .5);
                json["Items"]![i]!["Frozen"] = new JsonObject {
                    ["Version"] = 1, ["SettingsVersion"] = 1, ["Ordinal"] = i,
                    ["Settings"] = JsonSerializer.SerializeToNode(settings.Capture()), ["LookName"] = $"Photo{i}",
                    ["OutputFormat"] = (int)ExportFormat.Png, ["LongEdge"] = 1024
                };
            }
            var frozen = json.Deserialize<BatchJob>()!;
            foreach (var mode in new string?[] { null, "uniform_frozen" })
            {
                var downgraded = JsonNode.Parse(json.ToJsonString())!;
                if (mode == null) downgraded.AsObject().Remove("settings_mode"); else downgraded["settings_mode"] = mode;
                rejected = false;
                try { new BatchJournal(Path.Combine(root, "invalid-mode")).Save(downgraded.Deserialize<BatchJob>()!); }
                catch (Exception) { rejected = true; }
                Check(rejected, "Frozen items cannot silently downgrade to a global snapshot");
            }
            var copied = frozen.Copy();
            var exposedSettings = copied.Items[0].Frozen!.Settings;
            exposedSettings.Values[(int)Parameter.Exposure] = 3;
            Check(copied.Items[0].Frozen!.Settings.Restore()[Parameter.Exposure] == .5,
                "Frozen settings must retain ownership of mutable native values");
            var duplicated = frozen.Copy();
            duplicated.Items[1] = duplicated.Items[0] with { Id = Guid.NewGuid(),
                Frozen = duplicated.Items[1].Frozen };
            rejected = false;
            try { new BatchJournal(Path.Combine(root, "invalid-identity")).Save(duplicated); }
            catch (Exception) { rejected = true; }
            Check(rejected, "Frozen target identities cannot be duplicated with a new row UUID");
            var journal = new BatchJournal(Path.Combine(root, "journal"));
            var exposures = new List<double>();
            using var cancellation = new CancellationTokenSource();
            BatchRunner.Run(frozen, journal, false, cancellation.Token, (_, _) => { }, (_, settings, _, destination, edge) => {
                exposures.Add(settings[Parameter.Exposure]);
                Check(Path.GetExtension(destination) == ".png" && edge == 1024, "Each target freezes its output settings");
                File.WriteAllText(destination, "first"); cancellation.Cancel();
            });
            Check(exposures.SequenceEqual([.5]), "Cancel keeps first target's distinct settings");
            var resumed = journal.Load()!;
            BatchRunner.Run(resumed, journal, false, CancellationToken.None, (_, _) => { }, (input, settings, _, destination) => {
                exposures.Add(settings[Parameter.Exposure]);
                if (input == inputs[1]) throw new InvalidOperationException("retry me");
                File.WriteAllText(destination, "resumed");
            });
            Check(exposures.SequenceEqual([.5, 1, 1.5]), "Resume retains order and does not repeat successful targets");
            resumed = journal.Load()!;
            BatchRunner.Run(resumed, journal, true, CancellationToken.None, (_, _) => { }, (_, settings, _, destination) => {
                exposures.Add(settings[Parameter.Exposure]); File.WriteAllText(destination, "retry");
            });
            Check(exposures.SequenceEqual([.5, 1, 1.5, 1]) && resumed.SucceededCount == 3,
                "Failed-only retry uses the original frozen settings");
            json["Items"]![0]!.AsObject().Remove("Frozen");
            rejected = false;
            try { journal.Save(json.Deserialize<BatchJob>()!); } catch (Exception) { rejected = true; }
            Check(rejected, "Missing per-target snapshots must not fall back to global settings");
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine("PASS: per-target journal, cancellation, recovery and retry");
    }
}
