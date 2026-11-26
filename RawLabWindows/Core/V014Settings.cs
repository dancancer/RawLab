using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

[JsonConverter(typeof(GrainToneCurveJsonConverter))]
public enum GrainToneCurve { Legacy = 0, NegativeAsymmetric = 1 }

public sealed class GrainToneCurveJsonConverter : JsonConverter<GrainToneCurve>
{
    public override GrainToneCurve Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "legacy" => GrainToneCurve.Legacy,
            "negative_asymmetric" => GrainToneCurve.NegativeAsymmetric,
            _ => throw new JsonException("Invalid GrainToneCurve")
        } : throw new JsonException("Invalid GrainToneCurve");

    public override void Write(Utf8JsonWriter writer, GrainToneCurve value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.WireValue());
}

public static class GrainToneCurveExtensions
{
    public static string WireValue(this GrainToneCurve value) => value switch
    {
        GrainToneCurve.Legacy => "legacy",
        GrainToneCurve.NegativeAsymmetric => "negative_asymmetric",
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };

    public static GrainToneCurve ParseGrainToneCurve(string? value) => value switch
    {
        null or "legacy" => GrainToneCurve.Legacy,
        "negative_asymmetric" => GrainToneCurve.NegativeAsymmetric,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };
}

[JsonConverter(typeof(GrainFormatPresetJsonConverter))]
public enum GrainFormatPreset { Custom = 0, Film135 = 1, Film120 = 2 }

public sealed class GrainFormatPresetJsonConverter : JsonConverter<GrainFormatPreset>
{
    public override GrainFormatPreset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "custom" => GrainFormatPreset.Custom,
            "135" => GrainFormatPreset.Film135,
            "120" => GrainFormatPreset.Film120,
            _ => throw new JsonException("Invalid GrainFormatPreset")
        } : throw new JsonException("Invalid GrainFormatPreset");

    public override void Write(Utf8JsonWriter writer, GrainFormatPreset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.WireValue());
}

public static class GrainFormatPresetExtensions
{
    public static string WireValue(this GrainFormatPreset value) => value switch
    {
        GrainFormatPreset.Custom => "custom",
        GrainFormatPreset.Film135 => "135",
        GrainFormatPreset.Film120 => "120",
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };

    public static GrainFormatPreset ParseGrainFormatPreset(string? value) => value switch
    {
        null or "custom" => GrainFormatPreset.Custom,
        "135" => GrainFormatPreset.Film135,
        "120" => GrainFormatPreset.Film120,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };
}

public sealed record CameraCalibrationSettings(
    [property: JsonPropertyName("shadowTint")] double ShadowTint = 0,
    [property: JsonPropertyName("redHue")] double RedHue = 0,
    [property: JsonPropertyName("redSaturation")] double RedSaturation = 0,
    [property: JsonPropertyName("greenHue")] double GreenHue = 0,
    [property: JsonPropertyName("greenSaturation")] double GreenSaturation = 0,
    [property: JsonPropertyName("blueHue")] double BlueHue = 0,
    [property: JsonPropertyName("blueSaturation")] double BlueSaturation = 0)
{
    [JsonIgnore]
    public bool IsDefault => ShadowTint == 0 && RedHue == 0 && RedSaturation == 0 &&
        GreenHue == 0 && GreenSaturation == 0 && BlueHue == 0 && BlueSaturation == 0;

    public void Validate()
    {
        var m = AdjustmentFieldSpec.Fields.ColorCalibrationShadowTint.WindowsModel;
        double min = m.Min!.Value, max = m.Max!.Value;
        foreach (var v in new[] { ShadowTint, RedHue, RedSaturation, GreenHue, GreenSaturation, BlueHue, BlueSaturation })
        {
            if (!double.IsFinite(v) || v < min || v > max)
                throw new ArgumentOutOfRangeException(nameof(CameraCalibrationSettings), $"Calibration value {v} out of [{min}, {max}]");
        }
    }
}

public sealed record PointColorSwatch(
    [property: JsonPropertyName("srcHue")] double SrcHue = 0,
    [property: JsonPropertyName("srcSaturation")] double SrcSaturation = 0.5,
    [property: JsonPropertyName("srcLuminance")] double SrcLuminance = 0.5,
    [property: JsonPropertyName("hueShift")] double HueShift = 0,
    [property: JsonPropertyName("saturationShift")] double SaturationShift = 0,
    [property: JsonPropertyName("luminanceShift")] double LuminanceShift = 0,
    [property: JsonPropertyName("range")] double Range = 50,
    [property: JsonPropertyName("hueRange")] double HueRange = 50,
    [property: JsonPropertyName("satRange")] double SatRange = 50,
    [property: JsonPropertyName("lumRange")] double LumRange = 50,
    [property: JsonPropertyName("variance")] double Variance = 0,
    [property: JsonPropertyName("enabled")] bool Enabled = true)
{
    public void Validate()
    {
        if (!double.IsFinite(SrcHue) || SrcHue < AdjustmentFieldSpec.SubFields.PointColor.SrcHueMin ||
            SrcHue >= AdjustmentFieldSpec.SubFields.PointColor.SrcHueMax)
            throw new ArgumentOutOfRangeException(nameof(SrcHue));
        if (!double.IsFinite(SrcSaturation) || SrcSaturation < AdjustmentFieldSpec.SubFields.PointColor.SrcSaturationMin ||
            SrcSaturation > AdjustmentFieldSpec.SubFields.PointColor.SrcSaturationMax)
            throw new ArgumentOutOfRangeException(nameof(SrcSaturation));
        if (!double.IsFinite(SrcLuminance) || SrcLuminance < AdjustmentFieldSpec.SubFields.PointColor.SrcLuminanceMin ||
            SrcLuminance > AdjustmentFieldSpec.SubFields.PointColor.SrcLuminanceMax)
            throw new ArgumentOutOfRangeException(nameof(SrcLuminance));
        foreach (var v in new[] { HueShift, SaturationShift, LuminanceShift, Variance })
            if (!double.IsFinite(v) || v < AdjustmentFieldSpec.SubFields.PointColor.ShiftMin ||
                v > AdjustmentFieldSpec.SubFields.PointColor.ShiftMax)
                throw new ArgumentOutOfRangeException(nameof(PointColorSwatch));
        foreach (var v in new[] { Range, HueRange, SatRange, LumRange })
            if (!double.IsFinite(v) || v < AdjustmentFieldSpec.SubFields.PointColor.RangeControlMin ||
                v > AdjustmentFieldSpec.SubFields.PointColor.RangeControlMax)
                throw new ArgumentOutOfRangeException(nameof(PointColorSwatch));
    }
}

public sealed record PointColorSettings : IEquatable<PointColorSettings>
{
    [JsonPropertyName("swatches")]
    public IReadOnlyList<PointColorSwatch> Swatches { get; init; }

    public PointColorSettings() : this([]) { }

    [JsonConstructor]
    public PointColorSettings(IReadOnlyList<PointColorSwatch>? swatches)
    {
        Swatches = swatches?.ToArray() ?? [];
    }

    [JsonIgnore]
    public bool IsDefault => Swatches.Count == 0;

    public void Validate()
    {
        if (Swatches.Count > AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches)
            throw new ArgumentOutOfRangeException(nameof(Swatches), "Too many point color swatches");
        foreach (var swatch in Swatches) swatch.Validate();
    }

    public bool Equals(PointColorSettings? other) =>
        other != null && Swatches.SequenceEqual(other.Swatches);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var swatch in Swatches) hash.Add(swatch);
        return hash.ToHashCode();
    }
}

[JsonConverter(typeof(SelectiveColorMethodJsonConverter))]
public enum SelectiveColorMethod { Relative = 0, Absolute = 1 }

public sealed class SelectiveColorMethodJsonConverter : JsonConverter<SelectiveColorMethod>
{
    public override SelectiveColorMethod Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch
        {
            "relative" => SelectiveColorMethod.Relative,
            "absolute" => SelectiveColorMethod.Absolute,
            _ => throw new JsonException("Invalid SelectiveColorMethod")
        } : throw new JsonException("Invalid SelectiveColorMethod");

    public override void Write(Utf8JsonWriter writer, SelectiveColorMethod value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.WireValue());
}

public static class SelectiveColorMethodExtensions
{
    public static string WireValue(this SelectiveColorMethod value) => value switch
    {
        SelectiveColorMethod.Relative => "relative",
        SelectiveColorMethod.Absolute => "absolute",
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };

    public static SelectiveColorMethod ParseSelectiveColorMethod(string? value) => value switch
    {
        null or "relative" => SelectiveColorMethod.Relative,
        "absolute" => SelectiveColorMethod.Absolute,
        _ => throw new ArgumentOutOfRangeException(nameof(value))
    };
}

public sealed record SelectiveColorBand(
    [property: JsonPropertyName("cyan")] double Cyan = 0,
    [property: JsonPropertyName("magenta")] double Magenta = 0,
    [property: JsonPropertyName("yellow")] double Yellow = 0,
    [property: JsonPropertyName("black")] double Black = 0)
{
    [JsonIgnore]
    public bool IsDefault => Cyan == 0 && Magenta == 0 && Yellow == 0 && Black == 0;

    public void Validate()
    {
        foreach (var v in new[] { Cyan, Magenta, Yellow, Black })
            if (!double.IsFinite(v) || v < AdjustmentFieldSpec.SubFields.SelectiveColor.ComponentMin ||
                v > AdjustmentFieldSpec.SubFields.SelectiveColor.ComponentMax)
                throw new ArgumentOutOfRangeException(nameof(SelectiveColorBand));
    }
}

public sealed record SelectiveColorBands
{
    [JsonPropertyName("reds")] public SelectiveColorBand Reds { get; init; } = new();
    [JsonPropertyName("yellows")] public SelectiveColorBand Yellows { get; init; } = new();
    [JsonPropertyName("greens")] public SelectiveColorBand Greens { get; init; } = new();
    [JsonPropertyName("cyans")] public SelectiveColorBand Cyans { get; init; } = new();
    [JsonPropertyName("blues")] public SelectiveColorBand Blues { get; init; } = new();
    [JsonPropertyName("magentas")] public SelectiveColorBand Magentas { get; init; } = new();
    [JsonPropertyName("whites")] public SelectiveColorBand Whites { get; init; } = new();
    [JsonPropertyName("neutrals")] public SelectiveColorBand Neutrals { get; init; } = new();
    [JsonPropertyName("blacks")] public SelectiveColorBand Blacks { get; init; } = new();

    [JsonIgnore]
    public bool IsDefault => Reds.IsDefault && Yellows.IsDefault && Greens.IsDefault &&
        Cyans.IsDefault && Blues.IsDefault && Magentas.IsDefault &&
        Whites.IsDefault && Neutrals.IsDefault && Blacks.IsDefault;

    public void Validate()
    {
        foreach (var band in new[] { Reds, Yellows, Greens, Cyans, Blues, Magentas, Whites, Neutrals, Blacks })
            (band ?? throw new ArgumentNullException(nameof(SelectiveColorBands))).Validate();
    }

    public IReadOnlyDictionary<string, SelectiveColorBand> AsMap() => new Dictionary<string, SelectiveColorBand>
    {
        ["reds"] = Reds, ["yellows"] = Yellows, ["greens"] = Greens,
        ["cyans"] = Cyans, ["blues"] = Blues, ["magentas"] = Magentas,
        ["whites"] = Whites, ["neutrals"] = Neutrals, ["blacks"] = Blacks
    };
}

public sealed record SelectiveColorSettings
{
    [JsonPropertyName("method")]
    public SelectiveColorMethod Method { get; init; } = SelectiveColorMethod.Relative;

    [JsonPropertyName("bands")]
    public SelectiveColorBands Bands { get; init; } = new();

    public SelectiveColorSettings() { }

    public SelectiveColorSettings(SelectiveColorMethod method, SelectiveColorBands? bands = null)
    {
        Method = method;
        Bands = bands ?? new();
    }

    [JsonIgnore]
    public bool IsDefault => Method == SelectiveColorMethod.Relative && Bands.IsDefault;

    public void Validate()
    {
        if (!Enum.IsDefined(Method)) throw new ArgumentOutOfRangeException(nameof(Method));
        (Bands ?? throw new ArgumentNullException(nameof(Bands))).Validate();
    }
}

public sealed record BwMixerWeights(
    [property: JsonPropertyName("red")] double Red = 0,
    [property: JsonPropertyName("orange")] double Orange = 0,
    [property: JsonPropertyName("yellow")] double Yellow = 0,
    [property: JsonPropertyName("green")] double Green = 0,
    [property: JsonPropertyName("aqua")] double Aqua = 0,
    [property: JsonPropertyName("blue")] double Blue = 0,
    [property: JsonPropertyName("purple")] double Purple = 0,
    [property: JsonPropertyName("magenta")] double Magenta = 0)
{
    [JsonIgnore]
    public bool IsDefault => Red == 0 && Orange == 0 && Yellow == 0 && Green == 0 &&
        Aqua == 0 && Blue == 0 && Purple == 0 && Magenta == 0;

    public void Validate()
    {
        foreach (var v in new[] { Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta })
            if (!double.IsFinite(v) || v < AdjustmentFieldSpec.SubFields.BwMixer.ChannelMin ||
                v > AdjustmentFieldSpec.SubFields.BwMixer.ChannelMax)
                throw new ArgumentOutOfRangeException(nameof(BwMixerWeights));
    }

    public IReadOnlyDictionary<string, double> AsMap() => new Dictionary<string, double>
    {
        ["red"] = Red, ["orange"] = Orange, ["yellow"] = Yellow, ["green"] = Green,
        ["aqua"] = Aqua, ["blue"] = Blue, ["purple"] = Purple, ["magenta"] = Magenta
    };
}

public sealed record BwMixerSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; init; }

    [JsonPropertyName("mixer")]
    public BwMixerWeights Mixer { get; init; } = new();

    public BwMixerSettings() { }

    public BwMixerSettings(bool enabled, BwMixerWeights? mixer = null)
    {
        Enabled = enabled;
        Mixer = mixer ?? new();
    }

    [JsonIgnore]
    public bool IsDefault => !Enabled && Mixer.IsDefault;

    public void Validate()
    {
        (Mixer ?? throw new ArgumentNullException(nameof(Mixer))).Validate();
    }
}

public sealed record SharpenV2Settings(
    [property: JsonPropertyName("luminanceV2")] bool LuminanceV2 = false,
    [property: JsonPropertyName("radius")] double Radius = 1.0,
    [property: JsonPropertyName("detail")] double Detail = 25.0,
    [property: JsonPropertyName("masking")] double Masking = 0.0)
{
    [JsonIgnore]
    public bool IsDefault => !LuminanceV2 && Radius == 1.0 && Detail == 25.0 && Masking == 0.0;

    public void Validate()
    {
        CheckRange(Radius, AdjustmentFieldSpec.Fields.DetailSharpeningRadius.WindowsModel, nameof(Radius));
        CheckRange(Detail, AdjustmentFieldSpec.Fields.DetailSharpeningDetail.WindowsModel, nameof(Detail));
        CheckRange(Masking, AdjustmentFieldSpec.Fields.DetailSharpeningMasking.WindowsModel, nameof(Masking));
    }

    private static void CheckRange(double v, AdjustmentFieldModelSpec m, string name)
    {
        if (!double.IsFinite(v) || v < m.Min!.Value || v > m.Max!.Value)
            throw new ArgumentOutOfRangeException(name);
    }
}

public sealed record FilmOpticsSettings(
    [property: JsonPropertyName("halationAmount")] double HalationAmount = 0,
    [property: JsonPropertyName("halationThreshold")] double HalationThreshold = 75,
    [property: JsonPropertyName("halationRadius")] double HalationRadius = 35,
    [property: JsonPropertyName("halationHue")] double HalationHue = 0,
    [property: JsonPropertyName("bloomAmount")] double BloomAmount = 0,
    [property: JsonPropertyName("bloomThreshold")] double BloomThreshold = 70,
    [property: JsonPropertyName("bloomRadius")] double BloomRadius = 40)
{
    [JsonIgnore]
    public bool IsDefault => HalationAmount == 0 && HalationThreshold == 75 && HalationRadius == 35 &&
        HalationHue == 0 && BloomAmount == 0 && BloomThreshold == 70 && BloomRadius == 40;

    [JsonIgnore]
    public bool IsHalationDefault => HalationAmount == 0 && HalationThreshold == 75 && HalationRadius == 35 && HalationHue == 0;

    [JsonIgnore]
    public bool IsBloomDefault => BloomAmount == 0 && BloomThreshold == 70 && BloomRadius == 40;

    public FilmOpticsSettings ResetHalation() => this with { HalationAmount = 0, HalationThreshold = 75, HalationRadius = 35, HalationHue = 0 };
    public FilmOpticsSettings ResetBloom() => this with { BloomAmount = 0, BloomThreshold = 70, BloomRadius = 40 };

    public void Validate()
    {
        CheckRange(HalationAmount, AdjustmentFieldSpec.Fields.EffectsHalationAmount.WindowsModel, nameof(HalationAmount));
        CheckRange(HalationThreshold, AdjustmentFieldSpec.Fields.EffectsHalationThreshold.WindowsModel, nameof(HalationThreshold));
        CheckRange(HalationRadius, AdjustmentFieldSpec.Fields.EffectsHalationRadius.WindowsModel, nameof(HalationRadius));
        CheckRange(HalationHue, AdjustmentFieldSpec.Fields.EffectsHalationHue.WindowsModel, nameof(HalationHue));
        CheckRange(BloomAmount, AdjustmentFieldSpec.Fields.EffectsBloomAmount.WindowsModel, nameof(BloomAmount));
        CheckRange(BloomThreshold, AdjustmentFieldSpec.Fields.EffectsBloomThreshold.WindowsModel, nameof(BloomThreshold));
        CheckRange(BloomRadius, AdjustmentFieldSpec.Fields.EffectsBloomRadius.WindowsModel, nameof(BloomRadius));
    }

    private static void CheckRange(double v, AdjustmentFieldModelSpec m, string name)
    {
        if (!double.IsFinite(v) || v < m.Min!.Value || v > m.Max!.Value)
            throw new ArgumentOutOfRangeException(name);
    }
}
