using RawLab.Windows;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var root = Path.Combine(Path.GetTempPath(), "rawlab-edit-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    Check(typeof(Adjustments).GetProperty("MasterRecipeID") != null, "master recipes must be part of persisted adjustments");
    Check(MasterRecipe.All.Count == 14, "all fourteen shared recipes load");
    foreach (var recipe in MasterRecipe.All) {
        var preset = new Adjustments(); preset.ResolveWhiteBalance((5000, 8));
        preset.Set(Parameter.Temperature, 8000); preset.Set(Parameter.Sharpening, 75);
        preset.Hsl = preset.Hsl.WithValue(0, 7, 90); preset.ApplyMasterRecipe(recipe);
        Check(preset.Hsl.Equals(recipe.Hsl.Settings()) && preset[Parameter.Exposure] == recipe.ExposureDelta &&
              preset[Parameter.Highlights] == recipe.HighlightsDelta && preset[Parameter.Tint] == recipe.TintDelta,
              recipe.Id + " overwrites visible settings and HSL");
        Check(preset[Parameter.Temperature] == 8000 && preset[Parameter.Sharpening] == 75, "unrelated settings survive");
        preset.Hsl = preset.Hsl.WithValue(0, 7, 37).WithValue(1, 5, -80);
        var originalHsl = preset.Hsl;
        foreach (var strength in new[] { 0.0, .5, 1, 2 }) {
            preset.Set(Parameter.Strength, strength * 100);
            var request = preset.Request("fixture.ARW", "look.cube", 64, null);
            Check(Math.Abs(request.ExposureEv - recipe.ExposureDelta * strength) < 1e-5 &&
                  Math.Abs(request.Highlights + recipe.HighlightsDelta * strength / 100) < 1e-5 &&
                  Math.Abs(request.Contrast - (1 + recipe.ContrastDelta * strength / 100)) < 1e-5,
                  "recipe strength scales current controls");
            Check(preset.RenderHsl.Value(0, 7) == 37 * strength &&
                  preset.RenderHsl.Value(1, 5) == Math.Max(-100, -80 * strength) && preset.Hsl.Equals(originalHsl),
                  "HSL scaling preserves fractions and limits without changing visible values");
            var restoredRecipe = System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(
                System.Text.Json.JsonSerializer.Serialize(preset.Capture()))!.Restore();
            Check(restoredRecipe.MasterRecipeID == recipe.Id && restoredRecipe.RenderHsl.Equals(preset.RenderHsl), "recipe snapshot roundtrip");
        }
        preset.ClearMasterRecipe();
        Check(preset.MasterRecipeID == null && preset.RenderHsl.Equals(originalHsl), "ordinary HSL remains independent of strength");
    }
    FeatureRegressionChecks.Run(Check);
    var a = Path.Combine(root, "a", "same.ARW");
    var b = Path.Combine(root, "b", "same.ARW");
    foreach (var path in new[] { a, b }) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, path); }
    var state = new Adjustments(); state.ResolveWhiteBalance((5200, 8)); state.Set(Parameter.Temperature, 6000); state.Set(Parameter.Exposure, .75);
    Check(state.ExposureMode == 1 && state.Hsl.IsIdentity, "new photos use preview exposure and identity HSL");
    state.Hsl = state.Hsl.WithValue(1, 0, -60);
    var frozenHsl = state.Capture();
    state.Hsl = state.Hsl.WithValue(1, 0, 20);
    Check(frozenHsl.Restore().Hsl.Value(1, 0) == -60 && !frozenHsl.SameAs(state.Capture()), "HSL snapshots freeze values and detect edits");
    state.SetEffect(PhotoEffectParameter.VignetteAmount, -40);
    state.SetEffect(PhotoEffectParameter.GrainAmount, 65);
    state.DisplayChromaDenoise = 1;
    state.Lens = new LensSettings(true,true,false,true,"Maker\n镜头 Model,|\nMount\n1.000000");
    Check(new LensSettings(Manual:true).CoreProfileId == "__rawlab_manual_selection_required__", "manual lens requires selection");
    var saved = state.Capture();
    state.Denoise = DenoiseSettings.Clean;
    Check(!saved.SameAs(state.Capture()), "denoise changes mark the snapshot dirty");
    state.DisplayChromaDenoise = 0;
    Check(!saved.SameAs(state.Capture()), "display chroma changes mark the snapshot dirty");
    state.DisplayChromaDenoise = 1;
    saved = state.Capture();
    var storePath = Path.Combine(root, "edits");
    var store = new EditStore(storePath);
    store.Save(a, saved, "builtin:provia.cube");
    var reopened = new EditStore(storePath);
    var restored = reopened.Find(a)!;
    Check(restored.Settings.SameAs(saved), "settings survive store restart");
    Check(restored.Settings.Restore().Lens == saved.Lens, "lens survives store restart");
    Check(!saved.SameAs(saved with { Lens = new() }), "lens changes mark the snapshot dirty");
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.LensProfile>() == 908 &&
          System.Runtime.InteropServices.Marshal.SizeOf<Native.LensReport>() == 1440 &&
          System.Runtime.InteropServices.Marshal.SizeOf<Native.LensConfig>() == 32, "lens ABI layout");
    Check(!restored.Settings.Restore().CameraWhiteBalance, "custom white balance mode survives");
    Check(restored.Settings.Restore().Denoise == DenoiseSettings.Clean, "denoise survives store restart");
    Check(restored.Settings.Restore().Effects == state.Effects && restored.Settings.Restore().DisplayChromaDenoise == 1,
        "photo effects and display chroma survive store restart");
    var legacy = System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(saved))!.AsObject();
    legacy.Remove("Denoise");
    legacy.Remove("Lens");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Lens == new LensSettings(), "legacy lens is disabled");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Denoise == new DenoiseSettings(), "older records default to disabled denoise");
    Check(reopened.Find(b) == null, "same basename does not share edits");
    state.ResetGroup("镜头"); Check(state.Lens == new LensSettings(), "lens group reset");
    state.Lens = new LensSettings(true);
    state.ResetAll(); Check(state.Lens == new LensSettings(), "reset all clears lens");
    reopened.Save(a, state.Capture(), null);
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
        Check(settings.Lens == saved.Lens, "frozen source lens configuration");
        Check(settings.Effects == saved.Effects && settings.DisplayChromaDenoise == 1, "frozen source effects and display chroma");
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
    Check(recovered.Settings.Restore().Lens == saved.Lens, "lens survives journal recovery");
    Check(recovered.Settings.Restore().Effects == saved.Effects && recovered.Settings.Restore().DisplayChromaDenoise == 1,
        "effects and display chroma survive journal recovery");
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
