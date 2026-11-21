using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal static class CanonicalEditRecipe
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    internal static string ProcessingOnlyJson(int processingVersion, string exposureMode = "scene")
    {
        var payload = new Payload(
            SchemaVersion: 5,
            X3fMode: null,
            Processing: new ProcessingPayload("rawlab", Math.Clamp(processingVersion, 1, 3), "standard"),
            Input: new InputPayload("session.raw", "raw"),
            Edits: new EditsPayload(
                Exposure: new ExposurePayload(exposureMode, 0, 1),
                WhiteBalance: new WhiteBalancePayload("camera"),
                Look: new LookPayload(null, 1),
                Geometry: null,
                Tone: null,
                Color: null,
                ColorGrading: null,
                Detail: new DetailPayload(0),
                Hsl: null,
                Effects: null,
                Denoise: null,
                LensCorrection: null),
            Output: new OutputPayload("session.png", "png", new SizePayload("native")));
        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    internal static string Encode(Adjustments settings, bool isRaster, bool includeDenoise = true)
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

        var profileId = string.IsNullOrEmpty(settings.Lens.CoreProfileId) ? null : settings.Lens.CoreProfileId;

        var payload = new Payload(
            SchemaVersion: isRaster ? 5 : 7,
            X3fMode: isRaster ? null : (settings.X3fMode == X3fMode.Normal ? "normal-v1" : "legacy"),
            Processing: new ProcessingPayload("rawlab", processingVersion, "standard"),
            Input: new InputPayload(isRaster ? "session.png" : "session.raw", isRaster ? "raster" : "raw"),
            Edits: new EditsPayload(
                Exposure: new ExposurePayload(exposureMode, 0, 1),
                WhiteBalance: new WhiteBalancePayload(isRaster ? "none" : "camera"),
                Look: new LookPayload(null, 1),
                Geometry: new GeometryPayload(
                    Crop: new CropPayload(geometry.CropX, geometry.CropY, geometry.CropWidth, geometry.CropHeight),
                    QuarterTurns: geometry.QuarterTurns,
                    FlipHorizontal: geometry.FlipHorizontal,
                    FlipVertical: geometry.FlipVertical,
                    StraightenDegrees: geometry.StraightenDegrees,
                    Perspective: new PerspectivePayload(geometry.PerspectiveHorizontal, geometry.PerspectiveVertical)),
                Tone: new TonePayload(
                    Contrast: 1,
                    Saturation: 1,
                    Highlights: 0,
                    Shadows: 0,
                    SCurve: 0,
                    BlackPoint: tone.BlackPoint / 100.0,
                    WhitePoint: tone.WhitePoint / 100.0,
                    Curve: new CurvePayload(
                        Mode: curve.Mode == ToneCurveMode.Custom ? "custom" : "legacy",
                        Points: curve.Points.Select(p => new[] { p.X, p.Y }).ToArray(),
                        Channels: channels)),
                Color: new ColorPayload(tone.Vibrance / 100.0),
                ColorGrading: new ColorGradingPayload(
                    Shadows: new WheelPayload(grading.Shadows.Hue, grading.Shadows.Saturation),
                    Midtones: new WheelPayload(grading.Midtones.Hue, grading.Midtones.Saturation),
                    Highlights: new WheelPayload(grading.Highlights.Hue, grading.Highlights.Saturation)),
                Detail: new DetailPayload(0),
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
                    ProfileId: profileId)),
            Output: new OutputPayload("session.png", "png", new SizePayload("native")));

        return JsonSerializer.Serialize(payload, SerializerOptions);
    }

    private static CurveShapePayload ToCurveShapePayload(ToneCurveShape shape) =>
        new(shape.Mode == ToneCurveMode.Custom ? "custom" : "legacy",
            shape.Points.Select(p => new[] { p.X, p.Y }).ToArray());

    private sealed record Payload(
        [property: JsonPropertyName("schema_version")] int SchemaVersion,
        [property: JsonPropertyName("x3f_mode")] string? X3fMode,
        [property: JsonPropertyName("processing")] ProcessingPayload Processing,
        [property: JsonPropertyName("input")] InputPayload Input,
        [property: JsonPropertyName("edits")] EditsPayload Edits,
        [property: JsonPropertyName("output")] OutputPayload Output);

    private sealed record ProcessingPayload(
        [property: JsonPropertyName("family")] string Family,
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("quality")] string Quality);

    private sealed record InputPayload(
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("type")] string Type);

    private sealed record OutputPayload(
        [property: JsonPropertyName("path")] string Path,
        [property: JsonPropertyName("format")] string Format,
        [property: JsonPropertyName("size")] SizePayload Size);

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
        [property: JsonPropertyName("lens_correction")] LensCorrectionPayload? LensCorrection);

    private sealed record ExposurePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("ev")] double Ev,
        [property: JsonPropertyName("brightness")] double Brightness);

    private sealed record WhiteBalancePayload(
        [property: JsonPropertyName("mode")] string Mode);

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

    private sealed record CurvePayload(
        [property: JsonPropertyName("mode")] string Mode,
        [property: JsonPropertyName("points")] double[][] Points,
        [property: JsonPropertyName("channels")] CurveChannelsPayload? Channels);

    private sealed record ColorPayload(
        [property: JsonPropertyName("vibrance")] double Vibrance);

    private sealed record WheelPayload(
        [property: JsonPropertyName("hue")] double Hue,
        [property: JsonPropertyName("saturation")] double Saturation);

    private sealed record ColorGradingPayload(
        [property: JsonPropertyName("shadows")] WheelPayload Shadows,
        [property: JsonPropertyName("midtones")] WheelPayload Midtones,
        [property: JsonPropertyName("highlights")] WheelPayload Highlights);

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
