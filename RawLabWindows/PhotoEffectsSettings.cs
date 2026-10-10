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
        return Math.Clamp(Math.Round(Min + position * (Max - Min), MidpointRounding.AwayFromZero), Min, Max);
    }

    public double? Parse(string text) => double.TryParse(text, System.Globalization.NumberStyles.Float,
        System.Globalization.CultureInfo.CurrentCulture, out var value) && double.IsFinite(value)
        ? Math.Clamp(value, Min, Max) : null;

    public static readonly PhotoEffectSpec[] All = [
        new(PhotoEffectParameter.VignetteAmount, "强度", true, -100, 100, 0),
        new(PhotoEffectParameter.VignetteMidpoint, "中点", true, 0, 100, 50),
        new(PhotoEffectParameter.VignetteRoundness, "圆度", true, -100, 100, 0),
        new(PhotoEffectParameter.VignetteFeather, "羽化", true, 0, 100, 50),
        new(PhotoEffectParameter.VignetteHighlights, "高光保护", true, 0, 100, 0),
        new(PhotoEffectParameter.GrainAmount, "强度", false, 0, 100, 0),
        new(PhotoEffectParameter.GrainSize, "大小", false, 0, 100, 25),
        new(PhotoEffectParameter.GrainRoughness, "粗糙度", false, 0, 100, 50)
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
    double GrainRoughness = 50)
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
        Validate(VignetteAmount, -100, 100, nameof(VignetteAmount));
        Validate(VignetteMidpoint, 0, 100, nameof(VignetteMidpoint));
        Validate(VignetteRoundness, -100, 100, nameof(VignetteRoundness));
        Validate(VignetteFeather, 0, 100, nameof(VignetteFeather));
        Validate(VignetteHighlights, 0, 100, nameof(VignetteHighlights));
        Validate(GrainAmount, 0, 100, nameof(GrainAmount));
        Validate(GrainSize, 0, 100, nameof(GrainSize));
        Validate(GrainRoughness, 0, 100, nameof(GrainRoughness));
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
}
