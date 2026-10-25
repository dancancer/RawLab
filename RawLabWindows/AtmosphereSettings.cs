using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum AtmosphereParameter { Clarity, Dehaze }
public sealed record AtmosphereSpec(AtmosphereParameter Id, string Title)
{
    public static readonly AtmosphereSpec[] All = [
        new(AtmosphereParameter.Clarity, "清晰度"), new(AtmosphereParameter.Dehaze, "去朦胧")
    ];
    public static AtmosphereSpec For(AtmosphereParameter id) => All[(int)id];
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record AtmosphereSettings(double Clarity = 0, double Dehaze = 0)
{
    [JsonIgnore] public bool IsIdentity => Clarity == 0 && Dehaze == 0;
    public double this[AtmosphereParameter id] => id switch {
        AtmosphereParameter.Clarity => Clarity, AtmosphereParameter.Dehaze => Dehaze,
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    public AtmosphereSettings With(AtmosphereParameter id, double value) => id switch {
        AtmosphereParameter.Clarity => this with { Clarity = value },
        AtmosphereParameter.Dehaze => this with { Dehaze = value },
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    internal Native.AtmosphereConfig NativeConfig()
    {
        foreach (var value in new[] { Clarity, Dehaze })
            if (!double.IsFinite(value) || value is < -100 or > 100)
                throw new ArgumentOutOfRangeException(nameof(value), Loc.Text("无效的清晰度或去朦胧参数"));
        return new() { Version = 1, StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.AtmosphereConfig>(),
            Clarity = (float)(Clarity / 100), Dehaze = (float)(Dehaze / 100) };
    }
}
