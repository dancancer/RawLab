using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum HDRMode { Sdr, Hdr }

internal sealed record HDRToneSettings
{
    internal double BlackPoint { get; init; }
    internal double WhitePoint { get; init; }
    internal double CurveStrength { get; init; }
    internal ToneCurveSettings Curve { get; init; } = new();

    internal bool IsDefault => BlackPoint == 0 && WhitePoint == 0 && CurveStrength == 0 && Curve.IsDefault;
    internal bool IsIdentity => BlackPoint == 0 && WhitePoint == 0 && (Curve.IsDefault ? CurveStrength == 0 : Curve.IsIdentity);
    internal bool IsValid => BlackPoint is >= -100 and <= 100 && WhitePoint is >= -100 and <= 100 &&
        CurveStrength is >= -100 and <= 100;
}

internal sealed record HDRColorSettings
{
    internal double Vibrance { get; init; }
    internal HslSettings Hsl { get; init; } = new();
    internal ColorGradingSettings Grading { get; init; } = new();
    internal bool IsDefault => Vibrance == 0 && Hsl.IsIdentity && Grading.IsDefault;
    internal bool IsIdentity => Vibrance == 0 && Hsl.IsIdentity && Grading.IsIdentity;
    internal bool IsValid => Vibrance is >= -100 and <= 100 && Grading.IsValid;
}

internal sealed record HDRRenditionSettings
{
    internal double PeakLimitEV { get; init; }
    internal double SdrExposureEV { get; init; }
    internal double SdrContrast { get; init; }
    internal double SdrSaturation { get; init; }
    internal bool IsDefault => PeakLimitEV == 0 && SdrExposureEV == 0 && SdrContrast == 0 && SdrSaturation == 0;
    internal bool IsValid => PeakLimitEV is >= 0 and <= 6 && SdrExposureEV is >= -4 and <= 4 &&
        SdrContrast is >= -100 and <= 100 && SdrSaturation is >= -100 and <= 100;
}

internal sealed record HDRDetailSettings(double Sharpening = 0, double Clarity = 0, double Dehaze = 0, double Denoise = 0)
{
    internal bool IsDefault => Sharpening == 0 && Clarity == 0 && Dehaze == 0 && Denoise == 0;
    internal bool IsValid => Sharpening is >= 0 and <= 2 && Clarity is >= -1 and <= 1 &&
        Dehaze is >= -1 and <= 1 && Denoise is >= 0 and <= 1;
}

internal sealed record HDRLookSettings(string? Sha256 = null, string? Name = null, double Strength = 0)
{
    internal const long MaximumBytes = 32 * 1024 * 1024;
    internal static string Directory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Looks", "HDR");
    internal static bool IsFingerprint(string? value) => value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    internal bool IsDefault => Sha256 == null && Name == null && Strength == 0;
    internal bool IsValid => IsDefault || IsFingerprint(Sha256) && Name is { Length: > 0 } &&
        Encoding.UTF8.GetByteCount(Name) <= 512 && !Name.Any(char.IsControl) && Strength is >= 0 and <= 2;
    internal string? AssetPath(string? directory = null) => IsFingerprint(Sha256) ? Path.Combine(directory ?? Directory, Sha256 + ".cube") : null;

    internal bool AssetIsAvailable(string? directory = null)
    {
        if (IsDefault) return true;
        if (!IsValid || AssetPath(directory) is not { } path) return false;
        try {
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return stream.Length is > 0 and <= MaximumBytes &&
                Convert.ToHexString(SHA256.HashData(stream)).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }
}

internal sealed record HDRCameraProfile(string Sha256, string Name)
{
    internal static string Directory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "HDRCameraProfiles");
    internal bool IsValid => HDRLookSettings.IsFingerprint(Sha256) && Name is { Length: > 0 } &&
        Encoding.UTF8.GetByteCount(Name) <= 512 && !Name.Any(char.IsControl);
    internal string AssetPath => Path.Combine(Directory, Sha256 + ".profile");
}

internal sealed record HDRCameraDevelopmentSettings(bool CustomWhiteBalance = false, double Temperature = 0, double Tint = 0,
    bool SensorExposure = false, int FbddLevel = 0, bool LensDistortion = false, bool LensTca = false,
    bool LensAutoCrop = true, string? LensProfile = null, HDRCameraProfile? CameraProfile = null)
{
    internal bool LensActive => LensDistortion || LensTca;
    internal bool AllowsAI => FbddLevel == 0 && CameraProfile == null;
    internal bool IsDefault => this == new HDRCameraDevelopmentSettings();
    internal bool IsValid => (CustomWhiteBalance ? Temperature is >= 2000 and <= 50000 && Tint is >= -150 and <= 150
        : Temperature == 0 && Tint == 0) && FbddLevel is >= 0 and <= 2 &&
        (LensProfile == null || LensActive && Encoding.UTF8.GetByteCount(LensProfile) is >= 1 and <= 1024 &&
            !LensProfile.Any(char.IsControl)) && (CameraProfile?.IsValid ?? true);
}

[JsonConverter(typeof(HDRSettingsJsonConverter))]
public sealed record HDRSettings
{
    public int RecordVersion => CameraDevelopment == null ? ProcessingVersion : 8;
    public int ProcessingVersion => Look != null ? 7 : Detail != null ? 6 : Effects != null ? 5 : Rendition != null ? 4 : Color != null ? 3 : Tone != null ? 2 : 1;
    public HDRMode Mode { get; init; } = HDRMode.Hdr;
    public double Exposure { get; init; }
    public double Temperature { get; init; } = 6500;
    public double Tint { get; init; }
    public double Contrast { get; init; }
    public double Highlights { get; init; }
    public double Shadows { get; init; }
    public double Saturation { get; init; }
    public GeometrySettings Geometry { get; init; } = new();
    internal HDRToneSettings? Tone { get; init; }
    internal HDRToneSettings ToneSettings => Tone ?? new();
    internal HDRColorSettings? Color { get; init; }
    internal HDRColorSettings ColorSettings => Color ?? new();
    internal HDRRenditionSettings? Rendition { get; init; }
    internal HDRRenditionSettings RenditionSettings => Rendition ?? new();
    internal PhotoEffectsSettings? Effects { get; init; }
    internal PhotoEffectsSettings EffectSettings => Effects ?? new();
    internal HDRDetailSettings? Detail { get; init; }
    internal HDRDetailSettings DetailSettings => Detail ?? new();
    internal HDRLookSettings? Look { get; init; }
    internal HDRLookSettings LookSettings => Look ?? new();
    internal HDRCameraDevelopmentSettings? CameraDevelopment { get; init; }
    internal HDRCameraDevelopmentSettings CameraSettings => CameraDevelopment ?? new();

    public bool IsValid => (Mode is HDRMode.Sdr or HDRMode.Hdr) &&
        new[] { Exposure, Temperature, Tint, Contrast, Highlights, Shadows, Saturation }.All(double.IsFinite) &&
        Exposure is >= -4 and <= 4 && Temperature is >= 2000 and <= 50000 && Tint is >= -150 and <= 150 &&
        Contrast is >= -100 and <= 100 && Highlights is >= -100 and <= 100 && Shadows is >= -100 and <= 100 &&
        Saturation is >= -100 and <= 100 && GeometryIsValid(Geometry) && (Tone?.IsValid ?? true) &&
        (Color == null || Tone != null && Color.IsValid) &&
        (Rendition == null || Color != null && Rendition.IsValid) &&
        (Effects == null || Rendition != null && PhotoEffectSpec.All.All(spec =>
            Effects[spec.Id] >= spec.Min && Effects[spec.Id] <= spec.Max)) &&
        (Detail == null || Effects != null && Detail.IsValid) && (Look == null || Detail != null && Look.IsValid) &&
        (CameraDevelopment?.IsValid ?? true);

    public bool IsIdentity => Exposure == 0 && Temperature == 6500 && Tint == 0 && Contrast == 0 &&
        Highlights == 0 && Shadows == 0 && Saturation == 0 && GeometryIsValid(Geometry) && Geometry.IsIdentity &&
        (Tone?.IsIdentity ?? true) && (Color?.IsIdentity ?? true) && (Rendition?.IsDefault ?? true) &&
        (Effects == null || Effects.VignetteAmount == 0 && Effects.GrainAmount == 0) && (Detail?.IsDefault ?? true) &&
        LookSettings.IsDefault && CameraSettings.IsDefault;

    public HDRSettings Reset() => this with {
        Exposure = 0, Temperature = 6500, Tint = 0, Contrast = 0, Highlights = 0,
        Shadows = 0, Saturation = 0, Geometry = new(), Tone = Tone == null ? null : new(),
        Color = Color == null ? null : new(), Rendition = Rendition == null ? null : new(),
        Effects = Effects == null ? null : new(), Detail = Detail == null ? null : new(), Look = Look == null ? null : new(),
        CameraDevelopment = CameraDevelopment == null ? null : new()
    };

    internal HDRSettings WithTone(HDRToneSettings tone) => this with { Tone = Tone == null && tone.IsDefault ? null : tone };
    internal HDRSettings WithColor(HDRColorSettings color) =>
        Color == null && color.IsDefault ? this : this with { Tone = ToneSettings, Color = color };
    internal HDRSettings WithRendition(HDRRenditionSettings rendition) =>
        Rendition == null && rendition.IsDefault ? this : this with { Tone = ToneSettings, Color = ColorSettings, Rendition = rendition };
    internal HDRSettings WithEffects(PhotoEffectsSettings effects) => Effects == null && effects == PhotoEffectsSettings.Default
        ? this : this with { Tone=ToneSettings, Color=ColorSettings, Rendition=RenditionSettings, Effects=effects };
    internal HDRSettings WithDetail(HDRDetailSettings detail) => Detail == null && detail.IsDefault ? this : this with {
        Tone = ToneSettings, Color = ColorSettings, Rendition = RenditionSettings, Effects = EffectSettings, Detail = detail
    };
    internal HDRSettings WithLook(HDRLookSettings look) => Look == null && look.IsDefault ? this : this with {
        Tone = ToneSettings, Color = ColorSettings, Rendition = RenditionSettings, Effects = EffectSettings, Detail = DetailSettings, Look = look
    };
    internal HDRSettings WithCameraDevelopment(HDRCameraDevelopmentSettings camera) =>
        CameraDevelopment == null && camera.IsDefault ? this : this with { CameraDevelopment = camera };
    internal static bool Supports(Parameter id) => id is Parameter.Exposure or Parameter.Temperature or Parameter.Tint or
        Parameter.Contrast or Parameter.Highlights or Parameter.Shadows or Parameter.Saturation or Parameter.ToneCurve or Parameter.Sharpening;
    internal static bool Supports(ToneControlParameter id) =>
        id is ToneControlParameter.BlackPoint or ToneControlParameter.WhitePoint or ToneControlParameter.Vibrance;

    internal double Get(Parameter id) => id switch {
        Parameter.Exposure => Exposure, Parameter.Temperature => Temperature, Parameter.Tint => Tint,
        Parameter.Contrast => Contrast, Parameter.Highlights => Highlights, Parameter.Shadows => Shadows,
        Parameter.Saturation => Saturation, Parameter.ToneCurve => ToneSettings.CurveStrength,
        Parameter.Sharpening => DetailSettings.Sharpening * 100,
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };

    internal HDRSettings Set(Parameter id, double value) => id switch {
        Parameter.Exposure => this with { Exposure = Math.Clamp(value, -4, 4) },
        Parameter.Temperature => this with { Temperature = Math.Clamp(value, 2000, 50000) },
        Parameter.Tint => this with { Tint = Math.Clamp(value, -150, 150) },
        Parameter.Contrast => this with { Contrast = Math.Clamp(value, -100, 100) },
        Parameter.Highlights => this with { Highlights = Math.Clamp(value, -100, 100) },
        Parameter.Shadows => this with { Shadows = Math.Clamp(value, -100, 100) },
        Parameter.Saturation => this with { Saturation = Math.Clamp(value, -100, 100) },
        Parameter.ToneCurve => WithTone(ToneSettings with { CurveStrength = Math.Clamp(value, -100, 100) }),
        Parameter.Sharpening => WithDetail(DetailSettings with { Sharpening = Math.Clamp(value, 0, 200) / 100 }),
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };

    internal static HDRSettings FromSdr(Adjustments settings) => new() {
        Exposure = settings[Parameter.Exposure], Contrast = settings[Parameter.Contrast],
        Highlights = settings[Parameter.Highlights], Shadows = settings[Parameter.Shadows],
        Saturation = settings[Parameter.Saturation], Geometry = settings.Geometry
    };

    internal Native.HDRRequestV7 NativeRenderRequest(HDRIntent intent, uint longEdge = 0)
    {
        var tone = ToneSettings;
        var color = ColorSettings;
        var rendition = RenditionSettings;
        var effects = new Native.HDRRequestV5 {
            Base = new() {
                Base = new() {
                    Base = new() {
                        Base = NativeRequest(intent, longEdge),
                        BlackPoint = (float)tone.BlackPoint, WhitePoint = (float)tone.WhitePoint, CurveStrength = (float)tone.CurveStrength,
                        Curve = tone.Curve.NativeConfig()
                    },
                    Vibrance = (float)color.Vibrance, Hsl = color.Hsl.NativeConfig(), Grading = color.Grading.NativeConfig()
                },
                PeakLimitEV = (float)rendition.PeakLimitEV, SdrExposureEV = (float)rendition.SdrExposureEV,
                SdrContrast = (float)rendition.SdrContrast, SdrSaturation = (float)rendition.SdrSaturation
            },
            Effects = EffectSettings.NativeConfig()
        };
        var detail = DetailSettings;
        var look = LookSettings;
        var fingerprint = new byte[65];
        if (HDRLookSettings.IsFingerprint(look.Sha256)) Encoding.ASCII.GetBytes(look.Sha256!,fingerprint);
        return new() {
            Base = new() { Base = effects, Sharpening = (float)detail.Sharpening, Clarity = (float)detail.Clarity,
                Dehaze = (float)detail.Dehaze, Denoise = (float)detail.Denoise },
            LookPath = look.AssetPath(), LookStrength = (float)look.Strength, LookSha256 = fingerprint
        };
    }

    private Native.HDRRequest NativeRequest(HDRIntent intent, uint longEdge) => new() {
        Version = 1, StructSize = (uint)(ProcessingVersion switch {
            1 => Marshal.SizeOf<Native.HDRRequest>(),
            2 => Marshal.SizeOf<Native.HDRRequestV2>(),
            3 => Marshal.SizeOf<Native.HDRRequestV3>(),
            4 => Marshal.SizeOf<Native.HDRRequestV4>(),
            5 => Marshal.SizeOf<Native.HDRRequestV5>(),
            6 => Marshal.SizeOf<Native.HDRRequestV6>(),
            _ => Marshal.SizeOf<Native.HDRRequestV7>()
        }),
        HDRProcessingVersion = (uint)ProcessingVersion, Intent = (uint)intent,
        ExposureEv = (float)Exposure, Temperature = (float)Temperature, Tint = (float)Tint,
        // The HDR renderer consumes the shared percentage contract directly.
        Contrast = (float)Contrast, Highlights = (float)Highlights, Shadows = (float)Shadows,
        Saturation = (float)Saturation,
        CropX = (float)Geometry.CropX, CropY = (float)Geometry.CropY,
        CropWidth = (float)Geometry.CropWidth, CropHeight = (float)Geometry.CropHeight,
        QuarterTurns = Geometry.QuarterTurns, FlipHorizontal = Geometry.FlipHorizontal ? 1u : 0u,
        FlipVertical = Geometry.FlipVertical ? 1u : 0u, StraightenDegrees = (float)Geometry.StraightenDegrees,
        PerspectiveHorizontal = (float)Geometry.PerspectiveHorizontal,
        PerspectiveVertical = (float)Geometry.PerspectiveVertical, LongEdge = longEdge
    };

    public static HDRSettings Enabling(HDRSettings? stored, HDRSettings initial, bool sourceIsHDR,
        IEnumerable<string>? conflicts = null, bool cameraRaw = false)
    {
        if (!sourceIsHDR) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        if (stored is { } existing)
        {
            if (!existing.IsValid) throw new HDRModeException(HDRModeFailure.InvalidSettings);
            return existing with { Mode = HDRMode.Hdr };
        }
        var blocked = conflicts?.Where(value => !string.IsNullOrEmpty(value)).ToArray() ?? Array.Empty<string>();
        if (blocked.Length != 0) throw new HDRModeException(HDRModeFailure.Conflicts, blocked);
        // Camera RAW keeps the existing SDR record (including LUT, as-shot WB
        // and RAW denoise) but starts its separate HDR record from a neutral
        // scene snapshot. Geometry is the only shared edit copied here.
        var result = cameraRaw
            ? new HDRSettings { Mode = HDRMode.Hdr, Geometry = initial.Geometry }
            : initial with { Mode = HDRMode.Hdr, Temperature = 6500, Tint = 0 };
        if (!result.IsValid) throw new HDRModeException(HDRModeFailure.InvalidSettings);
        return result;
    }

    internal static bool GeometryIsValid(GeometrySettings value) =>
        new[] { value.CropX, value.CropY, value.CropWidth, value.CropHeight, value.StraightenDegrees,
         value.PerspectiveHorizontal, value.PerspectiveVertical }.All(double.IsFinite) &&
        value.CropX >= 0 && value.CropY >= 0 && value.CropWidth > 0 && value.CropHeight > 0 &&
        value.CropX + value.CropWidth <= 1 && value.CropY + value.CropHeight <= 1 && value.QuarterTurns is >= 0 and <= 3 &&
        value.StraightenDegrees is >= -45 and <= 45 && value.PerspectiveHorizontal is >= -1 and <= 1 &&
        value.PerspectiveVertical is >= -1 and <= 1;
}

public enum HDRIntent { Preview = 0, Final = 1 }
public enum HDRModeFailure { UnsupportedSource, Conflicts, InvalidSettings }
public sealed class HDRModeException(HDRModeFailure failure, IReadOnlyList<string>? conflicts = null) : IOException(LocalizedMessage(failure))
{
    public HDRModeFailure Failure { get; } = failure;
    public IReadOnlyList<string> Conflicts { get; } = conflicts ?? [];
    private static string LocalizedMessage(HDRModeFailure failure) => failure switch {
        HDRModeFailure.UnsupportedSource => Loc.Text("此照片没有可编辑的 HDR 增益图。"),
        HDRModeFailure.Conflicts => Loc.Text("当前 SDR 调整包含 HDR 暂不支持的工具。请先重置这些工具，再启用 HDR。"),
        _ => Loc.Text("HDR 调整记录无效，原有文件未被覆盖。")
    };
}

internal sealed class HDRSettingsJsonConverter : JsonConverter<HDRSettings>
{
    private static readonly HashSet<string> Keys = ["record_version", "hdr_processing_version", "mode", "exposure_ev",
        "relative_temperature", "relative_tint", "contrast", "highlights", "shadows", "saturation", "geometry"];
    private static readonly HashSet<string> GeometryKeys = ["cropX", "cropY", "cropWidth", "cropHeight", "quarterTurns",
        "flipHorizontal", "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical"];
    private static readonly JsonSerializerOptions CamelCaseOptions = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, IgnoreReadOnlyProperties = true
    };
    private static readonly JsonSerializerOptions EffectsOptions = new() {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, IgnoreReadOnlyProperties = true
    };
    private static readonly string[] EffectsKeys = Enum.GetNames<PhotoEffectParameter>()
        .Select(JsonNamingPolicy.SnakeCaseLower.ConvertName).Order(StringComparer.Ordinal).ToArray();

    public override HDRSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var value = document.RootElement;
        if (value.ValueKind != JsonValueKind.Object) throw new JsonException("HDR settings must be an object");
        var properties = value.EnumerateObject().ToArray();
        var names = properties.Select(property => property.Name).ToArray();
        var extended = value.TryGetProperty("tone", out var toneValue);
        var color = value.TryGetProperty("color", out var colorValue);
        var rendition = value.TryGetProperty("rendition", out var renditionValue);
        var effects = value.TryGetProperty("effects", out var effectsValue);
        var detail = value.TryGetProperty("detail", out var detailValue);
        var look = value.TryGetProperty("look", out var lookValue);
        var camera = value.TryGetProperty("camera_development", out var cameraValue);
        if (properties.Length != Keys.Count + (extended ? 1 : 0) + (color ? 1 : 0) + (rendition ? 1 : 0) + (effects ? 1 : 0) + (detail ? 1 : 0) + (look ? 1 : 0) + (camera ? 1 : 0) ||
            names.Distinct(StringComparer.Ordinal).Count() != names.Length ||
            names.Any(name => name is not ("tone" or "color" or "rendition" or "effects" or "detail" or "look" or "camera_development") && !Keys.Contains(name)))
            throw new JsonException("Unsupported HDR settings field");
        int Integer(string name) => value.GetProperty(name).GetInt32();
        double Number(string name) => value.GetProperty(name).GetDouble();
        var version = look ? 7 : detail ? 6 : effects ? 5 : rendition ? 4 : color ? 3 : extended ? 2 : 1;
        if (look && !detail || detail && !effects || effects && !rendition || rendition && !color || color && !extended ||
            Integer("record_version") != (camera ? 8 : version) || Integer("hdr_processing_version") != version)
            throw new JsonException("Unsupported HDR settings version");
        var mode = value.GetProperty("mode").GetString() switch {
            "sdr" => HDRMode.Sdr, "hdr" => HDRMode.Hdr, _ => throw new JsonException("Invalid HDR mode")
        };
        var geometryValue = value.GetProperty("geometry");
        if (geometryValue.ValueKind != JsonValueKind.Object || geometryValue.EnumerateObject().Any(p => !GeometryKeys.Contains(p.Name)))
            throw new JsonException("Invalid HDR geometry");
        var geometry = geometryValue.Deserialize<GeometrySettings>(CamelCaseOptions) ?? new();
        var result = new HDRSettings {
            Mode = mode,
            Exposure = Number("exposure_ev"), Temperature = Number("relative_temperature"), Tint = Number("relative_tint"),
            Contrast = Number("contrast"), Highlights = Number("highlights"), Shadows = Number("shadows"),
            Saturation = Number("saturation"), Geometry = geometry, Tone = extended ? ReadTone(toneValue) : null,
            Color = color ? ReadColor(colorValue) : null,
            Rendition = rendition ? ReadRendition(renditionValue) : null,
            Effects = effects ? ReadEffects(effectsValue) : null,
            Detail = detail ? ReadDetail(detailValue) : null,
            Look = look ? ReadLook(lookValue) : null,
            CameraDevelopment = camera ? ReadCameraDevelopment(cameraValue) : null
        };
        if (!result.IsValid) throw new JsonException("Invalid HDR settings parameters");
        return result;
    }

    private static HDRCameraDevelopmentSettings ReadCameraDevelopment(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid camera RAW HDR development");
        var keys = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (keys.Count(key => key == "lens_profile") > 1 || keys.Count(key => key == "camera_profile") > 1 ||
            !keys.Where(key => key is not "lens_profile" and not "camera_profile").Order(StringComparer.Ordinal)
            .SequenceEqual(new[] { "exposure_reference", "fbdd_level", "lens_auto_crop", "lens_distortion", "lens_tca",
                "temperature", "tint", "version", "white_balance_mode" }) || value.GetProperty("version").GetInt32() != 1)
            throw new JsonException("Unsupported camera RAW HDR development fields");
        HDRCameraProfile? cameraProfile = null;
        if (value.TryGetProperty("camera_profile", out var cameraProfileValue)) {
            if (cameraProfileValue.ValueKind != JsonValueKind.Object || !cameraProfileValue.EnumerateObject().Select(p => p.Name)
                .Order(StringComparer.Ordinal).SequenceEqual(new[] { "name", "sha256" }))
                throw new JsonException("Invalid HDR camera profile fields");
            cameraProfile = new(cameraProfileValue.GetProperty("sha256").GetString() ?? "", cameraProfileValue.GetProperty("name").GetString() ?? "");
        }
        return new(value.GetProperty("white_balance_mode").GetString() switch {
            "as_shot" => false, "temperature" => true, _ => throw new JsonException("Invalid camera white balance mode")
        }, value.GetProperty("temperature").GetDouble(), value.GetProperty("tint").GetDouble(),
            value.GetProperty("exposure_reference").GetString() switch {
                "metadata" => false, "sensor" => true, _ => throw new JsonException("Invalid RAW exposure reference")
            },
            value.GetProperty("fbdd_level").GetInt32(), value.GetProperty("lens_distortion").GetBoolean(),
            value.GetProperty("lens_tca").GetBoolean(), value.GetProperty("lens_auto_crop").GetBoolean(),
            value.TryGetProperty("lens_profile", out var profile) ? profile.GetString() : null, cameraProfile);
    }

    internal static HDRLookSettings ReadLook(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.EnumerateObject().Select(p => p.Name)
            .Order(StringComparer.Ordinal).SequenceEqual(new[] { "name", "sha256", "strength" }))
            throw new JsonException("Unsupported HDR look field");
        return new(value.GetProperty("sha256").GetString(), value.GetProperty("name").GetString(), value.GetProperty("strength").GetDouble());
    }

    private static HDRDetailSettings ReadDetail(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.EnumerateObject().Select(p => p.Name)
            .Order(StringComparer.Ordinal).SequenceEqual(new[] { "clarity", "dehaze", "denoise", "sharpening" }))
            throw new JsonException("Unsupported HDR detail field");
        return new(value.GetProperty("sharpening").GetDouble(), value.GetProperty("clarity").GetDouble(),
            value.GetProperty("dehaze").GetDouble(), value.GetProperty("denoise").GetDouble());
    }

    private static PhotoEffectsSettings ReadEffects(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object ||
            !value.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).SequenceEqual(EffectsKeys))
            throw new JsonException("Unsupported HDR effects field");
        return value.Deserialize<PhotoEffectsSettings>(EffectsOptions)!;
    }

    private static HDRRenditionSettings ReadRendition(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.EnumerateObject().Select(p => p.Name)
            .Order(StringComparer.Ordinal).SequenceEqual(new[] { "peak_limit_ev", "sdr_contrast", "sdr_exposure_ev", "sdr_saturation" }))
            throw new JsonException("Unsupported HDR rendition field");
        return new() {
            PeakLimitEV = value.GetProperty("peak_limit_ev").GetDouble(), SdrExposureEV = value.GetProperty("sdr_exposure_ev").GetDouble(),
            SdrContrast = value.GetProperty("sdr_contrast").GetDouble(), SdrSaturation = value.GetProperty("sdr_saturation").GetDouble()
        };
    }

    private static HDRColorSettings ReadColor(JsonElement value)
    {
        static void RequireKeys(JsonElement objectValue, params string[] keys)
        {
            if (objectValue.ValueKind != JsonValueKind.Object ||
                !objectValue.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).SequenceEqual(keys))
                throw new JsonException("Unsupported HDR color field");
        }
        RequireKeys(value, "grading", "hsl", "vibrance");
        var hsl = value.GetProperty("hsl");
        RequireKeys(hsl, "hue", "lightness", "saturation");
        var channels = new List<double>(24);
        foreach (var name in new[] { "hue", "saturation", "lightness" })
        {
            var axis = hsl.GetProperty(name);
            if (axis.ValueKind != JsonValueKind.Array || axis.GetArrayLength() != 8)
                throw new JsonException("Invalid HDR HSL channel count");
            foreach (var channel in axis.EnumerateArray())
            {
                if (channel.ValueKind != JsonValueKind.Number || !channel.TryGetDouble(out var number) ||
                    number is < -100 or > 100 || !double.IsFinite(number))
                    throw new JsonException("Invalid HDR HSL value");
                channels.Add(number);
            }
        }
        var grading = value.GetProperty("grading");
        RequireKeys(grading, "highlights", "midtones", "shadows");
        foreach (var wheel in grading.EnumerateObject()) RequireKeys(wheel.Value, "hue", "saturation");
        return new() {
            Vibrance = value.GetProperty("vibrance").GetDouble(),
            Hsl = new(channels.ToArray()),
            Grading = grading.Deserialize<ColorGradingSettings>(CamelCaseOptions)!
        };
    }

    private static HDRToneSettings ReadTone(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.EnumerateObject().Select(p => p.Name)
            .Order(StringComparer.Ordinal).SequenceEqual(new[] { "black_point", "curve", "curve_strength", "white_point" }))
            throw new JsonException("Unsupported HDR tone field");
        return new() {
            BlackPoint = value.GetProperty("black_point").GetDouble(), WhitePoint = value.GetProperty("white_point").GetDouble(),
            CurveStrength = value.GetProperty("curve_strength").GetDouble(), Curve = ToneCurveSettings.Parse(value.GetProperty("curve"))
        };
    }

    public override void Write(Utf8JsonWriter writer, HDRSettings value, JsonSerializerOptions options)
    {
        if (!value.IsValid) throw new JsonException("Invalid HDR settings parameters");
        writer.WriteStartObject();
        writer.WriteNumber("record_version", value.RecordVersion);
        writer.WriteNumber("hdr_processing_version", value.ProcessingVersion);
        if (value.CameraDevelopment is { } camera) {
            writer.WriteStartObject("camera_development");
            writer.WriteNumber("version",1);
            writer.WriteString("white_balance_mode",camera.CustomWhiteBalance ? "temperature" : "as_shot");
            writer.WriteNumber("temperature",camera.Temperature);
            writer.WriteNumber("tint",camera.Tint);
            writer.WriteString("exposure_reference",camera.SensorExposure ? "sensor" : "metadata");
            writer.WriteNumber("fbdd_level",camera.FbddLevel);
            writer.WriteBoolean("lens_distortion",camera.LensDistortion);
            writer.WriteBoolean("lens_tca",camera.LensTca);
            writer.WriteBoolean("lens_auto_crop",camera.LensAutoCrop);
            if (camera.LensProfile != null) writer.WriteString("lens_profile",camera.LensProfile);
            if (camera.CameraProfile is { } profile) {
                writer.WriteStartObject("camera_profile");
                writer.WriteString("sha256",profile.Sha256);
                writer.WriteString("name",profile.Name);
                writer.WriteEndObject();
            }
            writer.WriteEndObject();
        }
        writer.WriteString("mode", value.Mode == HDRMode.Hdr ? "hdr" : "sdr");
        writer.WriteNumber("exposure_ev", value.Exposure);
        writer.WriteNumber("relative_temperature", value.Temperature);
        writer.WriteNumber("relative_tint", value.Tint);
        writer.WriteNumber("contrast", value.Contrast);
        writer.WriteNumber("highlights", value.Highlights);
        writer.WriteNumber("shadows", value.Shadows);
        writer.WriteNumber("saturation", value.Saturation);
        writer.WritePropertyName("geometry");
        JsonSerializer.Serialize(writer, value.Geometry, CamelCaseOptions);
        if (value.Tone is { } tone) {
            writer.WriteStartObject("tone");
            writer.WriteNumber("black_point", tone.BlackPoint);
            writer.WriteNumber("white_point", tone.WhitePoint);
            writer.WriteNumber("curve_strength", tone.CurveStrength);
            writer.WritePropertyName("curve");
            JsonSerializer.Serialize(writer, tone.Curve, options);
            writer.WriteEndObject();
        }
        if (value.Color is { } color) {
            writer.WriteStartObject("color");
            writer.WriteNumber("vibrance", color.Vibrance);
            writer.WritePropertyName("hsl");
            var values = color.Hsl.Values;
            JsonSerializer.Serialize(writer, new { hue = values[0..8], saturation = values[8..16], lightness = values[16..24] });
            writer.WritePropertyName("grading");
            JsonSerializer.Serialize(writer, color.Grading, CamelCaseOptions);
            writer.WriteEndObject();
        }
        if (value.Rendition is { } rendition) {
            writer.WriteStartObject("rendition");
            writer.WriteNumber("peak_limit_ev", rendition.PeakLimitEV);
            writer.WriteNumber("sdr_exposure_ev", rendition.SdrExposureEV);
            writer.WriteNumber("sdr_contrast", rendition.SdrContrast);
            writer.WriteNumber("sdr_saturation", rendition.SdrSaturation);
            writer.WriteEndObject();
        }
        if (value.Effects is { } effects) {
            writer.WritePropertyName("effects");
            JsonSerializer.Serialize(writer, effects, EffectsOptions);
        }
        if (value.Detail is { } detail) {
            writer.WriteStartObject("detail");
            writer.WriteNumber("sharpening", detail.Sharpening);
            writer.WriteNumber("clarity", detail.Clarity);
            writer.WriteNumber("dehaze", detail.Dehaze);
            writer.WriteNumber("denoise", detail.Denoise);
            writer.WriteEndObject();
        }
        if (value.Look is { } look) {
            writer.WriteStartObject("look");
            writer.WriteString("sha256", look.Sha256);
            writer.WriteString("name", look.Name);
            writer.WriteNumber("strength", look.Strength);
            writer.WriteEndObject();
        }
        writer.WriteEndObject();
    }
}
