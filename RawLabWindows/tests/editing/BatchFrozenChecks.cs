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
        RunUniformX3fTargetModeChecks();
        RunCorruptJobIsolationChecks();
        RunFutureVersionJournalRefusalChecks();
        Console.WriteLine("PASS: per-target journal, cancellation, recovery and retry");
    }

    internal static void RunUniformX3fTargetModeChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-uniform-x3f-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var store = new EditStore(Path.Combine(root, "edits"));
            var savedLegacyPath = Path.Combine(root, "saved-legacy.X3F");
            var savedNormalPath = Path.Combine(root, "saved-normal.x3f");
            var unsavedNormalPath = Path.Combine(root, "unsaved-normal.x3f");
            var unsavedLegacyPath = Path.Combine(root, "unsaved-legacy.x3f");
            var nonX3fRawPath = Path.Combine(root, "target.nef");
            foreach (var path in new[] { savedLegacyPath, savedNormalPath, unsavedNormalPath, unsavedLegacyPath, nonX3fRawPath })
                File.WriteAllText(path, path);

            store.Save(savedLegacyPath, new Adjustments { X3fMode = X3fMode.Legacy }.Capture(), null);
            store.Save(savedNormalPath, new Adjustments { X3fMode = X3fMode.Normal }.Capture(), null);

            var defaultCalls = new List<string>();
            var resolver = PhotoInput.CreateBatchX3fModeResolver(
                store: store,
                defaultMode: path =>
                {
                    var name = Path.GetFileName(path);
                    defaultCalls.Add(name);
                    return name switch
                    {
                        "saved-legacy.X3F" => X3fMode.Normal,
                        "saved-normal.x3f" => X3fMode.Legacy,
                        "unsaved-normal.x3f" => X3fMode.Normal,
                        "unsaved-legacy.x3f" => X3fMode.Legacy,
                        _ => throw new InvalidOperationException("Unexpected default X3F probe: " + name),
                    };
                });

            var sourceLens = new LensSettings(
                Distortion: true,
                Tca: true,
                AutoCrop: false,
                Manual: true,
                ProfileId: "saved-lens-profile",
                FocalLength: 35,
                CropFactor: 1.5,
                Vignetting: true);
            var sourceSettings = new Adjustments
            {
                X3fMode = X3fMode.Legacy,
                AIDenoiseEnabled = true,
                Lens = sourceLens,
            };
            sourceSettings.Set(Parameter.Exposure, 0.75);
            var sourceSnapshot = sourceSettings.Capture();

            var resolvedSavedLegacy = PhotoInput.PrepareBatchSettings("source.x3f", savedLegacyPath, sourceSettings, resolver);
            Check(resolvedSavedLegacy.X3fMode == X3fMode.Legacy &&
                  resolvedSavedLegacy.AIDenoiseEnabled &&
                  resolvedSavedLegacy.Lens == sourceLens &&
                  resolvedSavedLegacy[Parameter.Exposure] == 0.75,
                "Saved legacy X3F mode wins over file default normal and retains source lens and AI flags");

            var resolvedSavedNormal = PhotoInput.PrepareBatchSettings("source.x3f", savedNormalPath, sourceSettings, resolver);
            Check(resolvedSavedNormal.X3fMode == X3fMode.Normal &&
                  !resolvedSavedNormal.AIDenoiseEnabled &&
                  !resolvedSavedNormal.Lens.Distortion &&
                  !resolvedSavedNormal.Lens.Tca &&
                  !resolvedSavedNormal.Lens.Vignetting &&
                  !resolvedSavedNormal.Lens.Enabled &&
                  !resolvedSavedNormal.Lens.AutoCrop &&
                  resolvedSavedNormal.Lens.Manual &&
                  resolvedSavedNormal.Lens.ProfileId == "saved-lens-profile" &&
                  resolvedSavedNormal.Lens.FocalLength == 35 &&
                  resolvedSavedNormal.Lens.CropFactor == 1.5 &&
                  resolvedSavedNormal[Parameter.Exposure] == 0.75,
                "Saved normal X3F mode wins over file default legacy and clears distortion, TCA, vignetting, and AI denoise");

            var resolvedUnsavedNormal = PhotoInput.PrepareBatchSettings("source.x3f", unsavedNormalPath, sourceSettings, resolver);
            Check(resolvedUnsavedNormal.X3fMode == X3fMode.Normal &&
                  !resolvedUnsavedNormal.AIDenoiseEnabled &&
                  !resolvedUnsavedNormal.Lens.Distortion &&
                  !resolvedUnsavedNormal.Lens.Tca &&
                  !resolvedUnsavedNormal.Lens.Vignetting &&
                  !resolvedUnsavedNormal.Lens.Enabled,
                "Unsaved X3F target falls back to file default normal and clears lens flags and AI denoise");

            var normalSource = sourceSettings.Clone();
            normalSource.X3fMode = X3fMode.Normal;
            var resolvedUnsavedLegacy = PhotoInput.PrepareBatchSettings("source.x3f", unsavedLegacyPath, normalSource, resolver);
            Check(resolvedUnsavedLegacy.X3fMode == X3fMode.Legacy &&
                  resolvedUnsavedLegacy.Lens == sourceLens,
                "Unsaved X3F target falls back to file default legacy instead of inheriting normal source mode");

            var resolvedNonX3f = PhotoInput.PrepareBatchSettings("source.x3f", nonX3fRawPath, sourceSettings,
                _ => throw new InvalidOperationException("Non-X3F target must not resolve X3F mode"));
            Check(ReferenceEquals(resolvedNonX3f, sourceSettings) &&
                  defaultCalls.SequenceEqual(["unsaved-normal.x3f", "unsaved-legacy.x3f"]) &&
                  sourceSettings.Capture().SameAs(sourceSnapshot),
                "Default X3F probe runs only for unsaved X3F targets and source settings remain immutable");

            var replacedPath = Path.Combine(root, "replaced.x3f");
            var corruptPath = Path.Combine(root, "corrupt.x3f");
            File.WriteAllText(replacedPath, "original-x3f");
            File.WriteAllText(corruptPath, "corrupt-x3f");
            store.Save(replacedPath, new Adjustments { X3fMode = X3fMode.Legacy }.Capture(), null);

            var output = Path.Combine(root, "uniform-output");
            Directory.CreateDirectory(output);
            var runnerJob = BatchJob.Create("source.x3f", sourceSnapshot, null, "Neutral");
            runnerJob.OutputDirectory = output;
            runnerJob.Items =
            [
                BatchItem.Create(replacedPath) with { Selected = true },
                BatchItem.Create(corruptPath) with { Selected = true },
                BatchItem.Create(savedNormalPath) with { Selected = true },
            ];

            File.WriteAllText(replacedPath, "replaced-with-different-size-bytes");

            var runnerProbeCalls = new List<string>();
            var runnerResolver = PhotoInput.CreateBatchX3fModeResolver(
                store: store,
                defaultMode: path =>
                {
                    var name = Path.GetFileName(path);
                    runnerProbeCalls.Add(name);
                    if (name == "replaced.x3f")
                        throw new InvalidOperationException("Replaced X3F must fail identity check before probing");
                    if (name == "corrupt.x3f")
                        throw new InvalidOperationException("corrupt X3F header");
                    throw new InvalidOperationException("Unexpected runner X3F probe: " + name);
                });

            Adjustments? renderedNormal = null;
            var runnerJournal = new BatchJournal(Path.Combine(root, "uniform-journal"));
            BatchRunner.Run(runnerJob, runnerJournal, false, CancellationToken.None, (_, _) => { },
                (_, effective, _, destination) =>
                {
                    renderedNormal = effective;
                    File.WriteAllText(destination, "ok");
                },
                runnerResolver);

            Check(!runnerJob.Interrupted &&
                  runnerJob.Items[0].Status == BatchStatus.Failed &&
                  runnerJob.Items[0].Error == Loc.Text("原始文件已被替换，请重新选择照片。") &&
                  runnerJob.Items[1].Status == BatchStatus.Failed &&
                  runnerJob.Items[1].Error == "corrupt X3F header" &&
                  runnerJob.Items[2].Status == BatchStatus.Succeeded &&
                  runnerProbeCalls.SequenceEqual(["corrupt.x3f"]) &&
                  renderedNormal is { X3fMode: X3fMode.Normal, AIDenoiseEnabled: false } &&
                  !renderedNormal.Lens.Distortion && !renderedNormal.Lens.Tca && !renderedNormal.Lens.Vignetting,
                "BatchRunner checks SameFile before X3F resolution and isolates corrupt X3F probe failures per item");
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine("PASS: uniform batch X3F target-first mode resolution");
    }

    internal static void RunCorruptJobIsolationChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-corrupt-journal-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var journal = new BatchJournal(root);
            var journalPath = Path.Combine(root, "job.json");

            // Write 1 truncated/garbled job file
            File.WriteAllText(journalPath, "{\"Id\": \"corrupt\", \"Version\": 3, \"Items\": [truncated...");

            // Load() isolates the corrupt file and allows recovery to proceed (returns null)
            var loaded = journal.Load();
            Check(loaded == null, "Corrupt job.json returns null on load without throwing");
            Check(!File.Exists(journalPath), "Corrupt job.json is moved from active path");
            var quarantined = Directory.GetFiles(root, "job.json.corrupt-*");
            Check(quarantined.Length == 1, "Corrupt job.json is quarantined with timestamp");

            // Subsequent Save() succeeds and is not blocked
            var input = Path.Combine(root, "test.raw");
            File.WriteAllText(input, "raw");
            var validJob = BatchJob.Create(input, new Adjustments().Capture(), null, "Neutral");
            journal.Save(validJob);
            Check(File.Exists(journalPath), "Subsequent Save() succeeds and writes new job.json");

            var reloaded = journal.Load();
            Check(reloaded != null && reloaded.Id == validJob.Id, "Reloading returns valid job");

            // Direct Save() when job.json is corrupt also isolates and succeeds
            File.WriteAllText(journalPath, "not valid json {");
            var anotherJob = BatchJob.Create(input, new Adjustments().Capture(), null, "Another");
            journal.Save(anotherJob);
            Check(File.Exists(journalPath), "Direct Save() isolates corrupt job and writes new job");
            Check(journal.LastQuarantinedPath != null && Path.GetFileName(journal.LastQuarantinedPath).StartsWith("job.json.corrupt-"),
                "LastQuarantinedPath points at the latest quarantined file");
            var reloadedAnother = journal.Load();
            Check(reloadedAnother != null && reloadedAnother.Id == anotherJob.Id, "Direct Save() job reloads successfully");
            Check(Directory.GetFiles(root, "job.json.corrupt-*").Length >= 2, "Both corrupt files are quarantined");

            Check(journal.Load() != null && journal.LastQuarantinedPath == null,
                "A clean load clears LastQuarantinedPath so stale quarantine notices do not surface");

            // 「读不了」不是「坏了」: a sharing violation must surface as I/O and must not isolate a good journal.
            var corruptCountBefore = Directory.GetFiles(root, "job.json.corrupt-*").Length;
            var healthyBefore = File.ReadAllText(journalPath);
            using (new FileStream(journalPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                var readFailed = false;
                try { journal.Load(); } catch (IOException) { readFailed = true; }
                Check(readFailed, "An unreadable job.json must surface as an I/O failure instead of returning null");
                Check(journal.LastQuarantinedPath == null, "A read failure must not be recorded as a quarantine");
            }
            Check(File.Exists(journalPath) && File.ReadAllText(journalPath) == healthyBefore,
                "An unreadable but good job.json must stay untouched on its active path");
            Check(Directory.GetFiles(root, "job.json.corrupt-*").Length == corruptCountBefore,
                "A read failure must not quarantine a healthy journal");
        }
        finally
        {
            Directory.Delete(root, true);
        }
        Console.WriteLine("PASS: corrupt batch journal entry isolation and save unblocking");
    }

    internal static void RunFutureVersionJournalRefusalChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-future-journal-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var input = Path.Combine(root, "future.raw");
            File.WriteAllText(input, "raw");
            // Fabricate a GOOD record whose only anomaly is a future version field.
            var snapshot = new Adjustments().Capture() with { HDR = new HDRSettings { Mode = HDRMode.Hdr }, ProRAWDecodeVersion = HDRNative.ProRAWDecodeVersion };
            void Refusal(string caseName, string pattern, string replacement)
            {
                var caseRoot = Path.Combine(root, caseName);
                var journal = new BatchJournal(caseRoot);
                var job = BatchJob.Create(input, snapshot, null, "Neutral");
                job.SourceIsProRAW = true;
                journal.Save(job);
                var journalPath = Path.Combine(caseRoot, "job.json");
                var original = File.ReadAllText(journalPath);
                var patched = original.Replace(pattern, replacement);
                File.WriteAllText(journalPath, patched);
                Check(patched != original, "Future-version fixture must patch " + caseName);
                var loadRejected = false;
                try { journal.Load(); } catch (Exception) { loadRejected = true; }
                Check(loadRejected, $"{caseName}: future-version journal must not load as corrupt-null");
                Check(File.Exists(journalPath), $"{caseName}: future-version journal must stay on its active path");
                Check(Directory.GetFiles(caseRoot, "job.json.corrupt-*").Length == 0, $"{caseName}: future version must refuse quarantine");
                var saveRejected = false;
                try { journal.Save(job); } catch (Exception) { saveRejected = true; }
                Check(saveRejected, $"{caseName}: save must refuse to overwrite a future-version journal");
                Check(File.ReadAllText(journalPath) == patched,
                    $"{caseName}: rejected save leaves the future record untouched");
                Directory.Delete(caseRoot, true);
            }
            Refusal("version", "\"Version\":1", "\"Version\":9");
            Refusal("proraw", "\"ProRAWDecodeVersion\":2", "\"ProRAWDecodeVersion\":99");
            Refusal("recipe", "\"MasterRecipeSettingsVersion\":3", "\"MasterRecipeSettingsVersion\":5");
            Refusal("hdr", "\"hdr_processing_version\":1", "\"hdr_processing_version\":9");
        }
        finally
        {
            Directory.Delete(root, true);
        }
        Console.WriteLine("PASS: future-version batch journal refuses quarantine and overwrite");
    }
}
