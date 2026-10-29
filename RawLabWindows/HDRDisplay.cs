using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

// 浮点图用于 HDR swap chain，WPF bitmap 用于独立的 SDR 回退和假色监看。
internal sealed record HDRFloatImage(int Width, int Height, int StrideBytes, float[] RGB, float ContentHeadroom, uint HeadroomKind);
internal sealed record HDRRenderedPair(HDRFloatImage HDR, HDRFloatImage SDR, uint NativeWidth, uint NativeHeight,
    uint OutputNativeWidth, uint OutputNativeHeight, bool IsProxy, byte[] SourceSha256)
{
    internal BitmapSource SDRBitmap => HDRDisplay.SDRBitmap(SDR);
    private HDRLuminanceStatistics? statistics;
    internal HDRLuminanceStatistics Statistics => statistics ??= HDRDisplay.Analyze(HDR);
}

internal sealed record HDRLuminanceStatistics(uint[] Bins, double AboveWhite);

internal static class HDRDisplay
{
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
        var bytes=new byte[checked(image.Width*image.Height*4)];
        for(var p=0;p<image.Width*image.Height;p++) {
            if(p%image.Width==0)cancellation.ThrowIfCancellationRequested();
            var i=p*3;var y=.2126f*image.RGB[i]+.7152f*image.RGB[i+1]+.0722f*image.RGB[i+2];
            var rgb=y>headroom ? (1f,0f,.35f) : y>1 ? (1f,.6f,0f) : y<=.01f ? (.02f,.15f,.7f) : (.35f,.35f,.35f);
            bytes[p*4]=ToByte(rgb.Item3);bytes[p*4+1]=ToByte(rgb.Item2);bytes[p*4+2]=ToByte(rgb.Item1);bytes[p*4+3]=255;
        }
        var bitmap=BitmapSource.Create(image.Width,image.Height,96,96,PixelFormats.Pbgra32,null,bytes,image.Width*4);bitmap.Freeze();return bitmap;
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

    internal static BitmapSource SDRBitmap(HDRFloatImage image)
    {
        var pixels = new byte[checked(image.Width * image.Height * 4)];
        for (var y = 0; y < image.Height; y++)
        for (var x = 0; x < image.Width; x++)
        {
            var source = (y * image.Width + x) * 3;
            var destination = (y * image.Width + x) * 4;
            pixels[destination] = ToByte(image.RGB[source + 2]);
            pixels[destination + 1] = ToByte(image.RGB[source + 1]);
            pixels[destination + 2] = ToByte(image.RGB[source]);
            pixels[destination + 3] = 255;
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null,
            pixels, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    internal static byte[] SDRRgb8(HDRFloatImage image)
    {
        var pixels = new byte[checked(image.Width * image.Height * 3)];
        for (var i = 0; i < image.RGB.Length; i++) pixels[i] = ToByte(image.RGB[i]);
        return pixels;
    }

    internal static (uint[] Histogram, double Shadows, double Highlights) Statistics(HDRFloatImage image)
    {
        var bins = new uint[768]; long shadows = 0, highlights = 0;
        for (var pixel = 0; pixel < image.RGB.Length; pixel += 3)
        {
            var shadow = false; var highlight = false;
            for (var channel = 0; channel < 3; channel++)
            {
                var value = image.RGB[pixel + channel];
                if (value <= 0) shadow = true;
                if (value >= 1) highlight = true;
                var bin = ToByte(value);
                bins[channel * 256 + bin]++;
            }
            if (shadow) shadows++;
            if (highlight) highlights++;
        }
        var count = Math.Max(1, image.Width * image.Height);
        return (bins, (double)shadows / count, (double)highlights / count);
    }

    private static HDRFloatImage Copy(Native.HDRBuffer buffer)
    {
        if (buffer.Data == IntPtr.Zero || buffer.PixelFormat != HDRNative.PixelRGB32FLinear ||
            buffer.ColorEncoding != HDRNative.LinearSRGB || buffer.Width == 0 || buffer.Height == 0 ||
            buffer.StrideBytes < (ulong)buffer.Width * 12 || buffer.SizeBytes < (ulong)(buffer.Height - 1) * buffer.StrideBytes + (ulong)buffer.Width * 12)
            throw new InvalidDataException("Invalid HDR float buffer");
        var width = checked((int)buffer.Width); var height = checked((int)buffer.Height);
        var values = new float[checked(width * height * 3)]; var row = new byte[checked(width * 12)];
        for (var y = 0; y < height; y++)
        {
            Marshal.Copy(IntPtr.Add(buffer.Data, checked((int)((ulong)y * buffer.StrideBytes))), row, 0, row.Length);
            var floats = MemoryMarshal.Cast<byte, float>(row);
            for (var x = 0; x < width * 3; x++)
            {
                if (!float.IsFinite(floats[x])) throw new InvalidDataException("Nonfinite HDR float buffer");
                values[(y * width * 3) + x] = floats[x];
            }
        }
        return new(width, height, checked((int)buffer.StrideBytes), values, buffer.ContentHeadroom, buffer.HeadroomKind);
    }

    private static byte ToByte(float value)
    {
        if (!float.IsFinite(value)) throw new InvalidDataException("Nonfinite SDR rendition");
        value = Math.Clamp(value, 0, 1);
        var encoded = value <= .0031308f ? 12.92f * value : 1.055f * MathF.Pow(value, 1 / 2.4f) - .055f;
        return (byte)Math.Clamp(MathF.Round(encoded * 255, MidpointRounding.AwayFromZero), 0, 255);
    }
}
