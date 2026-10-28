using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;
using F = RawLab.Windows.AdjustmentField;

internal static class ToneControlsChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Reject(Action operation, string message)
    {
        try { operation(); } catch (ArgumentException) { return; } catch (JsonException) { return; }
        throw new Exception(message);
    }
    internal static void Run()
    {
        var atmosphereJson = JsonSerializer.SerializeToNode(new Adjustments().Capture())!.AsObject();
        atmosphereJson["Atmosphere"] = new JsonObject { ["Clarity"] = -37.25, ["Dehaze"] = 42.5 };
        var atmosphereRestored = atmosphereJson.Deserialize<AdjustmentSnapshot>()!.Restore().Capture();
        Check(JsonSerializer.SerializeToNode(atmosphereRestored)!["Atmosphere"]?["Dehaze"]?.GetValue<double>() == 42.5,
            "Atmosphere values survive a persisted snapshot round trip");

        var tone = new ToneControlsSettings(-37.25, 42.5, 18.125);
        var state = new Adjustments { ToneControls = tone };
        var snapshot = state.Capture();
        Check(snapshot.Values.Length == 10 && Enum.GetValues<Parameter>().Length == 10, "Tone fields retain the ten legacy parameter indexes");
        var json = JsonSerializer.Serialize(snapshot);
        Check(JsonSerializer.Deserialize<AdjustmentSnapshot>(json)!.Restore().ToneControls == tone, "Tone extension survives JSON and snapshot restore");
        var old = JsonNode.Parse(json)!.AsObject(); old.Remove("ToneControls");
        Check(old.Deserialize<AdjustmentSnapshot>()!.Restore().ToneControls.IsIdentity, "Missing old tone extension restores identity");
        var neutral = new Adjustments().Capture();
        Check(neutral.SameAs(neutral with { ToneControls = new() }), "Null and explicit identity compare as the same snapshot");
        Check(!neutral.SameAs(snapshot), "Tone-only edit participates in snapshot equality");
        foreach(var bad in new[] {-100.000001, 100.000001, double.NaN, double.PositiveInfinity}) {
            foreach(var parameter in Enum.GetValues<ToneControlParameter>())
                Reject(() => (snapshot with { ToneControls = tone.With(parameter,bad) }).Restore(), "Invalid persisted tone must not be accepted");
        }
        var config = tone.NativeConfig();
        Check(config.Version == 1 && config.StructSize == 20 && config.BlackPoint == -.3725f && config.WhitePoint == .425f && config.Vibrance == .18125f,
            "Native tone config converts the complete UI state exactly once");
        var fields = new HashSet<F> { F.BlackPoint, F.WhitePoint, F.Vibrance };
        var identity = new OriginalIdentity("tone.jpg",1,2,3);
        SavedEdit Edit(Adjustments settings) => new(identity, settings.Capture(), null);
        var context = new AdjustmentTransferContext("tone",false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(payload.Fields.SetEquals(fields), "Modified copy contains exactly the new tone fields");
        Check(fields.All(AdjustmentFields.Common.Contains), "Standard scope includes tone fields");
        Check(AdjustmentTransfer.Prepare(payload,Edit(new()),context).Settings.Restore().ToneControls == tone, "Tone transfer retains exact UI values");
        var target = new Adjustments { ToneControls = new(71,-29,-63) };
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.WhitePoint]),Edit(state),context);
        Check(AdjustmentTransfer.Prepare(partial,Edit(target),context).Settings.Restore().ToneControls == new ToneControlsSettings(71,42.5,-63),
            "Partial tone paste preserves unselected target values");
        var legacy = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Exposure]),Edit(new()),context);
        Check(AdjustmentTransfer.Prepare(legacy,Edit(target),context).Settings.Restore().ToneControls == target.ToneControls,
            "Legacy payload omitting tone keeps the target extension");
        state.ApplyMasterRecipe(MasterRecipe.All[0]); state.Set(Parameter.Strength,0);
        target.ApplyMasterRecipe(MasterRecipe.All[0]); target.Set(Parameter.Strength,0);
        var recipeCopy = AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields),Edit(state),context);
        Check(AdjustmentTransfer.Prepare(recipeCopy,Edit(target),context).Settings.Restore().ToneControls == tone,
            "Tone fields stay independent of source and target recipe strength, including zero");
        state = new() { ToneControls = tone };
        Check(EditorAdjustmentRules.IsModified(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.BlackPoint),Edit(state)), "Tone tools participate in modified state");
        var light = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light),Edit(state));
        Check(light.Status == EditorResetStatus.Ready && light.Candidate!.Settings.Restore().ToneControls == (tone with {BlackPoint=0,WhitePoint=0}),
            "Light reset preserves independent color vibrance");
        var color = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Color),Edit(state));
        Check(color.Status == EditorResetStatus.Ready && color.Candidate!.Settings.Restore().ToneControls == (tone with {Vibrance=0}),
            "Color reset preserves independent black and white point");
        var job = BatchJob.Create("tone.jpg",state.Capture(),null,"neutral");
        Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(job))!.Settings.Restore().ToneControls == tone,
            "Frozen batch snapshot round-trips tone values");
        Console.WriteLine("PASS: tone extension, legacy indexes, bounds, config, transfer, recipe, reset and batch snapshots");
    }
}
