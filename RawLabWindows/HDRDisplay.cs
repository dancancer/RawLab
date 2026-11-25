using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

// 浮点图用于 HDR swap chain，WPF bitmap 用于独立的 SDR 回退和假色监看。
internal sealed record HDRFloatImage(int Width, int Height, int StrideBytes, float[] RGB, float ContentHeadroom, uint HeadroomKind);
internal sealed record HDRRenderedPair(HDRFloatImage HDR, HDRFloatImage SDR, uint NativeWidth, uint NativeHeight,
    uint OutputNativeWidth, uint OutputNativeHeight, bool IsProxy, byte[] SourceSha256)
{
    private BitmapSource? sdrBitmap;
    private HDRLuminanceStatistics? statistics;
    internal BitmapSource SDRBitmap => LazyInitializer.EnsureInitialized(ref sdrBitmap, () => HDRDisplay.SDRBitmap(SDR))!;
    internal HDRLuminanceStatistics Statistics => LazyInitializer.EnsureInitialized(ref statistics, () => HDRDisplay.Analyze(HDR))!;
    internal void SeedSDRBitmap(BitmapSource bitmap)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        Interlocked.CompareExchange(ref sdrBitmap, bitmap, null);
    }

    public bool Equals(HDRRenderedPair? other) =>
        other is not null &&
        EqualityComparer<HDRFloatImage>.Default.Equals(HDR, other.HDR) &&
        EqualityComparer<HDRFloatImage>.Default.Equals(SDR, other.SDR) &&
        NativeWidth == other.NativeWidth &&
        NativeHeight == other.NativeHeight &&
        OutputNativeWidth == other.OutputNativeWidth &&
        OutputNativeHeight == other.OutputNativeHeight &&
        IsProxy == other.IsProxy &&
        EqualityComparer<byte[]>.Default.Equals(SourceSha256, other.SourceSha256);

    public override int GetHashCode() =>
        HashCode.Combine(HDR, SDR, NativeWidth, NativeHeight, OutputNativeWidth, OutputNativeHeight, IsProxy, SourceSha256);
}

internal sealed record HDRLuminanceStatistics(uint[] Bins, double AboveWhite);

internal static class HDRDisplay
{
    private static readonly uint FalseColorOverHeadroom = PackBgra(255, 0, 160);
    private static readonly uint FalseColorHighlight = PackBgra(255, 203, 0);
    private static readonly uint FalseColorShadow = PackBgra(39, 108, 218);
    private static readonly uint FalseColorMid = PackBgra(160, 160, 160);

    internal static HDRLuminanceStatistics Analyze(HDRFloatImage image)
    {
        var bins = new uint[256]; long above = 0;
        for (var i=0;i<image.RGB.Length;i+=3) {
            var y=.2126f*image.RGB[i]+.7152f*image.RGB[i+1]+.0722f*image.RGB[i+2];
            if (!float.IsFinite(y)) throw new InvalidDataException("Nonfinite HDR luminance");
            var ev=y>0 ? MathF.Log2(y) : -8;
            bins[Math.Clamp((int)((Math.Clamp(ev,-8,8)+8)*16),0,255)]++;
            if(y>1)above++;
        }
        return new(bins,(double)above/(image.Width*image.Height));
    }

    internal static BitmapSource FalseColor(HDRFloatImage image, float headroom, CancellationToken cancellation = default)
    {
        var width = image.Width;
        var height = image.Height;
        var bytes = new byte[checked(width * height * 4)];
        var pixels = MemoryMarshal.Cast<byte, uint>(bytes);
        var rgb = image.RGB;
        for (var row = 0; row < height; row++)
        {
            cancellation.ThrowIfCancellationRequested();
            var rowOffset = row * width;
            for (var col = 0; col < width; col++)
            {
                var p = rowOffset + col;
                var i = p * 3;
                var y = .2126f * rgb[i] + .7152f * rgb[i + 1] + .0722f * rgb[i + 2];
                pixels[p] = y > headroom ? FalseColorOverHeadroom
                    : y > 1f ? FalseColorHighlight
                    : y <= .01f ? FalseColorShadow
                    : FalseColorMid;
            }
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, bytes, width * 4);
        bitmap.Freeze();
        return bitmap;
    }
    internal static HDRRenderedPair CopyPair(Native.HDRImagePair pair)
    {
        var hdr = Copy(pair.Hdr); var sdr = Copy(pair.Sdr);
        if (hdr.Width != sdr.Width || hdr.Height != sdr.Height || pair.OrientationApplied != 1 ||
            pair.NativeWidth == 0 || pair.NativeHeight == 0)
            throw new InvalidDataException("Invalid HDR image pair");
        return new(hdr, sdr, pair.NativeWidth, pair.NativeHeight, pair.OutputNativeWidth, pair.OutputNativeHeight,
            pair.IsProxy != 0, pair.SourceSha256?.ToArray() ?? []);
    }

    // 导出尾趟/输入喂图/缩略图等只消费 SDR 平面：仅克隆一份 float[]，省掉整幅 HDR 平面
    // （42MP 量级即每处约 0.5GB 的 LOH 分配与随后的即弃回收）。HDR 槽位别名到同一份拷贝，
    // 需要 HDR 语义（Statistics、FalseColor、swap chain）的消费者必须继续用 CopyPair。
    internal static HDRRenderedPair CopySDROnly(Native.HDRImagePair pair)
    {
        if (!IsReadable(pair.Hdr) || !IsReadable(pair.Sdr)) throw new InvalidDataException("Invalid HDR float buffer");
        var sdr = Copy(pair.Sdr);
        if (pair.Hdr.Width != pair.Sdr.Width || pair.Hdr.Height != pair.Sdr.Height || pair.OrientationApplied != 1 ||
            pair.NativeWidth == 0 || pair.NativeHeight == 0)
            throw new InvalidDataException("Invalid HDR image pair");
        return new(sdr, sdr, pair.NativeWidth, pair.NativeHeight, pair.OutputNativeWidth, pair.OutputNativeHeight,
            pair.IsProxy != 0, pair.SourceSha256?.ToArray() ?? []);
    }

    private static Native.Buffer EncodeSdrBuffer(HDRFloatImage image, bool bgra)
    {
        if (image.Width <= 0 || image.Height <= 0)
            throw new InvalidDataException("Invalid HDR image dimensions");
        var pixelCount = checked(image.Width * image.Height);
        var floatCount = checked(pixelCount * 3);
        if (image.RGB.Length < floatCount)
            throw new InvalidDataException("Truncated HDR float buffer");

        var pin = GCHandle.Alloc(image.RGB, GCHandleType.Pinned);
        Native.Buffer output = default;
        try
        {
            var hdrBuffer = new Native.HDRBuffer
            {
                Version = 1,
                StructSize = (uint)Marshal.SizeOf<Native.HDRBuffer>(),
                Data = pin.AddrOfPinnedObject(),
                SizeBytes = (ulong)floatCount * sizeof(float),
                Width = (uint)image.Width,
                Height = (uint)image.Height,
                StrideBytes = (ulong)image.Width * 12,
                PixelFormat = HDRNative.PixelRGB32FLinear,
                ColorEncoding = HDRNative.LinearSRGB,
                ContentHeadroom = image.ContentHeadroom,
                HeadroomKind = image.HeadroomKind
            };
            var status = bgra
                ? Native.sony2fuji_hdr_encode_bgra8(ref hdrBuffer, out output)
                : Native.sony2fuji_hdr_encode_rgba8(ref hdrBuffer, out output);
            if (status == Native.StatusInvalidArgument)
                throw new InvalidDataException("Nonfinite or invalid SDR rendition");
            Native.CheckWithoutSession(status);
            var result = output;
            output = default;
            return result;
        }
        finally
        {
            if (output.Data != IntPtr.Zero) Native.sony2fuji_release_buffer(ref output);
            pin.Free();
        }
    }

    internal static BitmapSource SDRBitmap(HDRFloatImage image)
    {
        var bgraBuffer = EncodeSdrBuffer(image, bgra: true);
        try
        {
            var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null,
                bgraBuffer.Data, checked((int)bgraBuffer.Size), checked((int)bgraBuffer.Stride));
            bitmap.Freeze();
            return bitmap;
        }
        finally { Native.sony2fuji_release_buffer(ref bgraBuffer); }
    }

    internal static (BitmapSource Bitmap, uint[] Histogram, double Shadows, double Highlights, BitmapSource? Clipping)
        RenderSDRWithStatistics(HDRFloatImage image, bool clipping = false)
    {
        var bgraBuffer = EncodeSdrBuffer(image, bgra: true);
        try
        {
            var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null,
                bgraBuffer.Data, checked((int)bgraBuffer.Size), checked((int)bgraBuffer.Stride));
            bitmap.Freeze();
            var (bins, shadows, highlights, overlay) = AnalyzeBgraBuffer(ref bgraBuffer, image.Width, image.Height, clipping);
            return (bitmap, bins, shadows, highlights, overlay);
        }
        finally { Native.sony2fuji_release_buffer(ref bgraBuffer); }
    }

    internal static byte[] SDRRgba8(HDRFloatImage image)
    {
        var rgbaBuffer = EncodeSdrBuffer(image, bgra: false);
        try
        {
            var pixels = new byte[checked((int)rgbaBuffer.Size)];
            Marshal.Copy(rgbaBuffer.Data, pixels, 0, pixels.Length);
            return pixels;
        }
        finally { Native.sony2fuji_release_buffer(ref rgbaBuffer); }
    }

    internal static (uint[] Histogram, double Shadows, double Highlights, BitmapSource? Clipping) Statistics(HDRFloatImage image, bool clipping = false)
    {
        var bgraBuffer = EncodeSdrBuffer(image, bgra: true);
        try
        {
            return AnalyzeBgraBuffer(ref bgraBuffer, image.Width, image.Height, clipping);
        }
        finally { Native.sony2fuji_release_buffer(ref bgraBuffer); }
    }

    private static (uint[] Histogram, double Shadows, double Highlights, BitmapSource? Clipping)
        AnalyzeBgraBuffer(ref Native.Buffer bgraBuffer, int width, int height, bool clipping)
    {
        var bins = new uint[768];
        Native.Buffer mask = default;
        try
        {
            Native.CheckWithoutSession(RenderEngine.AnalyzeStatistics(ref bgraBuffer, clipping, bins, out var shadows, out var highlights, out mask));
            var overlay = clipping && mask.Data != IntPtr.Zero ? RenderEngine.Bitmap(mask, opaque: false) : null;
            var count = Math.Max(1, checked(width * height));
            return (bins, (double)shadows / count, (double)highlights / count, overlay);
        }
        finally { Native.sony2fuji_release_buffer(ref mask); }
    }

    private static bool IsReadable(Native.HDRBuffer buffer) =>
        !(buffer.Data == IntPtr.Zero || buffer.PixelFormat != HDRNative.PixelRGB32FLinear ||
          buffer.ColorEncoding != HDRNative.LinearSRGB || buffer.Width == 0 || buffer.Height == 0 ||
          buffer.StrideBytes < (ulong)buffer.Width * 12 ||
          buffer.SizeBytes < (ulong)(buffer.Height - 1) * buffer.StrideBytes + (ulong)buffer.Width * 12);

    private static unsafe HDRFloatImage Copy(Native.HDRBuffer buffer)
    {
        if (!IsReadable(buffer)) throw new InvalidDataException("Invalid HDR float buffer");
        var width = checked((int)buffer.Width); var height = checked((int)buffer.Height);
        var rowFloats = checked(width * 3);
        var rowBytes = (nuint)checked(rowFloats * sizeof(float));
        var totalFloats = checked(rowFloats * height);
        var values = new float[totalFloats];
        fixed (float* dstBase = values)
        {
            if (buffer.StrideBytes == (ulong)rowBytes)
            {
                var totalBytes = (nuint)totalFloats * sizeof(float);
                Buffer.MemoryCopy((void*)buffer.Data, dstBase, totalBytes, totalBytes);
            }
            else
            {
                var srcBase = (byte*)buffer.Data;
                var stride = checked((nuint)buffer.StrideBytes);
                for (var y = 0; y < height; y++)
                    Buffer.MemoryCopy(srcBase + (nuint)y * stride, dstBase + (nuint)y * (nuint)rowFloats, rowBytes, rowBytes);
            }
        }
        var span = values.AsSpan();
        var i = 0;
        for (; i <= span.Length - Vector<float>.Count; i += Vector<float>.Count)
        {
            var v = new Vector<float>(span.Slice(i));
            if (!Vector.EqualsAll(v - v, Vector<float>.Zero))
                throw new InvalidDataException("Nonfinite HDR float buffer");
        }
        for (; i < span.Length; i++)
        {
            if (!float.IsFinite(span[i]))
                throw new InvalidDataException("Nonfinite HDR float buffer");
        }
        return new(width, height, checked((int)buffer.StrideBytes), values, buffer.ContentHeadroom, buffer.HeadroomKind);
    }

    private static uint PackBgra(byte r, byte g, byte b) =>
        (uint)b | ((uint)g << 8) | ((uint)r << 16) | 0xFF00_0000u;
}
