using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class CanonicalEditRecipeChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static void Run()
    {
        var rawSettings = new Adjustments
        {
            Processing = ProcessingIdentity.C5,
            X3fMode = X3fMode.Legacy,
            ExposureMode = 0,
            ToneControls = new ToneControlsSettings(-25, 40, 15),
            Atmosphere = new AtmosphereSettings(30, -10),
            ColorGrading = new ColorGradingSettings
            {
                Shadows = new ColorGradingWheel(200, 30),
                Midtones = new ColorGradingWheel(45, 10),
                Highlights = new ColorGradingWheel(350, 20)
            },
            Curve = new ToneCurveSettings(
                ToneCurveMode.Custom,
                [new(0, 0), new(0.5, 0.6), new(1, 1)],
                new ToneCurveChannels(
                    new ToneCurveShape(ToneCurveMode.Custom, [new(0, 0), new(0.5, 0.55), new(1, 1)]),
                    new ToneCurveShape(),
                    new ToneCurveShape())),
            Hsl = new HslSettings().WithValue(0, 0, 12),
            Geometry = new GeometrySettings(0.1, 0.2, 0.7, 0.6, 1, true, false, -2.5, 0.2, -0.1),
            Lens = new LensSettings(Distortion: true, Tca: true, AutoCrop: false, Manual: true, ProfileId: "lens-win", Vignetting: true),
            Effects = new PhotoEffectsSettings(VignetteAmount: -50, GrainAmount: 25),
            Denoise = new DenoiseSettings(Enabled: true, Luma: 15, Chroma: 60, Coarse: 70),
            DisplayChromaDenoise = 1
        };

        var rawJson = CanonicalEditRecipe.Encode(rawSettings, isRaster: false);
        var rawRoot = JsonNode.Parse(rawJson)!.AsObject();
        Check(rawRoot["input"]!["path"] == null, "Strict canonical recipe omits synthetic file path placeholders");
        Check(rawRoot["schema_version"]!.GetValue<int>() == 7, "RAW canonical recipe uses schema_version 7");
        Check(rawRoot["x3f_mode"]!.GetValue<string>() == "legacy", "RAW canonical recipe preserves x3f_mode");
        Check(rawRoot["processing"]!["version"]!.GetValue<int>() == 2, "RAW canonical recipe uses integer processing version");
        Check(rawRoot["edits"]!["exposure"]!["mode"]!.GetValue<string>() == "scene", "RAW canonical recipe encodes exposure mode");
        Check(Math.Abs(rawRoot["edits"]!["tone"]!["black_point"]!.GetValue<double>() - (-0.25)) < 1e-6, "black_point scales to [-1, 1]");
        Check(Math.Abs(rawRoot["edits"]!["tone"]!["white_point"]!.GetValue<double>() - 0.40) < 1e-6, "white_point scales to [-1, 1]");
        Check(Math.Abs(rawRoot["edits"]!["color"]!["vibrance"]!.GetValue<double>() - 0.15) < 1e-6, "vibrance scales to [-1, 1]");
        Check(Math.Abs(rawRoot["edits"]!["effects"]!["clarity"]!.GetValue<double>() - 0.30) < 1e-6, "clarity scales to [-1, 1]");
        Check(Math.Abs(rawRoot["edits"]!["effects"]!["dehaze"]!.GetValue<double>() - (-0.10)) < 1e-6, "dehaze scales to [-1, 1]");
        Check(rawRoot["edits"]!["tone"]!["curve"]!["channels"]!["red"] != null, "channel curves serialize when non-default");
        Check(rawRoot["edits"]!["lens_correction"]!["profile_id"]!.GetValue<string>() == "lens-win", "manual lens profile_id preserved");

        var rasterSettings = new Adjustments
        {
            Processing = ProcessingIdentity.Legacy,
            ExposureMode = 1,
            Lens = new LensSettings(Distortion: true, Manual: false)
        };
        var rasterJson = CanonicalEditRecipe.Encode(rasterSettings, isRaster: true, includeDenoise: false);
        var rasterRoot = JsonNode.Parse(rasterJson)!.AsObject();
        Check(rasterRoot["schema_version"]!.GetValue<int>() == 5, "Raster canonical recipe uses schema_version 5");
        Check(!rasterRoot.ContainsKey("x3f_mode"), "Raster canonical recipe omits x3f_mode");
        Check(rasterRoot["input"]!["type"]!.GetValue<string>() == "raster", "Raster canonical recipe sets input.type=raster");
        Check(rasterRoot["edits"]!["exposure"]!["mode"]!.GetValue<string>() == "sensor", "Raster canonical recipe forces sensor exposure mode");
        Check(rasterRoot["edits"]!["white_balance"]!["mode"]!.GetValue<string>() == "none", "Raster canonical recipe sets white_balance.mode=none");
        Check(!rasterRoot["edits"]!["lens_correction"]!.AsObject().ContainsKey("profile_id"), "Automatic lens omits profile_id");
        Check(rasterRoot["edits"]!["denoise"]!["chroma_mode"]!.GetValue<int>() == 0, "Disabled includeDenoise zeroes chroma_mode");

        var procOnly = JsonNode.Parse(CanonicalEditRecipe.ProcessingStateJson(3, "scene"))!.AsObject();
        Check(procOnly["processing"]!["version"]!.GetValue<int>() == 3, "Processing-state helper preserves version");
        Check(procOnly["edits"]!["exposure"]!["mode"]!.GetValue<string>() == "scene" && !procOnly.ContainsKey("input"),
            "Processing-state helper preserves exposure mode without synthetic input");

        var compatPreview = JsonNode.Parse(CanonicalEditRecipe.CompatibilityPreviewStateJson(2, "scene", "look.cube", 0.75))!.AsObject();
        Check(compatPreview["edits"]!["look"]!["path"]!.GetValue<string>() == "look.cube" &&
              compatPreview["edits"]!["look"]!["strength"]!.GetValue<double>() == 0.75,
            "Compatibility preview helper serializes look path and strength");

        var recipeState = new Adjustments { AIDenoiseEnabled = true, AIDenoiseStrength = 40 };
        recipeState.ApplyMasterRecipe(MasterRecipe.All[0]);
        recipeState.Set(Parameter.Strength, 0.8);
        recipeState.Set(Parameter.Temperature, 5400);
        recipeState.Set(Parameter.Tint, 12);
        var stateJson = JsonNode.Parse(CanonicalEditRecipe.EncodeState(recipeState, isRaster: false, lutPath: "film.cube"))!.AsObject();
        Check(stateJson["edits"]!["master_recipe"]!["active"]!.GetValue<bool>() &&
              Math.Abs(stateJson["edits"]!["master_recipe"]!["strength"]!.GetValue<double>() - 0.8) < 1e-6 &&
              stateJson["edits"]!["master_recipe"]!["temperature_kelvin"]!.GetValue<double>() == 5400 &&
              Math.Abs(stateJson["edits"]!["ai_denoise_blend"]!.GetValue<double>() - 0.4) < 1e-6 &&
              stateJson["edits"]!["look"]!["path"]!.GetValue<string>() == "film.cube",
            "Session state encoder populates master_recipe, ai_denoise_blend, and look path");

        var zeroStrengthRecipe = new Adjustments();
        zeroStrengthRecipe.ApplyMasterRecipe(MasterRecipe.All[0]);
        zeroStrengthRecipe.ResolveWhiteBalance((6955, 99));
        zeroStrengthRecipe.Set(Parameter.Strength, 0.0);
        var zeroStrengthJson = JsonNode.Parse(CanonicalEditRecipe.EncodeState(zeroStrengthRecipe, isRaster: false))!.AsObject();
        Check(!zeroStrengthJson["edits"]!["master_recipe"]!["custom_wb"]!.GetValue<bool>() &&
              zeroStrengthJson["edits"]!["master_recipe"]!["temperature_kelvin"]!.GetValue<double>() == 6500 &&
              zeroStrengthJson["edits"]!["master_recipe"]!["tint"]!.GetValue<double>() == 0,
            "Zero-strength Camera WB master_recipe normalizes temperature_kelvin=6500 and tint=0");

        var zeroTintRecipe = new Adjustments();
        zeroTintRecipe.ApplyMasterRecipe(MasterRecipe.All[0]);
        zeroTintRecipe.ResolveWhiteBalance((6955, 99));
        zeroTintRecipe.SetRelativeWhiteBalance(6955, 0);
        zeroTintRecipe.ResolveWhiteBalance((6955, 99));
        var zeroTintJson = JsonNode.Parse(CanonicalEditRecipe.EncodeState(zeroTintRecipe, isRaster: false))!.AsObject();
        Check(!zeroTintJson["edits"]!["master_recipe"]!["custom_wb"]!.GetValue<bool>() &&
              zeroTintJson["edits"]!["master_recipe"]!["temperature_kelvin"]!.GetValue<double>() == 6500 &&
              zeroTintJson["edits"]!["master_recipe"]!["tint"]!.GetValue<double>() == 0,
            "Zero-tint Camera WB master_recipe normalizes temperature_kelvin=6500 and tint=0");

        var unpinnedMaster = new Adjustments
        {
            Curve = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0.2), new(1, 0.8)])
        };
        Check(JsonNode.Parse(CanonicalEditRecipe.Encode(unpinnedMaster, isRaster: false))!["schema_version"]!.GetValue<int>() == 17,
            "Unpinned curve endpoints promote canonical recipe to schema_version 17");
        var freeXMaster = new Adjustments
        {
            Curve = new ToneCurveSettings(ToneCurveMode.Custom, [new(0.15, 0), new(0.85, 1)])
        };
        Check(JsonNode.Parse(CanonicalEditRecipe.Encode(freeXMaster, isRaster: false))!["schema_version"]!.GetValue<int>() == 18 &&
            JsonNode.Parse(CanonicalEditRecipe.Encode(freeXMaster, isRaster: true))!["schema_version"]!.GetValue<int>() == 18,
            "Free endpoint X promotes canonical recipe to schema_version 18");

        var sharpenedJson = CanonicalEditRecipe.Encode(new Adjustments(), isRaster: false, outputSharpening: OutputSharpening.Standard);
        var sharpenedRoot = JsonNode.Parse(sharpenedJson)!.AsObject();
        Check(sharpenedRoot["schema_version"]!.GetValue<int>() >= 16,
            "Non-off output_sharpening promotes canonical recipe to at least schema_version 16");
        Check(sharpenedRoot["output"]!["output_sharpening"]!.GetValue<string>() == "standard",
            "Canonical recipe serializes output.output_sharpening wire token");

        var rasterRelativeWb = new Adjustments();
        rasterRelativeWb.SetRelativeWhiteBalance(5200, 18);
        var rasterRelativeJson = JsonNode.Parse(CanonicalEditRecipe.Encode(rasterRelativeWb, isRaster: true))!.AsObject();
        Check(rasterRelativeJson["schema_version"]!.GetValue<int>() == 17,
            "SDR raster relative WB promotes canonical recipe to schema_version 17");
        Check(rasterRelativeJson["edits"]!["white_balance"]!["mode"]!.GetValue<string>() == "relative" &&
              rasterRelativeJson["edits"]!["white_balance"]!["relative_temperature"]!.GetValue<double>() == 5200 &&
              rasterRelativeJson["edits"]!["white_balance"]!["relative_tint"]!.GetValue<double>() == 18,
            "SDR raster relative WB encodes mode=relative with relative_temperature and relative_tint");

        var gradingV2 = new Adjustments
        {
            ColorGrading = new ColorGradingSettings
            {
                Shadows = new(180, 25, -12),
                Global = new(60, 15, 8),
                Blending = 75,
                Balance = -20
            }
        };
        var gradingV2Json = JsonNode.Parse(CanonicalEditRecipe.Encode(gradingV2, isRaster: true))!.AsObject();
        Check(gradingV2Json["schema_version"]!.GetValue<int>() == 17 &&
              gradingV2Json["edits"]!["color_grading"]!["global"]!["luminance"]!.GetValue<double>() == 8 &&
              gradingV2Json["edits"]!["color_grading"]!["blending"]!.GetValue<double>() == 75 &&
              gradingV2Json["edits"]!["color_grading"]!["balance"]!.GetValue<double>() == -20,
            "CanonicalEditRecipe encodes Color Grading v2 global, luminance, blending, and balance under schema_version 17");

        var masterRecipe = MasterRecipe.All.First(recipe => recipe.TintDelta != 0);
        var masterTwo = new Adjustments();
        masterTwo.ApplyMasterRecipe(masterRecipe);
        masterTwo.Set(Parameter.Strength, 2.0);
        masterTwo.ResolveWhiteBalance((2000, -150));
        var masterTwoRequest = masterTwo.Request("fixture.dng", masterRecipe.LutPath, 0, "out.png", 128);
        var masterTwoState = JsonNode.Parse(CanonicalEditRecipe.EncodeState(masterTwo, isRaster: false, lutPath: masterRecipe.LutPath))!.AsObject();
        var canonicalContrast = (float)masterTwoState["edits"]!["tone"]!["contrast"]!.GetValue<double>();
        var canonicalSaturation = (float)masterTwoState["edits"]!["tone"]!["saturation"]!.GetValue<double>();
        Check(BitConverter.SingleToInt32Bits(masterTwoRequest.Contrast) == BitConverter.SingleToInt32Bits(canonicalContrast) &&
              BitConverter.SingleToInt32Bits(masterTwoRequest.Saturation) == BitConverter.SingleToInt32Bits(canonicalSaturation),
            "Adjustments.Request Contrast and Saturation match CanonicalEditRecipe.EncodeState bit-for-bit at master strength 2.0");

        var contrastParity = masterTwo.Clone();
        contrastParity.Set(Parameter.Contrast, 0.92);
        var contrastParityRequest = contrastParity.Request("fixture.dng", masterRecipe.LutPath, 0, "out.png", 128);
        var contrastParityState = JsonNode.Parse(CanonicalEditRecipe.EncodeState(contrastParity, isRaster: false, lutPath: masterRecipe.LutPath))!.AsObject();
        var canonicalContrast92 = (float)contrastParityState["edits"]!["tone"]!["contrast"]!.GetValue<double>();
        Check(BitConverter.SingleToInt32Bits(contrastParityRequest.Contrast) == BitConverter.SingleToInt32Bits(canonicalContrast92),
            "Adjustments.Request Contrast matches CanonicalEditRecipe.EncodeState bit-for-bit without float addition 1-ULP drift");

        var coreClamp = new Adjustments();
        coreClamp.ApplyMasterRecipe(masterRecipe);
        coreClamp.Set(Parameter.Strength, 2.0);
        coreClamp.Set(Parameter.Contrast, 2.0);
        coreClamp.Set(Parameter.Saturation, 0.0);
        coreClamp.Set(Parameter.Highlights, -1.0);
        coreClamp.Set(Parameter.Shadows, -1.0);
        coreClamp.Set(Parameter.ToneCurve, 1.0);
        coreClamp.Set(Parameter.Sharpening, 2.0);
        var coreClampState = JsonNode.Parse(CanonicalEditRecipe.EncodeState(coreClamp, isRaster: false, lutPath: masterRecipe.LutPath))!.AsObject();
        var coreClampTone = coreClampState["edits"]!["tone"]!.AsObject();
        Check(coreClampTone["contrast"]!.GetValue<double>() == 2.0 &&
              coreClampTone["saturation"]!.GetValue<double>() == 0.0 &&
              coreClampTone["highlights"]!.GetValue<double>() == -1.0 &&
              coreClampTone["shadows"]!.GetValue<double>() == -1.0 &&
              coreClampTone["s_curve"]!.GetValue<double>() == 0.0 &&
              coreClampState["edits"]!["detail"]!["sharpening"]!.GetValue<double>() == 2.0 &&
              coreClampState["edits"]!["look"]!["strength"]!.GetValue<double>() == 2.0 &&
              coreClampState["edits"]!["master_recipe"]!["strength"]!.GetValue<double>() == 2.0,
            "CanonicalEditRecipe.EncodeState clamps master-recipe-scaled Contrast, Saturation, Highlights, and Shadows to canonical bounds (core-clamp)");

        var coreClampOpposite = new Adjustments();
        coreClampOpposite.ApplyMasterRecipe(masterRecipe);
        coreClampOpposite.Curve = new ToneCurveSettings();
        coreClampOpposite.Set(Parameter.Strength, 2.0);
        coreClampOpposite.Set(Parameter.Contrast, 0.0);
        coreClampOpposite.Set(Parameter.Saturation, 2.0);
        coreClampOpposite.Set(Parameter.Highlights, 1.0);
        coreClampOpposite.Set(Parameter.Shadows, 1.0);
        coreClampOpposite.Set(Parameter.ToneCurve, -0.8);
        coreClampOpposite.Set(Parameter.Sharpening, 2.0);
        var oppositeTone = JsonNode.Parse(CanonicalEditRecipe.EncodeState(coreClampOpposite, isRaster: false, lutPath: masterRecipe.LutPath))!["edits"]!["tone"]!.AsObject();
        Check(oppositeTone["contrast"]!.GetValue<double>() == 0.0 &&
              oppositeTone["saturation"]!.GetValue<double>() == 2.0 &&
              oppositeTone["highlights"]!.GetValue<double>() == 1.0 &&
              oppositeTone["shadows"]!.GetValue<double>() == 1.0 &&
              oppositeTone["s_curve"]!.GetValue<double>() == -1.0,
            "CanonicalEditRecipe.EncodeState clamps opposite master-recipe-scaled tone extremes and legacy s_curve");

        foreach (var cameraVersion in new[] { 1, 2, 3 })
        {
            var cameraInfo = new HDRSourceInfo(HDRProbeState.Supported, 100, 80, 1, HDRNative.ContainerCameraRaw,
                0, HDRNative.ColorSrgb, 0, HDRNative.HeadroomUnknown, new byte[32])
            {
                CameraProcessingVersion = cameraVersion
            };
            var defaultCameraJson = JsonNode.Parse(HDRNative.BuildCameraRawDecodeJson(cameraInfo, null, cameraAI: false))!.AsObject();
            Check(defaultCameraJson["camera_development"]!["processing_version"]!.GetValue<int>() == cameraVersion &&
                  defaultCameraJson["camera_development"]!["wb_mode"]!.GetValue<string>() == "as_shot" &&
                  defaultCameraJson["camera_development"]!["fbdd_level"]!.GetValue<int>() == 0 &&
                  !defaultCameraJson["camera_development"]!["use_ai"]!.GetValue<bool>(),
                "Default camera RAW HDR decode JSON preserves CameraProcessingVersion " + cameraVersion);

            var editedCameraJson = JsonNode.Parse(HDRNative.BuildCameraRawDecodeJson(cameraInfo, new HDRCameraDevelopmentSettings(FbddLevel: 2), cameraAI: false))!.AsObject();
            Check(editedCameraJson["camera_development"]!["processing_version"]!.GetValue<int>() == cameraVersion &&
                  editedCameraJson["camera_development"]!["fbdd_level"]!.GetValue<int>() == 2,
                "Edited camera RAW HDR decode JSON preserves CameraProcessingVersion " + cameraVersion);
        }
        var aiBlockedThrown = false;
        try
        {
            var cameraInfoV3 = new HDRSourceInfo(HDRProbeState.Supported, 100, 80, 1, HDRNative.ContainerCameraRaw,
                0, HDRNative.ColorSrgb, 0, HDRNative.HeadroomUnknown, new byte[32]);
            _ = HDRNative.BuildCameraRawDecodeJson(cameraInfoV3, new HDRCameraDevelopmentSettings(FbddLevel: 1), cameraAI: true);
        }
        catch (HDRSourceException ex) when (ex.Reason == HDRNative.ReasonCameraAI)
        {
            aiBlockedThrown = true;
        }
        Check(aiBlockedThrown, "Camera RAW HDR decode JSON still rejects AI when FBDD is active");

        var neutralHdrV9 = JsonNode.Parse(new HDRSettings().ToCanonicalEditStateJson(outputSharpening: OutputSharpening.High))!.AsObject();
        var parametricHdrV9 = JsonNode.Parse(new HDRSettings().WithTone(new HDRToneSettings
        {
            Curve = new ToneCurveSettings(ToneCurveMode.Custom, [new(0, 0), new(1, 1)],
                parametric: new ToneCurveParametric(Shadows: 15))
        }).ToCanonicalEditStateJson(outputSharpening: OutputSharpening.High))!.AsObject();
        Check(neutralHdrV9["schema_version"]!.GetValue<int>() == 16 &&
              neutralHdrV9["processing"]!["version"]!.GetValue<int>() == 9 &&
              neutralHdrV9["output"]!["output_sharpening"]!.GetValue<string>() == "high" &&
              neutralHdrV9["edits"]!["tone"]!["curve"]!["parametric"] == null &&
              parametricHdrV9["edits"]!["tone"]!["curve"]!["parametric"]!["shadows"]!.GetValue<double>() == 15 &&
              Math.Abs(parametricHdrV9["edits"]!["tone"]!["curve"]!["parametric"]!["split_shadow"]!.GetValue<double>() - 0.25) < 1e-6 &&
              Math.Abs(parametricHdrV9["edits"]!["tone"]!["curve"]!["parametric"]!["split_midtone"]!.GetValue<double>() - 0.50) < 1e-6 &&
              Math.Abs(parametricHdrV9["edits"]!["tone"]!["curve"]!["parametric"]!["split_highlight"]!.GetValue<double>() - 0.75) < 1e-6,
            "HDR v9 canonical JSON omits default parametric object and populates parametric splits when active");
    }
}
