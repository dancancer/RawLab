using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal sealed class InspectionOverlayCache
{
    private readonly struct CacheKey : IEquatable<CacheKey>
    {
        public BitmapSource Source { get; }
        public InspectionOverlayMode Mode { get; }

        public CacheKey(BitmapSource source, InspectionOverlayMode mode)
        {
            Source = source;
            Mode = mode;
        }

        public bool Equals(CacheKey other) => ReferenceEquals(Source, other.Source) && Mode == other.Mode;

        public override bool Equals(object? obj) => obj is CacheKey other && Equals(other);

        public override int GetHashCode() => HashCode.Combine(RuntimeHelpers.GetHashCode(Source), (int)Mode);
    }

    private readonly object gate = new();
    private readonly int maxEntries;
    private readonly Dictionary<CacheKey, BitmapSource> entries = new();
    private readonly List<CacheKey> lru = new();
    private readonly HashSet<CacheKey> inFlight = new();

    public InspectionOverlayCache(int maxEntries = 4)
    {
        this.maxEntries = Math.Max(1, maxEntries);
    }

    public int Count
    {
        get { lock (gate) return entries.Count; }
    }

    public int InFlightCount
    {
        get { lock (gate) return inFlight.Count; }
    }

    public void Clear()
    {
        lock (gate)
        {
            entries.Clear();
            lru.Clear();
            inFlight.Clear();
        }
    }

    public bool TryGet(BitmapSource source, InspectionOverlayMode mode, out BitmapSource transformed)
    {
        var key = new CacheKey(source, mode);
        lock (gate)
        {
            if (entries.TryGetValue(key, out var hit))
            {
                lru.Remove(key);
                lru.Add(key);
                transformed = hit;
                return true;
            }
        }
        transformed = null!;
        return false;
    }

    public bool TryBeginRender(BitmapSource source, InspectionOverlayMode mode)
    {
        var key = new CacheKey(source, mode);
        lock (gate)
        {
            if (entries.ContainsKey(key)) return false;
            return inFlight.Add(key);
        }
    }

    public void CompleteRender(BitmapSource source, InspectionOverlayMode mode, BitmapSource transformed)
    {
        var key = new CacheKey(source, mode);
        lock (gate)
        {
            inFlight.Remove(key);
            entries[key] = transformed;
            lru.Remove(key);
            lru.Add(key);
            while (lru.Count > maxEntries)
            {
                var oldest = lru[0];
                lru.RemoveAt(0);
                entries.Remove(oldest);
            }
        }
    }

    public void CancelRender(BitmapSource source, InspectionOverlayMode mode)
    {
        var key = new CacheKey(source, mode);
        lock (gate)
        {
            inFlight.Remove(key);
        }
    }
}

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

        var localNormX = boxW == 1 ? 0.0 : (double)(cx - x0) / (boxW - 1);
        var localNormY = boxH == 1 ? 0.0 : (double)(cy - y0) / (boxH - 1);
        return InspectionColorMath.SampleBgra32(patch, boxW, boxH, stride, localNormX, localNormY, r);
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
        InspectionColorMath.ApplyOverlayBgra32(srcBytes, dstBytes, w, h, stride, stride, mode);

        var result = BitmapSource.Create(w, h, src.DpiX, src.DpiY, PixelFormats.Pbgra32, null, dstBytes, stride);
        result.Freeze();
        return result;
    }
}
