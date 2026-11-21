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
    private static readonly uint FalseColorOverHeadroom = PackBgra(1f, 0f, .35f);
    private static readonly uint FalseColorHighlight = PackBgra(1f, .6f, 0f);
    private static readonly uint FalseColorShadow = PackBgra(.02f, .15f, .7f);
    private static readonly uint FalseColorMid = PackBgra(.35f, .35f, .35f);

    private static readonly Vector<float> LinearThreshold = new(0.0031308f);
    private static readonly Vector<float> LinearSlope = new(12.92f);
    private static readonly Vector<float> GammaScale = new(1.055f);
    private static readonly Vector<float> GammaOffset = new(0.055f);
    private static readonly Vector<float> ByteScale = new(255f);
    private static readonly Vector<float> Half = new(0.5f);
    private static readonly Vector<float> PolyC0 = new(-0.00633837899f);
    private static readonly Vector<float> PolyC1 = new(0.156613938f);
    private static readonly Vector<float> PolyC2 = new(1.17948606f);
    private static readonly Vector<float> PolyC3 = new(-0.530382713f);
    private static readonly Vector<float> PolyC4 = new(0.261369359f);
    private static readonly Vector<float> PolyC5 = new(-0.0607587535f);

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

    internal static byte[] EncodePbgra32(HDRFloatImage image)
    {
        var pixelCount = checked(image.Width * image.Height);
        var floatCount = checked(pixelCount * 3);
        var src = image.RGB.AsSpan(0, floatCount);
        var pixels = new byte[checked(pixelCount * 4)];
        var simdPixels = Vector<float>.Count;
        Span<int> encoded = stackalloc int[simdPixels * 3];
        var p = 0;
        for (; p <= pixelCount - simdPixels; p += simdPixels)
        {
            var baseFloat = p * 3;
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat))).CopyTo(encoded);
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat + simdPixels))).CopyTo(encoded.Slice(simdPixels));
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat + simdPixels * 2))).CopyTo(encoded.Slice(simdPixels * 2));
            for (var k = 0; k < simdPixels; k++)
            {
                var srcIdx = k * 3;
                var dstIdx = (p + k) * 4;
                pixels[dstIdx] = (byte)encoded[srcIdx + 2];
                pixels[dstIdx + 1] = (byte)encoded[srcIdx + 1];
                pixels[dstIdx + 2] = (byte)encoded[srcIdx];
                pixels[dstIdx + 3] = 255;
            }
        }
        for (; p < pixelCount; p++)
        {
            var source = p * 3;
            var destination = p * 4;
            pixels[destination] = ToByte(src[source + 2]);
            pixels[destination + 1] = ToByte(src[source + 1]);
            pixels[destination + 2] = ToByte(src[source]);
            pixels[destination + 3] = 255;
        }
        return pixels;
    }

    internal static BitmapSource SDRBitmap(HDRFloatImage image)
    {
        var pixels = EncodePbgra32(image);
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null,
            pixels, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    internal static (BitmapSource Bitmap, uint[] Histogram, double Shadows, double Highlights, BitmapSource? Clipping)
        RenderSDRWithStatistics(HDRFloatImage image, bool clipping = false)
    {
        var pixels = EncodePbgra32(image);
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null,
            pixels, image.Width * 4);
        bitmap.Freeze();

        var bins = new uint[768];
        long shadows = 0, highlights = 0;
        var mask = clipping ? new byte[pixels.Length] : null;
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            var b = pixels[offset];
            var g = pixels[offset + 1];
            var r = pixels[offset + 2];
            bins[r]++;
            bins[256 + g]++;
            bins[512 + b]++;
            var highlight = (r == 255) | (g == 255) | (b == 255);
            var shadow = (r == 0) & (g == 0) & (b == 0);
            if (highlight)
            {
                highlights++;
                if (mask != null) { mask[offset + 2] = 255; mask[offset + 3] = 160; }
            }
            else if (shadow)
            {
                shadows++;
                if (mask != null) { mask[offset] = 255; mask[offset + 1] = 130; mask[offset + 3] = 160; }
            }
        }
        BitmapSource? overlay = null;
        if (mask != null)
        {
            overlay = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, mask, image.Width * 4);
            overlay.Freeze();
        }
        var count = Math.Max(1, image.Width * image.Height);
        return (bitmap, bins, (double)shadows / count, (double)highlights / count, overlay);
    }

    internal static byte[] SDRRgb8(HDRFloatImage image)
    {
        var floatCount = checked(image.Width * image.Height * 3);
        var src = image.RGB.AsSpan(0, floatCount);
        var pixels = new byte[floatCount];
        var simdCount = Vector<float>.Count;
        Span<int> temp = stackalloc int[simdCount];
        var i = 0;
        for (; i <= src.Length - simdCount; i += simdCount)
        {
            EncodeSrgbVector(new Vector<float>(src.Slice(i))).CopyTo(temp);
            for (var k = 0; k < simdCount; k++) pixels[i + k] = (byte)temp[k];
        }
        for (; i < src.Length; i++) pixels[i] = ToByte(src[i]);
        return pixels;
    }

    internal static (uint[] Histogram, double Shadows, double Highlights, BitmapSource? Clipping) Statistics(HDRFloatImage image, bool clipping = false)
    {
        var pixelCount = checked(image.Width * image.Height);
        var floatCount = checked(pixelCount * 3);
        var src = image.RGB.AsSpan(0, floatCount);
        var bins = new uint[768]; long shadows = 0, highlights = 0;
        var mask = clipping ? new byte[checked(pixelCount * 4)] : null;
        var simdPixels = Vector<float>.Count;
        Span<int> encoded = stackalloc int[simdPixels * 3];
        var p = 0;
        for (; p <= pixelCount - simdPixels; p += simdPixels)
        {
            var baseFloat = p * 3;
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat))).CopyTo(encoded);
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat + simdPixels))).CopyTo(encoded.Slice(simdPixels));
            EncodeSrgbVector(new Vector<float>(src.Slice(baseFloat + simdPixels * 2))).CopyTo(encoded.Slice(simdPixels * 2));
            for (var k = 0; k < simdPixels; k++)
            {
                var srcIdx = k * 3;
                var r = (byte)encoded[srcIdx];
                var g = (byte)encoded[srcIdx + 1];
                var b = (byte)encoded[srcIdx + 2];
                bins[r]++;
                bins[256 + g]++;
                bins[512 + b]++;
                var highlight = (r == 255) | (g == 255) | (b == 255);
                var shadow = (r == 0) & (g == 0) & (b == 0);
                var offset = (p + k) * 4;
                // 与普通八位显示统计一致：任一通道为白标红，三通道全黑标蓝。
                if (highlight) { highlights++; if (mask != null) { mask[offset + 2] = 255; mask[offset + 3] = 160; } }
                else if (shadow) { shadows++; if (mask != null) { mask[offset] = 255; mask[offset + 1] = 130; mask[offset + 3] = 160; } }
            }
        }
        for (; p < pixelCount; p++)
        {
            var baseFloat = p * 3;
            var r = ToByte(src[baseFloat]);
            var g = ToByte(src[baseFloat + 1]);
            var b = ToByte(src[baseFloat + 2]);
            bins[r]++;
            bins[256 + g]++;
            bins[512 + b]++;
            var highlight = (r == 255) | (g == 255) | (b == 255);
            var shadow = (r == 0) & (g == 0) & (b == 0);
            var offset = p * 4;
            if (highlight) { highlights++; if (mask != null) { mask[offset + 2] = 255; mask[offset + 3] = 160; } }
            else if (shadow) { shadows++; if (mask != null) { mask[offset] = 255; mask[offset + 1] = 130; mask[offset + 3] = 160; } }
        }
        BitmapSource? overlay = null;
        if (mask != null)
        {
            overlay = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, mask, image.Width * 4);
            overlay.Freeze();
        }
        var count = Math.Max(1, pixelCount);
        return (bins, (double)shadows / count, (double)highlights / count, overlay);
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

    private static Vector<int> EncodeSrgbVector(Vector<float> value)
    {
        if (!Vector.EqualsAll(value - value, Vector<float>.Zero))
            throw new InvalidDataException("Nonfinite SDR rendition");
        var clamped = Vector.Min(Vector.Max(value, Vector<float>.Zero), Vector<float>.One);
        var linear = clamped * LinearSlope;
        var t = Vector.SquareRoot(Vector.SquareRoot(clamped));
        var poly = PolyC5 * t + PolyC4;
        poly = poly * t + PolyC3;
        poly = poly * t + PolyC2;
        poly = poly * t + PolyC1;
        poly = poly * t + PolyC0;
        var gamma = poly * GammaScale - GammaOffset;
        var isLinear = Vector.LessThanOrEqual(clamped, LinearThreshold);
        var encoded = Vector.ConditionalSelect(isLinear, linear, gamma);
        var scaled = Vector.Min(Vector.Max(encoded * ByteScale, Vector<float>.Zero), ByteScale);
        return Vector.ConvertToInt32(scaled + Half);
    }

    private static uint PackBgra(float r, float g, float b) =>
        (uint)ToByte(b) | ((uint)ToByte(g) << 8) | ((uint)ToByte(r) << 16) | 0xFF00_0000u;

    private static byte ToByte(float value)
    {
        if (!float.IsFinite(value)) throw new InvalidDataException("Nonfinite SDR rendition");
        value = Math.Clamp(value, 0, 1);
        var encoded = value <= .0031308f ? 12.92f * value : 1.055f * MathF.Pow(value, 1 / 2.4f) - .055f;
        return (byte)Math.Clamp(MathF.Round(encoded * 255, MidpointRounding.AwayFromZero), 0, 255);
    }
}
