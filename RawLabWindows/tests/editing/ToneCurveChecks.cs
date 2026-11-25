using RawLab.Windows;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
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
        var hdrChannelsJson = JsonNode.Parse(hdrChannels.ToCanonicalEditStateJson())!.AsObject();
        Check(hdrChannelsJson["processing"]!["version"]!.GetValue<int>() == 8 &&
              hdrChannelsJson["edits"]!["tone"]!["curve"]!["channels"]!["red"]!["points"]!.AsArray().Count == 4,
            "HDR channel canonical JSON");
        var hdrV2 = new HDRSettings {
            Color = new HDRColorSettings { Grading = new ColorGradingSettings { Blending = 75 } }
        }.WithTone(new HDRToneSettings {
            Curve = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.1), new(1, 0.9)],
                applyToLuminosity: true, parametric: new ToneCurveParametric(15, 0, 0, -10))
        });
        var hdrV2Json = JsonNode.Parse(hdrV2.ToCanonicalEditStateJson())!.AsObject();
        Check(hdrV2.ProcessingVersion == 9 && hdrV2.RecordVersion == 10 &&
            hdrV2Json["processing"]!["version"]!.GetValue<int>() == 9 &&
            hdrV2Json["edits"]!["tone"]!["s_curve"]!.GetValue<double>() == 0 &&
            hdrV2Json["edits"]!["tone"]!["curve"]!["apply_to_luminosity"]!.GetValue<bool>() &&
            hdrV2Json["edits"]!["tone"]!["curve"]!["parametric"]!["highlights"]!.GetValue<double>() == 15 &&
            hdrV2Json["edits"]!["color_grading"]!["blending"]!.GetValue<double>() == 75,
            "HDR v9 curve v2 canonical JSON");
        // 已发布的 v9 只放开端点 y；端点 x 内移升到处理版本 10 / 文档 schema 19。
        var hdrFreeX = new HDRSettings().WithTone(new HDRToneSettings {
            Curve = new ToneCurveSettings(channels: new ToneCurveChannels(new(), new(ToneCurveMode.Custom, [new(0.1, 0), new(0.9, 1)]), new()))
        });
        var hdrFreeXJson = JsonNode.Parse(hdrFreeX.ToCanonicalEditStateJson())!.AsObject();
        Check(hdrFreeX.ProcessingVersion == 10 && hdrFreeX.RecordVersion == 11 &&
            hdrFreeXJson["schema_version"]!.GetValue<int>() == 19 &&
            hdrFreeXJson["processing"]!["version"]!.GetValue<int>() == 10 &&
            JsonSerializer.Deserialize<HDRSettings>(JsonSerializer.Serialize(hdrFreeX)) == hdrFreeX,
            "HDR free endpoint X persists as processing v10 / record v11 and canonical schema 19");
        var tamperedFreeX = JsonSerializer.Serialize(hdrFreeX)
            .Replace("\"hdr_processing_version\":10", "\"hdr_processing_version\":9").Replace("\"record_version\":11", "\"record_version\":10");
        var tamperedRejected = false;
        try { JsonSerializer.Deserialize<HDRSettings>(tamperedFreeX); } catch (JsonException) { tamperedRejected = true; }
        Check(tamperedRejected, "HDR v9 record with free endpoint X is rejected");
        Loc.Initialize("en");
        var coordinate = new NumericRange(0, 1, .001, .01, .001, AllowOffGrid: true);
        Check(coordinate.Parse("0.250000000000001") == curve.Points[1].X && coordinate.Parse("1.000001") == null &&
            new NumericRange(0, 1, .001).Parse("0.2501") == null, "Precise curve input keeps Double coordinates without relaxing other controls");
        Check(curve.IsEndpoint(0) && curve.IsEndpoint(3) && curve.CanMoveX(0) && curve.CanMoveX(3) && curve.CanMoveY(0) && curve.CanMoveY(3) &&
            !curve.IsInterior(0) && !curve.IsInterior(3) && curve.Removing(0) == curve && curve.Removing(3) == curve,
            "Endpoints allow X and Y movement while disallowing deletion");
        var movedBlack = curve.Moving(0, .2, .1);
        var clampedBlack = curve.Moving(0, .5, .5);
        var movedWhite = curve.Moving(3, .8, .9);
        var clampedWhite = curve.Moving(3, .2, .2);
        Check(movedBlack.Points[0] == new ToneCurvePoint(.2, .1) &&
            clampedBlack.Points[0].X < curve.Points[1].X && clampedBlack.Points[0].Y == curve.Points[1].Y &&
            movedWhite.Points[3] == new ToneCurvePoint(.8, .9) &&
            clampedWhite.Points[3].X > curve.Points[2].X && clampedWhite.Points[3].Y == curve.Points[2].Y,
            "Endpoints move along X and Y within monotonic neighbor bounds");
        var moved = curve.Moving(1, 1, 1);
        Check(moved.Points[1].X < moved.Points[2].X && moved.Points[1].Y == .875, "Moving cannot cross adjacent points");
        var state = new Adjustments { Curve = curve }; state.Set(Parameter.ToneCurve, .65);
        var snapshot = state.Capture();
        Check(snapshot.Values.Length == 10 && JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!.Restore().Curve == curve,
            "Curve preserves Double coordinates without changing legacy parameter indexes");
        Check(state.Request("curve.jpg", null, 32, null).ToneCurve == 0 && state[Parameter.ToneCurve] == .65, "Custom adapter masks but retains inactive legacy value");
        var old = JsonSerializer.SerializeToNode(snapshot)!.AsObject(); old.Remove("Curve");
        Check(old.Deserialize<AdjustmentSnapshot>()!.Restore().Curve.IsDefault, "Legacy records use legacy mode");
        Check(!snapshot.SameAs(snapshot with { Curve = null }) && snapshot.SameAs(snapshot.Copy()), "Snapshots compare curve points by value");
        var config = curve.NativeConfig();
        Check(Marshal.SizeOf<Native.ToneCurveConfig>() == 544 && config.Count == 4 && config.Points[2] == curve.Points[1].X,
            "Additive curve config retains binary64 points and stable ABI");
        foreach (var bad in new[] { """{"mode":"custom","points":[[0,0],[1,1,2]]}""",
            """{"mode":"custom","points":[[-0.1,0],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1.1,1]]}""",
            """{"mode":"custom","points":[[0,0],[0.5,0.6],[0.6,0.5],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1,1]],"future":0}""" })
            Reject(() => JsonSerializer.Deserialize<ToneCurveSettings>(bad));
        var unpinned = new ToneCurveSettings(ToneCurveMode.Custom, [new(0.12, 0.08), new(0.5, 0.55), new(0.88, 0.92)],
            applyToLuminosity: true, parametric: new ToneCurveParametric(-10, 15, -5, 20, 0.2, 0.5, 0.8));
        Check(JsonSerializer.Deserialize<ToneCurveSettings>(JsonSerializer.Serialize(unpinned)) == unpinned,
            "Unpinned X/Y and parametric curve round-trip");
        var diagInset = new ToneCurveSettings(ToneCurveMode.Custom, [new(0.1, 0.1), new(0.9, 0.9)]);
        var insertedOutside = diagInset.Inserting(0.05, 0.05).Inserting(0.95, 0.95);
        var freeXHalf = new ToneCurveSettings(ToneCurveMode.Custom, unpinned.Points).Scaled(0.5);
        var crossing = new ToneCurveSettings(ToneCurveMode.Custom, [new(0.4, 0.2), new(0.7, 0.9)]).Scaled(2.0);
        Check(!curve.HasV2Extensions &&
            !diagInset.IsIdentity && diagInset.Progress > 0 &&
            insertedOutside.Points[0] == new ToneCurvePoint(0.05, 0.05) && insertedOutside.Points[^1] == new ToneCurvePoint(0.95, 0.95) &&
            Math.Abs(freeXHalf.Points[0].X - 0.06) < 1e-12 && Math.Abs(freeXHalf.Points[2].X - 0.94) < 1e-12 &&
            crossing.Points[0].X < crossing.Points[1].X &&
            new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.2), new(1, 0.8)]).HasV2Extensions &&
            new ToneCurveSettings(ToneCurveMode.Custom, [new(0.1, 0), new(1, 1)]).HasV2Extensions &&
            new ToneCurveSettings(channels: new ToneCurveChannels(
                new ToneCurveShape(ToneCurveMode.Custom, [new(0, 0.1), new(1, 1)]),
                new(), new())).HasV2Extensions &&
            new ToneCurveSettings(channels: new ToneCurveChannels(
                new ToneCurveShape(ToneCurveMode.Custom, [new(0.1, 0), new(0.9, 1)]),
                new(), new())).HasV2Extensions,
            "HasV2Extensions, IsIdentity, Inserting, and Scaled handle unpinned X/Y endpoints on master and channel curves");
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
        // v10 只放开曲线端点 x；各作用域的捕获、解析与应用都必须接受它，不能因版本映射缺项抛异常。
        foreach (var scope in new[] { AdjustmentScope.All, AdjustmentScope.Modified, AdjustmentScope.Custom([F.Curve]) }) {
            var freeXPayload = AdjustmentTransfer.Capture(scope, Edit(new Adjustments { HDR = hdrFreeX }), context);
            Check(freeXPayload.Source.HdrProcessingVersion == 10 &&
                AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(freeXPayload.ToJson()), Edit(hdrTarget), context).Settings.HDR!.ToneSettings.Curve == hdrFreeX.ToneSettings.Curve,
                $"HDR v10 free endpoint X transfer round-trips ({scope})");
        }
        var all = AdjustmentTransfer.Capture(AdjustmentScope.Modified, Edit(state), context);
        Check(all.Fields.SetEquals([F.SCurve, F.Curve]), "Modified scope includes inactive scalar and selected custom mode");
        var target = new Adjustments(); target.Set(Parameter.ToneCurve, -.25);
        var partial = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Curve]), Edit(state), context);
        var pasted = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(partial.ToJson()), Edit(target), context).Settings.Restore();
        Check(pasted.Curve == curve && pasted[Parameter.ToneCurve] == -.25, "Curve-only paste leaves legacy scalar untouched");
        var scalar = AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.SCurve]), Edit(state), context);
        Check(AdjustmentTransfer.Prepare(scalar, Edit(pasted), context).Settings.Restore().Curve == curve, "Legacy scalar-only paste keeps custom mode");
        var legacyRecipe = MasterRecipe.All[0] with { SettingsVersion = 3,
            Tone = null, Atmosphere = null, Grading = null, Curve = null };
        state.ApplyMasterRecipe(legacyRecipe);
        foreach (var strength in new[] { 0.0, .5, 1, 2 }) {
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
        RunCanvasMouseChecks();
        Console.WriteLine("PASS: curve precision, persistence, immutable snapshots, native adapter, selective transfer, reset, batch and WPF canvas deletion");
    }

    private static void RunCanvasMouseChecks()
    {
        Exception? staFailure = null;
        var sta = new Thread(() =>
        {
            try
            {
                var canvas = new ToneCurveCanvas
                {
                    Width = 224,
                    Height = 164,
                    Sampler = static (settings, _, _) => settings.Points,
                };
                canvas.Measure(new Size(224, 164));
                canvas.Arrange(new Rect(0, 0, 224, 164));

                var captured = false;
                var lostCaptureEvents = 0;
                var gestureCompletedCount = 0;
                var gestureCancelledCount = 0;
                var commits = 0;
                var selected = 0;
                var current = ToneCurveSettings.Identity;
                var beforeGesture = current;

                canvas.CaptureMouseOverride = () => { captured = true; return true; };
                canvas.ReleaseMouseCaptureOverride = () =>
                {
                    if (!captured) return;
                    captured = false;
                    // Reproduce WPF's synchronous LostMouseCaptureEvent dispatch inside ReleaseMouseCapture().
                    lostCaptureEvents++;
                    canvas.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0)
                    {
                        RoutedEvent = UIElement.LostMouseCaptureEvent,
                        Source = canvas,
                    });
                };
                canvas.SelectionChanged += idx => selected = idx;
                canvas.AddHandler(ParameterRow.GestureStartedEvent, new RoutedEventHandler((_, _) => beforeGesture = current));
                canvas.AddHandler(ParameterRow.GestureCompletedEvent, new RoutedEventHandler((_, _) => gestureCompletedCount++));
                canvas.AddHandler(ParameterRow.GestureCancelledEvent, new RoutedEventHandler((_, _) =>
                {
                    gestureCancelledCount++;
                    current = beforeGesture;
                }));
                canvas.Changed += (next, interactive) =>
                {
                    current = next;
                    if (!interactive) commits++;
                    // Mirror ToneCurvePanel.Change -> Refresh re-entering canvas.Refresh on every update.
                    canvas.Refresh(current, "photo-1", selected, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);
                };

                static Point Pt(double nx, double ny) => new(12 + nx * 200.0, 12 + (1.0 - ny) * 140.0);
                canvas.Refresh(current, "photo-1", 0, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);

                // 1. Accidental double-click on empty curve space inserts on Click 1 and must NOT delete on Click 2.
                Check(canvas.HandleLeftButtonDown(Pt(0.5, 0.55), clickCount: 1, nowMsOverride: 1000), "Click 1 on empty curve space starts insertion");
                Check(canvas.HandleLeftButtonUp(Pt(0.5, 0.55)), "Click 1 release succeeds");
                Check(current.Points.Count == 3 && commits == 1 && lostCaptureEvents == 1, "Click 1 inserts one interior point and fires LostMouseCapture");
                Check(canvas.HandleLeftButtonDown(Pt(0.5, 0.55), clickCount: 2, nowMsOverride: 1100), "Click 2 after empty-space insertion selects instead of deleting");
                Check(canvas.HandleLeftButtonUp(Pt(0.5, 0.55)), "Click 2 release succeeds");
                Check(current.Points.Count == 3, "Newly inserted point survives accidental double-click on empty curve space");

                // 2. Double-clicking an existing interior point deletes it even after ReleaseMouseCapture raises LostMouseCapture.
                var lostBefore = lostCaptureEvents;
                Check(canvas.HandleLeftButtonDown(Pt(0.5, 0.55), clickCount: 1, nowMsOverride: 2000), "Click 1 on existing interior point starts selection");
                Check(canvas.HandleLeftButtonUp(Pt(0.5, 0.55)), "Click 1 release on existing interior point succeeds");
                Check(lostCaptureEvents == lostBefore + 1 && current.Points.Count == 3, "ReleaseMouseCapture synchronously dispatched LostMouseCapture");
                Check(canvas.HandleLeftButtonDown(Pt(0.5, 0.55), clickCount: 2, nowMsOverride: 2120), "Click 2 within double-click window deletes interior point");
                Check(current.Points.Count == 2 && commits == 2, "Windows double-click deletes existing interior point cleanly");

                // 3. Slight sub-threshold jitter during Click 1 (which triggers Changed + Refresh on release) still arms double-click delete.
                current = ToneCurveSettings.Identity.Inserting(0.5, 0.55);
                canvas.Refresh(current, "photo-1", 1, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);
                Check(canvas.HandleLeftButtonDown(Pt(0.5, 0.55), clickCount: 1, nowMsOverride: 3000), "Jitter Click 1 down");
                Check(canvas.HandlePointerMove(Pt(0.505, 0.555)), "Sub-threshold 1px jitter move");
                Check(canvas.HandleLeftButtonUp(Pt(0.505, 0.555)), "Jitter Click 1 up");
                Check(current.Points.Count == 3 && commits == 3, "Jitter Click 1 committed slight nudge");
                Check(canvas.HandleLeftButtonDown(Pt(0.505, 0.555), clickCount: 2, nowMsOverride: 3150), "Jitter Click 2 deletes nudged interior point");
                Check(current.Points.Count == 2 && commits == 4, "Double-click delete survives sub-threshold jitter and Refresh");

                // 4. Significant drag (> 0.02) disarms quick-reclick deletion; involuntary mid-drag LostMouseCapture cancels and rolls back.
                current = ToneCurveSettings.Identity.Inserting(0.4, 0.4);
                canvas.Refresh(current, "photo-1", 1, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);
                Check(canvas.HandleLeftButtonDown(Pt(0.4, 0.4), clickCount: 1, nowMsOverride: 4000), "Drag Click 1 down");
                Check(canvas.HandlePointerMove(Pt(0.4, 0.65)), "Significant drag move");
                Check(canvas.HandleLeftButtonUp(Pt(0.4, 0.65)), "Drag Click 1 up");
                Check(canvas.HandleLeftButtonDown(Pt(0.4, 0.65), clickCount: 2, nowMsOverride: 4100), "Quick click after significant drag selects without deleting");
                Check(canvas.HandleLeftButtonUp(Pt(0.4, 0.65)), "Quick click release");
                Check(current.Points.Count == 3 && Math.Abs(current.Points[1].Y - 0.65) < 1e-12, "Significant drag disarms quick second-click deletion");

                Check(canvas.HandleLeftButtonDown(Pt(0.4, 0.65), clickCount: 1, nowMsOverride: 5000), "Mid-drag capture-loss down");
                Check(canvas.HandlePointerMove(Pt(0.4, 0.80)), "Mid-drag move to 0.80");
                Check(Math.Abs(current.Points[1].Y - 0.80) < 1e-12, "Interactive preview reached 0.80 before capture loss");
                captured = false;
                canvas.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, 0)
                {
                    RoutedEvent = UIElement.LostMouseCaptureEvent,
                    Source = canvas,
                });
                canvas.Refresh(current, "photo-1", selected, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);
                Check(gestureCancelledCount == 1 && current.Points.Count == 3 && Math.Abs(current.Points[1].Y - 0.65) < 1e-12,
                    "Involuntary mid-drag LostMouseCapture cancels gesture and restores pre-drag curve");

                // 5. Drag-out-of-bounds previews removal, dragging back inside restores, releasing outside commits removal.
                Check(canvas.HandleLeftButtonDown(Pt(0.4, 0.65), clickCount: 1, nowMsOverride: 6000), "Drag-out down");
                Check(canvas.HandlePointerMove(Pt(0.4, -0.20)), "Drag outside bottom margin");
                Check(current.Points.Count == 2, "Dragging interior point outside bounds previews removal");
                Check(canvas.HandlePointerMove(Pt(0.45, 0.60)), "Drag back inside bounds");
                Check(current.Points.Count == 3 && Math.Abs(current.Points[1].X - 0.45) < 1e-12 && Math.Abs(current.Points[1].Y - 0.60) < 1e-12,
                    "Dragging back inside bounds before release restores interior point");
                Check(canvas.HandlePointerMove(Pt(1.20, 0.60)), "Drag outside right margin");
                Check(canvas.HandleLeftButtonUp(Pt(1.20, 0.60)), "Release outside bounds");
                Check(current.Points.Count == 2, "Releasing outside bounds commits interior point deletion");

                // 6. Right-click deletes interior points; endpoints and Parametric view ignore point deletion/editing.
                current = ToneCurveSettings.Identity.Inserting(0.3, 0.35);
                canvas.Refresh(current, "photo-1", 1, ToneCurveChannel.Rgb, nextShowSplitMarkers: false);
                Check(canvas.HandleRightButtonDown(Pt(0.3, 0.35)) && current.Points.Count == 2, "Right-clicking interior point deletes it immediately");
                Check(!canvas.HandleRightButtonDown(Pt(0.0, 0.0)) && current.Points.Count == 2, "Right-clicking endpoint does not delete");
                Check(canvas.HandleLeftButtonDown(Pt(0.0, 0.0), clickCount: 1, nowMsOverride: 7000) && canvas.HandleLeftButtonUp(Pt(0.0, 0.0)), "Endpoint Click 1");
                Check(canvas.HandleLeftButtonDown(Pt(0.0, 0.0), clickCount: 2, nowMsOverride: 7100) && canvas.HandleLeftButtonUp(Pt(0.0, 0.0)) && current.Points.Count == 2,
                    "Double-clicking endpoint never deletes endpoint");
                canvas.Refresh(current, "photo-1", 0, ToneCurveChannel.Rgb, nextShowSplitMarkers: true);
                Check(!canvas.HandleLeftButtonDown(Pt(0.5, 0.5), clickCount: 1, nowMsOverride: 8000) &&
                    !canvas.HandleRightButtonDown(Pt(0.5, 0.5)) && current.Points.Count == 2,
                    "Parametric view suppresses canvas point editing and deletion");
                Check(gestureCompletedCount >= 6, "Completed gestures emit GestureCompletedEvent");
            }
            catch (Exception ex)
            {
                staFailure = ex;
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        });
        sta.SetApartmentState(ApartmentState.STA);
        sta.Start();
        sta.Join();
        if (staFailure != null) ExceptionDispatchInfo.Capture(staFailure).Throw();
    }
}
