using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
internal sealed record RenderedImage(BitmapSource Image, BitmapSource Clipping, uint[] Histogram, double Shadows, double Highlights, float Baseline, (double Temperature,double Tint)? WhiteBalance, int Backend);
internal sealed class RenderEngine : IDisposable
{
    private readonly Native.Session session = new();
    public int LastBackend => Native.sony2fuji_session_get_last_backend(session);
    public RenderEngine(int gpuMode=1) => SetGpuMode(gpuMode);
    public void SetGpuMode(int mode) { var config=new Native.GpuConfig{Version=1,StructSize=12,Mode=mode};Native.Check(Native.sony2fuji_session_set_gpu_config(session,ref config)); }
    public void Dispose() => session.Dispose();
    public RenderedImage? Render(string path, Adjustments settings, string? lut, int edge, bool interactive = false, string? output = null)
    {
        Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session,settings.ExposureMode));
        Native.Check(Native.sony2fuji_session_set_interactive_preview(session,interactive && output == null ? 1 : 0));
        var request = settings.Request(path,lut,edge,output);
        Native.Buffer buffer = default, mask = default;
        try
        {
            Native.Check(Native.sony2fuji_process(session,ref request,out buffer));
            if (output != null) { ExportMetadata.Preserve(path,output); return null; }
            var image = Bitmap(buffer);
            var bins = new uint[768];
            Native.Check(Native.sony2fuji_analyze_image(ref buffer,0,bins,out var shadows,out var highlights,out mask));
            Native.Check(Native.sony2fuji_session_get_raw_exposure(session,out var baseline,out _));
            var calibrated = Native.sony2fuji_session_get_raw_white_balance(session,out var temperature,out var tint) == 0;
            var count = (double)buffer.Width * buffer.Height;
            return new(image,Bitmap(mask),bins,shadows/count,highlights/count,baseline,
                calibrated ? (Math.Round(temperature),Math.Round(tint)) : null,LastBackend);
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }
    private static BitmapSource Bitmap(Native.Buffer buffer)
    {
        var bytes = new byte[checked((int)buffer.Size)];
        Marshal.Copy(buffer.Data,bytes,0,bytes.Length);
        for (var i=0;i<bytes.Length;i+=4) (bytes[i],bytes[i+2])=(bytes[i+2],bytes[i]);
        var image = BitmapSource.Create((int)buffer.Width,(int)buffer.Height,96,96,PixelFormats.Bgra32,null,bytes,(int)buffer.Stride);
        image.Freeze(); return image;
    }
    public static BitmapSource? Thumbnail(string path)
    {
        Native.Buffer buffer = default;
        try
        {
            if (Native.rawlab_thumbnail(path,out buffer,out var kind,out var flip) != 0) return null;
            var bytes = new byte[checked((int)buffer.Size)]; Marshal.Copy(buffer.Data,bytes,0,bytes.Length);
            BitmapSource image;
            if (kind == 1)
            {
                using var stream = new MemoryStream(bytes);
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption=BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth=180; bitmap.StreamSource=stream; bitmap.EndInit(); image=bitmap;
            }
            else image=BitmapSource.Create((int)buffer.Width,(int)buffer.Height,96,96,PixelFormats.Rgb24,null,bytes,(int)buffer.Stride);
            // LibRaw flip bits: transpose, vertical reflection, horizontal reflection.
            var transforms=new TransformGroup();
            transforms.Children.Add(new ScaleTransform((flip&1)!=0 ? -1 : 1,(flip&2)!=0 ? -1 : 1));
            if ((flip & 4)!=0) transforms.Children.Add(new MatrixTransform(0,1,1,0,0,0));
            var scale=Math.Min(1,180.0/Math.Max(image.PixelWidth,image.PixelHeight));
            transforms.Children.Add(new ScaleTransform(scale,scale));
            image=new TransformedBitmap(image,transforms); image.Freeze(); return image;
        }
        catch (Exception ex) when (ex is IOException or NotSupportedException or ArgumentException) { return null; }
        finally { Native.sony2fuji_release_buffer(ref buffer); }
    }
}
