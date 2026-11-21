using System.Windows.Media;
using System.Windows.Media.Imaging;
using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
public sealed class ForceGpuDiagnosticsTests
{
    private static BitmapSource DummyBitmap()
    {
        var bmp = BitmapSource.Create(1, 1, 96, 96, PixelFormats.Bgra32, null, new byte[] { 0, 0, 0, 255 }, 4);
        bmp.Freeze();
        return bmp;
    }

    [Fact]
    public void FormatErrorMessageUsesForceGpuPromptAndProcessingDetail()
    {
        var previous = Loc.Preference;
        try
        {
            Loc.Initialize("en");
            var forceMsg = Native.FormatErrorMessage(2, null, Native.UnsupportedReason.ForceGpu);
            Assert.Contains("Auto", forceMsg);
            Assert.NotEqual(Native.FormatErrorMessage(2, null, Native.UnsupportedReason.None), forceMsg);

            var detailMsg = Native.FormatErrorMessage(4, null, Native.UnsupportedReason.None, "DXGI_ERROR_DEVICE_RESET");
            Assert.Contains("DXGI_ERROR_DEVICE_RESET", detailMsg);

            var genericMsg = Native.FormatErrorMessage(4, null, Native.UnsupportedReason.None, null);
            Assert.DoesNotContain("{0}", genericMsg);
            Assert.NotEqual(detailMsg, genericMsg);
        }
        finally
        {
            Loc.Initialize(previous);
        }
    }

    [Fact]
    public void FormatFallbackToolTipCoversAllFallbackReasonsAcrossLocales()
    {
        var previous = Loc.Preference;
        try
        {
            Loc.Initialize("en");
            foreach (var reason in Enum.GetValues<Native.GpuFallbackReason>())
            {
                var image = new RenderedImage(
                    DummyBitmap(), null, [], 0, 0, 0, null,
                    Backend: 0, FallbackReason: reason, GpuError: null);
                var tip = MainWindow.FormatFallbackToolTip(image, gpuMode: 1);
                if (reason == Native.GpuFallbackReason.None)
                {
                    Assert.Null(tip);
                }
                else
                {
                    Assert.NotNull(tip);
                    Assert.Contains("CPU", tip);
                }
            }

            var withDetail = new RenderedImage(
                DummyBitmap(), null, [], 0, 0, 0, null,
                Backend: 0, FallbackReason: Native.GpuFallbackReason.DeviceError, GpuError: "E_OUTOFMEMORY");
            var detailTip = MainWindow.FormatFallbackToolTip(withDetail, gpuMode: 1);
            Assert.NotNull(detailTip);
            Assert.Contains("E_OUTOFMEMORY", detailTip);

            var gpuUsed = new RenderedImage(
                DummyBitmap(), null, [], 0, 0, 0, null,
                Backend: 3, FallbackReason: Native.GpuFallbackReason.DeviceError, GpuError: "ignored");
            Assert.Null(MainWindow.FormatFallbackToolTip(gpuUsed, gpuMode: 1));
            Assert.Null(MainWindow.FormatFallbackToolTip(withDetail, gpuMode: 0));
        }
        finally
        {
            Loc.Initialize(previous);
        }
    }
}
