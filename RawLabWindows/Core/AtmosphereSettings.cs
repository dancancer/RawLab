using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum AtmosphereParameter { Clarity, Dehaze, Texture }
public sealed record AtmosphereSpec(AtmosphereParameter Id, string Title)
{
    public static readonly AtmosphereSpec[] All = [
        new(AtmosphereParameter.Clarity, "清晰度"), new(AtmosphereParameter.Dehaze, "去朦胧"),
        new(AtmosphereParameter.Texture, "纹理")
    ];
    public static AtmosphereSpec For(AtmosphereParameter id) => All[(int)id];
}

public sealed record AtmosphereSettings(
    double Clarity = 0,
    double Dehaze = 0,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] double Texture = 0)
{
    [JsonIgnore] public bool IsIdentity => Clarity == 0 && Dehaze == 0 && Texture == 0;
    public AtmosphereSettings Scaled(double strength) => new(
        Math.Clamp(Clarity * strength, -100, 100),
        Math.Clamp(Dehaze * strength, -100, 100),
        Texture);
    public double this[AtmosphereParameter id] => id switch {
        AtmosphereParameter.Clarity => Clarity, AtmosphereParameter.Dehaze => Dehaze,
        AtmosphereParameter.Texture => Texture,
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    public AtmosphereSettings With(AtmosphereParameter id, double value) => id switch {
        AtmosphereParameter.Clarity => this with { Clarity = value },
        AtmosphereParameter.Dehaze => this with { Dehaze = value },
        AtmosphereParameter.Texture => this with { Texture = value },
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    internal Native.AtmosphereConfig NativeConfig()
    {
        var specs = new[] {
            (Clarity, AdjustmentFieldSpec.Fields.EffectsClarity.WindowsModel),
            (Dehaze, AdjustmentFieldSpec.Fields.EffectsDehaze.WindowsModel),
            (Texture, AdjustmentFieldSpec.Fields.EffectsTexture.WindowsModel)
        };
        foreach (var (value, model) in specs)
            if (!double.IsFinite(value) || value < model.Min!.Value || value > model.Max!.Value)
                throw new ArgumentOutOfRangeException(nameof(value), Loc.Text("无效的清晰度或去朦胧参数"));
        return new() { Version = 1, StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.AtmosphereConfig>(),
            Clarity = (float)(Clarity / 100), Dehaze = (float)(Dehaze / 100) };
    }
}
