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
        var channels = new ToneCurveSettings().Replacing(ToneCurveChannel.Red, curve.Master);
        Check(JsonSerializer.Deserialize<ToneCurveSettings>(JsonSerializer.Serialize(channels)) == channels,
            "Independent curve channels survive persistence");
        Check(channels.Scaled(.5).Channels.Red.Points[1].Y > channels.Channels.Red.Points[1].Y,
            "Independent channels follow refinement strength");
        var channelConfig = channels.NativeSetConfig();
        Check(Marshal.SizeOf<Native.ToneCurveSetConfig>() == 2184 && channelConfig.Master.Mode == 0 && channelConfig.Red.Count == 4,
            "Complete curve set ABI");
        var hdrChannels = new HDRSettings().WithTone(new HDRToneSettings { Curve = channels });
        Check(hdrChannels.ProcessingVersion == 8 && hdrChannels.RecordVersion == 9 &&
            JsonSerializer.Deserialize<HDRSettings>(JsonSerializer.Serialize(hdrChannels)) == hdrChannels, "HDR channels persist as record v9");
        var hdrChannelRequest = hdrChannels.NativeRenderRequest(HDRIntent.Final);
        Check(Marshal.SizeOf<Native.HDRRequestV8>() == 2584 && hdrChannelRequest.Base.Red.Count == 4 &&
            hdrChannelRequest.Base.Base.Base.Base.Base.Base.Base.Base.HDRProcessingVersion == 8, "HDR channel ABI");
        var hdrV2 = new HDRSettings().WithTone(new HDRToneSettings {
            Curve = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.1), new(1, 0.9)],
                applyToLuminosity: true, parametric: new ToneCurveParametric(15, 0, 0, -10))
        });
        var hdrV2Req = hdrV2.NativeRenderRequest(HDRIntent.Final);
        Check(hdrV2.ProcessingVersion == 9 && hdrV2.RecordVersion == 10 &&
            hdrV2Req.Base.Base.Base.Base.Base.Base.Base.Base.HDRProcessingVersion == 9 &&
            hdrV2Req.CurveApplyToLuminosity == 1 && hdrV2Req.ParametricCurve.Highlights == 15f &&
            hdrV2Req.GradingV2.Version == 2 && hdrV2Req.GradingV2.StructSize == 64 && hdrV2Req.GradingV2.Blending == 50f,
            "HDR v9 curve v2 ABI");
        Loc.Initialize("en");
        var coordinate = new NumericRange(0, 1, .001, .01, .001, AllowOffGrid: true);
        Check(coordinate.Parse("0.250000000000001") == curve.Points[1].X && coordinate.Parse("1.000001") == null &&
            new NumericRange(0, 1, .001).Parse("0.2501") == null, "Precise curve input keeps Double coordinates without relaxing other controls");
        Check(curve.IsEndpoint(0) && curve.IsEndpoint(3) && curve.CanMoveY(0) && curve.CanMoveY(3) &&
            !curve.IsInterior(0) && !curve.IsInterior(3) && curve.Removing(0) == curve && curve.Removing(3) == curve,
            "Endpoints allow Y movement while disallowing deletion and X drag");
        var movedBlack = curve.Moving(0, .2, .1);
        var clampedBlack = curve.Moving(0, .2, .5);
        var movedWhite = curve.Moving(3, .8, .9);
        Check(movedBlack.Points[0] == new ToneCurvePoint(0, .1) && clampedBlack.Points[0] == new ToneCurvePoint(0, curve.Points[1].Y) &&
            movedWhite.Points[3] == new ToneCurvePoint(1, .9), "Endpoints move along Y within monotonic neighbor bounds");
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
            """{"mode":"custom","points":[[0.1,0],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[0.5,0.6],[0.6,0.5],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1,1]],"future":0}""" })
            Reject(() => JsonSerializer.Deserialize<ToneCurveSettings>(bad));
        var unpinned = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.125), new(0.5, 0.55), new(1, 0.875)],
            applyToLuminosity: true, parametric: new ToneCurveParametric(-10, 15, -5, 20, 0.2, 0.5, 0.8));
        Check(JsonSerializer.Deserialize<ToneCurveSettings>(JsonSerializer.Serialize(unpinned)) == unpinned,
            "Unpinned Y and parametric curve round-trip");
        Check(!curve.HasV2Extensions &&
            new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.2), new(1, 0.8)]).HasV2Extensions &&
            new ToneCurveSettings(channels: new ToneCurveChannels(
                new ToneCurveShape(ToneCurveMode.Custom, [new(0, 0.1), new(1, 1)]),
                new(), new())).HasV2Extensions,
            "HasV2Extensions tracks unpinned endpoints on master and channel curves");
        try {
            AdjustmentPayload.Parse("""{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":3},"values":{"light.curve":{"mode":"custom","points":[[0,0],[1,1]],"apply_to_luminosity":true}}}""");
            throw new Exception("Nested apply_to_luminosity accepted inside light.curve");
        } catch (AdjustmentTransferException) { }
        var context = new AdjustmentTransferContext("curve", false);
        var original = new OriginalIdentity("curve.jpg", 1, 2, 3);
        SavedEdit Edit(Adjustments value) => new(original, value.Capture(), null);
        var hdrSource = new Adjustments { HDR = hdrChannels };
        var hdrPayload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(hdrSource), context);
        var hdrTarget = new Adjustments { HDR = new HDRSettings() };
        Check(hdrPayload.Source.HdrProcessingVersion == 8 &&
            AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(hdrPayload.ToJson()), Edit(hdrTarget), context).Settings.HDR!.ToneSettings.Curve == channels,
            "HDR v8 channel transfer preserves independent curves");
        var all = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(all.Fields.SetEquals([F.SCurve, F.Curve]), "Modified scope includes inactive scalar and selected custom mode");
        var target = new Adjustments(); target.Set(Parameter.ToneCurve, -25);
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Curve]), Edit(state), context);
        var pasted = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(partial.ToJson()), Edit(target), context).Settings.Restore();
        Check(pasted.Curve == curve && pasted[Parameter.ToneCurve] == -25, "Curve-only paste leaves legacy scalar untouched");
        var scalar = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.SCurve]), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(scalar, Edit(pasted), context).Settings.Restore().Curve == curve, "Legacy scalar-only paste keeps custom mode");
        var legacyRecipe = MasterRecipe.All[0] with { SettingsVersion = 3,
            Tone = null, Atmosphere = null, Grading = null, Curve = null };
        state.ApplyMasterRecipe(legacyRecipe);
        foreach (var strength in new[] { 0.0, 50, 100, 200 }) {
            state.Set(Parameter.Strength, strength);
            Check(state.Curve == curve && state.Request("curve.jpg", null, 32, null).ToneCurve == 0, "Curve is independent of v3 recipe strength");
        }
        state = snapshot.Restore();
        foreach (var scope in new[] { new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.ToneCurve), new(EditorResetKind.Group, EditorAdjustmentGroup.Light) }) {
            var reset = EditorAdjustmentRules.PrepareReset(scope, Edit(state));
            Check(reset.Status == EditorResetStatus.Ready && reset.Candidate!.Settings.Restore().Curve.IsDefault, "Curve mode and points participate in tool/group reset");
        }
        var batch = BatchJob.Create("curve.jpg", snapshot, null, "neutral");
        state.Curve = ToneCurveSettings.Identity;
        Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(batch))!.Settings.Restore().Curve == curve, "Batch snapshot freezes curve independently of later editing");
        var fullReset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), Edit(state));
        Check(fullReset.Status == EditorResetStatus.Ready, "Full reset returns a candidate");
        state = fullReset.Candidate!.Settings.Restore();
        Check(state.Curve.IsDefault, "Full reset returns to legacy identity");
        var v2Config = unpinned.NativeSetV2Config();
        Check(Marshal.SizeOf<Native.ToneCurveParametricConfig>() == 40 &&
            Marshal.SizeOf<Native.ToneCurveSetV2Config>() == 2232 &&
            v2Config.Version == 2 && v2Config.StructSize == 2232 && v2Config.ApplyToLuminosity == 1 &&
            v2Config.Parametric.Version == 1 && v2Config.Parametric.StructSize == 40 &&
            v2Config.Parametric.Highlights == -10f && v2Config.Parametric.Lights == 15f,
            "Tone curve v2 native set config layout matches C ABI");
        Check(!string.IsNullOrWhiteSpace(AdjustmentTransferPresentation.Title(F.CurveApplyToLuminosity)) &&
            !string.IsNullOrWhiteSpace(AdjustmentTransferPresentation.Title(F.CurveParametric)),
            "Selective transfer presentation registers Track A curve fields");
        var v2TransferSource = new Adjustments { Curve = unpinned };
        var v2TransferPayload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(v2TransferSource), context);
        Check(v2TransferPayload.Fields.Contains(F.CurveApplyToLuminosity) && v2TransferPayload.Fields.Contains(F.CurveParametric),
            "Modified scope captures Track A luminosity and parametric fields");
        var targetSamples = new[] { new ToneCurvePoint(0, 0), new ToneCurvePoint(0.5, 0.5), new ToneCurvePoint(1, 1) };
        var targetInteraction = new CurveTargetInteraction();
        var rev = new HslTargetRevision(1, 2);
        var token = targetInteraction.Begin(new ToneCurveSettings(), ToneCurveChannel.Rgb, rev, targetSamples);
        var nearGraySample = new HslTargetSample(rev, HslTargetAvailability.NearGray, [0.4, 0.4, 0.4], new double[8], false);
        var accepted = targetInteraction.Accept(nearGraySample, token, rev);
        Check(accepted != null && accepted.Mode == ToneCurveMode.Custom && accepted.Points.Count == 3,
            "Curve target interaction accepts NearGray and auto-switches legacy to custom");
        var dragged = targetInteraction.Move(20.0);
        Check(dragged != null && Math.Abs(dragged.Points[1].Y - 0.5) < 1e-9,
            "Curve target interaction applies vertical drag delta/200");
        var cancelled = targetInteraction.Cancel();
        Check(cancelled == new ToneCurveSettings(), "Curve target cancel reverts to original settings");
        Console.WriteLine("PASS: curve precision, persistence, immutable snapshots, native adapter, selective transfer, reset and batch");
    }
}
