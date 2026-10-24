using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
internal sealed record RenderedImage(BitmapSource Image, BitmapSource? Clipping, uint[] Histogram, double Shadows, double Highlights, float Baseline, (double Temperature,double Tint)? WhiteBalance, int Backend, LensInfo? Lens = null, int NativeWidth = 0, int NativeHeight = 0);
internal sealed record PreviewFrame(RenderedImage Neutral,RenderedImage Result);
internal sealed record EmbeddedPreview(BitmapSource? Image,int Width,int Height);
internal sealed partial class RenderEngine : IDisposable
{
    internal delegate int StatisticsAnalyzer(ref Native.Buffer buffer,bool clipping,uint[] bins,out uint shadows,out uint highlights,out Native.Buffer mask);
    private Native.Session session = new();
    private int gpuMode;
    private readonly StatisticsAnalyzer statisticsAnalyzer;
    private sealed record Stamp(string Path,long Length,long Time,long Created=0);
    private sealed record PreviewKey(Native.Request Request,DenoiseSettings Denoise,PhotoEffectsSettings Effects,ToneControlsSettings ToneControls,AtmosphereSettings Atmosphere,ColorGradingSettings ColorGrading,ToneCurveSettings Curve,int DisplayChromaDenoise,
        int ExposureMode,HslSettings Hsl,LensSettings Lens,GeometrySettings Geometry,ProcessingIdentity Processing,bool AIEnabled,int Mode,bool Compare,bool Clipping,Stamp Raw,Stamp? Lut);
    private readonly string lensDatabase;
    private Stamp? lensStamp;
    private LensCandidate[] lensCandidates = [];
    private PreviewKey? previewKey;
    private (Stamp Raw,Stamp? Lut)? sourceStamp;
    private (NeutralReferenceKey Key,RenderedImage Frame)? original;
    private readonly Dictionary<int,PreviewFrame> previews=new();
    // The optional result cache is separate from the active comparison image.
    internal long CachedPreviewBytes=>previews.Values.Sum(FrameBytes);
    private static long ImageBytes(RenderedImage value)=>(long)value.Image.PixelWidth*value.Image.PixelHeight*4*(value.Clipping==null ? 1 : 2);
    private static long FrameBytes(PreviewFrame frame)=>ImageBytes(frame.Result)+
        (ReferenceEquals(frame.Neutral,frame.Result) ? 0 : ImageBytes(frame.Neutral));
    public int LastBackend => Native.sony2fuji_session_get_last_backend(session);
    public RenderEngine(int gpuMode=1, string? lensDatabase=null,StatisticsAnalyzer? statisticsAnalyzer=null,string? aiModelDirectory=null,string? aiCacheDirectory=null,int? aiBackend=null)
    {
        this.statisticsAnalyzer=statisticsAnalyzer ?? AnalyzeStatistics;
        this.lensDatabase = lensDatabase ?? Path.Combine(AppContext.BaseDirectory,"Lensfun");
        this.aiModelDirectory=aiModelDirectory ?? BundledAIModel;
        this.aiCacheDirectory=aiCacheDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","Cache","DualDn");
        aiBackendOverride=aiBackend;
        try { InitializeSession(); SetGpuMode(gpuMode); }
        catch { session.Dispose(); throw; }
    }
    private void InitializeSession() => Native.Check(Native.sony2fuji_session_set_lens_database(session,lensDatabase));
    public void SetGpuMode(int mode) { var config=new Native.GpuConfig{Version=1,StructSize=12,Mode=mode};Native.Check(Native.sony2fuji_session_set_gpu_config(session,ref config));gpuMode=mode; }
    public void Dispose() {previews.Clear();original=null;Native.sony2fuji_release_buffer(ref displayInput);inputStamp=null;session.Dispose();}
    public double AutoExposure(string path, Adjustments settings)
    {
        settings = PrepareRecipe(path, settings);
        EnsureInput(path);
        SetProcessing(settings.Processing);SetTone(settings.ToneControls);SetAtmosphere(settings.Atmosphere);SetGrading(settings.ColorGrading);SetCurve(settings.Curve);
        ConfigureAI(settings.AIDenoiseEnabled);
        SetLens(settings.Lens);
        SetGeometry(settings.Geometry);
        Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session,settings.ExposureMode));
        var request=settings.Request(path,null,0,null);
        SetInput(ref request,path);
        var status=Native.sony2fuji_session_estimate_auto_exposure(session,ref request,out var ev);
        if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status);
        return ev;
    }
    public PreviewFrame RenderPreview(string path,Adjustments settings,string? lut,int edge,bool interactive,bool compare,bool clipping)
    {
        settings=PrepareInputSettings(path,settings);
        static Stamp FileStamp(string file) {var info=new FileInfo(file);return new(info.FullName,info.Length,info.LastWriteTimeUtc.Ticks,info.CreationTimeUtc.Ticks);}
        var rawStamp=FileStamp(path);var lutStamp=lut==null ? null : FileStamp(lut);
        // Replaced files must invalidate the native decoded data as well as WPF frames.
        if(sourceStamp is {} previous &&
            ((previous.Raw.Path==rawStamp.Path && previous.Raw!=rawStamp) ||
             (previous.Lut?.Path==lutStamp?.Path && previous.Lut!=lutStamp)))
        {
            if(previous.Raw!=rawStamp){Native.sony2fuji_release_buffer(ref displayInput);inputStamp=null;}
            session.Dispose();session=new();InitializeSession();SetGpuMode(gpuMode);lensStamp=null;
        }
        sourceStamp=(rawStamp,lutStamp);
        var key=new PreviewKey(settings.Request(path,lut,2000,null),settings.Denoise,settings.Effects,settings.ToneControls,settings.Atmosphere,settings.ColorGrading,settings.Curve,settings.DisplayChromaDenoise,
            settings.ExposureMode,settings.Hsl,settings.Lens,settings.Geometry,settings.Processing,settings.AIDenoiseEnabled,gpuMode,compare,clipping,rawStamp,lutStamp);
        if(previewKey!=key){previews.Clear();previewKey=key;}
        var referenceKey=new NeutralReferenceKey(new(rawStamp.Path,rawStamp.Length,rawStamp.Time,rawStamp.Created),
            PhotoInput.IsRaster(path),settings.Processing,settings.Geometry,settings.Lens,edge);
        if(original?.Key!=referenceKey)original=null;
        var cacheEdge=edge;
        // AI 模型或磁盘结果可在 WPF 帧之外变化，必须经过 native 的完整性与身份检查。
        if(!settings.AIDenoiseEnabled && previews.TryGetValue(cacheEdge,out var cached))return cached;
        var neutral=compare ? original?.Frame : null;
        if(compare && neutral==null)
        {
            neutral=Render(path,NeutralReference.Settings(path,settings),null,edge,clipping:false,viewportPreview:true)!;
            if(neutral.Histogram.Length==768)original=(referenceKey,neutral);
        }
        var result=Render(path,settings,lut,edge,interactive,clipping:clipping,viewportPreview:true)!;
        var frame=new PreviewFrame(neutral ?? result,result);
        if(!interactive && !settings.AIDenoiseEnabled && result.Histogram.Length==768 && (!compare || neutral?.Histogram.Length==768))
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
    public RenderedImage? Render(string path, Adjustments settings, string? lut, int edge, bool interactive = false, string? output = null, bool statistics = true, bool clipping = true, int? longEdge = null, bool viewportPreview = false)
    {
        (settings,var request)=PrepareRequest(path,settings,lut,edge,interactive,output,longEdge,viewportPreview);
        var format=output==null ? (ExportFormat?)null : ExportFormatExtensions.FromPath(output);
        Native.Buffer buffer = default, mask = default;
        try
        {
            var status = Native.sony2fuji_process(session,ref request,out buffer);
            if (output != null && (status == 6 || (status == 3 && format != ExportFormat.RenderedDng)))
                throw new OutputWriteException(Loc.Text("无法写入成片，请检查输出位置和剩余空间。"));
            if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status);
            if (output != null) {
                if (format != ExportFormat.RenderedDng)
                {
                    try { ExportMetadata.Preserve(path,output); }
                    catch (IOException error) { throw new OutputWriteException(Loc.Text("无法完成成片元数据写入：") + error.Message, error); }
                }
                return null;
            }
            Native.Check(Native.sony2fuji_session_get_geometry_size(session,out var nativeWidth,out var nativeHeight));
            var bins = statistics || clipping ? new uint[768] : Array.Empty<uint>();
            uint shadows=0,highlights=0;
            var statisticsAvailable=false;
            if(statistics || clipping)
            {
                // 显示像素已在 CPU；统计失败只清空统计，不丢弃成功的照片或改变照片 GPU 模式。
                var analysis=statisticsAnalyzer(ref buffer,clipping,bins,out shadows,out highlights,out mask);
                statisticsAvailable=analysis==0 && Enumerable.Range(0,3).All(c=>bins.Skip(c*256).Take(256).Sum(v=>(long)v)==(long)buffer.Width*buffer.Height);
                if(!statisticsAvailable){bins=Array.Empty<uint>();shadows=highlights=0;}
            }
            float baseline=0,temperature=6500,tint=0;
            var raster=LibraryEntry.IsRaster(path);
            if(!raster)Native.Check(Native.sony2fuji_session_get_raw_exposure(session,out baseline,out _));
            var calibrated = !raster && Native.sony2fuji_session_get_raw_white_balance(session,out temperature,out tint) == 0;
            var count = (double)buffer.Width * buffer.Height;
            // Statistics consume RGBA before the private output buffers are swizzled for WPF.
            return new(Bitmap(buffer),!statisticsAvailable || mask.Data==IntPtr.Zero ? null : Bitmap(mask,false),bins,shadows/count,highlights/count,baseline,
                calibrated ? RoundCameraWhiteBalance(temperature,tint) : null,LastBackend,raster ? null : ReadLens(path),checked((int)nativeWidth),checked((int)nativeHeight));
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }
    private (Adjustments,Native.Request) PrepareRequest(string path,Adjustments settings,string? lut,int edge,bool interactive,string? output,int? longEdge,bool viewportPreview)
    {
        settings = PrepareRecipe(path, settings);
        EnsureInput(path);
        SetProcessing(settings.Processing);SetTone(settings.ToneControls);SetAtmosphere(settings.Atmosphere);SetGrading(settings.ColorGrading);SetCurve(settings.Curve);
        ConfigureAI(settings.AIDenoiseEnabled);
        SetLens(settings.Lens);
        SetGeometry(settings.Geometry);
        Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session,settings.ExposureMode));
        var hsl=settings.RenderHsl.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_hsl(session,ref hsl));
        Native.Check(Native.sony2fuji_session_set_interactive_preview(session,interactive && edge>0 && output == null ? 1 : 0));
        Native.Check(Native.sony2fuji_session_set_viewport_preview(session,viewportPreview && edge>0 && output == null ? 1 : 0));
        var denoise=settings.Denoise.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_wavelet_denoise(session,ref denoise));
        var effects=settings.Effects.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_photo_effects(session,ref effects));
        Native.Check(Native.sony2fuji_session_set_chroma_denoise(session,settings.DisplayChromaDenoise));
        var request = settings.Request(path,lut,edge,output,longEdge);
        SetInput(ref request,path);
        return (settings,request);
    }
    internal HslTargetSample SampleHsl(string path,Adjustments settings,string? lut,int edge,bool interactive,HslTargetRevision revision,double x,double y)
    {
        if(!double.IsFinite(x) || !double.IsFinite(y))return HslTargetSample.Unavailable(revision,HslTargetAvailability.Nonfinite);
        if(x<0 || x>1 || y<0 || y>1)return HslTargetSample.Unavailable(revision,HslTargetAvailability.Outside);
        var prepared=PrepareRequest(path,settings,lut,edge,interactive,null,null,true);
        var request=prepared.Item2;
        IntPtr probe=IntPtr.Zero;
        try {
            Native.Check(Native.sony2fuji_session_create_hsl_probe(session,ref request,revision.Source,revision.Request,out probe));
            var query=new Native.HslProbeQuery {Version=1,StructSize=(uint)Marshal.SizeOf<Native.HslProbeQuery>(),SourceRevision=revision.Source,RequestRevision=revision.Request,X=(float)x,Y=(float)y};
            Native.Check(Native.sony2fuji_hsl_probe_sample(probe,ref query,out var sample));
            if(sample.SourceRevision!=revision.Source || sample.RequestRevision!=revision.Request)
                return HslTargetSample.Unavailable(revision,HslTargetAvailability.Stale);
            return new(revision,(HslTargetAvailability)sample.Availability,sample.Rgb.Select(v=>(double)v),sample.Weights.Select(v=>(double)v),sample.Quality==1);
        } finally { if(probe!=IntPtr.Zero)Native.sony2fuji_hsl_probe_destroy(probe); }
    }
    internal static int AnalyzeStatistics(ref Native.Buffer buffer,bool clipping,uint[] bins,out uint shadows,out uint highlights,out Native.Buffer mask)
    {
        if(clipping)return Native.sony2fuji_analyze_image(ref buffer,0,bins,out shadows,out highlights,out mask);
        mask=default;
        return Native.AnalyzeWithoutMask(ref buffer,0,bins,out shadows,out highlights,IntPtr.Zero);
    }
    internal static (double Temperature,double Tint) RoundCameraWhiteBalance(float temperature,float tint) =>
        (Math.Round(temperature,MidpointRounding.AwayFromZero),Math.Round(tint,MidpointRounding.AwayFromZero));
    private void SetGrading(ColorGradingSettings value)
    {
        var config = value.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_color_grading(session, ref config));
    }
    private void SetCurve(ToneCurveSettings value)
    {
        var config = value.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_tone_curve(session, ref config));
    }
    private void SetAtmosphere(AtmosphereSettings value)
    {
        var config = value.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_atmosphere(session, ref config));
    }
    private void SetTone(ToneControlsSettings value)
    {
        var config = value.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_tone_controls(session, ref config));
    }
    private void SetProcessing(ProcessingIdentity value) =>
        Native.Check(Native.sony2fuji_session_set_processing_version(session,ProcessingIdentity.Require(value).Version));
    private void SetLens(LensSettings value)
    {
        var config = new Native.LensConfig { Version=1,StructSize=(uint)Marshal.SizeOf<Native.LensConfig>(),
            Distortion=value.Distortion ? 1 : 0,Tca=value.Tca ? 1 : 0,AutoCrop=value.AutoCrop ? 1 : 0,ProfileId=value.CoreProfileId };
        Native.Check(Native.sony2fuji_session_set_lens_correction(session,ref config));
    }
    private void SetGeometry(GeometrySettings value)
    {
        var config=value.NativeConfig();
        Native.Check(Native.sony2fuji_session_set_geometry(session,ref config));
        var perspective=value.NativePerspectiveConfig();
        Native.Check(Native.sony2fuji_session_set_perspective(session,ref perspective));
    }
    private LensInfo ReadLens(string path) {
        var file = new FileInfo(path);
        var stamp = new Stamp(file.FullName, file.Length, file.LastWriteTimeUtc.Ticks);
        if (stamp != lensStamp) {
            Native.Check(Native.sony2fuji_session_inspect_lens(session, path, out _, null, 0, out var count));
            var profiles = new Native.LensProfile[checked((int)count)];
            Native.Check(Native.sony2fuji_session_inspect_lens(session, path, out _, profiles, count, out _));
            lensCandidates = profiles.Select(p => new LensCandidate(Native.Text(p.Id), Native.Text(p.Maker), Native.Text(p.Model), p.HasDistortion != 0, p.HasTca != 0, p.IsMatch != 0)).ToArray();
            lensStamp = stamp;
        }
        Native.Check(Native.sony2fuji_session_get_lens_report(session, out var report));
        return new(report.State, Native.Text(report.LensModel), Native.Text(report.Profile.Model), report.AppliedDistortion != 0,
            report.AppliedTca != 0, report.CropScale, lensCandidates);
    }
    private Adjustments PrepareRecipe(string path, Adjustments settings)
    {
        if(LibraryEntry.IsRaster(path))return PrepareInputSettings(path,settings);
        if (settings.MasterRecipeID == null || (settings.CameraWhiteBalance && settings[Parameter.Tint] * settings[Parameter.Strength] == 0)) return settings;
        // 配方色调属于目标 RAW 的拍摄白平衡，不沿用冻结来源的相机值。
        var neutral = new Adjustments { ExposureMode = settings.ExposureMode, Processing = settings.Processing };
        var camera = Render(path, neutral, null, 32, statistics: false, clipping: false)?.WhiteBalance
            ?? throw new InvalidOperationException(Loc.Text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"));
        var prepared = settings.Clone();
        prepared.ResolveWhiteBalance(camera);
        return prepared;
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
            if(LibraryEntry.IsRaster(path))
            {
                if(edge<=0 || Native.rawlab_display_preview(path,(uint)edge,ref buffer,out var sourceWidth,out var sourceHeight)!=0)return new(null,0,0);
                return new(Bitmap(buffer),checked((int)sourceWidth),checked((int)sourceHeight));
            }
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
