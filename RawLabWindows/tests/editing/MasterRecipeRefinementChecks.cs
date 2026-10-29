using System.Text.Json;
using System.Text.Json.Nodes;
using RawLab.Windows;
using F = RawLab.Windows.AdjustmentField;

internal static class MasterRecipeRefinementChecks
{
    public static void Run()
    {
        var recipe = JsonSerializer.Deserialize<MasterRecipe>(File.ReadAllText("Shared/fixtures/master-recipe-v4.json"),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        var state = new Adjustments { ToneControls = new(-20, 30, -25), Atmosphere = new(-40, 20) };
        state.Set(Parameter.ToneCurve, 35); state.Set(Parameter.Temperature, 8000); state.Set(Parameter.Sharpening, 75);
        state.ApplyMasterRecipe(recipe);
        Check(state.ToneControls == new ToneControlsSettings(50, -60, 15) && state.Atmosphere == new AtmosphereSettings(12, -6),
            "Explicit v4 application replaces visible tone and atmosphere");
        Check(state.ColorGrading.Shadows == new ColorGradingWheel(210, 8) && state.Curve.Mode == ToneCurveMode.Custom &&
            state.Curve.Points.Count == 5 && state[Parameter.ToneCurve] == 0, "V4 application replaces grading and curve");
        Check(state[Parameter.Temperature] == 8000 && state[Parameter.Sharpening] == 75, "V4 retains independent adjustments");
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(state.Capture()))!.Restore();
        Check(restored.Capture().SameAs(state.Capture()), "V4 snapshot survives serialization");
        Check(restored.MasterRecipeSettingsVersion == 4, "Snapshot preserves explicit recipe version");
        foreach (var strength in new[] { 0.0, 0.5, 1, 2 }) {
            state.Set(Parameter.Strength, strength * 100);
            Check(state.RenderToneControls == new ToneControlsSettings(Math.Min(100, 50 * strength), Math.Max(-100, -60 * strength), 15 * strength) &&
                state.RenderAtmosphere == new AtmosphereSettings(12 * strength, -6 * strength), "V4 current tone/atmosphere scale once");
            Check(state.RenderGrading.Shadows == new ColorGradingWheel(210, 8 * strength), "Grading scales saturation, not hue");
            Check(strength != 0 || state.RenderCurve.IsIdentity, "Zero strength bypasses the recipe curve");
            Check(state.ToneControls.BlackPoint == 50 && state.Curve.Points.Count == 5, "Rendering preserves visible controls");
            var removed = state.Clone(); removed.ResolveWhiteBalance((5300, 8));
            var before = removed.Request("photo.ARW", null, 0, null);
            removed.ClearMasterRecipe();
            var after = removed.Request("photo.ARW", null, 0, null);
            Check(removed.MasterRecipeID == null && removed.ToneControls == state.RenderToneControls &&
                removed.Atmosphere == state.RenderAtmosphere && removed.ColorGrading == state.RenderGrading &&
                removed.Curve == state.RenderCurve && before.ExposureEv == after.ExposureEv && before.Tint == after.Tint &&
                before.WbMode == after.WbMode, "Direct recipe removal materializes every owned field once");
        }
        var legacy = JsonSerializer.SerializeToNode(state.Capture())!.AsObject();
        legacy.Remove("MasterRecipeSettingsVersion");
        var old = legacy.Deserialize<AdjustmentSnapshot>()!.Restore();
        Check(old.MasterRecipeSettingsVersion == 3 && old.RenderToneControls == old.ToneControls && old.RenderCurve == old.Curve &&
            old.RenderGrading == old.ColorGrading && old.RenderAtmosphere == old.Atmosphere, "Missing version retains independent modern controls");
        Check(!old.Capture().SameAs(state.Capture()), "Different recipe semantics are a snapshot change");
        legacy["MasterRecipeSettingsVersion"] = 5;
        try { _ = legacy.Deserialize<AdjustmentSnapshot>()!.Restore(); throw new Exception("Future recipe version accepted"); }
        catch (InvalidDataException) { }
        var flat = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0), new(.2, .8), new(.4, .8), new(1, 1)]);
        Check(flat.Scaled(2).Points.Select(p => p.Y).SequenceEqual(new[] { 0.0, 1, 1, 1 }), "Extreme manual curve scaling stays monotone");
        state.ResolveWhiteBalance((5300, 8)); state.Set(Parameter.Strength, 50);
        var detached = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group, EditorAdjustmentGroup.Looks),
            new(new("photo.ARW", 1, 2, 3), state.Capture(), null));
        Check(detached.Status == EditorResetStatus.Ready, "V4 look reset is representable");
        Check(detached.MaterializedFields!.Contains("曲线") && detached.MaterializedFields!.Contains("颜色分级"),
            "Recipe removal reports materialized curve and grading controls");
        var independent = detached.Candidate!.Settings.Restore();
        Check(independent.MasterRecipeID == null && independent.ToneControls == state.RenderToneControls &&
            independent.Atmosphere == state.RenderAtmosphere && independent.ColorGrading == state.RenderGrading && independent.Curve == state.RenderCurve,
            "V4 look reset materializes modern controls once");
        var extreme = state.Clone(); extreme.Set(Parameter.Exposure, 4); extreme.Set(Parameter.Strength, 200);
        var unchanged = extreme.Capture();
        try { extreme.ClearMasterRecipe(); throw new Exception("Unrepresentable direct removal accepted"); }
        catch (InvalidDataException) { Check(extreme.Capture().SameAs(unchanged), "Blocked removal preserves the original edit"); }
        Console.WriteLine("PASS: master recipe refinements apply and persist");
        Transfer(recipe);
    }
    private static void Transfer(MasterRecipe recipe)
    {
        var context = new AdjustmentTransferContext("source", true, new HashSet<string> { "recipe:" + recipe.Id },
            CameraWhiteBalance: (5200, 10));
        var identity = new OriginalIdentity("photo.ARW", 1, 2, 3);
        SavedEdit Edit(Adjustments value) => new(identity, value.Capture(), null);
        var source = new Adjustments(); source.ApplyMasterRecipe(recipe); source.ResolveWhiteBalance((5200, 10));
        var fields = new[] { F.BlackPoint, F.WhitePoint, F.Vibrance, F.Clarity, F.Dehaze, F.Curve, F.SCurve,
            F.GradingShadows, F.GradingMidtones, F.GradingHighlights };
        foreach (var strength in new[] { 0.0, 0.5, 1, 2 }) {
            source.Set(Parameter.Strength, strength * 100);
            var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields), Edit(source), context);
            var plain = AdjustmentTransfer.Prepare(partial, Edit(new()), context).Settings.Restore();
            Check(plain.MasterRecipeID == null && plain.ToneControls == source.RenderToneControls && plain.Atmosphere == source.RenderAtmosphere &&
                plain.ColorGrading == source.RenderGrading && plain.Curve == source.RenderCurve, "Partial v4 transfer materializes all new groups");
            var full = AdjustmentTransfer.Capture(AdjustmentScope.All, Edit(source), context);
            var copied = AdjustmentTransfer.Prepare(full, Edit(new()), context).Settings.Restore();
            Check(copied.MasterRecipeSettingsVersion == 4 && copied[Parameter.Strength] == strength * 100 &&
                copied.ToneControls == source.ToneControls && copied.ColorGrading == source.ColorGrading && copied.Curve == source.Curve,
                "Full v4 transfer keeps logical controls and version");
        }
        source.Set(Parameter.Strength, 50);
        var legacyFields = AdjustmentTransfer.Capture(AdjustmentScope.Custom(AdjustmentFields.RecipeDependencies), Edit(source), context);
        var separate = AdjustmentTransfer.Prepare(legacyFields, Edit(new()), context);
        Check(separate.Settings.MasterRecipeID == null && separate.Look == "recipe-lut:" + recipe.Id, "Incomplete v4 becomes an independent LUT");
        var target = source.Clone(); target.Set(Parameter.Tint, 0); source.Set(Parameter.Strength, 100);
        var strengthOnly = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Strength]), Edit(source), context);
        var changed = AdjustmentTransfer.Prepare(strengthOnly, Edit(target), context).Settings.Restore();
        Check(changed.RenderToneControls == target.RenderToneControls && changed.RenderAtmosphere == target.RenderAtmosphere &&
            changed.RenderGrading == target.RenderGrading && changed.RenderCurve == target.RenderCurve,
            "Strength-only transfer preserves unselected effective refinements");
        Console.WriteLine("PASS: v4 complete, partial and strength-only transfers");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
}
