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
    private const uint FalseColorBgra8Flags = HDRNative.DisplayFalseColor | HDRNative.DisplayBgra8Srgb;
    private const int FalseColorRowBand = 16;

    internal static HDRLuminanceStatistics Analyze(HDRFloatImage image)
    {
        var bins = new uint[256];
        var pin = GCHandle.Alloc(image.RGB, GCHandleType.Pinned);
        try
        {
            var buffer = FloatBuffer(image, pin.AddrOfPinnedObject(), 0, image.Height);
            var status = Native.sony2fuji_hdr_analyze_luminance(ref buffer, bins, out var above, out _);
            if (status == Native.StatusInvalidArgument) throw new InvalidDataException("Nonfinite HDR luminance");
            Native.CheckWithoutSession(status);
            return new(bins, (double)above / (image.Width * image.Height));
        }
        finally { pin.Free(); }
    }

    internal static BitmapSource FalseColor(HDRFloatImage image, float headroom, CancellationToken cancellation = default)
    {
        var width = image.Width;
        var height = image.Height;
        var bytes = new byte[checked(width * height * 4)];
        var source = GCHandle.Alloc(image.RGB, GCHandleType.Pinned);
        var target = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            // 假色分档与 sRGB 编码在共享核心；按行段调用以保留逐段取消。
            for (var row = 0; row < height; row += FalseColorRowBand)
            {
                cancellation.ThrowIfCancellationRequested();
                var rows = Math.Min(FalseColorRowBand, height - row);
                var buffer = FloatBuffer(image, source.AddrOfPinnedObject(), row, rows);
                var status = Native.sony2fuji_hdr_display_into(ref buffer, IntPtr.Zero, headroom, 1, FalseColorBgra8Flags,
                    target.AddrOfPinnedObject() + checked(row * width * 4), (ulong)rows * (ulong)width * 4, (ulong)width * 4);
                if (status == Native.StatusInvalidArgument) throw new InvalidDataException("Nonfinite HDR luminance");
                Native.CheckWithoutSession(status);
            }
        }
        finally
        {
            target.Free();
            source.Free();
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, bytes, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    // 紧密排列的 RGB32F 平面上 [firstRow, firstRow + rows) 行的线性 sRGB 视图；data 须已钉住。
    private static Native.HDRBuffer FloatBuffer(HDRFloatImage image, IntPtr data, int firstRow, int rows)
    {
        var rowBytes = checked((ulong)image.Width * 12);
        if (image.Width <= 0 || image.Height <= 0 || (ulong)image.RGB.Length * sizeof(float) < rowBytes * (ulong)image.Height)
            throw new InvalidDataException("Invalid HDR float buffer");
        return new Native.HDRBuffer
        {
            Version = 1,
            StructSize = (uint)Marshal.SizeOf<Native.HDRBuffer>(),
            Data = data + checked((nint)((ulong)firstRow * rowBytes)),
            SizeBytes = (ulong)rows * rowBytes,
            Width = (uint)image.Width,
            Height = (uint)rows,
            StrideBytes = rowBytes,
            PixelFormat = HDRNative.PixelRGB32FLinear,
            ColorEncoding = HDRNative.LinearSRGB,
            ContentHeadroom = image.ContentHeadroom,
            HeadroomKind = image.HeadroomKind
        };
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
            var hdrBuffer = FloatBuffer(image, pin.AddrOfPinnedObject(), 0, image.Height);
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
}
