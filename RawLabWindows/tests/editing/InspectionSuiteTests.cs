using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class InspectionSuiteTests
{
    [Fact]
    [Trait("Category", "Model")]
    public void ColorMathAndLuminanceMatchCanonicalContract()
    {
        var red = InspectionColorSample.FromRgb(255, 0, 0);
        Assert.InRange(red.HueDeg, -0.01, 0.01);
        Assert.InRange(red.SaturationPct, 99.99, 100.01);
        Assert.InRange(red.BrightnessPct, 99.99, 100.01);
        Assert.InRange(red.Luminance, 0.2125, 0.2127);

        var green = InspectionColorSample.FromRgb(0, 255, 0);
        Assert.InRange(green.HueDeg, 119.99, 120.01);
        Assert.InRange(green.Luminance, 0.7151, 0.7153);

        var blue = InspectionColorSample.FromRgb(0, 0, 255);
        Assert.InRange(blue.HueDeg, 239.99, 240.01);
        Assert.InRange(blue.Luminance, 0.0721, 0.0723);

        var gray = InspectionColorSample.FromRgb(128, 128, 128);
        Assert.Equal(0.0, gray.SaturationPct, 3);
        Assert.InRange(gray.Luminance, 128.0 / 255.0 - 1e-4, 128.0 / 255.0 + 1e-4);

        // 3x3 BGRA32 box sampling: left half (100,100,100), right half (200,100,50)
        const int w = 4, h = 4, stride = w * 4;
        var buf = new byte[stride * h];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var off = y * stride + x * 4;
                var r = x < 2 ? (byte)100 : (byte)200;
                var g = (byte)100;
                var b = x < 2 ? (byte)100 : (byte)50;
                buf[off] = b;
                buf[off + 1] = g;
                buf[off + 2] = r;
                buf[off + 3] = 255;
            }
        }
        var corner = InspectionColorMath.SampleBgra32(buf, w, h, stride, 0, 0, radiusPx: 0);
        Assert.NotNull(corner);
        Assert.Equal((byte)100, corner!.Value.R);

        var straddle = InspectionColorMath.SampleBgra32(buf, w, h, stride, 1.0 / 3.0, 0.5, radiusPx: 1);
        Assert.NotNull(straddle);
        Assert.Equal((byte)133, straddle!.Value.R);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void GeometryCoordinateMapperRoundTripsAndDetectsCropOut()
    {
        const int srcW = 4000, srcH = 3000;
        var cases = new[]
        {
            new GeometrySettings(),
            new GeometrySettings(QuarterTurns: 1),
            new GeometrySettings(QuarterTurns: 2, FlipHorizontal: true),
            new GeometrySettings(QuarterTurns: 3, FlipVertical: true),
            new GeometrySettings(0.1, 0.2, 0.6, 0.5, 1, true, false, 7.5, 0.35, -0.25),
            new GeometrySettings(0.15, 0.1, 0.7, 0.75, 0, false, true, -12.0, -0.4, 0.5),
        };

        foreach (var geom in cases)
        {
            foreach (var (ox, oy) in new[] { (0.5, 0.5), (0.35, 0.6), (0.68, 0.42) })
            {
                var src = GeometryCoordinateMapper.OutputNormToSourceNorm(ox, oy, srcW, srcH, geom);
                Assert.NotNull(src);
                var back = GeometryCoordinateMapper.SourceNormToOutputNorm(src!.Value.X, src.Value.Y, srcW, srcH, geom);
                Assert.NotNull(back);
                Assert.InRange(back!.Value.X, ox - 1e-4, ox + 1e-4);
                Assert.InRange(back.Value.Y, oy - 1e-4, oy + 1e-4);
            }
        }

        var cropped = new GeometrySettings(0.25, 0.25, 0.5, 0.5);
        Assert.Null(GeometryCoordinateMapper.SourceNormToOutputNorm(0.1, 0.1, srcW, srcH, cropped));
        Assert.NotNull(GeometryCoordinateMapper.SourceNormToOutputNorm(0.5, 0.5, srcW, srcH, cropped));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void SessionStateFourAnchorCapAndOverlaysAndZeroRecipePollution()
    {
        var session = new InspectionSessionState();
        for (var i = 0; i < 4; i++)
            Assert.NotNull(session.PinAnchor(0.1 * (i + 1), 0.5));
        Assert.False(session.CanPinMore);
        Assert.Null(session.PinAnchor(0.9, 0.9));
        Assert.Equal(4, session.Anchors.Count);

        session.SelectOverlay(InspectionOverlayMode.WarmCoolBW);
        session.ToggleNeutralGray50();
        Assert.Equal(InspectionOverlayMode.NeutralGray50, session.Overlay);
        Assert.True(session.HandleEscape());
        Assert.Equal(InspectionOverlayMode.WarmCoolBW, session.Overlay);

        var (dr, dg, db) = InspectionColorMath.ApplyOverlayPixel(80, 80, 80, InspectionOverlayMode.SketchLuminance);
        var (br, bg, bb) = InspectionColorMath.ApplyOverlayPixel(180, 180, 180, InspectionOverlayMode.SketchLuminance);
        Assert.True(dr == dg && dg == db && dr < 80);
        Assert.True(br == bg && bg == bb && br > 180);

        var warm = InspectionColorMath.ApplyOverlayPixel(180, 140, 60, InspectionOverlayMode.WarmCoolBW);
        var cool = InspectionColorMath.ApplyOverlayPixel(60, 140, 220, InspectionOverlayMode.WarmCoolBW);
        Assert.True(warm.R > cool.R);

        var clip = InspectionColorMath.ApplyOverlayPixel(255, 100, 100, InspectionOverlayMode.OversaturationHeatmap);
        Assert.Equal((byte)255, clip.R);
        Assert.True(clip.B > 100);

        var redSkin = InspectionColorMath.ApplyOverlayPixel(210, 130, 120, InspectionOverlayMode.SkinHueAmplification);
        var yellowSkin = InspectionColorMath.ApplyOverlayPixel(210, 195, 120, InspectionOverlayMode.SkinHueAmplification);
        Assert.True(yellowSkin.G > redSkin.G);

        var gray50 = InspectionColorMath.ApplyOverlayPixel(20, 200, 250, InspectionOverlayMode.NeutralGray50);
        Assert.Equal(((byte)128, (byte)128, (byte)128), gray50);

        // Zero CanonicalEditRecipe pollution
        var settings = new Adjustments
        {
            Geometry = new GeometrySettings(0.1, 0.1, 0.8, 0.8, QuarterTurns: 1),
        };
        settings.Set(Parameter.Exposure, 0.4);
        var baseRecipe = CanonicalEditRecipe.Encode(settings, isRaster: false);
        foreach (var mode in Enum.GetValues<InspectionOverlayMode>())
        {
            session.SelectOverlay(mode);
            Assert.Equal(baseRecipe, CanonicalEditRecipe.Encode(settings, isRaster: false));
        }

        session.ResetForNewSource();
        Assert.Empty(session.Anchors);
        Assert.Equal(InspectionOverlayMode.None, session.Overlay);
    }

    [StaFact]
    [Trait("Category", "WpfModel")]
    [Trait("Suite", "inspection-suite")]
    public void OverlayRendererAndHistogramCursorPreserveExportByteIdentity()
    {
        const int w = 16, h = 16, stride = w * 4;
        var pixels = new byte[stride * h];
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var off = y * stride + x * 4;
                pixels[off] = (byte)(x < 8 ? 110 : 220);
                pixels[off + 1] = 135;
                pixels[off + 2] = (byte)(x < 8 ? 220 : 60);
                pixels[off + 3] = 255;
            }
        }
        var source = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
        source.Freeze();

        static byte[] EncodePng(BitmapSource bmp)
        {
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }

        static byte[] EncodeJpeg(BitmapSource bmp)
        {
            var enc = new JpegBitmapEncoder { QualityLevel = 92 };
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }

        var baselinePng = EncodePng(source);
        var baselineJpeg = EncodeJpeg(source);

        var histogram = new HistogramView();
        histogram.SetLuminanceCursor(0.5);
        Assert.Equal(0.5, histogram.LuminanceCursor);
        histogram.SetLuminanceCursor(null);
        Assert.Null(histogram.LuminanceCursor);

        var session = new InspectionSessionState();
        foreach (var mode in Enum.GetValues<InspectionOverlayMode>())
        {
            session.SelectOverlay(mode);
            var viewBitmap = InspectionOverlayRenderer.CreateOverlayBitmap(source, mode);
            Assert.NotNull(viewBitmap);
            if (mode == InspectionOverlayMode.NeutralGray50)
            {
                var graySample = InspectionOverlayRenderer.SampleBitmap(viewBitmap, 0.5, 0.5, 0);
                Assert.NotNull(graySample);
                Assert.Equal((byte)128, graySample!.Value.R);
                Assert.Equal((byte)128, graySample.Value.G);
                Assert.Equal((byte)128, graySample.Value.B);
            }
            // Source bitmap & export bytes remain untouched
            Assert.Equal(baselinePng, EncodePng(source));
            Assert.Equal(baselineJpeg, EncodeJpeg(source));
        }
    }
}
