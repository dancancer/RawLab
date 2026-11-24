using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal sealed class HDRSdrInput : IDisposable
{
    private readonly GCHandle pinned;
    private bool disposed;
    internal Native.Buffer Buffer { get; }

    internal HDRSdrInput(HDRFloatImage image)
    {
        var pixels = HDRDisplay.SDRRgba8(image);
        pinned = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        Buffer = new Native.Buffer {
            Data = pinned.AddrOfPinnedObject(), Size = (nuint)pixels.Length, Width = (uint)image.Width,
            Height = (uint)image.Height, Stride = (uint)(image.Width * 4), PixelFormat = 1
        };
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        pinned.Free();
    }
}
