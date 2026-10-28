using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Runtime.InteropServices;
using F = RawLab.Windows.AdjustmentField;

internal static class ToneCurveChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Reject(Action action) {
        try { action(); } catch (ArgumentException) { return; } catch (JsonException) { return; }
        throw new Exception("Invalid curve accepted");
    }
    internal static void Run()
    {
        var points = new[] { new ToneCurvePoint(0, 0), new ToneCurvePoint(1, 1) };
        var identity = new ToneCurveSettings(ToneCurveMode.Custom, points); points[1] = new(.5, .5);
        Check(identity == ToneCurveSettings.Identity && identity.IsIdentity && !identity.IsDefault, "Curve copies input points and keeps custom identity mode");
        var curve = identity.Inserting(.250000000000001, .125000000000001).Inserting(.75, .875);
        Loc.Initialize("en");
        var coordinate = new NumericRange(0, 1, .001, .01, .001, AllowOffGrid: true);
        Check(coordinate.Parse("0.250000000000001") == curve.Points[1].X && coordinate.Parse("1.000001") == null &&
            new NumericRange(0, 1, .001).Parse("0.2501") == null, "Precise curve input keeps Double coordinates without relaxing other controls");
        Check(curve.Moving(0, .1, .1) == curve && curve.Removing(3) == curve, "Endpoints remain fixed");
        var moved = curve.Moving(1, 1, 1);
        Check(moved.Points[1].X < moved.Points[2].X && moved.Points[1].Y == .875, "Moving cannot cross adjacent points");
        var state = new Adjustments { Curve = curve }; state.Set(Parameter.ToneCurve, 65);
        var snapshot = state.Capture();
        Check(snapshot.Values.Length == 10 && JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!.Restore().Curve == curve,
            "Curve preserves Double coordinates without changing legacy parameter indexes");
        Check(state.Request("curve.jpg", null, 32, null).ToneCurve == 0 && state[Parameter.ToneCurve] == 65, "Custom adapter masks but retains inactive legacy value");
        var old = JsonSerializer.SerializeToNode(snapshot)!.AsObject(); old.Remove("Curve");
        Check(old.Deserialize<AdjustmentSnapshot>()!.Restore().Curve.IsDefault, "Legacy records use legacy mode");
        Check(!snapshot.SameAs(snapshot with { Curve = null }) && snapshot.SameAs(snapshot.Copy()), "Snapshots compare curve points by value");
        var config = curve.NativeConfig();
        Check(Marshal.SizeOf<Native.ToneCurveConfig>() == 544 && config.Count == 4 && config.Points[2] == curve.Points[1].X,
            "Additive curve config retains binary64 points and stable ABI");
        foreach (var bad in new[] { """{"mode":"custom","points":[[0,0],[1,1,2]]}""",
            """{"mode":"custom","points":[[0,0],[0.5,0.6],[0.6,0.5],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1,1]],"future":0}""" })
            Reject(() => JsonSerializer.Deserialize<ToneCurveSettings>(bad));
        var context = new AdjustmentTransferContext("curve", false);
        var original = new OriginalIdentity("curve.jpg", 1, 2, 3);
        SavedEdit Edit(Adjustments value) => new(original, value.Capture(), null);
        var all = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(all.Fields.SetEquals([F.SCurve, F.Curve]), "Modified scope includes inactive scalar and selected custom mode");
        var target = new Adjustments(); target.Set(Parameter.ToneCurve, -25);
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Curve]), Edit(state), context);
        var pasted = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(partial.ToJson()), Edit(target), context).Settings.Restore();
        Check(pasted.Curve == curve && pasted[Parameter.ToneCurve] == -25, "Curve-only paste leaves legacy scalar untouched");
        var scalar = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.SCurve]), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(scalar, Edit(pasted), context).Settings.Restore().Curve == curve, "Legacy scalar-only paste keeps custom mode");
        state.ApplyMasterRecipe(MasterRecipe.All[0]);
        foreach (var strength in new[] { 0.0, 50, 100, 200 }) {
            state.Set(Parameter.Strength, strength);
            Check(state.Curve == curve && state.Request("curve.jpg", null, 32, null).ToneCurve == 0, "Curve is independent of recipe strength");
        }
        state = snapshot.Restore();
        foreach (var scope in new[] { new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.ToneCurve), new(EditorResetKind.Group, EditorAdjustmentGroup.Light) }) {
            var reset = EditorAdjustmentRules.PrepareReset(scope, Edit(state));
            Check(reset.Status == EditorResetStatus.Ready && reset.Candidate!.Settings.Restore().Curve.IsDefault, "Curve mode and points participate in tool/group reset");
        }
        var batch = BatchJob.Create("curve.jpg", snapshot, null, "neutral");
        state.Curve = ToneCurveSettings.Identity;
        Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(batch))!.Settings.Restore().Curve == curve, "Batch snapshot freezes curve independently of later editing");
        state.ResetAll(); Check(state.Curve.IsDefault, "Full reset returns to legacy identity");
        Console.WriteLine("PASS: curve precision, persistence, immutable snapshots, native adapter, selective transfer, reset and batch");
    }
}
