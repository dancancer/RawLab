using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal sealed class HDRSdrInput : IDisposable
{
    private readonly GCHandle pinned;
    private bool disposed;
    internal Native.Buffer Buffer { get; }

    internal HDRSdrInput(HDRFloatImage image)
    {
        var pixels = HDRDisplay.SDRRgb8(image);
        pinned = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        Buffer = new Native.Buffer {
            Data = pinned.AddrOfPinnedObject(), Size = (nuint)pixels.Length, Width = (uint)image.Width,
            Height = (uint)image.Height, Stride = (uint)(image.Width * 3), PixelFormat = 0
        };
    }

    internal void SetRequest(ref Native.Request request)
    {
        request.InputType = 2; request.InputPixels = Buffer.Data; request.InputWidth = Buffer.Width;
        request.InputHeight = Buffer.Height; request.InputPixelFormat = Buffer.PixelFormat;
        request.InputColorSpace = 0; request.InputIsLinear = 0; request.WbMode = 0;
        request.Temperature = 6500; request.Tint = 0;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        pinned.Free();
    }
}
