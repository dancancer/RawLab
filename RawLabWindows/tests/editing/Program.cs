using RawLab.Windows;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var root = Path.Combine(Path.GetTempPath(), "rawlab-edit-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    // S1 regression: reset scope ownership, lossless detach, input validation and candidate isolation.
    var resetIdentity = new OriginalIdentity("fixture.ARW", 12, 34, 56);
    SavedEdit Edit(Adjustments state, string? look = "film.cube") => new(resetIdentity, state.Capture(), look);
    EditorResetScope Group(EditorAdjustmentGroup group) => new(EditorResetKind.Group, group);
    Check(EditorAdjustmentRules.Tools(EditorAdjustmentGroup.Light).SequenceEqual(new[] { EditorAdjustmentTool.Exposure,
        EditorAdjustmentTool.Highlights, EditorAdjustmentTool.Shadows, EditorAdjustmentTool.Contrast, EditorAdjustmentTool.ToneCurve }),
        "light tool order follows native ownership");
    foreach (var tool in Enum.GetValues<EditorAdjustmentTool>())
        Check(EditorAdjustmentRules.Tools(EditorAdjustmentRules.GroupFor(tool)).Contains(tool), "every native tool belongs to one group");
    var neutral = new Adjustments(); neutral.ResolveWhiteBalance((5200, 8));
    Check(Enum.GetValues<EditorAdjustmentGroup>().Select(EditorAdjustmentRules.Id).SequenceEqual(
        new[] { "looks", "light", "color", "effects", "detail", "geometry" }), "stable group identifiers");
    foreach (var group in Enum.GetValues<EditorAdjustmentGroup>())
        Check(!EditorAdjustmentRules.IsModified(Group(group), Edit(neutral, null)), "neutral group has no changed marker: " + group);
    Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), Edit(neutral, null)).Status == EditorResetStatus.NoChange,
        "neutral reset has no candidate and cannot produce an edit");
    var mixedState = neutral.Clone(); mixedState.Set(Parameter.Exposure, .75); mixedState.ExposureMode = 0;
    mixedState.Set(Parameter.Saturation, 23); mixedState.Set(Parameter.Sharpening, 42);
    mixedState.Hsl = mixedState.Hsl.WithValue(0, 2, .5).WithValue(1, 6, -33).WithValue(2, 2, 24);
    mixedState.Effects = new(0, 21, 11, 70, 33, 0, 66, 80);
    mixedState.Denoise = new(false, 13, 40, 27); mixedState.DisplayChromaDenoise = 2;
    mixedState.Geometry = new(PerspectiveHorizontal: .2); mixedState.Lens = new(true, true, false, true, "fixture");
    var mixedEdit = Edit(mixedState); var mixedFrozen = mixedEdit.Settings.Copy();
    foreach (var group in Enum.GetValues<EditorAdjustmentGroup>()) {
        Check(EditorAdjustmentRules.IsModified(Group(group), mixedEdit), "complete stored objects contribute to marker: " + group);
        var prepared = EditorAdjustmentRules.PrepareReset(Group(group), mixedEdit);
        Check(prepared.Status == EditorResetStatus.Ready && prepared.RequiresConfirmation && prepared.Candidate!.Identity == resetIdentity,
            "group candidate retains identity and requests confirmation: " + group);
        var candidate = prepared.Candidate!;
        var expected = mixedFrozen.Copy();
        if (group == EditorAdjustmentGroup.Light) {
            foreach (var index in new[] { 1, 4, 5, 6, 7 }) expected.Values[index] = 0;
            expected = expected with { ExposureMode = 1 };
        }
        if (group == EditorAdjustmentGroup.Color) {
            expected.Values[2] = 5200; expected.Values[3] = 8; expected.Values[8] = 0;
            expected = expected with { CameraWhiteBalance = true, Hsl = new() };
        }
        if (group == EditorAdjustmentGroup.Effects) expected = expected with { Effects = new() };
        if (group == EditorAdjustmentGroup.Detail) { expected.Values[9] = 0; expected = expected with { Denoise = new(), DisplayChromaDenoise = 0 }; }
        if (group == EditorAdjustmentGroup.Geometry) expected = expected with { Geometry = new(), Lens = new() };
        Check(candidate.Settings.SameAs(expected), "group reset preserves every unowned stored field: " + group);
        foreach (var other in Enum.GetValues<EditorAdjustmentGroup>().Where(other => other != group))
            Check(EditorAdjustmentRules.IsModified(Group(other), candidate) == EditorAdjustmentRules.IsModified(Group(other), mixedEdit),
                "unselected group marker survives reset: " + group + " / " + other);
        Check(!EditorAdjustmentRules.IsModified(Group(group), candidate), "selected group restores complete defaults: " + group);
        Check(candidate.Look == (group == EditorAdjustmentGroup.Looks ? null : "film.cube"), "look ownership is preserved");
        candidate.Settings.Values[1] = -3;
        Check(mixedEdit.Settings.SameAs(mixedFrozen), "candidate Values array cannot mutate original");
    }
    var channelReset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.HslChannel, Channel: 2), mixedEdit);
    Check(channelReset.Status == EditorResetStatus.Ready && !channelReset.RequiresConfirmation &&
        channelReset.Candidate!.Settings.Hsl!.Value(0, 2) == 0 && channelReset.Candidate.Settings.Hsl.Value(2, 2) == 0 &&
        channelReset.Candidate.Settings.Hsl.Value(1, 6) == -33 && channelReset.Candidate.Settings.Values[8] == 23,
        "current HSL channel clears only its three axes");
    var allHsl = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.AllHsl), mixedEdit);
    Check(allHsl.Status == EditorResetStatus.Ready && allHsl.RequiresConfirmation && allHsl.Candidate!.Settings.Hsl!.IsIdentity &&
        allHsl.Candidate.Settings.Values.SequenceEqual(mixedEdit.Settings.Values), "all HSL preserves other color controls");
    var allReset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), mixedEdit).Candidate!;
    Check(allReset.Look == null && allReset.Settings.SameAs(neutral.Capture()), "all reset includes look and full effective defaults");
    var oldSnapshot = new AdjustmentSnapshot((double[])neutral.Capture().Values.Clone(), 0, true, 5200, 8);
    var oldReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Effects), new(resetIdentity, oldSnapshot, null));
    Check(oldReset.Status == EditorResetStatus.NoChange && oldSnapshot.Restore().ExposureMode == 0,
        "missing optional fields retain existing defaults and historical exposure mode");
    foreach (var invalid in new[] {
        mixedFrozen with { Effects = new(0, double.NaN) }, mixedFrozen with { Denoise = new(false, -1) },
        mixedFrozen with { Geometry = new(CropWidth: 0) }, mixedFrozen with { AsShotTint = double.NaN },
        mixedFrozen with { AsShotTemperature = null }, mixedFrozen with { DisplayChromaDenoise = 3 }
    }) Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), new(resetIdentity, invalid, "film")).Status == EditorResetStatus.Invalid,
        "all reset validates invalid dormant fields before replacing them");
    Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.HslChannel, Channel: 8), mixedEdit).Status == EditorResetStatus.Invalid,
        "invalid HSL scope is rejected");
    var unknown = mixedFrozen with { MasterRecipeID = "unknown" };
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), new(resetIdentity, unknown, "film")).Status == EditorResetStatus.Blocked,
        "unknown recipe cannot silently become ordinary adjustments");
    foreach (var strength in new[] { 0.0, 50, 100, 200 }) {
        var recipeState = neutral.Clone(); recipeState.ApplyMasterRecipe(MasterRecipe.All[0]);
        recipeState.Set(Parameter.Strength, strength); recipeState.Set(Parameter.Exposure, .75);
        recipeState.Set(Parameter.Contrast, 17.3); recipeState.Set(Parameter.Highlights, 13.7);
        recipeState.Set(Parameter.Shadows, -21.1); recipeState.Set(Parameter.Saturation, 22.9);
        recipeState.Set(Parameter.Tint, 10); recipeState.Hsl = new HslSettings().WithValue(0, 0, .5).WithValue(1, 7, -80);
        var recipeEdit = Edit(recipeState); var recipeFrozen = recipeEdit.Settings.Copy();
        var detached = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), recipeEdit);
        Check(detached.Status == EditorResetStatus.Ready, "representable recipe detaches at strength " + strength + ": " + detached.Reason);
        var detachedState = detached.Candidate!.Settings.Restore();
        Check(detached.Candidate.Look == null && detachedState.MasterRecipeID == null && detachedState[Parameter.Strength] == 100,
            "look and recipe identities are both cleared");
        var before = recipeState.Request("fixture.ARW", null, 64, null); var after = detachedState.Request("fixture.ARW", null, 64, null);
        Check(before.ExposureEv == after.ExposureEv && before.Contrast == after.Contrast && before.Highlights == after.Highlights &&
            before.Shadows == after.Shadows && before.Saturation == after.Saturation && before.WbMode == after.WbMode &&
            before.Temperature == after.Temperature && before.Tint == after.Tint &&
            recipeState.RenderHsl.Values.Select(v => (float)v).SequenceEqual(detachedState.RenderHsl.Values.Select(v => (float)v)),
            "detach preserves exact final core Float fields and HSL for strength " + strength);
        if (strength == 0) Check(detachedState[Parameter.Tint] == 8 && detachedState.CameraWhiteBalance,
            "zero recipe offset becomes stored absolute as-shot tint when identity is cleared");
        Check(detachedState.Hsl.Value(1, 7) == (strength == 200 ? -100 : -80 * strength / 100), "detach retains existing HSL clamp");
        Check(recipeEdit.Settings.SameAs(recipeFrozen), "preparing and discarding a recipe candidate is cancellation without mutation");
        var colorReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), recipeEdit).Candidate!.Settings.Restore();
        Check(colorReset.MasterRecipeID == recipeState.MasterRecipeID && colorReset[Parameter.Tint] == 0 &&
            colorReset[Parameter.Exposure] == .75 && colorReset.Hsl.IsIdentity, "color reset clears recipe offsets without replaying recipe");
        var json = System.Text.Json.JsonSerializer.Serialize(detached.Candidate);
        var roundtrip = System.Text.Json.JsonSerializer.Deserialize<SavedEdit>(json)!;
        Check(roundtrip.Identity == resetIdentity && roundtrip.Look == null && roundtrip.Settings.SameAs(detached.Candidate.Settings),
            "candidate JSON retains SavedEdit identity and existing schema");
    }
    var unsafeRecipe = new Adjustments(); unsafeRecipe.ApplyMasterRecipe(MasterRecipe.All[0]); unsafeRecipe.Set(Parameter.Tint, 10);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "RAW relative tint cannot invent as-shot calibration");
    unsafeRecipe.Set(Parameter.Tint, 0); unsafeRecipe.Set(Parameter.Temperature, 7000);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "RAW custom recipe WB also needs real calibration");
    unsafeRecipe.Set(Parameter.Exposure, 4); unsafeRecipe.Set(Parameter.Strength, 200);
    unsafeRecipe.ResolveWhiteBalance((5200, 8));
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "out of range materialized exposure is blocked without clamping");
    unsafeRecipe.Set(Parameter.Strength, 0);
    Check(EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Light), Edit(unsafeRecipe)), "zero recipe strength retains stored light marker");
    var calibrationFree = new Adjustments(); calibrationFree.ApplyMasterRecipe(MasterRecipe.All[0]);
    calibrationFree.Set(Parameter.Tint, 0);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(calibrationFree)).Status == EditorResetStatus.Ready,
        "as-shot recipe without relative tint does not require calibration");
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Effects), Edit(unsafeRecipe)).Status == EditorResetStatus.NoChange,
        "unrelated scope does not require recipe calibration");
    var clippedTint = neutral.Clone(); clippedTint.ApplyMasterRecipe(MasterRecipe.All[0]);
    clippedTint.Set(Parameter.Tint, 150); clippedTint.Set(Parameter.Strength, 200);
    var clippedDetach = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(clippedTint));
    Check(clippedDetach.Status == EditorResetStatus.Ready && clippedDetach.Candidate!.Settings.Values[3] == 150,
        "materialization retains original renderer tint clamp");
    clippedTint.Set(Parameter.Contrast, 100);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(clippedTint)).Status == EditorResetStatus.Blocked,
        "materialized contrast outside native range is blocked");
    var rasterState = mixedState.Clone(); rasterState.ApplyMasterRecipe(MasterRecipe.All[0]); rasterState.Set(Parameter.Strength, 50);
    var rasterEdit = new SavedEdit(resetIdentity with { Path = "fixture.jpg" }, rasterState.Capture(), "film");
    var rasterDetached = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), rasterEdit);
    Check(rasterDetached.Status == EditorResetStatus.Ready && rasterDetached.Candidate!.Settings.CameraWhiteBalance &&
        rasterDetached.Candidate.Settings.Values[2] == 6500 && rasterDetached.Candidate.Settings.Values[3] == 0,
        "raster detach follows input preparation and fixed display WB without camera calibration");
    var rasterDefault = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), rasterEdit).Candidate!.Settings.Restore();
    Check(rasterDefault.ExposureMode == 2 && rasterDefault.Lens == new LensSettings(false, false, false) && rasterDefault.AsShot == null,
        "raster reset uses sensor exposure and unavailable camera-only defaults");
    var rasterNeutralSnapshot = PhotoInput.PrepareInputSettings("fixture.jpg", new Adjustments()).Capture();
    var rasterMetadataOnly = rasterNeutralSnapshot.Copy() with {
        ExposureMode = 0, CameraWhiteBalance = false, AsShotTemperature = 5200, AsShotTint = 8
    };
    rasterMetadataOnly.Values[2] = 7300; rasterMetadataOnly.Values[3] = 17;
    var rasterMetadataEdit = new SavedEdit(resetIdentity with { Path = "fixture.jpg" }, rasterMetadataOnly, null);
    var rasterMetadataFrozen = rasterMetadataOnly.Copy();
    foreach (var scope in new[] { Group(EditorAdjustmentGroup.Light), Group(EditorAdjustmentGroup.Color), new EditorResetScope(EditorResetKind.All) }) {
        Check(!EditorAdjustmentRules.IsModified(scope, rasterMetadataEdit), "raster RAW-only metadata does not create a marker: " + scope.Kind + "/" + scope.Group);
        Check(EditorAdjustmentRules.PrepareReset(scope, rasterMetadataEdit).Status == EditorResetStatus.NoChange,
            "raster RAW-only metadata does not create a reset candidate: " + scope.Kind + "/" + scope.Group);
    }
    Check(rasterMetadataOnly.SameAs(rasterMetadataFrozen), "raster marker comparison preserves original metadata and Values array");
    var rasterLightChanged = rasterMetadataOnly.Copy(); rasterLightChanged.Values[1] = .5;
    var rasterLightReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Light), rasterMetadataEdit with { Settings = rasterLightChanged });
    Check(rasterLightReset.Status == EditorResetStatus.Ready && rasterLightReset.Candidate!.Settings.ExposureMode == 2 &&
        rasterLightReset.Candidate.Settings.Values[1] == 0 && rasterLightReset.Candidate.Settings.Values[2] == 7300,
        "real raster light reset restores owned exposure defaults and preserves stored WB");
    var rasterColorChanged = rasterMetadataOnly.Copy(); rasterColorChanged.Values[8] = 20;
    var rasterColorReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), rasterMetadataEdit with { Settings = rasterColorChanged });
    Check(rasterColorReset.Status == EditorResetStatus.Ready && rasterColorReset.Candidate!.Settings.CameraWhiteBalance &&
        rasterColorReset.Candidate.Settings.Values[2] == 6500 && rasterColorReset.Candidate.Settings.Values[3] == 0 &&
        rasterColorReset.Candidate.Settings.AsShotTemperature == null && rasterColorReset.Candidate.Settings.AsShotTint == null &&
        rasterColorReset.Candidate.Settings.ExposureMode == 0, "real raster color reset restores complete owned WB defaults only");
    var rasterRecipeTint = rasterMetadataOnly.Copy() with { MasterRecipeID = MasterRecipe.All[0].Id };
    rasterRecipeTint.Values[0] = 0; rasterRecipeTint.Values[3] = 0;
    Check(!EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Color), rasterMetadataEdit with { Settings = rasterRecipeTint }),
        "raster recipe color defaults compare tint with relative zero");
    rasterRecipeTint.Values[3] = 17;
    var rasterRecipeTintEdit = rasterMetadataEdit with { Settings = rasterRecipeTint };
    Check(EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Color), rasterRecipeTintEdit),
        "raster recipe relative tint remains marked at zero strength");
    var rasterRecipeTintReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), rasterRecipeTintEdit);
    Check(rasterRecipeTintReset.Status == EditorResetStatus.Ready && rasterRecipeTintReset.Candidate!.Settings.Values[3] == 0 &&
        rasterRecipeTintReset.Candidate.Settings.MasterRecipeID == rasterRecipeTint.MasterRecipeID,
        "raster color reset clears stored recipe tint without losing recipe identity");
    foreach (var dormant in new[] {
        (EditorAdjustmentGroup.Effects, rasterMetadataOnly.Copy() with { Effects = new(0, 21) }),
        (EditorAdjustmentGroup.Detail, rasterMetadataOnly.Copy() with { Denoise = new(false, 13) }),
        (EditorAdjustmentGroup.Geometry, rasterMetadataOnly.Copy() with { Lens = new(false, false, true) })
    }) {
        var dormantEdit = rasterMetadataEdit with { Settings = dormant.Item2 };
        Check(EditorAdjustmentRules.IsModified(Group(dormant.Item1), dormantEdit) &&
            EditorAdjustmentRules.IsModified(new(EditorResetKind.All), dormantEdit), "raster dormant complete object remains marked: " + dormant.Item1);
        Check(EditorAdjustmentRules.PrepareReset(Group(dormant.Item1), dormantEdit).Status == EditorResetStatus.Ready,
            "raster dormant complete object remains resettable: " + dormant.Item1);
    }
    var exposureSpec = ParameterSpec.All[(int)Parameter.Exposure];
    Check(exposureSpec.Value(exposureSpec.Position(.13)) == .13, "v08 exposure slider uses 0.01 fine grid");
    Check(Math.Abs(ParameterSpec.All[(int)Parameter.Tint].Value(ParameterSpec.All[(int)Parameter.Tint].Position(.3)) - .3) < 1e-10,
        "v08 tint slider retains tenths");
    var wheel = new ParameterWheel();
    Check(wheel.Feed(40,0,false,0,true) == (true,0) && wheel.Feed(40,0,false,1,true) == (true,1), "wheel threshold accumulates to 80 pixels");
    Check(wheel.Feed(800,0,false,126,true) == (true,1) && wheel.Feed(800,0,false,130,true) == (true,0), "wheel limits each event and 125 ms interval");
    Check(wheel.Feed(-40,0,false,260,true) == (true,0) && wheel.Feed(40,0,false,261,true) == (true,0), "reversing clears wheel remainder");
    Check(wheel.Feed(40,0,true,262,true) == (true,0) && wheel.Feed(40,0,true,263,true) == (true,1), "Shift resets remainder without changing direction");
    Check(wheel.Feed(40,0,true,500,true) == (true,0) && wheel.Feed(40,0,true,701,true) == (true,0), "200ms idle clears remainder");
    Check(wheel.Feed(120,0,false,900,false) == (false,0) && wheel.Feed(0,100,false,901,true) == (false,0) &&
          wheel.Feed(double.NaN,0,false,902,true) == (false,0), "disabled, horizontal and invalid events bubble");
    var temperatureRange = NumericRange.For(ParameterSpec.All[(int)Parameter.Temperature]);
    Check(temperatureRange.Position(50000) == 1 && temperatureRange.Position(2000) == 0 &&
          temperatureRange.Value(temperatureRange.Position(5200)) == 5200, "inverse temperature warms to the right and roundtrips");
    Check(new NumericRange(-100,100).Parse("999") == 100 && new NumericRange(-100,100).Parse("NaN") == null,
        "numeric commit clamps finite values and rejects invalid input");
    Loc.Initialize("de");Check(new NumericRange(-100,100).Parse("1,2") is {} localized && Math.Abs(localized-1.2)<1e-10 && new NumericRange(-100,100).Format(1.2)=="1,2","German numeric display and commit share one locale");Loc.Initialize("en");
    var fineEffects=new Adjustments();fineEffects.SetEffect(PhotoEffectParameter.GrainAmount,12.3);
    Check(Math.Abs(fineEffects.Effects.GrainAmount-12.3)<1e-10,"effect model preserves the v08 tenth-unit grid");
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
    var identityGeometry = new GeometrySettings();
    Check(typeof(GeometrySettings).GetProperty("PerspectiveHorizontal")!=null,
        "v08 geometry persists perspective without extending the existing geometry ABI");
    var perspective=new GeometrySettings(PerspectiveHorizontal:.23,PerspectiveVertical:-.4);
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.PerspectiveConfig>()==16 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.PerspectiveConfig>(nameof(Native.PerspectiveConfig.Horizontal)).ToInt32()==8 &&
          perspective.NativePerspectiveConfig() is{Version:1,StructSize:16,Horizontal:.23f,Vertical:-.4f},"additive perspective v1 ABI is 16 bytes");
    var transform=new TransformDraft();var committed=new Adjustments{Geometry=perspective};
    var committedSnapshot=committed.Capture();
    transform.Begin(committed.Geometry,committed.Lens,TransformTool.Geometry);
    transform.Update(perspective with{CropX=.1,CropWidth=.8,StraightenDegrees=12});
    Check(transform.Dirty && committed.Capture().SameAs(committedSnapshot) && transform.PreviewGeometry.CropWidth==1,
        "geometry draft previews full transformed canvas without changing committed/batch snapshot");
    transform.Cancel();Check(!transform.Active && committed.Capture().SameAs(committedSnapshot),"cancel discards draft only");
    transform.Begin(committed.Geometry,committed.Lens,TransformTool.Lens);transform.Update(new LensSettings(true,true));
    Check(committed.Lens==new LensSettings() && transform.Dirty,"lens correction has an independent unsaved draft");
    var applied=transform.Apply();Check(applied.Lens.Enabled && !transform.Active,"apply returns draft to committed owner");
    var selection=new CropRect(.2,.2,.6,.6);
    foreach(var handle in Enum.GetValues<CropHandle>())foreach(var ratio in new double?[]{null,1,3.0/2,16.0/9})
    {
        var moved=CropInteraction.Dragging(selection,handle,-2,3,6000,4000,ratio);
        Check(moved.X>=-1e-12 && moved.Y>=-1e-12 && moved.Right<=1+1e-12 && moved.Bottom<=1+1e-12 && moved.Width>0 && moved.Height>0,
            "eight crop handles and moving stay inside the canvas: "+handle);
        if(ratio.HasValue && handle!=CropHandle.Move)Check(Math.Abs(moved.Width*6000/(moved.Height*4000)-ratio.Value)<1e-8,"locked ratio survives boundary drag");
    }
    var freeTop=CropInteraction.Dragging(selection,CropHandle.Top,0,.1,6000,4000,null);
    Check(freeTop.Width==selection.Width && Math.Abs(freeTop.Y-.3)<1e-10,"free edge changes only its own axis");
    var rotated=(perspective with{CropX=.1,CropY=.2,CropWidth=.3,CropHeight=.4}).Rotate(1);
    Check(Math.Abs(rotated.CropX-.4)<1e-10 && rotated.CropY==.1 && rotated.CropWidth==.4 && rotated.CropHeight==.3,
        "quarter turn transforms crop coordinates instead of stretching selection");
    foreach(var extent in new[]{.1,.2,.3,.01})foreach(var turns in new[]{-1,1,2,3,4})
    {
        var edge=CropInteraction.Dragging(new(0,0,extent,extent),CropHandle.Move,2,2,6000,4000,null);
        var turned=CropInteraction.Applying(edge,new()).Rotate(turns);
        _=turned.NativeConfig();
        Check(turned.CropX>=0 && turned.CropY>=0 && turned.CropWidth==extent && turned.CropHeight==extent,
            "boundary crop remains valid after quarter turns: "+extent+" / "+turns);
    }
    Check(identityGeometry.IsIdentity && identityGeometry.NativeConfig() is { Version: 1, StructSize: 40, CropWidth: 1, CropHeight: 1 }, "geometry defaults and v1 ABI");
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.GeometryConfig>() == 40 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.GeometryConfig>(nameof(Native.GeometryConfig.QuarterTurns)).ToInt32() == 24 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.GeometryConfig>(nameof(Native.GeometryConfig.StraightenDegrees)).ToInt32() == 36, "geometry native layout");
    Check(identityGeometry.Rotate(-1).QuarterTurns == 3 && identityGeometry.Rotate(5).QuarterTurns == 1 && identityGeometry.Rotate(4).IsIdentity, "quarter turn wrapping");
    var crop = identityGeometry.WithCropPercent(CropComponent.X, 30).WithCropPercent(CropComponent.Width, 90);
    Check(crop.CropX == .3 && crop.CropWidth == .7, "crop inputs stay inside the normalized canvas");
    _ = crop.NativeConfig();
    foreach (var invalid in new[] {
        identityGeometry with { CropX = -.1 }, identityGeometry with { CropY = double.NaN },
        identityGeometry with { CropWidth = 0 }, identityGeometry with { CropHeight = double.PositiveInfinity },
        identityGeometry with { CropX = .2, CropWidth = .9 }, identityGeometry with { QuarterTurns = 4 },
        identityGeometry with { StraightenDegrees = 46 }, identityGeometry with { StraightenDegrees = double.NaN }
    }) {
        try { _ = invalid.NativeConfig(); throw new Exception("invalid geometry accepted"); }
        catch (ArgumentOutOfRangeException) { }
    }
    var geometryState = new Adjustments { Geometry = new(.2,.1,.65,.8,1,true,true,12.5) };
    var geometrySnapshot = geometryState.Capture(); var geometryClone = geometryState.Clone();
    geometryState.Geometry = new();
    Check(geometryClone.Geometry == geometrySnapshot.Geometry && !geometrySnapshot.SameAs(geometryState.Capture()), "geometry clone and snapshot freeze independent edits");
    try { _ = (geometrySnapshot with { Geometry = identityGeometry with { CropWidth = 0 } }).Restore(); throw new Exception("invalid saved geometry accepted"); }
    catch (ArgumentOutOfRangeException) { }
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
    state.Geometry = geometrySnapshot.Geometry!;
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
    Check(restored.Settings.Restore().Geometry == saved.Geometry, "geometry survives store restart");
    Check(!saved.SameAs(saved with { Geometry = new() }), "geometry changes mark snapshot dirty");
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
    legacy.Remove("Geometry");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Geometry.IsIdentity, "older records default to identity geometry");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Lens == new LensSettings(), "legacy lens is disabled");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Denoise == new DenoiseSettings(), "older records default to disabled denoise");
    Check(reopened.Find(b) == null, "same basename does not share edits");
    state.ResetGroup("几何"); Check(state.Geometry.IsIdentity, "geometry group reset");
    state.Geometry = geometrySnapshot.Geometry!;
    state.ResetGroup("镜头"); Check(state.Lens == new LensSettings(), "lens group reset");
    state.Lens = new LensSettings(true);
    state.ResetAll(); Check(state.Geometry.IsIdentity, "reset all clears geometry"); Check(state.Lens == new LensSettings(), "reset all clears lens");
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
    var invalidTarget=BatchItem.Create(a) with{Selected=true,ValidationError="unsupported RAW"};
    var preflightJob=BatchJob.Create(a,saved,null,"Velvia");preflightJob.Items.Add(invalidTarget);
    Check(!invalidTarget.CanSelect && preflightJob.SelectedCount==0,"Failed RAW preflight cannot become a selected batch target");
    job.OutputDirectory = output;
    job.Items.Add(BatchItem.Create(a) with { Selected = true });
    job.Items.Add(BatchItem.Create(b) with { Selected = true });
    var journal = new BatchJournal(Path.Combine(root, "batch"));
    var rasterSource = Path.Combine(root, "source.PNG");
    var mixed = BatchJob.Create(rasterSource, saved, null, "Mixed");
    mixed.OutputDirectory = output;
    mixed.Items.Add(BatchItem.Create(a) with { Selected = true });
    var mixedCalls = 0;
    BatchRunner.Run(mixed, journal, false, CancellationToken.None, (_, _) => { }, (_, settings, _, destination) => {
        mixedCalls++;
        Check(settings.ExposureMode == 1 && settings[Parameter.Temperature] == 6500 && settings[Parameter.Tint] == 0 &&
              settings.Lens == new LensSettings(false,false,false), "raster source does not leak camera-only settings into RAW targets");
        Check(settings[Parameter.Exposure] == .75 && settings.Geometry == saved.Geometry && settings.Denoise == saved.Denoise,
              "mixed targets retain common frozen editing parameters");
        File.WriteAllText(destination, "mixed");
    });
    Check(mixedCalls == 1 && mixed.Items[0].Status == BatchStatus.Succeeded && mixed.Settings.SameAs(saved),
          "renderer-independent batch normalization preserves the stored source snapshot");
    var calls = new List<string>();
    BatchRunner.Run(job, journal, false, CancellationToken.None, (_, _) => { }, (input, settings, _, destination) => {
        calls.Add(input); Check(settings[Parameter.Exposure] == .75, "frozen source parameters");
        Check(settings.Denoise == DenoiseSettings.Clean, "frozen source denoise");
        Check(settings.Geometry == saved.Geometry, "batch render uses frozen geometry");
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
    Check(recovered.Settings.Restore().Geometry == saved.Geometry, "geometry survives journal recovery");
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
