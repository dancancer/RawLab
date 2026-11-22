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
    public static InspectionColorSample FromRgb(byte r, byte g, byte b)
    {
        var rf = r / 255.0;
        var gf = g / 255.0;
        var bf = b / 255.0;
        var maxC = Math.Max(rf, Math.Max(gf, bf));
        var minC = Math.Min(rf, Math.Min(gf, bf));
        var delta = maxC - minC;

        var brightnessPct = maxC * 100.0;
        var saturationPct = maxC <= 0.0 ? 0.0 : (delta / maxC) * 100.0;

        var hue = 0.0;
        if (delta > 1e-6)
        {
            double seg;
            if (maxC == rf)
                seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0);
            else if (maxC == gf)
                seg = (bf - rf) / delta + 2.0;
            else
                seg = (rf - gf) / delta + 4.0;
            hue = seg * 60.0;
            if (hue < 0.0) hue += 360.0;
            if (hue >= 360.0) hue -= 360.0;
        }

        var luminance = Math.Clamp((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0, 0.0, 1.0);
        return new InspectionColorSample(r, g, b, hue, saturationPct, brightnessPct, luminance);
    }

    public string RgbText => string.Create(CultureInfo.InvariantCulture, $"{R} {G} {B}");

    public string HsbText => string.Create(CultureInfo.InvariantCulture, $"{HueDeg:0}° {SaturationPct:0}% {BrightnessPct:0}%");

    public static (double R, double G, double B) HsbToRgb(double hueDeg, double saturation, double brightness)
    {
        var h = hueDeg % 360.0;
        if (h < 0.0) h += 360.0;
        var s = Math.Clamp(saturation, 0.0, 1.0);
        var v = Math.Clamp(brightness, 0.0, 1.0);
        var c = v * s;
        var hp = h / 60.0;
        var x = c * (1.0 - Math.Abs(hp % 2.0 - 1.0));
        var m = v - c;
        var sector = ((int)Math.Floor(hp)) % 6;
        var (r1, g1, b1) = sector switch
        {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return (Math.Clamp(r1 + m, 0.0, 1.0), Math.Clamp(g1 + m, 0.0, 1.0), Math.Clamp(b1 + m, 0.0, 1.0));
    }
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
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        int stride,
        double normX,
        double normY,
        int radiusPx = 1)
    {
        if (width <= 0 || height <= 0 || stride < width * 4 || !double.IsFinite(normX) || !double.IsFinite(normY))
            return null;
        if (pixels.Length < (height - 1) * stride + width * 4)
            return null;

        var nx = Math.Clamp(normX, 0.0, 1.0);
        var ny = Math.Clamp(normY, 0.0, 1.0);
        var cx = width == 1 ? 0 : Math.Clamp((int)Math.Round(nx * (width - 1), MidpointRounding.AwayFromZero), 0, width - 1);
        var cy = height == 1 ? 0 : Math.Clamp((int)Math.Round(ny * (height - 1), MidpointRounding.AwayFromZero), 0, height - 1);
        var r = Math.Max(0, radiusPx);
        var x0 = Math.Max(0, cx - r);
        var x1 = Math.Min(width - 1, cx + r);
        var y0 = Math.Max(0, cy - r);
        var y1 = Math.Min(height - 1, cy + r);

        long sumR = 0, sumG = 0, sumB = 0;
        var count = 0;
        for (var y = y0; y <= y1; y++)
        {
            var rowOffset = y * stride;
            for (var x = x0; x <= x1; x++)
            {
                var off = rowOffset + x * 4;
                sumB += pixels[off];
                sumG += pixels[off + 1];
                sumR += pixels[off + 2];
                count++;
            }
        }
        if (count <= 0) return null;

        var avgR = (byte)Math.Clamp((int)Math.Round((double)sumR / count, MidpointRounding.AwayFromZero), 0, 255);
        var avgG = (byte)Math.Clamp((int)Math.Round((double)sumG / count, MidpointRounding.AwayFromZero), 0, 255);
        var avgB = (byte)Math.Clamp((int)Math.Round((double)sumB / count, MidpointRounding.AwayFromZero), 0, 255);
        return InspectionColorSample.FromRgb(avgR, avgG, avgB);
    }

    public static (byte R, byte G, byte B) ApplyOverlayPixel(byte r, byte g, byte b, InspectionOverlayMode mode)
    {
        switch (mode)
        {
            case InspectionOverlayMode.None:
                return (r, g, b);
            case InspectionOverlayMode.NeutralGray50:
                return (128, 128, 128);
            case InspectionOverlayMode.SketchLuminance:
            {
                var rf = r / 255.0;
                var gf = g / 255.0;
                var bf = b / 255.0;
                var y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
                var t = Math.Clamp((y - 0.5) * 2.4 + 0.5, 0.0, 1.0);
                var v = t * t * (3.0 - 2.0 * t);
                var outVal = ToByte(v);
                return (outVal, outVal, outVal);
            }
            case InspectionOverlayMode.WarmCoolBW:
            {
                var rf = r / 255.0;
                var gf = g / 255.0;
                var bf = b / 255.0;
                var y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
                var warmth = (rf - bf) + 0.35 * (gf - bf);
                var v = Math.Clamp(y + 0.55 * warmth, 0.0, 1.0);
                var outVal = ToByte(v);
                return (outVal, outVal, outVal);
            }
            case InspectionOverlayMode.OversaturationHeatmap:
            {
                var rf = r / 255.0;
                var gf = g / 255.0;
                var bf = b / 255.0;
                var maxC = Math.Max(rf, Math.Max(gf, bf));
                var minC = Math.Min(rf, Math.Min(gf, bf));
                var delta = maxC - minC;
                var bright = maxC;
                var sat = maxC <= 0.0 ? 0.0 : delta / maxC;
                var y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
                var baseVal = 0.28 * y;

                double or_, og_, ob_;
                if (minC >= 0.996)
                {
                    (or_, og_, ob_) = (1.0, 0.25, 0.25);
                }
                else if (maxC >= 0.996 && minC < 0.96)
                {
                    (or_, og_, ob_) = (1.0, 0.10, 0.55);
                }
                else if (sat > 0.85 && bright > 0.35)
                {
                    var sev = Math.Clamp(((sat - 0.85) / 0.15) * 0.7 + ((bright - 0.35) / 0.65) * 0.3, 0.0, 1.0);
                    if (sev < 0.5)
                    {
                        var u = sev * 2.0;
                        (or_, og_, ob_) = (1.0, 0.90 + (0.45 - 0.90) * u, 0.0);
                    }
                    else
                    {
                        var u = (sev - 0.5) * 2.0;
                        (or_, og_, ob_) = (1.0, 0.45 + (0.08 - 0.45) * u, 0.12 * u);
                    }
                }
                else if (sat > 0.75 && bright > 0.35)
                {
                    var t = Math.Clamp((sat - 0.75) / 0.10, 0.0, 1.0) * 0.65;
                    or_ = baseVal + (1.0 - baseVal) * t;
                    og_ = baseVal + (0.72 - baseVal) * t;
                    ob_ = baseVal + (0.12 - baseVal) * t;
                }
                else
                {
                    (or_, og_, ob_) = (baseVal, baseVal, baseVal);
                }

                return (ToByte(or_), ToByte(og_), ToByte(ob_));
            }
            case InspectionOverlayMode.SkinHueAmplification:
            {
                var rf = r / 255.0;
                var gf = g / 255.0;
                var bf = b / 255.0;
                var maxC = Math.Max(rf, Math.Max(gf, bf));
                var minC = Math.Min(rf, Math.Min(gf, bf));
                var delta = maxC - minC;
                var bright = maxC;
                var sat = maxC <= 0.0 ? 0.0 : delta / maxC;
                var hue = 0.0;
                if (delta > 1e-6)
                {
                    double seg;
                    if (maxC == rf)
                        seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0);
                    else if (maxC == gf)
                        seg = (bf - rf) / delta + 2.0;
                    else
                        seg = (rf - gf) / delta + 4.0;
                    hue = seg * 60.0;
                    if (hue < 0.0) hue += 360.0;
                    if (hue >= 360.0) hue -= 360.0;
                }
                if (hue >= 0.0 && hue <= 50.0 && sat >= 0.05 && bright >= 0.08)
                {
                    var stretchedHue = hue <= 22.0
                        ? (330.0 + 65.0 * (hue / 22.0)) % 360.0
                        : 35.0 + 115.0 * ((hue - 22.0) / 28.0);
                    var sPrime = Math.Clamp(Math.Max(0.55, sat * 1.8), 0.0, 1.0);
                    var bPrime = Math.Clamp(0.35 + 0.65 * bright, 0.0, 1.0);
                    var (nr, ng, nb) = InspectionColorSample.HsbToRgb(stretchedHue, sPrime, bPrime);
                    return (ToByte(nr), ToByte(ng), ToByte(nb));
                }
                var y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
                var muted = ToByte(0.35 * y);
                return (muted, muted, muted);
            }
            default:
                return (r, g, b);
        }
    }

    public static void ApplyOverlayBgra32(
        ReadOnlySpan<byte> src,
        Span<byte> dst,
        int width,
        int height,
        int srcStride,
        int dstStride,
        InspectionOverlayMode mode)
    {
        for (var y = 0; y < height; y++)
        {
            var sRow = y * srcStride;
            var dRow = y * dstStride;
            for (var x = 0; x < width; x++)
            {
                var sOff = sRow + x * 4;
                var dOff = dRow + x * 4;
                var (or_, og_, ob_) = ApplyOverlayPixel(src[sOff + 2], src[sOff + 1], src[sOff], mode);
                dst[dOff] = ob_;
                dst[dOff + 1] = og_;
                dst[dOff + 2] = or_;
                dst[dOff + 3] = 255;
            }
        }
    }

    private static byte ToByte(double value) =>
        (byte)Math.Clamp((int)Math.Round(value * 255.0, MidpointRounding.AwayFromZero), 0, 255);
}

public static class GeometryCoordinateMapper
{
    public readonly record struct CanvasSpec(
        int RotatedWidth,
        int RotatedHeight,
        int Width,
        int Height,
        int Left,
        int Top,
        int Right,
        int Bottom,
        double Cosine,
        double Sine)
    {
        public int OutputWidth => Right - Left;
        public int OutputHeight => Bottom - Top;
    }

    public static CanvasSpec CanvasFor(int width, int height, GeometrySettings options)
    {
        var safeW = Math.Max(1, width);
        var safeH = Math.Max(1, height);
        var turns = ((options.QuarterTurns % 4) + 4) % 4;
        var rotatedWidth = turns % 2 != 0 ? safeH : safeW;
        var rotatedHeight = turns % 2 != 0 ? safeW : safeH;
        var radians = options.StraightenDegrees * Math.PI / 180.0;
        var cosine = Math.Cos(radians);
        var sine = Math.Sin(radians);
        var absSine = Math.Abs(sine);
        var perspScale = 1.0 / (1.0 + 0.25 * Math.Abs(options.PerspectiveHorizontal) + 0.25 * Math.Abs(options.PerspectiveVertical));
        var w = Math.Max(1, (int)Math.Floor(rotatedWidth * perspScale));
        var h = Math.Max(1, (int)Math.Floor(rotatedHeight * perspScale));
        var scale = Math.Min((double)w / (w * cosine + h * absSine), (double)h / (w * absSine + h * cosine));
        var canvasW = Math.Max(1, (int)Math.Floor(w * scale));
        var canvasH = Math.Max(1, (int)Math.Floor(h * scale));
        var left = Math.Clamp((int)Math.Floor(options.CropX * canvasW), 0, canvasW - 1);
        var top = Math.Clamp((int)Math.Floor(options.CropY * canvasH), 0, canvasH - 1);
        var right = Math.Min(canvasW, Math.Max(left + 1, (int)Math.Ceiling(Math.Min(1.0, options.CropX + options.CropWidth) * canvasW)));
        var bottom = Math.Min(canvasH, Math.Max(top + 1, (int)Math.Ceiling(Math.Min(1.0, options.CropY + options.CropHeight) * canvasH)));
        return new CanvasSpec(rotatedWidth, rotatedHeight, canvasW, canvasH, left, top, right, bottom, cosine, sine);
    }

    public static (int Width, int Height) InferSourceSize(int outputWidth, int outputHeight, GeometrySettings options)
    {
        var safeW = Math.Max(1, outputWidth);
        var safeH = Math.Max(1, outputHeight);
        if (options.IsIdentity) return (safeW, safeH);
        var radians = options.StraightenDegrees * Math.PI / 180.0;
        var cosine = Math.Cos(radians);
        var absSine = Math.Abs(Math.Sin(radians));
        var perspScale = 1.0 / (1.0 + 0.25 * Math.Abs(options.PerspectiveHorizontal) + 0.25 * Math.Abs(options.PerspectiveVertical));
        var cw = safeW / Math.Max(0.0001, options.CropWidth);
        var ch = safeH / Math.Max(0.0001, options.CropHeight);
        var straightenScale = Math.Min(cw / (cw * cosine + ch * absSine), ch / (cw * absSine + ch * cosine));
        var rw = Math.Max(1, (int)Math.Round(cw / Math.Max(1e-4, perspScale * straightenScale)));
        var rh = Math.Max(1, (int)Math.Round(ch / Math.Max(1e-4, perspScale * straightenScale)));
        return (((options.QuarterTurns % 4) + 4) % 4) % 2 != 0 ? (rh, rw) : (rw, rh);
    }

    public static (double X, double Y)? OutputNormToSourceNorm(
        double outX,
        double outY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry)
    {
        if (!double.IsFinite(outX) || !double.IsFinite(outY) ||
            outX < -1e-4 || outX > 1.0 + 1e-4 || outY < -1e-4 || outY > 1.0 + 1e-4 ||
            sourceWidth < 1 || sourceHeight < 1)
            return null;

        var clampedOutX = Math.Clamp(outX, 0.0, 1.0);
        var clampedOutY = Math.Clamp(outY, 0.0, 1.0);
        if (geometry.IsIdentity) return (clampedOutX, clampedOutY);

        var canvas = CanvasFor(sourceWidth, sourceHeight, geometry);
        var x = clampedOutX * canvas.OutputWidth - 0.5;
        var y = clampedOutY * canvas.OutputHeight - 0.5;
        var dy = canvas.Top + y - (canvas.Height - 1) * 0.5;
        var dx = canvas.Left + x - (canvas.Width - 1) * 0.5;
        var rotatedX = canvas.Cosine * dx + canvas.Sine * dy;
        var rotatedY = -canvas.Sine * dx + canvas.Cosine * dy;
        var denominator = 1.0
            + 0.25 * geometry.PerspectiveHorizontal * (2.0 * rotatedX / canvas.RotatedWidth)
            + 0.25 * geometry.PerspectiveVertical * (2.0 * rotatedY / canvas.RotatedHeight);
        if (Math.Abs(denominator) <= 1e-6) return null;

        var px = (canvas.RotatedWidth - 1) * 0.5 + rotatedX / denominator;
        var py = (canvas.RotatedHeight - 1) * 0.5 + rotatedY / denominator;
        if (geometry.FlipHorizontal) px = (canvas.RotatedWidth - 1) - px;
        if (geometry.FlipVertical) py = (canvas.RotatedHeight - 1) - py;

        var turns = ((geometry.QuarterTurns % 4) + 4) % 4;
        var (sx, sy) = turns switch
        {
            1 => (py, (double)(sourceHeight - 1) - px),
            2 => ((double)(sourceWidth - 1) - px, (double)(sourceHeight - 1) - py),
            3 => ((double)(sourceWidth - 1) - py, px),
            _ => (px, py),
        };

        var uSrc = (sx + 0.5) / sourceWidth;
        var vSrc = (sy + 0.5) / sourceHeight;
        if (uSrc < -1e-3 || uSrc > 1.0 + 1e-3 || vSrc < -1e-3 || vSrc > 1.0 + 1e-3)
            return null;
        return (Math.Clamp(uSrc, 0.0, 1.0), Math.Clamp(vSrc, 0.0, 1.0));
    }

    public static (double X, double Y)? SourceNormToOutputNorm(
        double srcX,
        double srcY,
        int sourceWidth,
        int sourceHeight,
        GeometrySettings geometry)
    {
        if (!double.IsFinite(srcX) || !double.IsFinite(srcY) ||
            srcX < -1e-4 || srcX > 1.0 + 1e-4 || srcY < -1e-4 || srcY > 1.0 + 1e-4 ||
            sourceWidth < 1 || sourceHeight < 1)
            return null;

        var clampedSrcX = Math.Clamp(srcX, 0.0, 1.0);
        var clampedSrcY = Math.Clamp(srcY, 0.0, 1.0);
        if (geometry.IsIdentity) return (clampedSrcX, clampedSrcY);

        var canvas = CanvasFor(sourceWidth, sourceHeight, geometry);
        var sx = clampedSrcX * sourceWidth - 0.5;
        var sy = clampedSrcY * sourceHeight - 0.5;

        var turns = ((geometry.QuarterTurns % 4) + 4) % 4;
        var (px, py) = turns switch
        {
            1 => ((double)(sourceHeight - 1) - sy, sx),
            2 => ((double)(sourceWidth - 1) - sx, (double)(sourceHeight - 1) - sy),
            3 => (sy, (double)(sourceWidth - 1) - sx),
            _ => (sx, sy),
        };

        if (geometry.FlipHorizontal) px = (canvas.RotatedWidth - 1) - px;
        if (geometry.FlipVertical) py = (canvas.RotatedHeight - 1) - py;

        var ax = px - (canvas.RotatedWidth - 1) * 0.5;
        var ay = py - (canvas.RotatedHeight - 1) * 0.5;
        var ch = 0.5 * geometry.PerspectiveHorizontal / canvas.RotatedWidth;
        var cv = 0.5 * geometry.PerspectiveVertical / canvas.RotatedHeight;
        var denom = 1.0 - ch * ax - cv * ay;
        if (denom <= 1e-6) return null;

        var rx = ax / denom;
        var ry = ay / denom;
        var dx = canvas.Cosine * rx - canvas.Sine * ry;
        var dy = canvas.Sine * rx + canvas.Cosine * ry;
        var cx = dx + (canvas.Width - 1) * 0.5;
        var cy = dy + (canvas.Height - 1) * 0.5;
        var x = cx - canvas.Left;
        var y = cy - canvas.Top;

        var uOut = (x + 0.5) / canvas.OutputWidth;
        var vOut = (y + 0.5) / canvas.OutputHeight;
        if (uOut < -1e-4 || uOut > 1.0 + 1e-4 || vOut < -1e-4 || vOut > 1.0 + 1e-4)
            return null;
        return (Math.Clamp(uOut, 0.0, 1.0), Math.Clamp(vOut, 0.0, 1.0));
    }
}
