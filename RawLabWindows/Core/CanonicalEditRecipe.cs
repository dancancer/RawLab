using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal static class CanonicalEditRecipe
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    internal static string ProcessingStateJson(int processingVersion, string? exposureMode = null)
    {
        var edits = exposureMode == null
            ? null
            : new Dictionary<string, object?> { ["exposure"] = new { mode = exposureMode } };
        var payload = new
        {
            processing = new ProcessingPayload("rawlab", Math.Clamp(processingVersion, 1, 3), "standard"),
            edits
        };
        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    internal static string CompatibilityPreviewStateJson(int processingVersion, string exposureMode, string? lutPath, double lutStrength)
    {
        var payload = new
        {
            processing = new ProcessingPayload("rawlab", Math.Clamp(processingVersion, 1, 3), "standard"),
            edits = new
            {
                exposure = new ExposurePayload(exposureMode, 0, 1),
                look = new LookPayload(lutPath, lutStrength)
            }
        };
        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    internal static string Encode(Adjustments settings, bool isRaster, bool includeDenoise = true, OutputSharpening outputSharpening = OutputSharpening.Off) =>
        EncodeCore(settings, isRaster, includeDenoise, outputSharpening, lutPath: null, includeSessionState: false);

    internal static string EncodeState(Adjustments settings, bool isRaster, bool includeDenoise = true, OutputSharpening outputSharpening = OutputSharpening.Off, string? lutPath = null) =>
        EncodeCore(settings, isRaster, includeDenoise, outputSharpening, lutPath, includeSessionState: true);

    private static string EncodeCore(Adjustments settings, bool isRaster, bool includeDenoise, OutputSharpening outputSharpening, string? lutPath, bool includeSessionState)
    {
        var processingVersion = ProcessingIdentity.Require(settings.Processing).Version;
        if (!Enum.IsDefined(settings.X3fMode))
            throw new ArgumentOutOfRangeException(nameof(settings), "Invalid X3F rendering mode");

        var tone = settings.RenderToneControls;
        var atmosphere = settings.RenderAtmosphere;
        var grading = settings.RenderGrading;
        var curve = settings.RenderCurve;
        var hsl = settings.RenderHsl;
        var geometry = settings.Geometry;
        var effects = settings.Effects;
        var denoise = settings.Denoise;

        _ = tone.NativeConfig();
        _ = atmosphere.NativeConfig();
        _ = grading.NativeConfig();
        _ = curve.Master.NativeConfig();
        _ = curve.Channels.Red.NativeConfig();
        _ = curve.Channels.Green.NativeConfig();
        _ = curve.Channels.Blue.NativeConfig();
        _ = hsl.NativeConfig();
        _ = geometry.NativeConfig();
        _ = effects.NativeConfig();
        _ = denoise.NativeConfig();

        var hslValues = hsl.Values;
        var exposureMode = isRaster ? "sensor" : settings.ExposureMode switch
        {
            0 => "scene",
            2 => "sensor",
            _ => "preview"
        };

        var channels = curve.Channels.IsDefault
            ? null
            : new CurveChannelsPayload(
                Red: ToCurveShapePayload(curve.Channels.Red),
                Green: ToCurveShapePayload(curve.Channels.Green),
                Blue: ToCurveShapePayload(curve.Channels.Blue));

        var rasterRelativeActive = isRaster && settings.MasterRecipeID == null &&
            (settings[Parameter.Temperature] != 6500 || settings[Parameter.Tint] != 0);
        if (rasterRelativeActive &&
            (!double.IsFinite(settings[Parameter.Temperature]) || settings[Parameter.Temperature] is < 2000 or > 50000 ||
             !double.IsFinite(settings[Parameter.Tint]) || settings[Parameter.Tint] is < -150 or > 150))
            throw new ArgumentOutOfRangeException(nameof(settings), "Invalid raster relative white balance");
        var hasV12Features = curve.HasV2Extensions || grading.HasV2Extensions || rasterRelativeActive || outputSharpening != OutputSharpening.Off;
        var profileId = string.IsNullOrEmpty(settings.Lens.CoreProfileId) ? null : settings.Lens.CoreProfileId;
        var scale = settings.MasterRecipeID == null ? 1.0 : settings[Parameter.Strength];

        WhiteBalancePayload whiteBalance;
        MasterRecipePayload? masterRecipe = null;
        if (isRaster)
        {
            whiteBalance = rasterRelativeActive
                ? new WhiteBalancePayload("relative", RelativeTemperature: settings[Parameter.Temperature], RelativeTint: settings[Parameter.Tint])
                : new WhiteBalancePayload("none");
        }
        else if (includeSessionState && settings.MasterRecipeID != null)
        {
            var customWb = !settings.CameraWhiteBalance;
            var strength = settings[Parameter.Strength];
            var tint = settings[Parameter.Tint];
            whiteBalance = new WhiteBalancePayload("camera");
            masterRecipe = new MasterRecipePayload(
                Active: true,
                Strength: strength,
                CustomWb: customWb,
                TemperatureKelvin: customWb ? settings[Parameter.Temperature] : 6500.0,
                Tint: (!customWb && (strength == 0.0 || tint == 0.0)) ? 0.0 : tint,
                UncalibratedFallback: "error");
        }
        else if (includeSessionState && !settings.CameraWhiteBalance)
        {
            whiteBalance = new WhiteBalancePayload("temperature", TemperatureKelvin: settings[Parameter.Temperature], Tint: settings[Parameter.Tint]);
        }
        else
        {
            whiteBalance = new WhiteBalancePayload("camera");
        }

        double? aiDenoiseBlend = includeSessionState
            ? (settings.AIDenoiseEnabled ? Math.Clamp(settings.AIDenoiseStrength / 100.0, 0.0, 1.0) : 1.0)
            : null;

        var payload = new Payload(
            SchemaVersion: hasV12Features ? 17 : (isRaster ? 5 : 7),
            X3fMode: isRaster ? null : (settings.X3fMode == X3fMode.Normal ? "normal-v1" : "legacy"),
            Processing: new ProcessingPayload("rawlab", processingVersion, "standard"),
            Input: new InputPayload(null, isRaster ? "raster" : "raw"),
            Edits: new EditsPayload(
                Exposure: new ExposurePayload(
                    exposureMode,
                    includeSessionState ? settings[Parameter.Exposure] * scale : 0,
                    1),
                WhiteBalance: whiteBalance,
                Look: new LookPayload(
                    includeSessionState ? lutPath : null,
                    includeSessionState && lutPath != null ? settings[Parameter.Strength] : 1),
                Geometry: new GeometryPayload(
                    Crop: new CropPayload(geometry.CropX, geometry.CropY, geometry.CropWidth, geometry.CropHeight),
                    QuarterTurns: geometry.QuarterTurns,
                    FlipHorizontal: geometry.FlipHorizontal,
                    FlipVertical: geometry.FlipVertical,
                    StraightenDegrees: geometry.StraightenDegrees,
                    Perspective: new PerspectivePayload(geometry.PerspectiveHorizontal, geometry.PerspectiveVertical)),
                Tone: new TonePayload(
                    Contrast: includeSessionState ? 1.0 + (settings[Parameter.Contrast] - 1.0) * scale : 1,
                    Saturation: includeSessionState ? 1.0 + (settings[Parameter.Saturation] - 1.0) * scale : 1,
                    Highlights: includeSessionState ? settings[Parameter.Highlights] * scale : 0,
                    Shadows: includeSessionState ? settings[Parameter.Shadows] * scale : 0,
                    SCurve: includeSessionState && curve.Mode != ToneCurveMode.Custom
                        ? Math.Clamp(settings[Parameter.ToneCurve] * settings.RefinementScale, -1, 1)
                        : 0,
                    BlackPoint: tone.BlackPoint / 100.0,
                    WhitePoint: tone.WhitePoint / 100.0,
                    Curve: new CurvePayload(
                        Mode: curve.Mode == ToneCurveMode.Custom ? "custom" : "legacy",
                        Points: curve.Points.Select(p => new[] { p.X, p.Y }).ToArray(),
                        Channels: channels,
                        ApplyToLuminosity: curve.ApplyToLuminosity ? true : null,
                        Parametric: curve.Parametric.IsDefault ? null : ToParametricPayload(curve.Parametric))),
                Color: new ColorPayload(tone.Vibrance / 100.0),
                ColorGrading: new ColorGradingPayload(
                    Shadows: ToWheelPayload(grading.Shadows),
                    Midtones: ToWheelPayload(grading.Midtones),
                    Highlights: ToWheelPayload(grading.Highlights),
                    Global: grading.Global.IsDefault ? null : ToWheelPayload(grading.Global),
                    Blending: grading.Blending == 50.0 ? null : grading.Blending,
                    Balance: grading.Balance == 0.0 ? null : grading.Balance),
                Detail: new DetailPayload(includeSessionState ? settings[Parameter.Sharpening] : 0),
                Hsl: new HslPayload(
                    Hue: hslValues.Take(8).ToArray(),
                    Saturation: hslValues.Skip(8).Take(8).ToArray(),
                    Lightness: hslValues.Skip(16).Take(8).ToArray()),
                Effects: new EffectsPayload(
                    VignetteAmount: effects.VignetteAmount,
                    VignetteMidpoint: effects.VignetteMidpoint,
                    VignetteRoundness: effects.VignetteRoundness,
                    VignetteFeather: effects.VignetteFeather,
                    VignetteHighlights: effects.VignetteHighlights,
                    GrainAmount: effects.GrainAmount,
                    GrainSize: effects.GrainSize,
                    GrainRoughness: effects.GrainRoughness,
                    Clarity: atmosphere.Clarity / 100.0,
                    Dehaze: atmosphere.Dehaze / 100.0),
                Denoise: new DenoisePayload(
                    RawLevel: 0,
                    ChromaMode: includeDenoise ? settings.DisplayChromaDenoise : 0,
                    Wavelet: includeDenoise
                        ? new WaveletPayload(denoise.Enabled, denoise.Luma, denoise.Chroma, denoise.Coarse)
                        : null),
                LensCorrection: new LensCorrectionPayload(
                    Distortion: settings.Lens.Distortion,
                    Tca: settings.Lens.Tca,
                    Vignetting: settings.Lens.Vignetting,
                    AutoCrop: settings.Lens.AutoCrop,
                    ProfileId: profileId),
                MasterRecipe: masterRecipe,
                AiDenoiseBlend: aiDenoiseBlend),
            Output: outputSharpening == OutputSharpening.Off
                ? null
                : new OutputPayload(null, null, null, outputSharpening.WireValue()));

        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    private static WheelPayload ToWheelPayload(ColorGradingWheel w) =>
        new(w.Hue, w.Saturation, w.Luminance == 0.0 ? null : w.Luminance);

    private static CurveParametricPayload ToParametricPayload(ToneCurveParametric p) =>
        new(p.Highlights, p.Lights, p.Darks, p.Shadows, p.SplitShadow, p.SplitMidtone, p.SplitHighlight);

    private static CurveShapePayload ToCurveShapePayload(ToneCurveShape shape) =>
        new(shape.Mode == ToneCurveMode.Custom ? "custom" : "legacy",
            shape.Points.Select(p => new[] { p.X, p.Y }).ToArray());

    private sealed record Payload(
        [property: JsonPropertyName("schema_version")] int SchemaVersion,
        [property: JsonPropertyName("x3f_mode")] string? X3fMode,
        [property: JsonPropertyName("processing")] ProcessingPayload Processing,
        [property: JsonPropertyName("input")] InputPayload Input,
        [property: JsonPropertyName("edits")] EditsPayload Edits,
        [property: JsonPropertyName("output")] OutputPayload? Output);

    private sealed record ProcessingPayload(
        [property: JsonPropertyName("family")] string Family,
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("quality")] string Quality);

    private sealed record InputPayload(
        [property: JsonPropertyName("path")] string? Path,
        [property: JsonPropertyName("type")] string Type);

    private sealed record OutputPayload(
        [property: JsonPropertyName("path")] string? Path,
        [property: JsonPropertyName("format")] string? Format,
        [property: JsonPropertyName("size")] SizePayload? Size,
        [property: JsonPropertyName("output_sharpening")] string? OutputSharpening);

    private sealed record SizePayload(
        [property: JsonPropertyName("mode")] string Mode);

    private sealed record EditsPayload(
        [property: JsonPropertyName("exposure")] ExposurePayload Exposure,
        [property: JsonPropertyName("white_balance")] WhiteBalancePayload WhiteBalance,
        [property: JsonPropertyName("look")] LookPayload Look,
        [property: JsonPropertyName("geometry")] GeometryPayload? Geometry,
        [property: JsonPropertyName("tone")] TonePayload? Tone,
        [property: JsonPropertyName("color")] ColorPayload? Color,
        [property: JsonPropertyName("color_grading")] ColorGradingPayload? ColorGrading,
        [property: JsonPropertyName("detail")] DetailPayload Detail,
        [property: JsonPropertyName("hsl")] HslPayload? Hsl,
        [property: JsonPropertyName("effects")] EffectsPayload? Effects,
        [property: JsonPropertyName("denoise")] DenoisePayload? Denoise,
        [property: JsonPropertyName("lens_correction")] LensCorrectionPayload? LensCorrection,
        [property: JsonPropertyName("master_recipe")] MasterRecipePayload? MasterRecipe = null,
        [property: JsonPropertyName("ai_denoise_blend")] double? AiDenoiseBlend = null);

    private sealed record MasterRecipePayload(
        [property: JsonPropertyName("active")] bool Active,
        [property: JsonPropertyName("strength")] double Strength,
        [property: JsonPropertyName("custom_wb")] bool CustomWb,
        [property: JsonPropertyName("temperature_kelvin")] double TemperatureKelvin,
        [property: JsonPropertyName("tint")] double Tint,
        [property: JsonPropertyName("uncalibrated_fallback")] string UncalibratedFallback);

    private sealed record ExposurePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("ev")] double Ev,
        [property: JsonPropertyName("brightness")] double Brightness);

    private sealed record WhiteBalancePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("temperature_kelvin")] double? TemperatureKelvin = null,
        [property: JsonPropertyName("tint")] double? Tint = null,
        [property: JsonPropertyName("relative_temperature")] double? RelativeTemperature = null,
        [property: JsonPropertyName("relative_tint")] double? RelativeTint = null);

    private sealed record LookPayload(
        [property: JsonPropertyName("path"), JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? Path,
        [property: JsonPropertyName("strength")] double Strength);

    private sealed record GeometryPayload(
        [property: JsonPropertyName("crop")] CropPayload Crop,
        [property: JsonPropertyName("quarter_turns")] int QuarterTurns,
        [property: JsonPropertyName("flip_horizontal")] bool FlipHorizontal,
        [property: JsonPropertyName("flip_vertical")] bool FlipVertical,
        [property: JsonPropertyName("straighten_degrees")] double StraightenDegrees,
        [property: JsonPropertyName("perspective")] PerspectivePayload Perspective);

    private sealed record CropPayload(
        [property: JsonPropertyName("x")] double X,
        [property: JsonPropertyName("y")] double Y,
        [property: JsonPropertyName("width")] double Width,
        [property: JsonPropertyName("height")] double Height);

    private sealed record PerspectivePayload(
        [property: JsonPropertyName("horizontal")] double Horizontal,
        [property: JsonPropertyName("vertical")] double Vertical);

    private sealed record TonePayload(
        [property: JsonPropertyName("contrast")] double Contrast,
        [property: JsonPropertyName("saturation")] double Saturation,
        [property: JsonPropertyName("highlights")] double Highlights,
        [property: JsonPropertyName("shadows")] double Shadows,
        [property: JsonPropertyName("s_curve")] double SCurve,
        [property: JsonPropertyName("black_point")] double BlackPoint,
        [property: JsonPropertyName("white_point")] double WhitePoint,
        [property: JsonPropertyName("curve")] CurvePayload Curve);

    private sealed record CurveShapePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("points")] double[][] Points);

    private sealed record CurveChannelsPayload(
        [property: JsonPropertyName("red")] CurveShapePayload Red,
        [property: JsonPropertyName("green")] CurveShapePayload Green,
        [property: JsonPropertyName("blue")] CurveShapePayload Blue);

    private sealed record CurveParametricPayload(
        [property: JsonPropertyName("highlights")] double Highlights,
        [property: JsonPropertyName("lights")] double Lights,
        [property: JsonPropertyName("darks")] double Darks,
        [property: JsonPropertyName("shadows")] double Shadows,
        [property: JsonPropertyName("split_shadow")] double SplitShadow,
        [property: JsonPropertyName("split_midtone")] double SplitMidtone,
        [property: JsonPropertyName("split_highlight")] double SplitHighlight);

    private sealed record CurvePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("points")] double[][] Points,
        [property: JsonPropertyName("channels")] CurveChannelsPayload? Channels,
        [property: JsonPropertyName("apply_to_luminosity")] bool? ApplyToLuminosity,
        [property: JsonPropertyName("parametric")] CurveParametricPayload? Parametric);

    private sealed record ColorPayload(
        [property: JsonPropertyName("vibrance")] double Vibrance);

    private sealed record WheelPayload(
        [property: JsonPropertyName("hue")] double Hue,
        [property: JsonPropertyName("saturation")] double Saturation,
        [property: JsonPropertyName("luminance")] double? Luminance);

    private sealed record ColorGradingPayload(
        [property: JsonPropertyName("shadows")] WheelPayload Shadows,
        [property: JsonPropertyName("midtones")] WheelPayload Midtones,
        [property: JsonPropertyName("highlights")] WheelPayload Highlights,
        [property: JsonPropertyName("global")] WheelPayload? Global,
        [property: JsonPropertyName("blending")] double? Blending,
        [property: JsonPropertyName("balance")] double? Balance);

    private sealed record DetailPayload(
        [property: JsonPropertyName("sharpening")] double Sharpening);

    private sealed record HslPayload(
        [property: JsonPropertyName("hue")] double[] Hue,
        [property: JsonPropertyName("saturation")] double[] Saturation,
        [property: JsonPropertyName("lightness")] double[] Lightness);

    private sealed record EffectsPayload(
        [property: JsonPropertyName("vignette_amount")] double VignetteAmount,
        [property: JsonPropertyName("vignette_midpoint")] double VignetteMidpoint,
        [property: JsonPropertyName("vignette_roundness")] double VignetteRoundness,
        [property: JsonPropertyName("vignette_feather")] double VignetteFeather,
        [property: JsonPropertyName("vignette_highlights")] double VignetteHighlights,
        [property: JsonPropertyName("grain_amount")] double GrainAmount,
        [property: JsonPropertyName("grain_size")] double GrainSize,
        [property: JsonPropertyName("grain_roughness")] double GrainRoughness,
        [property: JsonPropertyName("clarity")] double Clarity,
        [property: JsonPropertyName("dehaze")] double Dehaze);

    private sealed record WaveletPayload(
        [property: JsonPropertyName("enabled")] bool Enabled,
        [property: JsonPropertyName("luma")] double Luma,
        [property: JsonPropertyName("chroma")] double Chroma,
        [property: JsonPropertyName("coarse")] double Coarse);

    private sealed record DenoisePayload(
        [property: JsonPropertyName("raw_level")] int RawLevel,
        [property: JsonPropertyName("chroma_mode")] int ChromaMode,
        [property: JsonPropertyName("wavelet")] WaveletPayload? Wavelet);

    private sealed record LensCorrectionPayload(
        [property: JsonPropertyName("distortion")] bool Distortion,
        [property: JsonPropertyName("tca")] bool Tca,
        [property: JsonPropertyName("vignetting")] bool Vignetting,
        [property: JsonPropertyName("auto_crop")] bool AutoCrop,
        [property: JsonPropertyName("profile_id")] string? ProfileId);
}
