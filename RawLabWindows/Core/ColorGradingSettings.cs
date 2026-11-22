using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum ColorGradingZone { Shadows, Midtones, Highlights }

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ColorGradingWheel
{
    [JsonRequired] public double Hue { get; init; }
    [JsonRequired] public double Saturation { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] public double Luminance { get; init; }
    public ColorGradingWheel() { }
    public ColorGradingWheel(double hue, double saturation, double luminance = 0) { Hue = hue; Saturation = saturation; Luminance = luminance; }
    [JsonIgnore] public bool IsDefault => Hue == 0 && Saturation == 0 && Luminance == 0;
    [JsonIgnore] public bool IsIdentity => Saturation == 0 && Luminance == 0;
    [JsonIgnore] public bool IsValid => double.IsFinite(Hue) && Hue >= AdjustmentFieldSpec.SubFields.ColorGradingWheel.HueMin && Hue < AdjustmentFieldSpec.SubFields.ColorGradingWheel.HueMax
        && double.IsFinite(Saturation) && Saturation >= AdjustmentFieldSpec.SubFields.ColorGradingWheel.SaturationMin && Saturation <= AdjustmentFieldSpec.SubFields.ColorGradingWheel.SaturationMax
        && double.IsFinite(Luminance) && Luminance >= AdjustmentFieldSpec.SubFields.ColorGradingWheel.LuminanceMin && Luminance <= AdjustmentFieldSpec.SubFields.ColorGradingWheel.LuminanceMax;
    internal float NativeHue => (float)Hue == 360 ? 0 : (float)Hue;
    public static double? InputHue(double value) => double.IsFinite(value) && value is >= 0 and <= 360 ? value == 360 ? 0 : value : null;
    [JsonIgnore] public (double X, double Y) Point => (Math.Cos(Hue * Math.PI / 180) * Saturation / 100, Math.Sin(Hue * Math.PI / 180) * Saturation / 100);
    public ColorGradingWheel Moving(double x, double y)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y)) return this;
        var radius = Math.Sqrt(x * x + y * y);
        if (radius == 0) return this with { Saturation = 0 };
        var angle = Math.Atan2(y, x) * 180 / Math.PI;
        return new(angle < 0 ? (angle + 360) % 360 : angle, Math.Min(1, radius) * 100, Luminance);
    }
}

[JsonConverter(typeof(ColorGradingSettingsJsonConverter))]
public sealed record ColorGradingSettings
{
    public ColorGradingWheel Shadows { get; init; } = new();
    public ColorGradingWheel Midtones { get; init; } = new();
    public ColorGradingWheel Highlights { get; init; } = new();
    public ColorGradingWheel Global { get; init; } = new();
    public double Blending { get; init; } = 50.0;
    public double Balance { get; init; }
    [JsonIgnore] public bool IsDefault => IsValid && Shadows.IsDefault && Midtones.IsDefault && Highlights.IsDefault && Global.IsDefault && Blending == 50.0 && Balance == 0.0;
    [JsonIgnore] public bool IsIdentity => IsValid && Shadows.IsIdentity && Midtones.IsIdentity && Highlights.IsIdentity && Global.IsIdentity;
    [JsonIgnore] public bool IsValid => Shadows?.IsValid == true && Midtones?.IsValid == true && Highlights?.IsValid == true && Global?.IsValid == true &&
        double.IsFinite(Blending) && Blending is >= 0 and <= 100 && double.IsFinite(Balance) && Balance is >= -100 and <= 100;
    [JsonIgnore] public bool HasV2Extensions => !Global.IsDefault || Blending != 50.0 || Balance != 0.0 ||
        Shadows.Luminance != 0.0 || Midtones.Luminance != 0.0 || Highlights.Luminance != 0.0;
    [JsonIgnore] public double Progress => new[] {
        Shadows.Saturation, Midtones.Saturation, Highlights.Saturation, Global.Saturation,
        Math.Abs(Shadows.Luminance), Math.Abs(Midtones.Luminance), Math.Abs(Highlights.Luminance), Math.Abs(Global.Luminance)
    }.Max() / 100;
    public ColorGradingSettings Scaled(double strength) => this with {
        Shadows = Shadows with { Saturation = Math.Clamp(Shadows.Saturation * strength, 0, 100), Luminance = Math.Clamp(Shadows.Luminance * strength, -100, 100) },
        Midtones = Midtones with { Saturation = Math.Clamp(Midtones.Saturation * strength, 0, 100), Luminance = Math.Clamp(Midtones.Luminance * strength, -100, 100) },
        Highlights = Highlights with { Saturation = Math.Clamp(Highlights.Saturation * strength, 0, 100), Luminance = Math.Clamp(Highlights.Luminance * strength, -100, 100) },
        Global = Global with { Saturation = Math.Clamp(Global.Saturation * strength, 0, 100), Luminance = Math.Clamp(Global.Luminance * strength, -100, 100) }
    };
    public ColorGradingWheel this[ColorGradingZone zone] => zone switch {
        ColorGradingZone.Shadows => Shadows, ColorGradingZone.Midtones => Midtones, ColorGradingZone.Highlights => Highlights,
        _ => throw new ArgumentOutOfRangeException(nameof(zone))
    };
    public ColorGradingSettings With(ColorGradingZone zone, ColorGradingWheel wheel) => zone switch {
        ColorGradingZone.Shadows => this with { Shadows = wheel }, ColorGradingZone.Midtones => this with { Midtones = wheel },
        ColorGradingZone.Highlights => this with { Highlights = wheel }, _ => throw new ArgumentOutOfRangeException(nameof(zone))
    };
    internal Native.ColorGradingConfig NativeConfig()
    {
        if (!IsValid) throw new ArgumentOutOfRangeException(nameof(ColorGradingSettings), Loc.Text("无效的颜色分级参数"));
        return new() { Version = 1, StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ColorGradingConfig>(),
            ShadowsHue = Shadows.NativeHue, ShadowsSaturation = (float)Shadows.Saturation,
            MidtonesHue = Midtones.NativeHue, MidtonesSaturation = (float)Midtones.Saturation,
            HighlightsHue = Highlights.NativeHue, HighlightsSaturation = (float)Highlights.Saturation };
    }
}

public sealed class ColorGradingSettingsJsonConverter : JsonConverter<ColorGradingSettings>
{
    public override ColorGradingSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid grading settings");
        string Name(string pascal) => options.PropertyNamingPolicy?.ConvertName(pascal) ?? pascal;
        var shadowsKey = Name("Shadows");
        var midtonesKey = Name("Midtones");
        var highlightsKey = Name("Highlights");
        var globalKey = Name("Global");
        var blendingKey = Name("Blending");
        var balanceKey = Name("Balance");
        var required = new HashSet<string>(StringComparer.Ordinal) { shadowsKey, midtonesKey, highlightsKey };
        var allowed = new HashSet<string>(StringComparer.Ordinal) { shadowsKey, midtonesKey, highlightsKey, globalKey, blendingKey, balanceKey };
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var prop in root.EnumerateObject())
        {
            if (!allowed.Contains(prop.Name) || !seen.Add(prop.Name))
                throw new JsonException("Invalid grading field: " + prop.Name);
        }
        if (!required.IsSubsetOf(seen)) throw new JsonException("Missing required grading zone");
        ColorGradingWheel ReadWheel(string key) => root.GetProperty(key).Deserialize<ColorGradingWheel>(options)
            ?? throw new JsonException("Null grading wheel");
        var result = new ColorGradingSettings {
            Shadows = ReadWheel(shadowsKey),
            Midtones = ReadWheel(midtonesKey),
            Highlights = ReadWheel(highlightsKey),
            Global = root.TryGetProperty(globalKey, out var gEl) ? gEl.Deserialize<ColorGradingWheel>(options) ?? throw new JsonException("Null global wheel") : new(),
            Blending = root.TryGetProperty(blendingKey, out var blEl) ? blEl.GetDouble() : 50.0,
            Balance = root.TryGetProperty(balanceKey, out var baEl) ? baEl.GetDouble() : 0.0
        };
        if (!result.IsValid) throw new JsonException("Invalid grading values");
        return result;
    }

    public override void Write(Utf8JsonWriter writer, ColorGradingSettings value, JsonSerializerOptions options)
    {
        string Name(string pascal) => options.PropertyNamingPolicy?.ConvertName(pascal) ?? pascal;
        writer.WriteStartObject();
        writer.WritePropertyName(Name("Shadows")); JsonSerializer.Serialize(writer, value.Shadows, options);
        writer.WritePropertyName(Name("Midtones")); JsonSerializer.Serialize(writer, value.Midtones, options);
        writer.WritePropertyName(Name("Highlights")); JsonSerializer.Serialize(writer, value.Highlights, options);
        if (!value.Global.IsDefault) { writer.WritePropertyName(Name("Global")); JsonSerializer.Serialize(writer, value.Global, options); }
        if (value.Blending != 50.0) writer.WriteNumber(Name("Blending"), value.Blending);
        if (value.Balance != 0.0) writer.WriteNumber(Name("Balance"), value.Balance);
        writer.WriteEndObject();
    }
}

public sealed record ColorGradingDrag(ColorGradingWheel Initial, double X, double Y, bool Fine)
{
    public ColorGradingWheel Value(double x, double y)
    {
        if (!Fine) return Initial.Moving(x, y);
        if (x == X && y == Y) return Initial;
        return Initial.Moving(Initial.Point.X + (x - X) * .25, Initial.Point.Y + (y - Y) * .25);
    }
}
