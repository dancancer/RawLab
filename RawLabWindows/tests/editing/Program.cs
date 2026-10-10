using RawLab.Windows;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var root = Path.Combine(Path.GetTempPath(), "rawlab-edit-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    FeatureRegressionChecks.Run(Check);
    var a = Path.Combine(root, "a", "same.ARW");
    var b = Path.Combine(root, "b", "same.ARW");
    foreach (var path in new[] { a, b }) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, path); }
    var state = new Adjustments(); state.ResolveWhiteBalance((5200, 8)); state.Set(Parameter.Temperature, 6000); state.Set(Parameter.Exposure, .75);
    var saved = state.Capture();
    state.Denoise = DenoiseSettings.Clean;
    Check(!saved.SameAs(state.Capture()), "denoise changes mark the snapshot dirty");
    saved = state.Capture();
    var storePath = Path.Combine(root, "edits");
    var store = new EditStore(storePath);
    store.Save(a, saved, "builtin:provia.cube");
    var reopened = new EditStore(storePath);
    var restored = reopened.Find(a)!;
    Check(restored.Settings.SameAs(saved), "settings survive store restart");
    Check(!restored.Settings.Restore().CameraWhiteBalance, "custom white balance mode survives");
    Check(restored.Settings.Restore().Denoise == DenoiseSettings.Clean, "denoise survives store restart");
    var legacy = System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(saved))!.AsObject();
    legacy.Remove("Denoise");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Denoise == new DenoiseSettings(), "older records default to disabled denoise");
    Check(reopened.Find(b) == null, "same basename does not share edits");
    state.ResetAll(); reopened.Save(a, state.Capture(), null);
    Check(new EditStore(storePath).Find(a)!.Settings.Restore()[Parameter.Exposure] == 0, "reset persists");
    File.AppendAllText(a, "replacement");
    Check(reopened.Find(a) == null, "replaced input does not inherit edits");
    var blocked = Path.Combine(root, "blocked"); File.WriteAllText(blocked, "file");
    try { new EditStore(blocked).Save(b, saved, null); throw new Exception("write failure swallowed"); }
    catch (IOException) { }

    var output = Path.Combine(root, "output"); Directory.CreateDirectory(output);
    var oldOutput = Path.Combine(output, "same-Velvia.jpg"); File.WriteAllText(oldOutput, "existing");
    var job = BatchJob.Create(a, saved, null, "Velvia");
    job.OutputDirectory = output;
    job.Items.Add(BatchItem.Create(a) with { Selected = true });
    job.Items.Add(BatchItem.Create(b) with { Selected = true });
    var journal = new BatchJournal(Path.Combine(root, "batch"));
    var calls = new List<string>();
    BatchRunner.Run(job, journal, false, CancellationToken.None, (_, _) => { }, (input, settings, _, destination) => {
        calls.Add(input); Check(settings[Parameter.Exposure] == .75, "frozen source parameters");
        Check(settings.Denoise == DenoiseSettings.Clean, "frozen source denoise");
        if (input == b) throw new InvalidOperationException("invalid RAW");
        File.WriteAllText(destination, "rendered");
    });
    Check(job.Items[0].Status == BatchStatus.Succeeded && job.Items[1].Status == BatchStatus.Failed, "per-file failure result");
    Check(File.ReadAllText(oldOutput) == "existing", "existing output not overwritten");
    calls.Clear();
    BatchRunner.Run(job, journal, true, CancellationToken.None, (_, _) => { }, (input, _, _, destination) => { calls.Add(input); File.WriteAllText(destination, "retry"); });
    Check(calls.SequenceEqual(new[] { b }), "retry skips succeeded items");
    Check(journal.Load()!.Items.All(x => x.Status == BatchStatus.Succeeded), "success persisted");

    var cancelled = BatchJob.Create(a, saved, null, "Velvia"); cancelled.OutputDirectory = output;
    cancelled.Items.Add(BatchItem.Create(a) with { Selected = true }); cancelled.Items.Add(BatchItem.Create(b) with { Selected = true });
    using var cancellation = new CancellationTokenSource();
    BatchRunner.Run(cancelled, journal, false, cancellation.Token, (_, _) => { }, (_, _, _, destination) => { File.WriteAllText(destination, "first"); cancellation.Cancel(); });
    Check(cancelled.Cancelled && cancelled.Items[0].Status == BatchStatus.Succeeded && cancelled.Items[1].Status == BatchStatus.Waiting, "cancel preserves completed output");
    cancelled.Items[1] = cancelled.Items[1] with { Status = BatchStatus.Running };
    journal.Save(cancelled);
    var recovered = journal.Load()!;
    Check(recovered.Settings.Restore().Denoise == DenoiseSettings.Clean, "denoise survives journal recovery");
    Check(recovered.Interrupted && recovered.Items[1].Status == BatchStatus.Waiting, "interrupted running work recovers");
    Directory.CreateDirectory(Path.Combine(output, "directory-collision.jpg"));
    Check(Path.GetFileName(BatchRunner.UniqueOutput(output, "directory-collision", "jpg")) == "directory-collision-1.jpg", "directory names also occupy output names");
    var storageFailure = BatchJob.Create(a, saved, null, "Velvia"); storageFailure.OutputDirectory = output;
    storageFailure.Items.Add(BatchItem.Create(a) with { Selected = true }); storageFailure.Items.Add(BatchItem.Create(b) with { Selected = true });
    var storageCalls = 0;
    try {
        BatchRunner.Run(storageFailure, journal, false, CancellationToken.None, (_, _) => { }, (_, _, _, _) => {
            storageCalls++; throw new OutputWriteException("output storage unavailable");
        });
        throw new Exception("global output failure swallowed");
    } catch (OutputWriteException) { }
    Check(storageCalls == 1 && journal.Load()!.Interrupted, "global output failure stops and is recoverable");
    var look = Path.Combine(root, "look.cube"); File.WriteAllText(look, "frozen look");
    var draft = BatchJob.Create(a, saved, look, "Look"); journal.FreezeLook(draft); journal.Save(draft);
    File.WriteAllText(look, "changed live look");
    Check(File.ReadAllText(draft.Look!) == "frozen look", "look resource is frozen, not a live path");
    journal.Discard(draft);
    Check(journal.Load() == null && !File.Exists(draft.Look), "discard removes journal and owned look but no source");
    Check(File.Exists(look) && File.Exists(a), "discard preserves original resources");
    Console.WriteLine("PASS: Windows edit persistence, identity, WB, reset, snapshot, collision, failures, retry and recovery");
}
finally { Directory.Delete(root, true); }
