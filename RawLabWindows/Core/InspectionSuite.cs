using System.Globalization;

namespace RawLab.Windows;

public enum InspectionOverlayMode
{
    None,
    SketchLuminance,
    WarmCoolBW,
    OversaturationHeatmap,
    SkinHueAmplification,
    NeutralGray50,
}

public static class InspectionOverlayModeExtensions
{
    public static string TitleKey(this InspectionOverlayMode mode) => mode switch
    {
        InspectionOverlayMode.SketchLuminance => "素描明度",
        InspectionOverlayMode.WarmCoolBW => "冷暖反差黑白",
        InspectionOverlayMode.OversaturationHeatmap => "过饱和熔断热力图",
        InspectionOverlayMode.SkinHueAmplification => "肤色色相放大",
        InspectionOverlayMode.NeutralGray50 => "50% 中性灰",
        _ => "关闭观察层",
    };

    public static bool IsActive(this InspectionOverlayMode mode) => mode != InspectionOverlayMode.None;
}

public readonly record struct InspectionColorSample(
    byte R,
    byte G,
    byte B,
    double HueDeg,
    double SaturationPct,
    double BrightnessPct,
    double Luminance)
{
    public static InspectionColorSample FromRgb(byte r, byte g, byte b) =>
        InspectionNative.ColorFromRgb(r, g, b);

    public string RgbText => string.Create(CultureInfo.InvariantCulture, $"{R} {G} {B}");

    public string HsbText => string.Create(CultureInfo.InvariantCulture, $"{HueDeg:0}° {SaturationPct:0}% {BrightnessPct:0}%");
}

public readonly record struct InspectionAnchor(Guid Id, double SourceX, double SourceY)
{
    public const int MaxCount = 4;

    public static InspectionAnchor Create(double sourceX, double sourceY) =>
        new(Guid.NewGuid(), Math.Clamp(sourceX, 0.0, 1.0), Math.Clamp(sourceY, 0.0, 1.0));
}

public sealed class InspectionSessionState
{
    private readonly List<InspectionAnchor> anchors = [];

    public bool MonitorEnabled { get; set; }
    public bool PinModeEnabled { get; set; }
    public (double X, double Y)? LiveOutputPoint { get; set; }
    public IReadOnlyList<InspectionAnchor> Anchors => anchors;
    public Guid? SelectedAnchorId { get; set; }
    public InspectionOverlayMode Overlay { get; private set; } = InspectionOverlayMode.None;
    public InspectionOverlayMode LastNonGrayOverlay { get; private set; } = InspectionOverlayMode.None;

    public bool NeedsReference => MonitorEnabled || anchors.Count > 0;
    public bool CanPinMore => anchors.Count < InspectionAnchor.MaxCount;

    public void SelectOverlay(InspectionOverlayMode mode)
    {
        if (mode != InspectionOverlayMode.NeutralGray50)
            LastNonGrayOverlay = mode;
        Overlay = mode;
    }

    public void ToggleNeutralGray50()
    {
        if (Overlay == InspectionOverlayMode.NeutralGray50)
        {
            Overlay = LastNonGrayOverlay == InspectionOverlayMode.NeutralGray50
                ? InspectionOverlayMode.None
                : LastNonGrayOverlay;
        }
        else
        {
            LastNonGrayOverlay = Overlay;
            Overlay = InspectionOverlayMode.NeutralGray50;
        }
    }

    public InspectionAnchor? PinAnchor(double sourceX, double sourceY)
    {
        if (!CanPinMore) return null;
        var anchor = InspectionAnchor.Create(sourceX, sourceY);
        anchors.Add(anchor);
        SelectedAnchorId = anchor.Id;
        return anchor;
    }

    public void RemoveAnchor(Guid id)
    {
        anchors.RemoveAll(a => a.Id == id);
        if (SelectedAnchorId == id)
            SelectedAnchorId = anchors.Count > 0 ? anchors[^1].Id : null;
    }

    public void ClearAnchors()
    {
        anchors.Clear();
        SelectedAnchorId = null;
    }

    public void ResetForNewSource()
    {
        PinModeEnabled = false;
        LiveOutputPoint = null;
        anchors.Clear();
        SelectedAnchorId = null;
        Overlay = InspectionOverlayMode.None;
        LastNonGrayOverlay = InspectionOverlayMode.None;
    }

    public bool HandleEscape()
    {
        if (Overlay == InspectionOverlayMode.NeutralGray50)
        {
            Overlay = LastNonGrayOverlay == InspectionOverlayMode.NeutralGray50
                ? InspectionOverlayMode.None
                : LastNonGrayOverlay;
            return true;
        }
        if (Overlay != InspectionOverlayMode.None)
        {
            Overlay = InspectionOverlayMode.None;
            LastNonGrayOverlay = InspectionOverlayMode.None;
            return true;
        }
        if (PinModeEnabled)
        {
            PinModeEnabled = false;
            return true;
        }
        if (MonitorEnabled)
        {
            MonitorEnabled = false;
            LiveOutputPoint = null;
            return true;
        }
        return false;
    }
}

public static class InspectionColorMath
{
    public static InspectionColorSample? SampleBgra32(
        byte[] pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx = 1) =>
        InspectionNative.SampleBgra32(pixels, width, height, stride, normX, normY, radiusPx);

    public static InspectionColorSample? SampleBgra32(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx = 1) =>
        InspectionNative.SampleBgra32(pixels, width, height, stride, normX, normY, radiusPx);

    public static (byte R, byte G, byte B) ApplyOverlayPixel(byte r, byte g, byte b, InspectionOverlayMode mode) =>
        InspectionNative.ApplyOverlayPixel(r, g, b, mode);

    public static void ApplyOverlayBgra32(
        byte[] src,
        byte[] dst,
        int width,
        int height,
        int srcStride,
        int dstStride,
        InspectionOverlayMode mode) =>
        InspectionNative.ApplyOverlayBgra32(src, dst, width, height, srcStride, dstStride, mode);
}

public static class GeometryCoordinateMapper
{
    public static (int Width, int Height) InferSourceSize(int outputWidth, int outputHeight, GeometrySettings options) =>
        InspectionNative.InferSourceSize(outputWidth, outputHeight, options);

    public static (double X, double Y)? OutputNormToSourceNorm(
        double outX,
        double outY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry) =>
        InspectionNative.OutputNormToSourceNorm(outX, outY, sourceWidth, sourceHeight, geometry);

    public static (double X, double Y)? SourceNormToOutputNorm(
        double srcX,
        double srcY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry) =>
        InspectionNative.SourceNormToOutputNorm(srcX, srcY, sourceWidth, sourceHeight, geometry);
}
