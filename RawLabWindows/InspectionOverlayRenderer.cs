using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal static class InspectionOverlayRenderer
{
    private static readonly BitmapSource Gray50Bitmap = CreateGray50Bitmap();

    private static BitmapSource CreateGray50Bitmap()
    {
        var bmp = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Pbgra32, null, new byte[] { 128, 128, 128, 255 }, 4);
        bmp.Freeze();
        return bmp;
    }

    internal static InspectionColorSample? SampleBitmap(BitmapSource? bitmap, double normX, double normY, int radiusPx = 1)
    {
        if (bitmap == null || bitmap.PixelWidth <= 0 || bitmap.PixelHeight <= 0) return null;
        if (!double.IsFinite(normX) || !double.IsFinite(normY)) return null;

        var src = bitmap;
        if (src.Format != PixelFormats.Pbgra32 && src.Format != PixelFormats.Bgra32)
        {
            var converted = new FormatConvertedBitmap(src, PixelFormats.Pbgra32, null, 0);
            converted.Freeze();
            src = converted;
        }

        var w = src.PixelWidth;
        var h = src.PixelHeight;
        var cx = w == 1 ? 0 : Math.Clamp((int)Math.Round(Math.Clamp(normX, 0.0, 1.0) * (w - 1), MidpointRounding.AwayFromZero), 0, w - 1);
        var cy = h == 1 ? 0 : Math.Clamp((int)Math.Round(Math.Clamp(normY, 0.0, 1.0) * (h - 1), MidpointRounding.AwayFromZero), 0, h - 1);
        var r = Math.Max(0, radiusPx);
        var x0 = Math.Max(0, cx - r);
        var x1 = Math.Min(w - 1, cx + r);
        var y0 = Math.Max(0, cy - r);
        var y1 = Math.Min(h - 1, cy + r);
        var boxW = x1 - x0 + 1;
        var boxH = y1 - y0 + 1;
        var stride = boxW * 4;
        var patch = new byte[stride * boxH];
        src.CopyPixels(new Int32Rect(x0, y0, boxW, boxH), patch, stride, 0);

        long sumR = 0, sumG = 0, sumB = 0;
        var count = boxW * boxH;
        for (var i = 0; i < patch.Length; i += 4)
        {
            sumB += patch[i];
            sumG += patch[i + 1];
            sumR += patch[i + 2];
        }
        var avgR = (byte)Math.Clamp((int)Math.Round((double)sumR / count, MidpointRounding.AwayFromZero), 0, 255);
        var avgG = (byte)Math.Clamp((int)Math.Round((double)sumG / count, MidpointRounding.AwayFromZero), 0, 255);
        var avgB = (byte)Math.Clamp((int)Math.Round((double)sumB / count, MidpointRounding.AwayFromZero), 0, 255);
        return InspectionColorSample.FromRgb(avgR, avgG, avgB);
    }

    internal static BitmapSource CreateOverlayBitmap(BitmapSource source, InspectionOverlayMode mode)
    {
        if (mode == InspectionOverlayMode.None) return source;
        if (mode == InspectionOverlayMode.NeutralGray50) return Gray50Bitmap;

        var src = source;
        if (src.Format != PixelFormats.Pbgra32 && src.Format != PixelFormats.Bgra32)
        {
            var converted = new FormatConvertedBitmap(src, PixelFormats.Pbgra32, null, 0);
            converted.Freeze();
            src = converted;
        }

        var w = src.PixelWidth;
        var h = src.PixelHeight;
        var stride = w * 4;
        var srcBytes = new byte[stride * h];
        var dstBytes = new byte[stride * h];
        src.CopyPixels(srcBytes, stride, 0);

        const int chunkRows = 32;
        var chunkCount = (h + chunkRows - 1) / chunkRows;
        Parallel.For(0, chunkCount, chunk =>
        {
            var y0 = chunk * chunkRows;
            var rows = Math.Min(chunkRows, h - y0);
            var offset = y0 * stride;
            InspectionColorMath.ApplyOverlayBgra32(
                srcBytes.AsSpan(offset, rows * stride),
                dstBytes.AsSpan(offset, rows * stride),
                w,
                rows,
                stride,
                stride,
                mode);
        });

        var result = BitmapSource.Create(w, h, src.DpiX, src.DpiY, PixelFormats.Pbgra32, null, dstBytes, stride);
        result.Freeze();
        return result;
    }
}
