using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum HDRMode { Sdr, Hdr }

[JsonConverter(typeof(HDRSettingsJsonConverter))]
public sealed record HDRSettings
{
    public int RecordVersion { get; init; } = 1;
    public int ProcessingVersion { get; init; } = 1;
    public HDRMode Mode { get; init; } = HDRMode.Hdr;
    public double Exposure { get; init; }
    public double Temperature { get; init; } = 6500;
    public double Tint { get; init; }
    public double Contrast { get; init; }
    public double Highlights { get; init; }
    public double Shadows { get; init; }
    public double Saturation { get; init; }
    public GeometrySettings Geometry { get; init; } = new();

    public bool IsValid => RecordVersion == 1 && ProcessingVersion == 1 && (Mode is HDRMode.Sdr or HDRMode.Hdr) &&
        new[] { Exposure, Temperature, Tint, Contrast, Highlights, Shadows, Saturation }.All(double.IsFinite) &&
        Exposure is >= -4 and <= 4 && Temperature is >= 2000 and <= 50000 && Tint is >= -150 and <= 150 &&
        Contrast is >= -100 and <= 100 && Highlights is >= -100 and <= 100 && Shadows is >= -100 and <= 100 &&
        Saturation is >= -100 and <= 100 && GeometryIsValid(Geometry);

    public bool IsIdentity => Exposure == 0 && Temperature == 6500 && Tint == 0 && Contrast == 0 &&
        Highlights == 0 && Shadows == 0 && Saturation == 0 && GeometryIsValid(Geometry) && Geometry.IsIdentity;

    public HDRSettings Reset() => this with {
        Exposure = 0, Temperature = 6500, Tint = 0, Contrast = 0, Highlights = 0,
        Shadows = 0, Saturation = 0, Geometry = new()
    };

    internal double Get(Parameter id) => id switch {
        Parameter.Exposure => Exposure, Parameter.Temperature => Temperature, Parameter.Tint => Tint,
        Parameter.Contrast => Contrast, Parameter.Highlights => Highlights, Parameter.Shadows => Shadows,
        Parameter.Saturation => Saturation, _ => throw new ArgumentOutOfRangeException(nameof(id))
    };

    internal HDRSettings Set(Parameter id, double value) => id switch {
        Parameter.Exposure => this with { Exposure = Math.Clamp(value, -4, 4) },
        Parameter.Temperature => this with { Temperature = Math.Clamp(value, 2000, 50000) },
        Parameter.Tint => this with { Tint = Math.Clamp(value, -150, 150) },
        Parameter.Contrast => this with { Contrast = Math.Clamp(value, -100, 100) },
        Parameter.Highlights => this with { Highlights = Math.Clamp(value, -100, 100) },
        Parameter.Shadows => this with { Shadows = Math.Clamp(value, -100, 100) },
        Parameter.Saturation => this with { Saturation = Math.Clamp(value, -100, 100) },
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };

    internal static HDRSettings FromSdr(Adjustments settings) => new() {
        Exposure = settings[Parameter.Exposure], Contrast = settings[Parameter.Contrast],
        Highlights = settings[Parameter.Highlights], Shadows = settings[Parameter.Shadows],
        Saturation = settings[Parameter.Saturation], Geometry = settings.Geometry
    };

    internal Native.HDRRequest NativeRequest(HDRIntent intent, uint longEdge = 0) => new() {
        Version = 1, StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequest>(),
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
        IEnumerable<string>? conflicts = null)
    {
        if (!sourceIsHDR) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        if (stored is { } existing)
        {
            if (!existing.IsValid) throw new HDRModeException(HDRModeFailure.InvalidSettings);
            return existing with { Mode = HDRMode.Hdr };
        }
        var blocked = conflicts?.Where(value => !string.IsNullOrEmpty(value)).ToArray() ?? Array.Empty<string>();
        if (blocked.Length != 0) throw new HDRModeException(HDRModeFailure.Conflicts, blocked);
        var result = initial with { Mode = HDRMode.Hdr, Temperature = 6500, Tint = 0 };
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
    private static readonly JsonSerializerOptions GeometryOptions = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, IgnoreReadOnlyProperties = true
    };

    public override HDRSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var value = document.RootElement;
        if (value.ValueKind != JsonValueKind.Object) throw new JsonException("HDR settings must be an object");
        var properties = value.EnumerateObject().ToArray();
        var names = properties.Select(property => property.Name).ToArray();
        if (properties.Length != Keys.Count || names.Distinct(StringComparer.Ordinal).Count() != names.Length ||
            names.Any(name => !Keys.Contains(name)) || Keys.Any(name => !names.Contains(name, StringComparer.Ordinal)))
            throw new JsonException("Unsupported HDR settings field");
        int Integer(string name) => value.GetProperty(name).GetInt32();
        double Number(string name) => value.GetProperty(name).GetDouble();
        var mode = value.GetProperty("mode").GetString() switch {
            "sdr" => HDRMode.Sdr, "hdr" => HDRMode.Hdr, _ => throw new JsonException("Invalid HDR mode")
        };
        var geometryValue = value.GetProperty("geometry");
        if (geometryValue.ValueKind != JsonValueKind.Object || geometryValue.EnumerateObject().Any(p => !GeometryKeys.Contains(p.Name)))
            throw new JsonException("Invalid HDR geometry");
        var geometry = geometryValue.Deserialize<GeometrySettings>(GeometryOptions) ?? new();
        var result = new HDRSettings {
            RecordVersion = Integer("record_version"), ProcessingVersion = Integer("hdr_processing_version"), Mode = mode,
            Exposure = Number("exposure_ev"), Temperature = Number("relative_temperature"), Tint = Number("relative_tint"),
            Contrast = Number("contrast"), Highlights = Number("highlights"), Shadows = Number("shadows"),
            Saturation = Number("saturation"), Geometry = geometry
        };
        if (!result.IsValid) throw new JsonException("Invalid HDR settings parameters");
        return result;
    }

    public override void Write(Utf8JsonWriter writer, HDRSettings value, JsonSerializerOptions options)
    {
        if (!value.IsValid) throw new JsonException("Invalid HDR settings parameters");
        writer.WriteStartObject();
        writer.WriteNumber("record_version", value.RecordVersion);
        writer.WriteNumber("hdr_processing_version", value.ProcessingVersion);
        writer.WriteString("mode", value.Mode == HDRMode.Hdr ? "hdr" : "sdr");
        writer.WriteNumber("exposure_ev", value.Exposure);
        writer.WriteNumber("relative_temperature", value.Temperature);
        writer.WriteNumber("relative_tint", value.Tint);
        writer.WriteNumber("contrast", value.Contrast);
        writer.WriteNumber("highlights", value.Highlights);
        writer.WriteNumber("shadows", value.Shadows);
        writer.WriteNumber("saturation", value.Saturation);
        writer.WritePropertyName("geometry");
        JsonSerializer.Serialize(writer, value.Geometry, GeometryOptions);
        writer.WriteEndObject();
    }
}
