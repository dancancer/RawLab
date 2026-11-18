using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum ColorGradingZone { Shadows, Midtones, Highlights }

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ColorGradingWheel
{
    [JsonRequired] public double Hue { get; init; }
    [JsonRequired] public double Saturation { get; init; }
    public ColorGradingWheel() { }
    public ColorGradingWheel(double hue, double saturation) { Hue = hue; Saturation = saturation; }
    [JsonIgnore] public bool IsDefault => Hue == 0 && Saturation == 0;
    [JsonIgnore] public bool IsIdentity => Saturation == 0;
    [JsonIgnore] public bool IsValid => double.IsFinite(Hue) && Hue is >= 0 and < 360
        && double.IsFinite(Saturation) && Saturation is >= 0 and <= 100;
    internal float NativeHue => (float)Hue == 360 ? 0 : (float)Hue;
    public static double? InputHue(double value) => double.IsFinite(value) && value is >= 0 and <= 360 ? value == 360 ? 0 : value : null;
    [JsonIgnore] public (double X, double Y) Point => (Math.Cos(Hue * Math.PI / 180) * Saturation / 100, Math.Sin(Hue * Math.PI / 180) * Saturation / 100);
    public ColorGradingWheel Moving(double x, double y)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y)) return this;
        var radius = Math.Sqrt(x * x + y * y);
        if (radius == 0) return this with { Saturation = 0 };
        var angle = Math.Atan2(y, x) * 180 / Math.PI;
        return new(angle < 0 ? (angle + 360) % 360 : angle, Math.Min(1, radius) * 100);
    }
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ColorGradingSettings
{
    [JsonRequired] public ColorGradingWheel Shadows { get; init; } = new();
    [JsonRequired] public ColorGradingWheel Midtones { get; init; } = new();
    [JsonRequired] public ColorGradingWheel Highlights { get; init; } = new();
    [JsonIgnore] public bool IsDefault => IsValid && Shadows.IsDefault && Midtones.IsDefault && Highlights.IsDefault;
    [JsonIgnore] public bool IsIdentity => IsValid && Shadows.IsIdentity && Midtones.IsIdentity && Highlights.IsIdentity;
    [JsonIgnore] public bool IsValid => Shadows?.IsValid == true && Midtones?.IsValid == true && Highlights?.IsValid == true;
    [JsonIgnore] public double Progress => Math.Max(Shadows.Saturation, Math.Max(Midtones.Saturation, Highlights.Saturation)) / 100;
    public ColorGradingSettings Scaled(double strength) => this with {
        Shadows = Shadows with { Saturation = Math.Clamp(Shadows.Saturation * strength, 0, 100) },
        Midtones = Midtones with { Saturation = Math.Clamp(Midtones.Saturation * strength, 0, 100) },
        Highlights = Highlights with { Saturation = Math.Clamp(Highlights.Saturation * strength, 0, 100) }
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

public sealed record ColorGradingDrag(ColorGradingWheel Initial, double X, double Y, bool Fine)
{
    public ColorGradingWheel Value(double x, double y)
    {
        if (!Fine) return Initial.Moving(x, y);
        if (x == X && y == Y) return Initial;
        return Initial.Moving(Initial.Point.X + (x - X) * .25, Initial.Point.Y + (y - Y) * .25);
    }
}
