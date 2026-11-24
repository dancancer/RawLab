using System.Buffers;
using System.Globalization;
using System.Runtime.InteropServices;

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

    internal static Native.InspectionOverlayMode ToNative(this InspectionOverlayMode mode) => mode switch
    {
        InspectionOverlayMode.SketchLuminance => Native.InspectionOverlayMode.SketchLuminance,
        InspectionOverlayMode.WarmCoolBW => Native.InspectionOverlayMode.WarmCoolBw,
        InspectionOverlayMode.OversaturationHeatmap => Native.InspectionOverlayMode.OversaturationHeatmap,
        InspectionOverlayMode.SkinHueAmplification => Native.InspectionOverlayMode.SkinHueAmplification,
        InspectionOverlayMode.NeutralGray50 => Native.InspectionOverlayMode.NeutralGray50,
        _ => Native.InspectionOverlayMode.None,
    };
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
    public static InspectionColorSample FromRgb(byte r, byte g, byte b)
    {
        var sample = CreateNativeSample();
        if (Native.sony2fuji_inspection_color_from_rgb(r, g, b, ref sample) != Native.StatusOk)
            return new InspectionColorSample(r, g, b, 0.0, 0.0, 0.0, 0.0);
        return FromNative(sample);
    }

    internal static Native.InspectionSample CreateNativeSample() => new()
    {
        Version = Native.InspectionSampleVersion,
        StructSize = (uint)Marshal.SizeOf<Native.InspectionSample>(),
    };

    internal static InspectionColorSample FromNative(in Native.InspectionSample s) =>
        new(s.R, s.G, s.B, s.HueDeg, s.SaturationPct, s.BrightnessPct, s.Luminance);

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
        int radiusPx = 1)
    {
        if (pixels == null || width <= 0 || height <= 0 || stride < width * 4 ||
            !double.IsFinite(normX) || !double.IsFinite(normY) ||
            pixels.Length < (height - 1) * stride + width * 4)
            return null;

        var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        try
        {
            var buf = new Native.Buffer
            {
                Data = handle.AddrOfPinnedObject(),
                Size = (nuint)pixels.Length,
                Width = (uint)width,
                Height = (uint)height,
                Stride = (uint)stride,
                PixelFormat = Native.PixelFormatBgra8,
            };
            var sample = InspectionColorSample.CreateNativeSample();
            var status = Native.sony2fuji_inspection_sample_patch(
                ref buf, normX, normY, (uint)Math.Max(0, radiusPx), ref sample);
            return status == Native.StatusOk ? InspectionColorSample.FromNative(sample) : null;
        }
        finally
        {
            handle.Free();
        }
    }

    public static InspectionColorSample? SampleBgra32(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx = 1)
    {
        var rented = ArrayPool<byte>.Shared.Rent(pixels.Length);
        try
        {
            pixels.CopyTo(rented);
            return SampleBgra32(rented, width, height, stride, normX, normY, radiusPx);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(rented);
        }
    }

    public static (byte R, byte G, byte B) ApplyOverlayPixel(byte r, byte g, byte b, InspectionOverlayMode mode)
    {
        if (Native.sony2fuji_inspection_overlay_pixel(r, g, b, mode.ToNative(), out var outR, out var outG, out var outB) != Native.StatusOk)
            return (r, g, b);
        return (outR, outG, outB);
    }

    public static void ApplyOverlayBgra32(
        byte[] src,
        byte[] dst,
        int width,
        int height,
        int srcStride,
        int dstStride,
        InspectionOverlayMode mode)
    {
        if (src == null || dst == null || width <= 0 || height <= 0 ||
            srcStride < width * 4 || dstStride < width * 4 ||
            src.Length < (height - 1) * srcStride + width * 4 ||
            dst.Length < (height - 1) * dstStride + width * 4)
            return;

        var srcHandle = GCHandle.Alloc(src, GCHandleType.Pinned);
        var dstHandle = GCHandle.Alloc(dst, GCHandleType.Pinned);
        try
        {
            var srcBuf = new Native.Buffer
            {
                Data = srcHandle.AddrOfPinnedObject(),
                Size = (nuint)src.Length,
                Width = (uint)width,
                Height = (uint)height,
                Stride = (uint)srcStride,
                PixelFormat = Native.PixelFormatBgra8,
            };
            var dstBuf = new Native.Buffer
            {
                Data = dstHandle.AddrOfPinnedObject(),
                Size = (nuint)dst.Length,
                Width = (uint)width,
                Height = (uint)height,
                Stride = (uint)dstStride,
                PixelFormat = Native.PixelFormatBgra8,
            };
            Native.CheckWithoutSession(
                Native.sony2fuji_inspection_render_overlay(ref srcBuf, mode.ToNative(), ref dstBuf));
        }
        finally
        {
            dstHandle.Free();
            srcHandle.Free();
        }
    }
}

public static class GeometryCoordinateMapper
{
    public static (int Width, int Height) InferSourceSize(int outputWidth, int outputHeight, GeometrySettings options)
    {
        var safeW = Math.Max(1, outputWidth);
        var safeH = Math.Max(1, outputHeight);
        try
        {
            var geom = options.NativeConfig();
            var persp = options.NativePerspectiveConfig();
            if (Native.sony2fuji_geometry_infer_source_size(
                    (uint)safeW, (uint)safeH, ref geom, ref persp, out var srcW, out var srcH) == Native.StatusOk &&
                srcW > 0 && srcH > 0)
            {
                return ((int)srcW, (int)srcH);
            }
        }
        catch (ArgumentOutOfRangeException)
        {
        }
        return (safeW, safeH);
    }

    public static (double X, double Y)? OutputNormToSourceNorm(
        double outX,
        double outY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry)
    {
        if (!double.IsFinite(outX) || !double.IsFinite(outY) || sourceWidth < 1 || sourceHeight < 1)
            return null;
        try
        {
            var geom = geometry.NativeConfig();
            var persp = geometry.NativePerspectiveConfig();
            if (Native.sony2fuji_geometry_output_norm_to_source_norm(
                    (uint)sourceWidth, (uint)sourceHeight, ref geom, ref persp,
                    outX, outY, out var srcX, out var srcY, out var valid) == Native.StatusOk &&
                valid != 0)
            {
                return (srcX, srcY);
            }
        }
        catch (ArgumentOutOfRangeException)
        {
        }
        return null;
    }

    public static (double X, double Y)? SourceNormToOutputNorm(
        double srcX,
        double srcY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry)
    {
        if (!double.IsFinite(srcX) || !double.IsFinite(srcY) || sourceWidth < 1 || sourceHeight < 1)
            return null;
        try
        {
            var geom = geometry.NativeConfig();
            var persp = geometry.NativePerspectiveConfig();
            if (Native.sony2fuji_geometry_source_norm_to_output_norm(
                    (uint)sourceWidth, (uint)sourceHeight, ref geom, ref persp,
                    srcX, srcY, out var outX, out var outY, out var valid) == Native.StatusOk &&
                valid != 0)
            {
                return (outX, outY);
            }
        }
        catch (ArgumentOutOfRangeException)
        {
        }
        return null;
    }
}
