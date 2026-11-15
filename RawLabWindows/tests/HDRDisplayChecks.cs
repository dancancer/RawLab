using System.IO;
using System.Runtime.InteropServices;
using RawLab.Windows;

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
