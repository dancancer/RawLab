using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

public enum AdjustmentField
{
    Look,
    Strength,
    Exposure,
    ExposureMode,
    Contrast,
    Highlights,
    Shadows,
    SCurve,
    WhiteBalanceMode,
    Temperature,
    Tint,
    Saturation,
    HslHueRed,
    HslHueOrange,
    HslHueYellow,
    HslHueGreen,
    HslHueAqua,
    HslHueBlue,
    HslHuePurple,
    HslHueMagenta,
    HslSaturationRed,
    HslSaturationOrange,
    HslSaturationYellow,
    HslSaturationGreen,
    HslSaturationAqua,
    HslSaturationBlue,
    HslSaturationPurple,
    HslSaturationMagenta,
    HslLightnessRed,
    HslLightnessOrange,
    HslLightnessYellow,
    HslLightnessGreen,
    HslLightnessAqua,
    HslLightnessBlue,
    HslLightnessPurple,
    HslLightnessMagenta,
    VignetteAmount,
    VignetteMidpoint,
    VignetteRoundness,
    VignetteFeather,
    VignetteHighlights,
    GrainAmount,
    GrainSize,
    GrainRoughness,
    Sharpening,
    RawDenoise,
    PostRGBDenoise,
    ChromaDenoise,
    WaveletDenoise,
    CropX,
    CropY,
    CropWidth,
    CropHeight,
    QuarterTurns,
    FlipHorizontal,
    FlipVertical,
    Straighten,
    PerspectiveHorizontal,
    PerspectiveVertical,
    LensDistortion,
    LensTCA,
    LensVignetting,
    LensAutoCrop,
    LensProfile,
    BlackPoint,
    WhitePoint,
    Vibrance,
    GradingShadows, GradingMidtones, GradingHighlights,
    Curve, Clarity, Dehaze, HdrTemperature, HdrTint,
    HdrPeakLimit, HdrSDRExposure, HdrSDRContrast, HdrSDRSaturation, HdrLook, HdrCameraDevelopment,
    CurveApplyToLuminosity, CurveParametric, GradingGlobal, GradingBlending, GradingBalance
}

public static class AdjustmentFields
{
    private static readonly string[] ids = [
        "looks.reference",
        "looks.strength",
        "light.exposure",
        "light.exposure_mode",
        "light.contrast",
        "light.highlights",
        "light.shadows",
        "light.s_curve",
        "color.white_balance.mode",
        "color.white_balance.temperature_kelvin",
        "color.white_balance.tint",
        "color.saturation",
        "color.hsl.hue.red",
        "color.hsl.hue.orange",
        "color.hsl.hue.yellow",
        "color.hsl.hue.green",
        "color.hsl.hue.aqua",
        "color.hsl.hue.blue",
        "color.hsl.hue.purple",
        "color.hsl.hue.magenta",
        "color.hsl.saturation.red",
        "color.hsl.saturation.orange",
        "color.hsl.saturation.yellow",
        "color.hsl.saturation.green",
        "color.hsl.saturation.aqua",
        "color.hsl.saturation.blue",
        "color.hsl.saturation.purple",
        "color.hsl.saturation.magenta",
        "color.hsl.lightness.red",
        "color.hsl.lightness.orange",
        "color.hsl.lightness.yellow",
        "color.hsl.lightness.green",
        "color.hsl.lightness.aqua",
        "color.hsl.lightness.blue",
        "color.hsl.lightness.purple",
        "color.hsl.lightness.magenta",
        "effects.vignette.amount",
        "effects.vignette.midpoint",
        "effects.vignette.roundness",
        "effects.vignette.feather",
        "effects.vignette.highlights",
        "effects.grain.amount",
        "effects.grain.size",
        "effects.grain.roughness",
        "detail.sharpening",
        "detail.denoise.raw_level",
        "detail.denoise.post_rgb",
        "detail.denoise.chroma_mode",
        "detail.denoise.wavelet",
        "geometry.crop.x",
        "geometry.crop.y",
        "geometry.crop.width",
        "geometry.crop.height",
        "geometry.quarter_turns",
        "geometry.flip_horizontal",
        "geometry.flip_vertical",
        "geometry.straighten_degrees",
        "geometry.perspective.horizontal",
        "geometry.perspective.vertical",
        "geometry.lens.distortion",
        "geometry.lens.tca",
        "geometry.lens.vignetting",
        "geometry.lens.auto_crop",
        "geometry.lens.profile_id",
        "tone.black_point",
        "tone.white_point",
        "color.vibrance",
        "color.grading.shadows", "color.grading.midtones", "color.grading.highlights",
        "light.curve", "effects.clarity", "effects.dehaze", "hdr.relative_temperature", "hdr.relative_tint",
        "hdr.peak_limit_ev", "hdr.sdr_exposure_ev", "hdr.sdr_contrast", "hdr.sdr_saturation", "hdr.look", "hdr.camera_development",
        "light.curve.apply_to_luminosity", "light.curve.parametric",
        "color.grading.global", "color.grading.blending", "color.grading.balance"
    ];
    // Keep the legacy catalog/index contract stable; HDR-only fields are
    // addressable through HDRSupported but are not legacy "common" fields.
    public static readonly IReadOnlyList<AdjustmentField> All = Array.AsReadOnly(
        Enum.GetValues<AdjustmentField>().Where(field => !field.IsHDROnly()).ToArray());
    public static AdjustmentFieldDefinition Spec(this AdjustmentField field) => AdjustmentFieldSpec.RequireById(field.ID());
    public static string ID(this AdjustmentField field) => ids[(int)field];
    public static string Group(this AdjustmentField field) => field.Spec().Group;
    public static ColorGradingZone? GradingZone(this AdjustmentField field) => field switch {
        AdjustmentField.GradingShadows => ColorGradingZone.Shadows, AdjustmentField.GradingMidtones => ColorGradingZone.Midtones,
        AdjustmentField.GradingHighlights => ColorGradingZone.Highlights, _ => null
    };
    public static int? HslIndex(this AdjustmentField field) => field is >= AdjustmentField.HslHueRed and <= AdjustmentField.HslLightnessMagenta
        ? (int)field - (int)AdjustmentField.HslHueRed : null;
    public static AdjustmentField Parse(string id) => Array.IndexOf(ids, id) is var index && index >= 0
        ? (AdjustmentField)index : throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload, id);
    public static bool IsHDRRelative(this AdjustmentField field) => field.Spec().Protocol.IsHdrRelative;
    public static bool IsHDRRendition(this AdjustmentField field) => field.Spec().Protocol.IsHdrRendition;
    public static bool IsHDROnly(this AdjustmentField field) => field.Spec().Protocol.IsHdrOnly;
    public static readonly IReadOnlySet<AdjustmentField> Common = All.Where(f => f.Group() != "geometry").ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRCommon = new HashSet<AdjustmentField> {
        AdjustmentField.Exposure, AdjustmentField.Contrast, AdjustmentField.Highlights, AdjustmentField.Shadows,
        AdjustmentField.Saturation, AdjustmentField.HdrTemperature, AdjustmentField.HdrTint
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRGeometry = new HashSet<AdjustmentField> {
        AdjustmentField.CropX, AdjustmentField.CropY, AdjustmentField.CropWidth, AdjustmentField.CropHeight,
        AdjustmentField.QuarterTurns, AdjustmentField.FlipHorizontal, AdjustmentField.FlipVertical,
        AdjustmentField.Straighten, AdjustmentField.PerspectiveHorizontal, AdjustmentField.PerspectiveVertical
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRTone = new HashSet<AdjustmentField> {
        AdjustmentField.BlackPoint, AdjustmentField.WhitePoint, AdjustmentField.SCurve, AdjustmentField.Curve
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRV1Supported = HDRCommon.Concat(HDRGeometry).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRV2Supported = HDRV1Supported.Concat(HDRTone).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRColor = All.Where(field =>
        field == AdjustmentField.Vibrance || field.HslIndex() != null || field.GradingZone() != null).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRV3Supported = HDRV2Supported.Concat(HDRColor).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRRendition = Enum.GetValues<AdjustmentField>()
        .Where(field => field.IsHDRRendition()).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDREffects = All
        .Where(field => field is >= AdjustmentField.VignetteAmount and <= AdjustmentField.GrainRoughness).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRDetail = new HashSet<AdjustmentField> {
        AdjustmentField.Sharpening, AdjustmentField.Clarity, AdjustmentField.Dehaze, AdjustmentField.PostRGBDenoise
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRV4Supported = HDRV3Supported.Concat(HDRRendition).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRV5Supported = HDRV4Supported.Concat(HDREffects).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRV6Supported = HDRV5Supported.Concat(HDRDetail).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRSupported = HDRV6Supported.Append(AdjustmentField.HdrLook).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> HDRV9ToneExtensions = new HashSet<AdjustmentField> {
        AdjustmentField.CurveApplyToLuminosity, AdjustmentField.CurveParametric
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRV9ColorExtensions = new HashSet<AdjustmentField> {
        AdjustmentField.GradingGlobal, AdjustmentField.GradingBlending, AdjustmentField.GradingBalance
    };
    public static readonly IReadOnlySet<AdjustmentField> HDRV9Supported = HDRSupported
        .Concat(HDRV9ToneExtensions).Concat(HDRV9ColorExtensions).ToHashSet();
    internal static IReadOnlySet<AdjustmentField> HDRTransferFields(bool cameraRaw) =>
        cameraRaw ? HDRV9Supported.Append(AdjustmentField.HdrCameraDevelopment).ToHashSet() : HDRV9Supported;
    public static IReadOnlySet<AdjustmentField> HDRSupportedFor(int version) => version switch {
        1 => HDRV1Supported, 2 => HDRV2Supported, 3 => HDRV3Supported, 4 => HDRV4Supported,
        5 => HDRV5Supported, 6 => HDRV6Supported, 7 or 8 => HDRSupported, 9 => HDRV9Supported,
        _ => throw new ArgumentOutOfRangeException(nameof(version))
    };
    public static readonly IReadOnlySet<AdjustmentField> WhiteBalance = new HashSet<AdjustmentField> { AdjustmentField.WhiteBalanceMode, AdjustmentField.Temperature, AdjustmentField.Tint };
    public static readonly IReadOnlySet<AdjustmentField> Lens = new HashSet<AdjustmentField> { AdjustmentField.LensDistortion, AdjustmentField.LensTCA, AdjustmentField.LensVignetting, AdjustmentField.LensAutoCrop, AdjustmentField.LensProfile };
    public static readonly IReadOnlySet<AdjustmentField> Denoise = new HashSet<AdjustmentField> { AdjustmentField.RawDenoise, AdjustmentField.PostRGBDenoise, AdjustmentField.ChromaDenoise, AdjustmentField.WaveletDenoise };
    public static readonly IReadOnlySet<AdjustmentField> RecipeDependencies = new[] { AdjustmentField.Look, AdjustmentField.Strength, AdjustmentField.Exposure,
        AdjustmentField.Contrast, AdjustmentField.Highlights, AdjustmentField.Shadows, AdjustmentField.Saturation }
        .Concat(WhiteBalance).Concat(All.Where(f => f.HslIndex() != null)).ToHashSet();
    public static readonly IReadOnlySet<AdjustmentField> RefinementScalars = new HashSet<AdjustmentField> {
        AdjustmentField.SCurve, AdjustmentField.BlackPoint, AdjustmentField.WhitePoint, AdjustmentField.Vibrance, AdjustmentField.Clarity, AdjustmentField.Dehaze };
    public static readonly IReadOnlySet<AdjustmentField> RefinementObjects = new HashSet<AdjustmentField> {
        AdjustmentField.Curve, AdjustmentField.GradingShadows, AdjustmentField.GradingMidtones, AdjustmentField.GradingHighlights };
    public static IReadOnlySet<AdjustmentField> DependenciesForRecipe(int version) => version >= 4
        ? RecipeDependencies.Concat(RefinementScalars).Concat(RefinementObjects).ToHashSet() : RecipeDependencies;
    public static (double Min, double Max)? Range(this AdjustmentField field)
    {
        var proto = field.Spec().Protocol;
        if (proto.Nullable || (proto.ValueType != AdjustmentProtocolValueType.Number && field != AdjustmentField.QuarterTurns))
            return null;
        return proto.Range;
    }
}

public enum AdjustmentFailure { InvalidPayload, UnsupportedVersion, EmptyScope, Draft, Incompatible, MissingLook, Unrepresentable }
public sealed class AdjustmentTransferException(AdjustmentFailure failure, string detail = "") : IOException($"{failure}: {detail}")
{ public AdjustmentFailure Failure { get; } = failure; public string Detail { get; } = detail; }
public sealed record AdjustmentRecipeContext(string ID, double Strength, int SettingsVersion = 3);
public sealed record AdjustmentSource(string Identifier, bool IsRaw, int ProcessingVersion, AdjustmentRecipeContext? Recipe = null,
    int? HdrProcessingVersion = null)
{
    public bool IsHDR => HdrProcessingVersion is not null;
}
public sealed record AdjustmentScope(string Kind, IReadOnlySet<AdjustmentField>? Fields = null)
{
    public static AdjustmentScope All => new("all");
    public static AdjustmentScope Modified => new("modified");
    public static AdjustmentScope Custom(IEnumerable<AdjustmentField> fields) => new("custom", fields.ToHashSet());
    public static AdjustmentScope Standard => Custom(AdjustmentFields.Common);
}

public sealed class AdjustmentPayload
{
    public int PayloadVersion { get; }
    public int ScopeVersion { get; }
    public AdjustmentSource Source { get; }
    public IReadOnlyDictionary<AdjustmentField, JsonElement> Values { get; }
    public IReadOnlySet<AdjustmentField> Fields => Values.Keys.ToHashSet();
    public JsonElement? this[AdjustmentField field] => Values.TryGetValue(field, out var value) ? value : null;
    public AdjustmentPayload(AdjustmentSource source, IDictionary<AdjustmentField, JsonElement> values, int payloadVersion = 1, int scopeVersion = 1)
    {
        if (source.IsHDR && payloadVersion == 1 && scopeVersion == 1) { payloadVersion = 2; scopeVersion = 2; }
        Source = source; PayloadVersion = payloadVersion; ScopeVersion = scopeVersion;
        Values = new ReadOnlyDictionary<AdjustmentField, JsonElement>(values.ToDictionary(p => p.Key, p => p.Value.Clone()));
        Validate();
    }
    public static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value);
    public static double? Number(JsonElement? value) => value is { ValueKind: JsonValueKind.Number } v && v.TryGetDouble(out var number) ? number : null;
    public static string? Text(JsonElement? value) => value is { ValueKind: JsonValueKind.String } v ? v.GetString() : null;
    public static bool? Boolean(JsonElement? value) => value is { ValueKind: JsonValueKind.True } ? true : value is { ValueKind: JsonValueKind.False } ? false : null;
    public static bool Null(JsonElement? value) => value is { ValueKind: JsonValueKind.Null };
    internal static HDRLookSettings? HDRLookValue(JsonElement? value)
    {
        if (Null(value)) return new();
        if (value is not { } obj || !ObjectKeys(obj, AdjustmentFieldSpec.Fields.HdrLook.Protocol.ObjectKeys.ToArray()) ||
            Text(obj.GetProperty("name")) is not { } name || Text(obj.GetProperty("sha256")) is not { } sha ||
            Number(obj.GetProperty("strength")) is not { } strength ||
            strength < AdjustmentFieldSpec.SubFields.HDRLook.StrengthMin ||
            strength > AdjustmentFieldSpec.SubFields.HDRLook.StrengthMax) return null;
        var look = new HDRLookSettings(sha, name, strength);
        return look.IsValid ? look : null;
    }
    internal static HDRCameraDevelopmentSettings? HDRCameraValue(JsonElement? value)
    {
        if (value is not { } obj || !ObjectKeys(obj, AdjustmentFieldSpec.Fields.HdrCameraDevelopment.Protocol.ObjectKeys.ToArray()) ||
            Number(obj.GetProperty("version")) is not { } ver || ver != Math.Truncate(ver) ||
            !AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.AllowedVersions.Contains((int)ver)) return null;
        var mode = Text(obj.GetProperty("white_balance_mode"));
        var exposure = Text(obj.GetProperty("exposure_reference"));
        if (mode is null || !AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.AllowedWhiteBalanceModes.Contains(mode) ||
            exposure is null || !AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.AllowedExposureReferences.Contains(exposure) ||
            Number(obj.GetProperty("temperature")) is not { } temperature || Number(obj.GetProperty("tint")) is not { } tint ||
            Number(obj.GetProperty("fbdd_level")) is not { } fbdd || fbdd != Math.Truncate(fbdd) ||
            !AdjustmentFieldSpec.SubFields.HDRCameraDevelopment.AllowedFbddLevels.Contains((int)fbdd)) return null;
        var camera = new HDRCameraDevelopmentSettings(mode == "temperature",temperature,tint,exposure == "sensor",(int)fbdd);
        return camera.IsValid ? camera : null;
    }
    public static bool Same(JsonElement? a, JsonElement? b) => a == null || b == null ? a == null && b == null : SameValue(a.Value,b.Value);
    private static bool SameValue(JsonElement a, JsonElement b)
    {
        if (a.ValueKind != b.ValueKind) return false;
        return a.ValueKind switch {
            JsonValueKind.Number => a.GetDouble() == b.GetDouble(), JsonValueKind.String => a.GetString() == b.GetString(),
            JsonValueKind.Object => a.EnumerateObject().Count() == b.EnumerateObject().Count() && a.EnumerateObject().All(p => b.TryGetProperty(p.Name,out var v) && SameValue(p.Value,v)),
            JsonValueKind.Array => a.GetArrayLength() == b.GetArrayLength() && a.EnumerateArray().Zip(b.EnumerateArray()).All(pair => SameValue(pair.First, pair.Second)),
            JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False => true, _ => false
        };
    }
    public string ToJson() => SerializeJson(indented: false);
    public string ToIndentedJson() => SerializeJson(indented: true);

    private string SerializeJson(bool indented)
    {
        var source = new Dictionary<string, object?> {
            ["identifier"] = Source.Identifier, ["is_raw"] = Source.IsRaw,
            ["processing_version"] = Source.ProcessingVersion,
            ["recipe"] = Source.Recipe is { } recipe ? new { id = recipe.ID, strength = recipe.Strength, settings_version = recipe.SettingsVersion } : null
        };
        if (Source.HdrProcessingVersion is { } hdrVersion) source["hdr_processing_version"] = hdrVersion;
        return JsonSerializer.Serialize(new {
            payload_version = PayloadVersion, scope_version = ScopeVersion, source,
            values = Values.ToDictionary(p => p.Key.ID(), p => p.Value)
        }, indented ? new JsonSerializerOptions { WriteIndented = true } : null);
    }
    public static AdjustmentPayload Parse(string json)
    {
        try {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement; Keys(root, "payload_version", "scope_version", "source", "values");
            var source = root.GetProperty("source"); Keys(source, "identifier", "is_raw", "processing_version", "recipe", "hdr_processing_version");
            AdjustmentRecipeContext? recipe = null;
            if (source.TryGetProperty("recipe", out var r) && r.ValueKind != JsonValueKind.Null) {
                Keys(r,"id","strength","settings_version"); recipe = new(r.GetProperty("id").GetString()!,r.GetProperty("strength").GetDouble(),r.GetProperty("settings_version").GetInt32());
            }
            var values = new Dictionary<AdjustmentField, JsonElement>();
            foreach (var property in root.GetProperty("values").EnumerateObject())
                if (!values.TryAdd(AdjustmentFields.Parse(property.Name), property.Value)) throw Invalid("duplicate field");
            var hdrVersion = source.TryGetProperty("hdr_processing_version", out var hv) && hv.ValueKind != JsonValueKind.Null ? hv.GetInt32() : (int?)null;
            return new(new(source.GetProperty("identifier").GetString()!,source.GetProperty("is_raw").GetBoolean(),source.GetProperty("processing_version").GetInt32(),recipe,hdrVersion),
                values,root.GetProperty("payload_version").GetInt32(),root.GetProperty("scope_version").GetInt32());
        } catch (AdjustmentTransferException) { throw; }
          catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException) { throw Invalid("JSON"); }
    }
    private static void Keys(JsonElement value, params string[] allowed)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Invalid("object");
        var keys = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (keys.Distinct().Count()!=keys.Length || keys.Any(k => !allowed.Contains(k))) throw Invalid("unknown/duplicate field");
    }
    public void Validate()
    {
        if (Source.IsHDR ? PayloadVersion != 2 || ScopeVersion != 2 || Source.HdrProcessingVersion is not (>= 1 and <= 9)
            : PayloadVersion != 1 || ScopeVersion != 1)
            throw new AdjustmentTransferException(AdjustmentFailure.UnsupportedVersion);
        if (Values.Count==0) throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope);
        if (string.IsNullOrEmpty(Source.Identifier) || Source.ProcessingVersion is not (1 or 2 or 3) ||
            Source.IsHDR && (Source.IsRaw || Source.Recipe != null)) throw Invalid("source");
        if (!Source.IsHDR && Values.Keys.Any(field => field.IsHDROnly())) throw Invalid("hdr context");
        if (Source.HdrProcessingVersion is { } hdrVersion) {
            var supported = AdjustmentFields.HDRSupportedFor(hdrVersion);
            if (Values.Keys.Any(field => field != AdjustmentField.HdrCameraDevelopment && !supported.Contains(field))) throw Invalid("hdr context");
        }
        if (Source.Recipe is {} recipe) {
            if (string.IsNullOrEmpty(recipe.ID) || !double.IsFinite(recipe.Strength) || recipe.Strength is <0 or >2 || recipe.SettingsVersion is not (2 or 3 or 4)) throw Invalid("recipe");
            if (Number(this[AdjustmentField.Strength]) is {} strength && strength!=recipe.Strength) throw Invalid("recipe.strength");
        }
        foreach (var (field,value) in Values) if (!Enum.IsDefined(field) || !Valid(field,value)) throw Invalid(field.ToString());
        if (this[AdjustmentField.Look] is {} look && Text(look.GetProperty("kind"))=="recipe" && Text(look.GetProperty("id"))!=Source.Recipe?.ID) throw Invalid("recipe.look");
        var mode = Text(this[AdjustmentField.WhiteBalanceMode]);
        if (mode!=null && (Source.IsRaw ? mode is "none" or "relative" : mode is not ("none" or "relative"))) throw Invalid("white_balance.mode");
        var temperature=this[AdjustmentField.Temperature]; var tint=this[AdjustmentField.Tint];
        if (!Source.IsRaw) {
            if (mode == "relative") {
                if (Null(temperature) || Null(tint)) throw Invalid("white_balance values conflict with mode");
            } else if (Number(temperature)!=null || Source.Recipe==null && Number(tint)!=null) {
                throw Invalid("raster.white_balance");
            }
        }
        if (Source.Recipe!=null && Null(tint)) throw Invalid("recipe.white_balance.tint");
        if (mode=="camera" && (Number(temperature)!=null || Source.Recipe==null && Number(tint)!=null) ||
            mode=="temperature" && (Null(temperature) || Null(tint))) throw Invalid("white_balance values conflict with mode");
        if (!Source.IsRaw && (modeValueInvalid(AdjustmentField.ExposureMode,"sensor") || numberInvalid(AdjustmentField.RawDenoise) ||
            !Source.IsHDR && numberInvalid(AdjustmentField.PostRGBDenoise))) throw Invalid("raster request");
        bool modeValueInvalid(AdjustmentField f,string expected) => this[f]!=null && Text(this[f])!=expected;
        bool numberInvalid(AdjustmentField f) => this[f]!=null && Number(this[f])!=0;
    }
    private static bool Valid(AdjustmentField field, JsonElement value)
    {
        var proto = field.Spec().Protocol;
        if (Null(value)) return proto.Nullable;
        if (field == AdjustmentField.HdrLook) return HDRLookValue(value) != null;
        if (field == AdjustmentField.HdrCameraDevelopment) return HDRCameraValue(value) != null;
        if (field == AdjustmentField.Curve) {
            try { _ = ToneCurveSettings.Parse(value, allowV2Fields: false); return true; } catch (JsonException) { return false; }
        }
        if (field == AdjustmentField.CurveParametric) {
            try { _ = ToneCurveParametric.Parse(value); return true; } catch (JsonException) { return false; }
        }
        if (field.GradingZone() != null || field == AdjustmentField.GradingGlobal) {
            if (value.ValueKind != JsonValueKind.Object) return false;
            var keys = value.EnumerateObject().Select(p => p.Name).ToArray();
            if (keys.Distinct(StringComparer.Ordinal).Count() != keys.Length ||
                !proto.ObjectKeys.All(keys.Contains) ||
                keys.Any(k => !proto.ObjectKeys.Contains(k) && !proto.OptionalKeys.Contains(k)))
                return false;
            var lum = 0.0;
            if (value.TryGetProperty("luminance", out var lumElem)) {
                if (Number(lumElem) is not {} lv) return false;
                lum = lv;
            }
            return Number(value.GetProperty("hue")) is {} hue && Number(value.GetProperty("saturation")) is {} saturation
                && new ColorGradingWheel(hue, saturation, lum).IsValid;
        }
        if (field == AdjustmentField.Look) {
            if (!ObjectKeys(value, proto.ObjectKeys.ToArray())) return false;
            var kind = Text(value.GetProperty("kind")); var id = Text(value.GetProperty("id"));
            if (kind is null || !AdjustmentFieldSpec.SubFields.LookReference.AllowedKinds.Contains(kind)) return false;
            return kind == AdjustmentFieldSpec.SubFields.LookReference.IdNullableWhenKind ? Null(value.GetProperty("id")) :
                id is {Length:>0} && id is not ("." or "..") && !id.Contains('/') && !id.Contains('\\');
        }
        if (field == AdjustmentField.WaveletDenoise) {
            return ObjectKeys(value, proto.ObjectKeys.ToArray()) && Boolean(value.GetProperty("enabled")) != null &&
                Text(value.GetProperty("preset")) is {} preset && AdjustmentFieldSpec.SubFields.WaveletDenoise.AllowedPresets.Contains(preset) &&
                Number(value.GetProperty("luma")) is >= AdjustmentFieldSpec.SubFields.WaveletDenoise.LumaMin and <= AdjustmentFieldSpec.SubFields.WaveletDenoise.LumaMax &&
                Number(value.GetProperty("chroma")) is >= AdjustmentFieldSpec.SubFields.WaveletDenoise.ChromaMin and <= AdjustmentFieldSpec.SubFields.WaveletDenoise.ChromaMax &&
                Number(value.GetProperty("coarse")) is >= AdjustmentFieldSpec.SubFields.WaveletDenoise.CoarseMin and <= AdjustmentFieldSpec.SubFields.WaveletDenoise.CoarseMax;
        }
        switch (proto.ValueType) {
            case AdjustmentProtocolValueType.Boolean:
                return Boolean(value) != null;
            case AdjustmentProtocolValueType.String:
                if (Text(value) is not {} text) return false;
                if (proto.NonEmpty && text.Length == 0) return false;
                return proto.AllowedStringValues.Count == 0 || proto.AllowedStringValues.Contains(text);
            case AdjustmentProtocolValueType.Integer:
                if (Number(value) is not {} iv || !double.IsFinite(iv) || iv != Math.Truncate(iv)) return false;
                if (proto.Range is {} ir && (iv < ir.Min || iv > ir.Max)) return false;
                return proto.AllowedIntValues.Count == 0 || proto.AllowedIntValues.Contains((int)iv);
            case AdjustmentProtocolValueType.Number:
                if (Number(value) is not {} nv || !double.IsFinite(nv)) return false;
                if (proto.Min is {} lo && (proto.ExclusiveMin ? nv <= lo : nv < lo)) return false;
                if (proto.Max is {} hi && nv > hi) return false;
                return true;
            default:
                return false;
        }
    }
    private static bool ObjectKeys(JsonElement value, params string[] keys) => value.ValueKind==JsonValueKind.Object &&
        value.EnumerateObject().Select(p=>p.Name).Order().SequenceEqual(keys.Order());
    private static AdjustmentTransferException Invalid(string detail) => new(AdjustmentFailure.InvalidPayload,detail);
}
