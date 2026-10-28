using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;
using F = RawLab.Windows.AdjustmentField;

internal static class AtmosphereChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    internal static void Run()
    {
        var atmosphere = new AtmosphereSettings(-37.251234, 42.5);
        var state = new Adjustments { Atmosphere = atmosphere };
        var snapshot = state.Capture();
        Check(snapshot.Values.Length == 10 && Enum.GetValues<Parameter>().Length == 10, "Atmosphere preserves legacy parameter indexes");
        Check(JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!.Restore().Atmosphere == atmosphere, "Atmosphere preserves full Double precision in snapshots");
        var old = JsonSerializer.SerializeToNode(snapshot)!.AsObject(); old.Remove("Atmosphere");
        Check(old.Deserialize<AdjustmentSnapshot>()!.Restore().Atmosphere.IsIdentity, "Old missing atmosphere restores identity");
        var neutral = new Adjustments().Capture();
        Check(neutral.SameAs(neutral with { Atmosphere = new() }) && !neutral.SameAs(snapshot), "Atmosphere equality normalizes null identity and detects edits");
        foreach (var bad in new[] { -100.000001, 100.000001, double.NaN, double.PositiveInfinity })
            foreach (var id in Enum.GetValues<AtmosphereParameter>()) {
                try { (snapshot with { Atmosphere = atmosphere.With(id, bad) }).Restore(); }
                catch (ArgumentException) { continue; }
                throw new Exception("Invalid atmosphere accepted");
            }
        var config = atmosphere.NativeConfig();
        Check(config.Version == 1 && config.StructSize == 16 && config.Clarity == (float)(atmosphere.Clarity / 100) && config.Dehaze == .425f,
            "Atmosphere adapter uses the additive 16-byte ABI and scales once");
        var identity = new OriginalIdentity("atmosphere.jpg",1,2,3);
        SavedEdit Edit(Adjustments settings) => new(identity, settings.Capture(), null);
        var context = new AdjustmentTransferContext("atmosphere",false);
        var fields = new HashSet<F> { F.Clarity, F.Dehaze };
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(payload.Fields.SetEquals(fields) && fields.All(AdjustmentFields.Common.Contains) && fields.All(f=>f.Group()=="effects"), "Atmosphere modified/common/effects scopes agree");
        Check(AdjustmentTransfer.Prepare(payload, Edit(new()), context).Settings.Restore().Atmosphere == atmosphere, "Atmosphere paste retains full precision");
        var target = new Adjustments { Atmosphere = new(71,-29), Effects = new(GrainAmount:13) };
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Dehaze]), Edit(state), context);
        var merged = AdjustmentTransfer.Prepare(partial,Edit(target),context).Settings.Restore();
        Check(merged.Atmosphere == new AtmosphereSettings(71,42.5) && merged.Effects == target.Effects, "Partial atmosphere paste leaves clarity and grain unchanged");
        var oldPayload = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Exposure]), Edit(new()), context);
        Check(AdjustmentTransfer.Prepare(oldPayload, Edit(target), context).Settings.Restore().Atmosphere == target.Atmosphere, "Legacy copy preserves target atmosphere");
        var legacyRecipe = MasterRecipe.All[0] with { SettingsVersion = 3,
            Tone = null, Atmosphere = null, Grading = null, Curve = null };
        state.ApplyMasterRecipe(legacyRecipe); state.Set(Parameter.Strength,0);
        target.ApplyMasterRecipe(legacyRecipe); target.Set(Parameter.Strength,0);
        var recipe = AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(recipe,Edit(target),context).Settings.Restore().Atmosphere == atmosphere, "Atmosphere is independent of zero v3 recipe strength");
        state = snapshot.Restore(); state.ToneControls = new(Vibrance:19);
        Check(EditorAdjustmentRules.IsModified(new(EditorResetKind.Group,EditorAdjustmentGroup.Effects),Edit(state)), "Atmosphere-only edits mark effects modified");
        var reset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Effects),Edit(state));
        Check(reset.Status == EditorResetStatus.Ready && reset.Candidate!.Settings.Restore().Atmosphere.IsIdentity && reset.Candidate.Settings.Restore().ToneControls.Vibrance == 19,
            "Effects reset clears atmosphere and preserves color");
        var job = BatchJob.Create("atmosphere.jpg",state.Capture(),null,"neutral");
        state.Atmosphere = new();
        Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(job))!.Settings.Restore().Atmosphere == atmosphere, "Batch freezes atmosphere independently of later edits");
        Console.WriteLine("PASS: atmosphere persistence, bounds, ABI, transfer, recipe independence, reset and batch");
    }
}
