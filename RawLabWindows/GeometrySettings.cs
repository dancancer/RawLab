using System.Runtime.InteropServices;

namespace RawLab.Windows;

public enum CropComponent { X, Y, Width, Height }

// Coordinates refer to the canvas after rotation, flipping, perspective and straightening.
public sealed record GeometrySettings(double CropX = 0, double CropY = 0, double CropWidth = 1,
    double CropHeight = 1, int QuarterTurns = 0, bool FlipHorizontal = false,
    bool FlipVertical = false, double StraightenDegrees = 0,
    double PerspectiveHorizontal = 0, double PerspectiveVertical = 0)
{
    public bool IsIdentity => this == new GeometrySettings();
    public GeometrySettings Rotate(int turns) => this with { QuarterTurns = ((QuarterTurns + turns) % 4 + 4) % 4 };

    public GeometrySettings WithCropPercent(CropComponent component, double percent)
    {
        if (!double.IsFinite(percent)) throw new ArgumentOutOfRangeException(nameof(percent));
        const double minimum = .0001;
        var fraction = percent / 100;
        return component switch {
            CropComponent.X => this with { CropX = Math.Clamp(fraction, 0, 1 - minimum),
                CropWidth = Math.Min(CropWidth, 1 - Math.Clamp(fraction, 0, 1 - minimum)) },
            CropComponent.Y => this with { CropY = Math.Clamp(fraction, 0, 1 - minimum),
                CropHeight = Math.Min(CropHeight, 1 - Math.Clamp(fraction, 0, 1 - minimum)) },
            CropComponent.Width => this with { CropWidth = Math.Clamp(fraction, Math.Min(minimum, 1 - CropX), 1 - CropX) },
            CropComponent.Height => this with { CropHeight = Math.Clamp(fraction, Math.Min(minimum, 1 - CropY), 1 - CropY) },
            _ => throw new ArgumentOutOfRangeException(nameof(component))
        };
    }

    internal Native.GeometryConfig NativeConfig()
    {
        Validate();
        return new() { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.GeometryConfig>(),
            CropX = (float)CropX, CropY = (float)CropY, CropWidth = (float)CropWidth, CropHeight = (float)CropHeight,
            QuarterTurns = QuarterTurns, FlipHorizontal = FlipHorizontal ? 1 : 0,
            FlipVertical = FlipVertical ? 1 : 0, StraightenDegrees = (float)StraightenDegrees };
    }

    internal Native.PerspectiveConfig NativePerspectiveConfig()
    {
        Validate();
        return new() { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.PerspectiveConfig>(),
            Horizontal = (float)PerspectiveHorizontal, Vertical = (float)PerspectiveVertical };
    }

    private void Validate()
    {
        if (!double.IsFinite(CropX) || !double.IsFinite(CropY) || !double.IsFinite(CropWidth) ||
            !double.IsFinite(CropHeight) || (float)CropWidth <= 0 || (float)CropHeight <= 0 || CropX < 0 || CropY < 0 || CropWidth <= 0 || CropHeight <= 0 ||
            CropX + CropWidth > 1 + 1e-12 || CropY + CropHeight > 1 + 1e-12 || QuarterTurns is < 0 or > 3 ||
            !double.IsFinite(StraightenDegrees) || StraightenDegrees is < -45 or > 45 ||
            !double.IsFinite(PerspectiveHorizontal) || PerspectiveHorizontal is < -1 or > 1 ||
            !double.IsFinite(PerspectiveVertical) || PerspectiveVertical is < -1 or > 1)
            throw new ArgumentOutOfRangeException(nameof(GeometrySettings), Loc.Text("几何调整无效。"));
    }
}
