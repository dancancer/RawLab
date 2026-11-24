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

        var procOnly = JsonNode.Parse(CanonicalEditRecipe.ProcessingOnlyJson(3))!.AsObject();
        Check(procOnly["schema_version"]!.GetValue<int>() == 5, "Processing-only helper uses schema_version 5");
        Check(procOnly["processing"]!["version"]!.GetValue<int>() == 3, "Processing-only helper preserves version");

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
    }
}
