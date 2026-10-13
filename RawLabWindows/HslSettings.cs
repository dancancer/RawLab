using System.Runtime.InteropServices;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public sealed class HslSettings : IEquatable<HslSettings>
{
    private readonly double[] values;
    public double[] Values => (double[])values.Clone();
    [JsonIgnore] public bool IsIdentity => values.All(value => value == 0);
    public HslSettings() : this(new double[24]) { }
    [JsonConstructor]
    public HslSettings(double[] values)
    {
        if (values.Length != 24 || values.Any(value => !double.IsFinite(value) || value is < -100 or > 100))
            throw new ArgumentException(Loc.Text("HSL 参数无效。"), nameof(values));
        this.values = (double[])values.Clone();
    }
    public double Value(int axis, int channel) => values[axis * 8 + channel];
    public HslSettings Scaled(double strength) => new(values.Select(value => Math.Clamp(value * strength, -100, 100)).ToArray());
    public HslSettings WithValue(int axis, int channel, double value)
    {
        if (axis is < 0 or > 2 || channel is < 0 or > 7 || !double.IsFinite(value))
            throw new ArgumentOutOfRangeException(nameof(value));
        var copy = Values;
        copy[axis * 8 + channel] = Math.Clamp(value, -100, 100);
        return new HslSettings(copy);
    }
    public bool Equals(HslSettings? other) => other != null && values.SequenceEqual(other.values);
    public override bool Equals(object? other) => other is HslSettings settings && Equals(settings);
    public override int GetHashCode() { var hash = new HashCode(); foreach (var value in values) hash.Add(value); return hash.ToHashCode(); }
    internal Native.HslConfig NativeConfig() => new() {
        Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HslConfig>(),
        Hue = values.Take(8).Select(value => (float)value).ToArray(),
        Saturation = values.Skip(8).Take(8).Select(value => (float)value).ToArray(),
        Lightness = values.Skip(16).Take(8).Select(value => (float)value).ToArray()
    };
}
