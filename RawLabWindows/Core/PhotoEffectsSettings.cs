using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum PhotoEffectParameter
{
    VignetteAmount,
    VignetteMidpoint,
    VignetteRoundness,
    VignetteFeather,
    VignetteHighlights,
    GrainAmount,
    GrainSize,
    GrainRoughness
}

public sealed record PhotoEffectSpec(
    PhotoEffectParameter Id,
    string Title,
    bool IsVignette,
    double Min,
    double Max,
    double DefaultValue)
{
    public double Position(double value) => (value - Min) / (Max - Min);

    public double Value(double position)
    {
        position = Math.Clamp(position, 0, 1);
        return Math.Clamp(Math.Round(Min + position * (Max - Min), 1, MidpointRounding.AwayFromZero), Min, Max);
    }

    public double? Parse(string text) => double.TryParse(text, System.Globalization.NumberStyles.Float,
        System.Globalization.CultureInfo.GetCultureInfo(Loc.Language), out var value) && double.IsFinite(value)
        ? Math.Clamp(Math.Round(value,1,MidpointRounding.AwayFromZero), Min, Max) : null;

    public static readonly PhotoEffectSpec[] All = [
        new(PhotoEffectParameter.VignetteAmount, Loc.Text("强度"), true, AdjustmentFieldSpec.Fields.EffectsVignetteAmount.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteAmount.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteAmount.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.VignetteMidpoint, Loc.Text("中点"), true, AdjustmentFieldSpec.Fields.EffectsVignetteMidpoint.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteMidpoint.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteMidpoint.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.VignetteRoundness, Loc.Text("圆度"), true, AdjustmentFieldSpec.Fields.EffectsVignetteRoundness.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteRoundness.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteRoundness.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.VignetteFeather, Loc.Text("羽化"), true, AdjustmentFieldSpec.Fields.EffectsVignetteFeather.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteFeather.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteFeather.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.VignetteHighlights, Loc.Text("高光保护"), true, AdjustmentFieldSpec.Fields.EffectsVignetteHighlights.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteHighlights.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsVignetteHighlights.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.GrainAmount, Loc.Text("强度"), false, AdjustmentFieldSpec.Fields.EffectsGrainAmount.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsGrainAmount.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsGrainAmount.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.GrainSize, Loc.Text("大小"), false, AdjustmentFieldSpec.Fields.EffectsGrainSize.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsGrainSize.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsGrainSize.WindowsModel.DefaultNumber!.Value),
        new(PhotoEffectParameter.GrainRoughness, Loc.Text("粗糙度"), false, AdjustmentFieldSpec.Fields.EffectsGrainRoughness.WindowsModel.Min!.Value, AdjustmentFieldSpec.Fields.EffectsGrainRoughness.WindowsModel.Max!.Value, AdjustmentFieldSpec.Fields.EffectsGrainRoughness.WindowsModel.DefaultNumber!.Value)
    ];

    public static PhotoEffectSpec For(PhotoEffectParameter parameter) => All[(int)parameter];
}

// Kept separate from the ten-item Parameter array so existing request and UI
// indexes remain stable while all effect values persist as one immutable state.
public sealed record PhotoEffectsSettings(
    double VignetteAmount = 0,
    double VignetteMidpoint = 50,
    double VignetteRoundness = 0,
    double VignetteFeather = 50,
    double VignetteHighlights = 0,
    double GrainAmount = 0,
    double GrainSize = 25,
    double GrainRoughness = 50,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] GrainToneCurve GrainToneCurve = GrainToneCurve.Legacy,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] GrainFormatPreset GrainFormatPreset = GrainFormatPreset.Custom)
{
    public static PhotoEffectsSettings Default => new();

    public double this[PhotoEffectParameter parameter] => parameter switch {
        PhotoEffectParameter.VignetteAmount => VignetteAmount,
        PhotoEffectParameter.VignetteMidpoint => VignetteMidpoint,
        PhotoEffectParameter.VignetteRoundness => VignetteRoundness,
        PhotoEffectParameter.VignetteFeather => VignetteFeather,
        PhotoEffectParameter.VignetteHighlights => VignetteHighlights,
        PhotoEffectParameter.GrainAmount => GrainAmount,
        PhotoEffectParameter.GrainSize => GrainSize,
        PhotoEffectParameter.GrainRoughness => GrainRoughness,
        _ => throw new ArgumentOutOfRangeException(nameof(parameter))
    };

    internal Native.PhotoEffectsConfig NativeConfig()
    {
        foreach (var param in Enum.GetValues<PhotoEffectParameter>())
        {
            var spec = PhotoEffectSpec.For(param);
            Validate(this[param], spec.Min, spec.Max, param.ToString());
        }
        if (!Enum.IsDefined(GrainToneCurve))
            throw new ArgumentOutOfRangeException(nameof(GrainToneCurve));
        if (!Enum.IsDefined(GrainFormatPreset))
            throw new ArgumentOutOfRangeException(nameof(GrainFormatPreset));
        return new() {
            Version = 1,
            StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.PhotoEffectsConfig>(),
            VignetteAmount = (float)VignetteAmount,
            VignetteMidpoint = (float)VignetteMidpoint,
            VignetteRoundness = (float)VignetteRoundness,
            VignetteFeather = (float)VignetteFeather,
            VignetteHighlights = (float)VignetteHighlights,
            GrainAmount = (float)GrainAmount,
            GrainSize = (float)GrainSize,
            GrainRoughness = (float)GrainRoughness
        };
    }

    private static void Validate(double value, double min, double max, string name)
    {
        if (!double.IsFinite(value) || value < min || value > max)
            throw new ArgumentOutOfRangeException(name, $"{name} must be finite and between {min} and {max}.");
    }

    public PhotoEffectsSettings ApplyGrainFormatPreset(GrainFormatPreset preset) => preset switch
    {
        GrainFormatPreset.Custom => this with { GrainFormatPreset = preset },
        GrainFormatPreset.Film135 => this with { GrainFormatPreset = preset, GrainSize = 18, GrainRoughness = 65 },
        GrainFormatPreset.Film120 => this with { GrainFormatPreset = preset, GrainSize = 34, GrainRoughness = 22 },
        _ => throw new ArgumentOutOfRangeException(nameof(preset))
    };

    public PhotoEffectsSettings WithCustomPresetIfDeviated()
    {
        if (GrainFormatPreset == GrainFormatPreset.Custom) return this;
        bool matches = (GrainFormatPreset == GrainFormatPreset.Film135 && GrainSize == 18 && GrainRoughness == 65) ||
                       (GrainFormatPreset == GrainFormatPreset.Film120 && GrainSize == 34 && GrainRoughness == 22);
        return matches ? this : this with { GrainFormatPreset = GrainFormatPreset.Custom };
    }
}
