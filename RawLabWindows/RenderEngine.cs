using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
internal sealed record RenderedImage(BitmapSource Image, BitmapSource? Clipping, uint[] Histogram, double Shadows, double Highlights, float Baseline, (double Temperature,double Tint)? WhiteBalance, int Backend);
internal sealed record PreviewFrame(RenderedImage Neutral,RenderedImage Result);
internal sealed record EmbeddedPreview(BitmapSource? Image,int Width,int Height);
internal sealed class RenderEngine : IDisposable
{
    private Native.Session session = new();
    private int gpuMode;
    private sealed record Stamp(string Path,long Length,long Time);
    private sealed record PreviewKey(Native.Request Request,DenoiseSettings Denoise,int ExposureMode,int Mode,bool Compare,bool Clipping,Stamp Raw,Stamp? Lut);
    private PreviewKey? previewKey;
    private (Stamp Raw,Stamp? Lut)? sourceStamp;
    private (Stamp Raw,int Edge,RenderedImage Frame)? original;
    private readonly Dictionary<int,PreviewFrame> previews=new();
    // The optional result cache is separate from the active comparison image.
    internal long CachedPreviewBytes=>previews.Values.Sum(FrameBytes);
    private static long ImageBytes(RenderedImage value)=>(long)value.Image.PixelWidth*value.Image.PixelHeight*4*(value.Clipping==null ? 1 : 2);
    private static long FrameBytes(PreviewFrame frame)=>ImageBytes(frame.Result)+
        (ReferenceEquals(frame.Neutral,frame.Result) ? 0 : ImageBytes(frame.Neutral));
    public int LastBackend => Native.sony2fuji_session_get_last_backend(session);
    public RenderEngine(int gpuMode=1) => SetGpuMode(gpuMode);
    public void SetGpuMode(int mode) { var config=new Native.GpuConfig{Version=1,StructSize=12,Mode=mode};Native.Check(Native.sony2fuji_session_set_gpu_config(session,ref config));gpuMode=mode; }
    public void Dispose() {previews.Clear();original=null;session.Dispose();}
    public PreviewFrame RenderPreview(string path,Adjustments settings,string? lut,int edge,bool interactive,bool compare,bool clipping)
    {
        static Stamp FileStamp(string file) {var info=new FileInfo(file);return new(info.FullName,info.Length,info.LastWriteTimeUtc.Ticks);}
        var rawStamp=FileStamp(path);var lutStamp=lut==null ? null : FileStamp(lut);
        // Replaced files must invalidate the native decoded data as well as WPF frames.
        if(sourceStamp is {} previous &&
            ((previous.Raw.Path==rawStamp.Path && previous.Raw!=rawStamp) ||
             (previous.Lut?.Path==lutStamp?.Path && previous.Lut!=lutStamp)))
        {session.Dispose();session=new();SetGpuMode(gpuMode);}
        sourceStamp=(rawStamp,lutStamp);
        var key=new PreviewKey(settings.Request(path,lut,2000,null),settings.Denoise,settings.ExposureMode,gpuMode,compare,clipping,rawStamp,lutStamp);
        if(previewKey!=key){previews.Clear();previewKey=key;}
        var cacheEdge=interactive && original?.Edge==0 ? 0 : interactive && edge==1000 ? 2000 : edge;
        if(previews.TryGetValue(cacheEdge,out var cached)) {
            original=compare ? (rawStamp,cacheEdge,cached.Neutral) : null;
            return cached;
        }
        if(original?.Raw!=rawStamp)original=null;
        if(!compare)original=null;
        var originalEdge=edge==0 || (interactive && original?.Edge==0) ? 0 : 2000;
        if(compare && (original==null || original.Value.Edge!=originalEdge))
            original=(rawStamp,originalEdge,Render(path,new Adjustments(),null,originalEdge,statistics:false,clipping:false)!);
        var neutral=compare ? original!.Value.Frame : null;
        var result=Render(path,settings,lut,edge,interactive,clipping:clipping)!;
        var frame=new PreviewFrame(neutral ?? result,result);
        if(!interactive && edge is 0 or 2000)
        {
            const long budget=256L*1024*1024;
            var bytes=FrameBytes(frame);
            if(bytes<=budget)
            {
                if(CachedPreviewBytes+bytes>budget)previews.Clear();
                previews[edge]=frame;
            }
        }
        return frame;
    }
    public RenderedImage? Render(string path, Adjustments settings, string? lut, int edge, bool interactive = false, string? output = null, bool statistics = true, bool clipping = true, int? longEdge = null)
    {
        Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session,settings.ExposureMode));
        Native.Check(Native.sony2fuji_session_set_interactive_preview(session,interactive && output == null ? 1 : 0));
        var denoise=settings.Denoise.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_wavelet_denoise(session,ref denoise));
        var request = settings.Request(path,lut,edge,output,longEdge);
        Native.Buffer buffer = default, mask = default;
        try
        {
            var status = Native.sony2fuji_process(session,ref request,out buffer);
            if (output != null && status == 3) throw new OutputWriteException("无法写入成片，请检查输出位置和剩余空间。");
            Native.Check(status);
            if (output != null) {
                try { ExportMetadata.Preserve(path,output); }
                catch (IOException error) { throw new OutputWriteException("无法完成成片元数据写入：" + error.Message, error); }
                return null;
            }
            var bins = statistics || clipping ? new uint[768] : Array.Empty<uint>();
            uint shadows=0,highlights=0;
            if(clipping) Native.Check(Native.sony2fuji_analyze_image(ref buffer,0,bins,out shadows,out highlights,out mask));
            else if(statistics) Native.Check(Native.AnalyzeWithoutMask(ref buffer,0,bins,out shadows,out highlights,IntPtr.Zero));
            Native.Check(Native.sony2fuji_session_get_raw_exposure(session,out var baseline,out _));
            var calibrated = Native.sony2fuji_session_get_raw_white_balance(session,out var temperature,out var tint) == 0;
            var count = (double)buffer.Width * buffer.Height;
            // Statistics consume RGBA before the private output buffers are swizzled for WPF.
            return new(Bitmap(buffer),mask.Data==IntPtr.Zero ? null : Bitmap(mask,false),bins,shadows/count,highlights/count,baseline,
                calibrated ? (Math.Round(temperature),Math.Round(tint)) : null,LastBackend);
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }
    private static unsafe BitmapSource Bitmap(Native.Buffer buffer,bool opaque=true)
    {
        // WPF copies these private RGBA8 buffers before their native allocations are freed.
        var pixels=new Span<uint>((void*)buffer.Data,checked((int)buffer.Size/4));
        var keep=new Vector<uint>(0xff00ff00);var red=new Vector<uint>(0xff);var blue=new Vector<uint>(0xff0000);
        var i=0;
        for(;i<=pixels.Length-Vector<uint>.Count;i+=Vector<uint>.Count)
        {
            var v=new Vector<uint>(pixels.Slice(i));
            ((v & keep) | ((v & red)<<16) | ((v & blue)>>16)).CopyTo(pixels.Slice(i));
        }
        for(;i<pixels.Length;i++){var v=pixels[i];pixels[i]=(v&0xff00ff00)|((v&0xff)<<16)|((v&0xff0000)>>16);}
        // Photo output is opaque. Pbgra32 avoids a full-image format conversion on
        // each software-composited pan; translucent diagnostic masks remain straight BGRA.
        var image = BitmapSource.Create((int)buffer.Width,(int)buffer.Height,96,96,opaque ? PixelFormats.Pbgra32 : PixelFormats.Bgra32,null,buffer.Data,checked((int)buffer.Size),(int)buffer.Stride);
        image.Freeze(); return image;
    }
    public static BitmapSource? Thumbnail(string path)=>ReadEmbeddedPreview(path,180).Image;
    public static EmbeddedPreview ReadEmbeddedPreview(string path,int edge=1600)
    {
        Native.Buffer buffer = default;
        try
        {
            if (Native.rawlab_preview(path,out buffer,out var kind,out var flip,out var width,out var height) != 0) return new(null,width,height);
            var bytes = new byte[checked((int)buffer.Size)]; Marshal.Copy(buffer.Data,bytes,0,bytes.Length);
            BitmapSource image;
            if (kind == 1)
            {
                using var stream = new MemoryStream(bytes);
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption=BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth=edge; bitmap.StreamSource=stream; bitmap.EndInit(); image=bitmap;
            }
            else image=BitmapSource.Create((int)buffer.Width,(int)buffer.Height,96,96,PixelFormats.Rgb24,null,bytes,(int)buffer.Stride);
            // LibRaw flip bits: transpose, vertical reflection, horizontal reflection.
            var transforms=new TransformGroup();
            transforms.Children.Add(new ScaleTransform((flip&1)!=0 ? -1 : 1,(flip&2)!=0 ? -1 : 1));
            if ((flip & 4)!=0) transforms.Children.Add(new MatrixTransform(0,1,1,0,0,0));
            var scale=Math.Min(1,(double)edge/Math.Max(image.PixelWidth,image.PixelHeight));
            transforms.Children.Add(new ScaleTransform(scale,scale));
            image=new TransformedBitmap(image,transforms);
            image=new FormatConvertedBitmap(image,PixelFormats.Pbgra32,null,0);
            image=new CachedBitmap(image,BitmapCreateOptions.None,BitmapCacheOption.OnLoad);
            image.Freeze(); return new(image,width,height);
        }
        catch (Exception ex) when (ex is IOException or NotSupportedException or ArgumentException) { return new(null,0,0); }
        finally { Native.sony2fuji_release_buffer(ref buffer); }
    }
}
