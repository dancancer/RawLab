using System.Buffers;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal readonly record struct PointColorSwatchPreview(
    byte SrcR,
    byte SrcG,
    byte SrcB,
    byte ShiftedR,
    byte ShiftedG,
    byte ShiftedB);

internal static class InspectionNative
{
    internal static Native.InspectionOverlayMode ToNative(InspectionOverlayMode mode) => mode switch
    {
        InspectionOverlayMode.SketchLuminance => Native.InspectionOverlayMode.SketchLuminance,
        InspectionOverlayMode.WarmCoolBW => Native.InspectionOverlayMode.WarmCoolBw,
        InspectionOverlayMode.OversaturationHeatmap => Native.InspectionOverlayMode.OversaturationHeatmap,
        InspectionOverlayMode.SkinHueAmplification => Native.InspectionOverlayMode.SkinHueAmplification,
        InspectionOverlayMode.NeutralGray50 => Native.InspectionOverlayMode.NeutralGray50,
        _ => Native.InspectionOverlayMode.None,
    };

    internal static Native.InspectionSample CreateNativeSample() => new()
    {
        Version = Native.InspectionSampleVersion,
        StructSize = (uint)Marshal.SizeOf<Native.InspectionSample>(),
    };

    internal static InspectionColorSample FromNative(in Native.InspectionSample s) =>
        new(s.R, s.G, s.B, s.HueDeg, s.SaturationPct, s.BrightnessPct, s.Luminance);

    internal static InspectionColorSample ColorFromRgb(byte r, byte g, byte b)
    {
        var sample = CreateNativeSample();
        if (Native.sony2fuji_inspection_color_from_rgb(r, g, b, ref sample) != Native.StatusOk)
            return new InspectionColorSample(r, g, b, 0.0, 0.0, 0.0, 0.0);
        return FromNative(sample);
    }

    internal static bool HasValidBgraBounds(int bufferLength, int width, int height, int stride) =>
        width > 0 && height > 0 && stride > 0 &&
        (long)stride >= (long)width * 4 &&
        bufferLength >= (long)(height - 1) * stride + (long)width * 4;

    private static InspectionColorSample? SampleBgra32Pinned(
        byte[] pixels,
        int validLength,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx)
    {
        var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        try
        {
            var buf = new Native.Buffer
            {
                Data = handle.AddrOfPinnedObject(),
                Size = (nuint)validLength,
                Width = (uint)width,
                Height = (uint)height,
                Stride = (uint)stride,
                PixelFormat = Native.PixelFormatBgra8,
            };
            var sample = CreateNativeSample();
            var status = Native.sony2fuji_inspection_sample_patch(
                ref buf, normX, normY, (uint)Math.Max(0, radiusPx), ref sample);
            return status == Native.StatusOk ? FromNative(sample) : null;
        }
        finally
        {
            handle.Free();
        }
    }

    internal static InspectionColorSample? SampleBgra32(
        byte[] pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx)
    {
        if (pixels == null || !HasValidBgraBounds(pixels.Length, width, height, stride) ||
            !double.IsFinite(normX) || !double.IsFinite(normY))
            return null;
        return SampleBgra32Pinned(pixels, pixels.Length, width, height, stride, normX, normY, radiusPx);
    }

    internal static InspectionColorSample? SampleBgra32(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx)
    {
        if (!HasValidBgraBounds(pixels.Length, width, height, stride) ||
            !double.IsFinite(normX) || !double.IsFinite(normY))
            return null;

        var rented = ArrayPool<byte>.Shared.Rent(pixels.Length);
        try
        {
            pixels.CopyTo(rented);
            return SampleBgra32Pinned(rented, pixels.Length, width, height, stride, normX, normY, radiusPx);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(rented);
        }
    }

    internal static (byte R, byte G, byte B) ApplyOverlayPixel(byte r, byte g, byte b, InspectionOverlayMode mode)
    {
        if (Native.sony2fuji_inspection_overlay_pixel(r, g, b, ToNative(mode), out var outR, out var outG, out var outB) != Native.StatusOk)
            return (r, g, b);
        return (outR, outG, outB);
    }

    internal static void ApplyOverlayBgra32(
        byte[] src,
        byte[] dst,
        int width,
        int height,
        int srcStride,
        int dstStride,
        InspectionOverlayMode mode)
    {
        if (src is not null && ReferenceEquals(src, dst))
            throw new ArgumentException("Source and destination buffers must not alias.", nameof(dst));
        if (src == null || dst == null ||
            !HasValidBgraBounds(src.Length, width, height, srcStride) ||
            !HasValidBgraBounds(dst.Length, width, height, dstStride))
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
                Native.sony2fuji_inspection_render_overlay(ref srcBuf, ToNative(mode), ref dstBuf));
        }
        finally
        {
            dstHandle.Free();
            srcHandle.Free();
        }
    }

    internal static (int Width, int Height) InferSourceSize(int outputWidth, int outputHeight, GeometrySettings options)
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

    internal static (double X, double Y)? OutputNormToSourceNorm(
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

    internal static (double X, double Y)? SourceNormToOutputNorm(
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

    internal static PointColorSwatchPreview? PointColorPreviewSwatch(PointColorSwatch swatch)
    {
        var srcRgb = new float[3];
        var shiftedRgb = new float[3];
        if (Native.sony2fuji_point_color_preview_swatch(
                (float)swatch.SrcHue,
                (float)swatch.SrcSaturation,
                (float)swatch.SrcLuminance,
                (float)swatch.HueShift,
                (float)swatch.SaturationShift,
                (float)swatch.LuminanceShift,
                srcRgb,
                shiftedRgb) != Native.StatusOk)
        {
            return null;
        }
        static byte ToByte(float value) =>
            (byte)Math.Clamp(Math.Round((float.IsFinite(value) ? value : 0f) * 255.0), 0, 255);
        return new PointColorSwatchPreview(
            ToByte(srcRgb[0]), ToByte(srcRgb[1]), ToByte(srcRgb[2]),
            ToByte(shiftedRgb[0]), ToByte(shiftedRgb[1]), ToByte(shiftedRgb[2]));
    }

    internal static PointColorSwatch SwatchFromSample(InspectionColorSample sample)
    {
        var hue = double.IsFinite(sample.HueDeg) ? Math.Clamp(sample.HueDeg, 0.0, 359.999) : 0.0;
        var sat = double.IsFinite(sample.SaturationPct) ? Math.Clamp(sample.SaturationPct / 100.0, 0.0, 1.0) : 0.0;
        var lum = double.IsFinite(sample.BrightnessPct) ? Math.Clamp(sample.BrightnessPct / 100.0, 0.0, 1.0) : 0.0;
        return new PointColorSwatch(SrcHue: hue, SrcSaturation: sat, SrcLuminance: lum);
    }
}
