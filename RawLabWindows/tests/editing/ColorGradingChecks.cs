using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;
using F = RawLab.Windows.AdjustmentField;

internal static class ColorGradingChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Reject(Action operation)
    {
        try { operation(); } catch (ArgumentException) { return; } catch (JsonException) { return; }
        throw new Exception("Invalid grading settings accepted");
    }
    internal static void Run()
    {
        var grading = new ColorGradingSettings { Shadows = new(231.25, 0), Midtones = new(110.125, 32.375), Highlights = new(359.999999, 99.5) };
        var state = new Adjustments { ColorGrading = grading };
        var snapshot = state.Capture();
        Check(snapshot.Values.Length == 10 && Enum.GetValues<Parameter>().Length == 10, "Grading keeps the ten legacy parameter indexes");
        Check(JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!.Restore().ColorGrading == grading, "All grading values survive snapshot JSON exactly");
        var old = JsonSerializer.SerializeToNode(snapshot)!.AsObject(); old.Remove("ColorGrading");
        Check(old.Deserialize<AdjustmentSnapshot>()!.Restore().ColorGrading.IsDefault, "Missing old grading object remains default");
        var neutral = new Adjustments().Capture();
        Check(neutral.SameAs(neutral with { ColorGrading = new() }) && !neutral.SameAs(snapshot), "Grading participates in snapshot equality");
        var config = grading.NativeConfig();
        Check(config.Version == 1 && config.StructSize == 32 && config.ShadowsHue == 231.25f && config.ShadowsSaturation == 0
            && config.MidtonesSaturation == 32.375f && config.HighlightsHue == 0, "Native grading preserves pending hue and normalizes Float rounding at 360");
        Check(ColorGradingWheel.InputHue(360) == 0 && ColorGradingWheel.InputHue(-1) == null && ColorGradingWheel.InputHue(361) == null,
            "Only valid UI hue endpoint wraps");
        Check(grading.Shadows.IsIdentity && !grading.Shadows.IsDefault && grading.Shadows.Moving(0, 0) == grading.Shadows,
            "Wheel center preserves pending hue");
        foreach (var bad in new[] { -0.01, 360.0, double.NaN, double.PositiveInfinity })
            Reject(() => (snapshot with { ColorGrading = grading with { Shadows = new(bad, 0) } }).Restore());
        foreach (var bad in new[] { -0.01, 100.01 })
            Reject(() => (snapshot with { ColorGrading = grading with { Shadows = new(0, bad) } }).Restore());
        foreach (var malformed in new[] { """{"Hue":0}""", """{"Hue":0,"Saturation":0,"Lightness":0}""", "null" }) {
            var json = JsonSerializer.SerializeToNode(snapshot)!;
            json["ColorGrading"]!["Shadows"] = JsonNode.Parse(malformed);
            Reject(() => json.Deserialize<AdjustmentSnapshot>()!.Restore());
        }
        var incomplete = JsonSerializer.SerializeToNode(snapshot)!; incomplete["ColorGrading"]!.AsObject().Remove("Midtones");
        Reject(() => incomplete.Deserialize<AdjustmentSnapshot>()!.Restore());
        var fine = new ColorGradingDrag(new(0, 20), .8, .4, true);
        Check(fine.Value(.8, .4) == fine.Initial && Math.Abs(fine.Value(1.2, .4).Saturation - 30) < 1e-6,
            "Fine drag starts at the current handle and scales pointer movement by one quarter");
        Check(grading.Shadows.Moving(1, -double.Epsilon).Hue == 0, "Internal negative angle rounding stays canonical");
        var fields = new HashSet<F> { F.GradingShadows, F.GradingMidtones, F.GradingHighlights };
        var identity = new OriginalIdentity("grading.jpg", 1, 2, 3);
        SavedEdit Edit(Adjustments value) => new(identity, value.Capture(), null);
        var context = new AdjustmentTransferContext("grading", false);
        var copy = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(copy.Fields.SetEquals(fields) && fields.All(AdjustmentFields.Common.Contains), "Modified and standard copy include all grading objects");
        Check(AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(copy.ToJson()), Edit(new()), context).Settings.Restore().ColorGrading == grading,
            "Grading payload JSON and paste retain exact values");
        var target = new Adjustments { ColorGrading = new() { Shadows = new(80, 75), Highlights = new(50, 15.125) } };
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.GradingMidtones]), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(partial, Edit(target), context).Settings.Restore().ColorGrading == (target.ColorGrading with { Midtones = grading.Midtones }),
            "Partial grading paste preserves sibling values");
        var legacy = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Exposure]), Edit(new()), context);
        Check(AdjustmentTransfer.Prepare(legacy, Edit(target), context).Settings.Restore().ColorGrading == target.ColorGrading, "Legacy payload preserves target grading");
        state.ApplyMasterRecipe(MasterRecipe.All[0]); state.Set(Parameter.Strength, 0);
        target.ApplyMasterRecipe(MasterRecipe.All[0]); target.Set(Parameter.Strength, 0);
        copy = AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(copy, Edit(target), context).Settings.Restore().ColorGrading == grading, "Grading is independent of recipe strength");
        state = new() { ColorGrading = grading };
        var zone = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.GradingZone, Zone: ColorGradingZone.Midtones), Edit(state));
        Check(zone.Status == EditorResetStatus.Ready && zone.Candidate!.Settings.Restore().ColorGrading == (grading with { Midtones = new() }), "Zone reset preserves both sibling zones");
        foreach (var scope in new[] { new EditorResetScope(EditorResetKind.AllGrading), new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.ColorGrading), new(EditorResetKind.Group, EditorAdjustmentGroup.Color) }) {
            var reset = EditorAdjustmentRules.PrepareReset(scope, Edit(state));
            Check(reset.Status == EditorResetStatus.Ready && reset.Candidate!.Settings.Restore().ColorGrading.IsDefault, "Tool and group reset clear all grading values");
        }
        var batch = BatchJob.Create("grading.jpg", snapshot, null, "neutral");
        Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(batch))!.Settings.Restore().ColorGrading == grading, "Frozen batch preserves grading");
        state.ResetAll(); Check(state.ColorGrading.IsDefault, "Direct full reset clears grading");
        Console.WriteLine("PASS: grading persistence, pending hue, bounds, transfer, recipe independence, reset and batch");
    }
}
