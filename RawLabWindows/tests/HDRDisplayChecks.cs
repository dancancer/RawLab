using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;
using Xunit;

// CopySDROnly 行为测试：导出尾趟等 SDR-only 消费者不得再为 HDR 平面分配第二份
// 整幅 float[]（LOH）；校验契约与 CopyPair 对齐（撤掉别名或漏检形状都能变红）。
internal static class HDRDisplayChecks
{
    private static Native.HDRBuffer Buffer(GCHandle handle, uint width, uint height) => new()
    {
        Data = handle.AddrOfPinnedObject(),
        SizeBytes = height * width * 12,
        Width = width,
        Height = height,
        StrideBytes = width * 12,
        PixelFormat = HDRNative.PixelRGB32FLinear,
        ColorEncoding = HDRNative.LinearSRGB,
        ContentHeadroom = 2f,
        HeadroomKind = 1
    };

    internal static void Run(Action<bool, string> check)
    {
        var hdrValues = Enumerable.Range(0, 12).Select(i => 2f + i).ToArray();        // 与 SDR 明显不同的像素
        var sdrValues = Enumerable.Range(0, 12).Select(i => i * 0.05f).ToArray();
        var hdrPin = GCHandle.Alloc(hdrValues, GCHandleType.Pinned);
        var sdrPin = GCHandle.Alloc(sdrValues, GCHandleType.Pinned);
        try
        {
            Native.HDRImagePair Synthetic() => new()
            {
                Hdr = Buffer(hdrPin, 2, 2),
                Sdr = Buffer(sdrPin, 2, 2),
                NativeWidth = 4000,
                NativeHeight = 3000,
                OrientationApplied = 1,
                OutputNativeWidth = 7,
                OutputNativeHeight = 5,
                SourceSha256 = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray()
            };

            var full = HDRDisplay.CopyPair(Synthetic());
            var tail = HDRDisplay.CopySDROnly(Synthetic());
            check(tail.SDR.RGB.SequenceEqual(sdrValues) && tail.SDR.StrideBytes == 24 &&
                tail.SDR.ContentHeadroom == 2f, "CopySDROnly clones the SDR plane exactly");
            check(ReferenceEquals(tail.HDR, tail.SDR),
                "CopySDROnly allocates one float[] for SDR-only consumers (no second LOH plane)");
            check(!ReferenceEquals(full.HDR, full.SDR) && full.HDR.RGB.SequenceEqual(hdrValues),
                "CopyPair keeps cloning both planes for HDR consumers");
            check(tail.SourceSha256.SequenceEqual(full.SourceSha256) && tail.OutputNativeWidth == 7 &&
                tail.NativeWidth == 4000 && !tail.IsProxy, "CopySDROnly preserves the pair contract fields");

            var truncated = Synthetic();
            truncated.Hdr.Width = 3;
            try
            {
                HDRDisplay.CopySDROnly(truncated);
                check(false, "CopySDROnly accepted a truncated HDR plane");
            }
            catch (InvalidDataException)
            {
                check(true, "CopySDROnly validates both plane shapes before copying");
            }

            var rotated = Synthetic();
            rotated.OrientationApplied = 0;
            try
            {
                HDRDisplay.CopySDROnly(rotated);
                check(false, "CopySDROnly accepted an unoriented pair");
            }
            catch (InvalidDataException)
            {
                check(true, "CopySDROnly keeps the orientation and native-size contract");
            }
        }
        finally
        {
            hdrPin.Free();
            sdrPin.Free();
        }
    }
}

public sealed class HDRDisplayTests
{
    private static byte ScalarToByte(float value)
    {
        if (!float.IsFinite(value)) throw new InvalidDataException("Nonfinite SDR rendition");
        value = Math.Clamp(value, 0f, 1f);
        var encoded = value <= .0031308f ? 12.92f * value : 1.055f * MathF.Pow(value, 1f / 2.4f) - .055f;
        return (byte)Math.Clamp(MathF.Round(encoded * 255f, MidpointRounding.AwayFromZero), 0f, 255f);
    }

    private static byte[] CopyBgraBytes(BitmapSource bitmap)
    {
        var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyPixels(bytes, bitmap.PixelWidth * 4, 0);
        return bytes;
    }

    private static HDRFloatImage MakeImage(int width, int height, Func<int, float> generator)
    {
        var rgb = new float[width * height * 3];
        for (var i = 0; i < rgb.Length; i++) rgb[i] = generator(i);
        return new(width, height, width * 12, rgb, 2.0f, 1);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void HdrRenderedPairCachesSdrBitmapThreadSafelyAndIgnoresCacheInEquality()
    {
        var image = MakeImage(17, 11, i => (i % 97) / 96f);
        var sha = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var pair = new HDRRenderedPair(image, image, 17, 11, 17, 11, false, sha);
        var twin = new HDRRenderedPair(image, image, 17, 11, 17, 11, false, sha);

        using var start = new ManualResetEventSlim(false);
        var results = new BitmapSource[4];
        var threads = Enumerable.Range(0, 4).Select(idx => new Thread(() =>
        {
            start.Wait();
            results[idx] = pair.SDRBitmap;
        })).ToArray();
        foreach (var thread in threads) thread.Start();
        start.Set();
        foreach (var thread in threads) thread.Join();

        Assert.True(results[0].IsFrozen);
        for (var i = 1; i < results.Length; i++)
            Assert.True(ReferenceEquals(results[0], results[i]), "Concurrent SDRBitmap reads must share one cached instance");
        Assert.True(ReferenceEquals(pair.SDRBitmap, results[0]));

        _ = pair.Statistics;
        Assert.True(pair.Equals(twin));
        Assert.Equal(pair.GetHashCode(), twin.GetHashCode());

        var seededPair = new HDRRenderedPair(image, image, 17, 11, 17, 11, false, sha);
        var rendered = HDRDisplay.RenderSDRWithStatistics(image, clipping: false);
        seededPair.SeedSDRBitmap(rendered.Bitmap);
        Assert.True(ReferenceEquals(seededPair.SDRBitmap, rendered.Bitmap));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void SimdSdrConversionMatchesScalarReferenceAndStatisticsBitForBit()
    {
        float[] samples =
        [
            -0.5f, 0f, 0.0005f, 0.0031308f, 0.0031309f, 0.02f, 0.05f, 0.18f,
            0.35f, 0.5f, 0.75f, 0.999f, 1.0f, 1.5f, 4.0f
        ];
        // 11 * 7 = 77 pixels = 231 floats -> exercises SIMD chunks AND scalar tail.
        var image = MakeImage(11, 7, i =>
        {
            var p = i / 3;
            if (p == 0) return 0f;     // pure black shadow pixel
            if (p == 1) return 1.2f;   // pure white highlight pixel
            if (p == 2) return i % 3 == 0 ? 1.0f : 0.25f; // single-channel highlight
            return samples[i % samples.Length];
        });

        var rgb8 = HDRDisplay.SDRRgb8(image);
        Assert.Equal(image.RGB.Length, rgb8.Length);
        for (var i = 0; i < image.RGB.Length; i++)
        {
            var expected = ScalarToByte(image.RGB[i]);
            if (image.RGB[i] <= 0f) Assert.Equal(0, rgb8[i]);
            else if (image.RGB[i] >= 1f) Assert.Equal(255, rgb8[i]);
            else Assert.True(Math.Abs(rgb8[i] - expected) <= 1,
                $"Channel {i} (v={image.RGB[i]}): actual={rgb8[i]}, expected={expected}");
        }

        var directBitmap = HDRDisplay.SDRBitmap(image);
        var directBgra = CopyBgraBytes(directBitmap);
        for (var p = 0; p < 11 * 7; p++)
        {
            Assert.Equal(rgb8[p * 3 + 2], directBgra[p * 4]);
            Assert.Equal(rgb8[p * 3 + 1], directBgra[p * 4 + 1]);
            Assert.Equal(rgb8[p * 3], directBgra[p * 4 + 2]);
            Assert.Equal(255, directBgra[p * 4 + 3]);
        }

        var singlePass = HDRDisplay.RenderSDRWithStatistics(image, clipping: true);
        var standaloneStats = HDRDisplay.Statistics(image, clipping: true);
        var singlePassBgra = CopyBgraBytes(singlePass.Bitmap);

        Assert.Equal(directBgra, singlePassBgra);
        Assert.Equal(standaloneStats.Histogram, singlePass.Histogram);
        Assert.Equal(standaloneStats.Shadows, singlePass.Shadows);
        Assert.Equal(standaloneStats.Highlights, singlePass.Highlights);
        Assert.NotNull(singlePass.Clipping);
        Assert.NotNull(standaloneStats.Clipping);
        Assert.Equal(CopyBgraBytes(standaloneStats.Clipping!), CopyBgraBytes(singlePass.Clipping!));

        // Verify 768-bin histogram matches actual Bitmap pixels bit-for-bit.
        var pixelBins = new uint[768];
        for (var o = 0; o < singlePassBgra.Length; o += 4)
        {
            pixelBins[singlePassBgra[o + 2]]++;
            pixelBins[256 + singlePassBgra[o + 1]]++;
            pixelBins[512 + singlePassBgra[o]]++;
        }
        Assert.Equal(pixelBins, singlePass.Histogram);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void NonFiniteValuesThrowInvalidDataExceptionInSimdAlignedAndTailPositions()
    {
        var floatCount = Vector<float>.Count * 3 * 2 + 6; // guaranteed aligned + tail
        var width = floatCount / 3;
        foreach (var bad in new[] { float.NaN, float.PositiveInfinity, float.NegativeInfinity })
        foreach (var badIndex in new[] { 0, floatCount - 1 })
        {
            var image = MakeImage(width, 1, i => i == badIndex ? bad : 0.25f);
            Assert.Throws<InvalidDataException>(() => HDRDisplay.SDRBitmap(image));
            Assert.Throws<InvalidDataException>(() => HDRDisplay.RenderSDRWithStatistics(image, clipping: false));
            Assert.Throws<InvalidDataException>(() => HDRDisplay.SDRRgb8(image));
            Assert.Throws<InvalidDataException>(() => HDRDisplay.Statistics(image, clipping: false));
            Assert.Throws<InvalidDataException>(() => HDRDisplay.Analyze(image));

            // Also verify CopyPair (both tight stride and padded stride) rejects non-finite floats.
            var paddedWidth = width;
            var paddedHeight = 2;
            var strideFloats = paddedWidth * 3 + 2;
            var rawBuffer = new float[strideFloats * paddedHeight];
            Array.Fill(rawBuffer, 0.25f);
            rawBuffer[badIndex == 0 ? 0 : strideFloats + paddedWidth * 3 - 1] = bad;
            var pin = GCHandle.Alloc(rawBuffer, GCHandleType.Pinned);
            try
            {
                var buffer = new Native.HDRBuffer
                {
                    Data = pin.AddrOfPinnedObject(),
                    SizeBytes = (ulong)(rawBuffer.Length * sizeof(float)),
                    Width = (uint)paddedWidth,
                    Height = (uint)paddedHeight,
                    StrideBytes = (ulong)(strideFloats * sizeof(float)),
                    PixelFormat = HDRNative.PixelRGB32FLinear,
                    ColorEncoding = HDRNative.LinearSRGB,
                    ContentHeadroom = 2f,
                    HeadroomKind = 1
                };
                var pair = new Native.HDRImagePair
                {
                    Hdr = buffer,
                    Sdr = buffer,
                    NativeWidth = (uint)paddedWidth,
                    NativeHeight = (uint)paddedHeight,
                    OrientationApplied = 1,
                    OutputNativeWidth = (uint)paddedWidth,
                    OutputNativeHeight = (uint)paddedHeight
                };
                Assert.Throws<InvalidDataException>(() => HDRDisplay.CopyPair(pair));
            }
            finally
            {
                pin.Free();
            }
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void FalseColorRendersAllLuminanceBandsAndHonorsCancellation()
    {
        var image = new HDRFloatImage(4, 1, 48,
        [
            3.0f, 3.0f, 3.0f,       // > headroom (2.0)
            1.5f, 1.5f, 1.5f,       // > 1.0
            0.005f, 0.005f, 0.005f, // <= 0.01
            0.25f, 0.25f, 0.25f     // mid
        ], 2.0f, 1);

        var bitmap = HDRDisplay.FalseColor(image, 2.0f);
        var bgra = CopyBgraBytes(bitmap);
        (float R, float G, float B)[] expected =
        [
            (1f, 0f, .35f),
            (1f, .6f, 0f),
            (.02f, .15f, .7f),
            (.35f, .35f, .35f)
        ];
        for (var p = 0; p < expected.Length; p++)
        {
            Assert.Equal(ScalarToByte(expected[p].B), bgra[p * 4]);
            Assert.Equal(ScalarToByte(expected[p].G), bgra[p * 4 + 1]);
            Assert.Equal(ScalarToByte(expected[p].R), bgra[p * 4 + 2]);
            Assert.Equal(255, bgra[p * 4 + 3]);
        }

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => HDRDisplay.FalseColor(image, 2.0f, cts.Token));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void BenchmarkSimdSinglePassVsScalarTwoPassReportsElapsedMs()
    {
        const int width = 2000;
        const int height = 1333;
        var image = MakeImage(width, height, i => (i % 1024) / 800f);

        // Warmup JIT
        _ = HDRDisplay.RenderSDRWithStatistics(image, clipping: false);
        _ = ScalarTwoPassReference(image);

        var sw = Stopwatch.StartNew();
        var scalarPixels = ScalarTwoPassReference(image);
        sw.Stop();
        var scalarMs = sw.Elapsed.TotalMilliseconds;

        var pair = new HDRRenderedPair(image, image, width, height, width, height, false, []);
        sw.Restart();
        var rendered = HDRDisplay.RenderSDRWithStatistics(pair.SDR, clipping: false);
        pair.SeedSDRBitmap(rendered.Bitmap);
        sw.Stop();
        var simdMs = sw.Elapsed.TotalMilliseconds;

        sw.Restart();
        var cached = pair.SDRBitmap;
        sw.Stop();
        var cachedMs = sw.Elapsed.TotalMilliseconds;

        Console.WriteLine(
            $"#526 benchmark ({width}x{height}, Vector<float>.Count={Vector<float>.Count}): " +
            $"scalar_2pass={scalarMs:F2}ms simd_singlepass={simdMs:F2}ms cached_read={cachedMs:F4}ms " +
            $"speedup={scalarMs / Math.Max(0.01, simdMs):F2}x");

        Assert.True(ReferenceEquals(rendered.Bitmap, cached));
        Assert.Equal(width * height * 4, scalarPixels.Length);
    }

    private static byte[] ScalarTwoPassReference(HDRFloatImage image)
    {
        var bins = new uint[768];
        for (var p = 0; p < image.RGB.Length; p += 3)
        {
            bins[ScalarToByte(image.RGB[p])]++;
            bins[256 + ScalarToByte(image.RGB[p + 1])]++;
            bins[512 + ScalarToByte(image.RGB[p + 2])]++;
        }
        var pixels = new byte[image.Width * image.Height * 4];
        for (var p = 0; p < image.Width * image.Height; p++)
        {
            var s = p * 3;
            var d = p * 4;
            pixels[d] = ScalarToByte(image.RGB[s + 2]);
            pixels[d + 1] = ScalarToByte(image.RGB[s + 1]);
            pixels[d + 2] = ScalarToByte(image.RGB[s]);
            pixels[d + 3] = 255;
        }
        return pixels;
    }
}
