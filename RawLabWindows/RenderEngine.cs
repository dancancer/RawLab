using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
internal sealed record RenderedImage(BitmapSource Image, BitmapSource? Clipping, uint[] Histogram, double Shadows, double Highlights, float Baseline, (double Temperature,double Tint)? WhiteBalance, int Backend, LensInfo? Lens = null, int NativeWidth = 0, int NativeHeight = 0, HDRRenderedPair? HDR = null);
internal sealed record PreviewFrame(RenderedImage Neutral,RenderedImage Result);
internal sealed record EmbeddedPreview(BitmapSource? Image,int Width,int Height);
internal sealed partial class RenderEngine : IDisposable
{
    internal delegate int StatisticsAnalyzer(ref Native.Buffer buffer,bool clipping,uint[] bins,out uint shadows,out uint highlights,out Native.Buffer mask);
    private Native.Session session = new();
    private int gpuMode;
    private GCHandle cancellationHandle;
    private Native.CancellationCallback? cancellationCallback;
    private readonly StatisticsAnalyzer statisticsAnalyzer;
    private sealed record Stamp(string Path,long Length,long Time,long Created=0);
    private sealed record PreviewKey(Native.Request Request,DenoiseSettings Denoise,PhotoEffectsSettings Effects,ToneControlsSettings ToneControls,AtmosphereSettings Atmosphere,ColorGradingSettings ColorGrading,ToneCurveSettings Curve,int DisplayChromaDenoise,
        int ExposureMode,HslSettings Hsl,LensSettings Lens,GeometrySettings Geometry,ProcessingIdentity Processing,X3fMode X3fMode,int RecipeSettingsVersion,double Strength,bool AIEnabled,int Mode,OriginalIdentity Raw,OriginalIdentity? Lut,HDRSettings? HDR,int? ProRAWDecodeVersion,string? SourceFingerprint);
    private sealed record CameraWhiteBalanceKey(OriginalIdentity Source, ProcessingIdentity Processing, X3fMode X3fMode, int ExposureMode);
    private (CameraWhiteBalanceKey Key, (double Temperature, double Tint) Value)? recipeWhiteBalance;
    private readonly string lensDatabase;
    private Stamp? lensStamp;
    private LensCandidate[] lensCandidates = [];
    private PreviewKey? previewKey;
    private (OriginalIdentity Raw,OriginalIdentity? Lut)? sourceStamp;
    private ((NeutralReferenceKey Reference, int GpuMode, int? ProRAWDecodeVersion) Key, RenderedImage Frame)? original;
    private readonly Dictionary<int,PreviewFrame> previews=new();
    // The optional result cache is separate from the active comparison image.
    internal long CachedPreviewBytes=>previews.Values.Sum(FrameBytes);
    private static long ImageBytes(RenderedImage value)=>(long)value.Image.PixelWidth*value.Image.PixelHeight*4*(value.Clipping==null ? 1 : 2) +
        (value.HDR is { } pair ? (long)pair.HDR.RGB.Length * sizeof(float) + (long)pair.SDR.RGB.Length * sizeof(float) : 0);
    private static long FrameBytes(PreviewFrame frame)=>ImageBytes(frame.Result)+
        (ReferenceEquals(frame.Neutral,frame.Result) ? 0 : ImageBytes(frame.Neutral));
    public int LastBackend => Native.sony2fuji_session_get_last_backend(session);
    public RenderEngine(int gpuMode=1, string? lensDatabase=null,StatisticsAnalyzer? statisticsAnalyzer=null,string? aiModelDirectory=null,string? aiCacheDirectory=null,int? aiBackend=null,
        string aiDeviceID="",AIDiagnosticStore? aiDiagnostics=null)
    {
        this.statisticsAnalyzer=statisticsAnalyzer ?? AnalyzeStatistics;
        this.lensDatabase = lensDatabase ?? Path.Combine(AppContext.BaseDirectory,"Lensfun");
        this.aiModelDirectory=aiModelDirectory ?? BundledAIModel;
        this.aiCacheDirectory=aiCacheDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","Cache","DualDn");
        aiBackendOverride=aiBackend;
        this.aiDeviceID=aiDeviceID;aiDiagnosticStore=aiDiagnostics ?? AIDiagnosticStore.Default;
        try { InitializeSession(); SetGpuMode(gpuMode); }
        catch { session.Dispose(); throw; }
    }
    private void InitializeSession() => Native.Check(Native.sony2fuji_session_set_lens_database(session,lensDatabase));
    public void SetGpuMode(int mode) { var config=new Native.GpuConfig{Version=1,StructSize=12,Mode=mode};Native.Check(Native.sony2fuji_session_set_gpu_config(session,ref config));gpuMode=mode; }
    private void RecreateSession()
    {
        session.Dispose();
        session = new();
        try
        {
            InitializeSession();
            SetGpuMode(gpuMode);
            if (cancellationCallback != null && cancellationHandle.IsAllocated)
                Native.Check(Native.sony2fuji_session_set_cancellation_callback(session, cancellationCallback,
                    GCHandle.ToIntPtr(cancellationHandle)));
        }
        catch
        {
            session.Dispose();
            throw;
        }
    }
    internal void SetCancellation(CancellationToken token)
    {
        ClearCancellation();
        if (!token.CanBeCanceled) return;
        var state = new CancellationState(token);
        cancellationHandle = GCHandle.Alloc(state);
        cancellationCallback = static context => ((CancellationState)GCHandle.FromIntPtr(context).Target!).Token.IsCancellationRequested ? 1 : 0;
        Native.Check(Native.sony2fuji_session_set_cancellation_callback(session, cancellationCallback,
            GCHandle.ToIntPtr(cancellationHandle)));
    }
    private void ClearCancellation()
    {
        if (!session.IsInvalid && !session.IsClosed)
            Native.Check(Native.sony2fuji_session_set_cancellation_callback(session, null, IntPtr.Zero));
        cancellationCallback = null;
        if (cancellationHandle.IsAllocated) cancellationHandle.Free();
    }
    private sealed record CancellationState(CancellationToken Token);
    public void Dispose() { ClearCancellation(); previews.Clear();original=null;Native.sony2fuji_release_buffer(ref displayInput);inputStamp=null;session.Dispose();}
    public double AutoExposure(string path, Adjustments settings)
    {
        BeginAIOperation("auto_exposure",path);
        try{return AutoExposureCore(path,settings);}
        catch(Exception error) when(settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }
    private double AutoExposureCore(string path, Adjustments settings)
    {
        if (settings.HDR is { Mode: HDRMode.Hdr } hdr)
        {
            if (gpuMode == 2)
                throw new HDRSourceException(HDRNative.StatusUnsupported, HDRNative.ReasonUnsupportedGpu, 6);
            HDRSourceInfo? sourceInfo;
            var probe = PhotoInput.IsRaw(path) ? PhotoInput.ProbeCameraRaw(path, out sourceInfo)
                : PhotoInput.ProbeHDR(path, out sourceInfo);
            if (probe != HDRProbeState.Supported || sourceInfo == null ||
                sourceInfo.IsProRAW != (settings.ProRAWDecodeVersion == HDRNative.ProRAWDecodeVersion))
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
            using var source = AcquireHDRSource(path,sourceInfo,false,1280,settings);
            return HDRNative.EstimateAutoExposure(source.Owner, hdr);
        }
        if (PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path, out var info) == HDRProbeState.Supported)
            return AutoExposureHDRSource(path, settings,info!);
        settings = PrepareRecipe(path, settings);
        EnsureInput(path);
        SetProcessing(settings.Processing);SetX3f(path,settings);SetTone(settings.RenderToneControls);SetAtmosphere(settings.RenderAtmosphere);SetGrading(settings.RenderGrading);SetCurve(settings.RenderCurve);
        ConfigureAI(settings.AIDenoiseEnabled);
        SetLens(settings.Lens);
        SetGeometry(settings.Geometry);
        Native.Check(Native.sony2fuji_session_set_raw_exposure_mode(session,settings.ExposureMode));
        var request=settings.Request(path,null,0,null);
        SetInput(ref request,path);
        aiNativeOperationStarted=true;
        var status=Native.sony2fuji_session_estimate_auto_exposure(session,ref request,out var ev);
        if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status,session);
        return ev;
    }

    private double AutoExposureHDRSource(string path, Adjustments settings,HDRSourceInfo info)
    {
        using var source = HDRSourceCache.Acquire(path,info,false,256,session);
        var pair = HDRDisplay.CopyPair(source.Owner.Pair);
        using var input = new HDRSdrInput(pair.SDR);
        var prepared = PrepareRequest(path, settings, null, 256, false, null, null, true, input.Buffer);
        var request = prepared.Item2;
        var status = Native.sony2fuji_session_estimate_auto_exposure(session, ref request, out var ev);
        if (settings.AIDenoiseEnabled) CheckAI(status); else Native.Check(status,session);
        return ev;
    }
    public PreviewFrame RenderPreview(string path,Adjustments settings,string? lut,int edge,bool interactive,bool compare,bool clipping,Action? renderStarted=null)
    {
        settings=PrepareInputSettings(path,settings);
        var rawStamp=OriginalIdentity.Read(path);var lutStamp=lut==null ? null : OriginalIdentity.Read(lut);
        // Replaced files must invalidate the native decoded data as well as WPF frames.
        if(sourceStamp is {} previous &&
            ((previous.Raw.Path==rawStamp.Path && previous.Raw!=rawStamp) ||
             (previous.Lut?.Path==lutStamp?.Path && previous.Lut!=lutStamp)))
        {
            if(previous.Raw!=rawStamp){Native.sony2fuji_release_buffer(ref displayInput);inputStamp=null;}
            RecreateSession();lensStamp=null;
        }
        sourceStamp=(rawStamp,lutStamp);
        string? sourceFingerprint = null;
        if (PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path, out var gainMapInfo) == HDRProbeState.Supported)
            sourceFingerprint = gainMapInfo!.CacheIdentity;
        else if (settings.IsHDREditing && PhotoInput.IsRaw(path) &&
            PhotoInput.ProbeCameraRaw(path, out var cameraInfo) == HDRProbeState.Supported)
            sourceFingerprint = cameraInfo!.CacheIdentity;
        var key=new PreviewKey(settings.Request(path,lut,2000,null),settings.Denoise,settings.Effects,settings.ToneControls,settings.Atmosphere,settings.ColorGrading,settings.Curve,settings.DisplayChromaDenoise,
            settings.ExposureMode,settings.Hsl,settings.Lens,settings.Geometry,settings.Processing,settings.X3fMode,settings.MasterRecipeSettingsVersion,settings[Parameter.Strength],settings.ActiveAIDenoise,gpuMode,rawStamp,lutStamp,settings.HDR,settings.ProRAWDecodeVersion,sourceFingerprint);
        var fingerprintChanged=previewKey?.SourceFingerprint!=sourceFingerprint;
        if(previewKey!=key){previews.Clear();previewKey=key;}
        // HDR previews have a 2000px ceiling, including the viewport's native-size request.
        var cacheEdge=settings.IsHDREditing && sourceFingerprint!=null ? HDRPreviewEdge(edge) : edge;
        var referenceKey=(new NeutralReferenceKey(rawStamp,PhotoInput.IsRaster(path),settings.Processing,
            settings.Geometry,settings.Lens,cacheEdge,settings.IsHDREditing,settings.X3fMode,NeutralReference.HDRCameraSettings(settings.IsHDREditing ? settings.HDR : null)),gpuMode,settings.ProRAWDecodeVersion);
        if(original?.Key!=referenceKey || fingerprintChanged)original=null;
        // AI 模型或磁盘结果可在 WPF 帧之外变化，必须经过 native 的完整性与身份检查。
        var cached=!settings.ActiveAIDenoise ? previews.GetValueOrDefault(cacheEdge) : null;
        if(cached!=null && !compare)
            return WithMask(ReferenceEquals(cached.Neutral,cached.Result) ? cached : new(cached.Result,cached.Result));
        if(cached!=null && !ReferenceEquals(cached.Neutral,cached.Result))
        {
            original=(referenceKey,cached.Neutral);
            return WithMask(cached);
        }
        var neutral=compare ? original?.Frame : null;
        if(cached==null || (compare && neutral==null))renderStarted?.Invoke();
        if(compare && neutral==null)
        {
            neutral=Render(path,NeutralReference.Settings(path,settings),null,edge,clipping:false,viewportPreview:true)!;
            if(neutral.Histogram.Length==768)original=(referenceKey,neutral);
        }
        var result=cached?.Result ?? Render(path,settings,lut,edge,interactive,clipping:false,viewportPreview:true)!;
        var frame=new PreviewFrame(neutral ?? result,result);
        if(!interactive && !settings.ActiveAIDenoise && result.Histogram.Length==768 && (!compare || neutral?.Histogram.Length==768))
        {
            const long budget=256L*1024*1024;
            var bytes=FrameBytes(frame);
            if(bytes<=budget)
            {
                previews.Remove(cacheEdge);
                if(CachedPreviewBytes+bytes>budget)previews.Clear();
                previews[cacheEdge]=frame;
            }
        }
        return WithMask(frame);

        PreviewFrame WithMask(PreviewFrame preview)
        {
            if (!clipping || preview.Result.Histogram.Length != 768) return preview;
            var masked = preview.Result with { Clipping = CreateClippingMask(preview.Result.Image) };
            return new(ReferenceEquals(preview.Neutral, preview.Result) ? masked : preview.Neutral, masked);
        }
    }

    internal static BitmapSource CreateClippingMask(BitmapSource image)
    {
        var width = image.PixelWidth;
        var height = image.PixelHeight;
        var stride = checked(width * 4);
        // 显影结果是已冻结的不透明 BGRA 像素。分块读取，遮罩每像素只存一个调色板索引。
        const int chunkRows = 32;
        var pixels = new byte[checked(stride * Math.Min(chunkRows, height))];
        var indices = new byte[checked(width * height)];
        for (var row = 0; row < height; row += chunkRows)
        {
            var rows = Math.Min(chunkRows, height - row);
            image.CopyPixels(new Int32Rect(0, row, width, rows), pixels, stride, 0);
            var start = row * width;
            for (int i = 0, offset = 0; i < rows * width; i++, offset += 4)
            {
                var b = pixels[offset];
                var g = pixels[offset + 1];
                var r = pixels[offset + 2];
                if (r == 255 || g == 255 || b == 255) indices[start + i] = 1;
                else if (r == 0 && g == 0 && b == 0) indices[start + i] = 2;
            }
        }
        // 与原有统计一致：高光标红，黑位标蓝，其余透明。
        var palette = new BitmapPalette([Color.FromArgb(0, 0, 0, 0), Color.FromArgb(160, 255, 0, 0), Color.FromArgb(160, 0, 130, 255)]);
        var mask = BitmapSource.Create(width, height, image.DpiX, image.DpiY, PixelFormats.Indexed8, palette, indices, width);
        mask.Freeze();
        return mask;
    }
    public RenderedImage? Render(string path, Adjustments settings, string? lut, int edge, bool interactive = false, string? output = null, bool statistics = true, bool clipping = true, int? longEdge = null, bool viewportPreview = false, ExportFormat? formatOverride = null)
    {
        BeginAIOperation(output==null ? "preview" : "export",path);
        try{return RenderCore(path,settings,lut,edge,interactive,output,statistics,clipping,longEdge,viewportPreview,formatOverride);}
        catch(Exception error) when(settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }
    private RenderedImage? RenderCore(string path,Adjustments settings,string? lut,int edge,bool interactive,string? output,bool statistics,bool clipping,int? longEdge,bool viewportPreview,ExportFormat? formatOverride)
    {
        if (output != null && formatOverride == ExportFormat.HdrJpeg &&
            (settings.HDR is not { Mode: HDRMode.Hdr } ||
             !(PhotoInput.IsHDRContainer(path) || PhotoInput.IsRaw(path))))
            throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
        if (settings.IsHDREditing && settings.ProRAWDecodeVersion == HDRNative.ProRAWDecodeVersion)
        {
            var proRAW = false;
            if (PhotoInput.IsRaw(path) && PhotoInput.ProbeCameraRaw(path, out var proRAWInfo) == HDRProbeState.Supported)
                proRAW = proRAWInfo?.IsProRAW == true;
            if (!proRAW) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        if (PhotoInput.IsHDRContainer(path))
        {
            var probe = PhotoInput.ProbeHDR(path, out var info);
            if (probe == HDRProbeState.Supported) return RenderHDR(path, settings, lut, edge, output, longEdge, formatOverride,info!,statistics,clipping);
            if (settings.IsHDREditing) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        else if (settings.IsHDREditing && PhotoInput.IsRaw(path))
        {
            var probe = PhotoInput.ProbeCameraRaw(path, out var info);
            if (probe == HDRProbeState.Supported) return RenderHDR(path, settings, lut, edge, output, longEdge, formatOverride, info!, statistics, clipping);
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        (settings,var request)=PrepareRequest(path,settings,lut,edge,interactive,output,longEdge,viewportPreview);
        var format=output==null ? (ExportFormat?)null : ExportFormatExtensions.FromPath(output);
        Native.Buffer buffer = default, mask = default;
        try
        {
            aiNativeOperationStarted=true;
            var status = Native.sony2fuji_process(session,ref request,out buffer);
            if (output != null && (status == 6 || (status == 3 && format != ExportFormat.RenderedDng)))
                throw new OutputWriteException(Loc.Text("无法写入成片，请检查输出位置和剩余空间。"));
            if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status,session);
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
            var normalX3f=PhotoInput.IsNormalX3f(path,settings);
            var calibrated = normalX3f || !raster && Native.sony2fuji_session_get_raw_white_balance(session,out temperature,out tint) == 0;
            var count = (double)buffer.Width * buffer.Height;
            // Statistics consume RGBA before the private output buffers are swizzled for WPF.
            return new(Bitmap(buffer),!statisticsAvailable || mask.Data==IntPtr.Zero ? null : Bitmap(mask,false),bins,shadows/count,highlights/count,baseline,
                calibrated ? RoundCameraWhiteBalance(temperature,tint) : null,LastBackend,raster || normalX3f ? null : ReadLens(path),checked((int)nativeWidth),checked((int)nativeHeight));
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }

    private static int HDRPreviewEdge(int edge) => Math.Clamp(edge <= 0 ? 2000 : edge, 1, 2000);
    private RenderedImage? RenderHDR(string path, Adjustments settings, string? lut, int edge, string? output,
        int? longEdge, ExportFormat? formatOverride,HDRSourceInfo info,bool statistics,bool clipping)
    {
        var final = output != null;
        var format = output == null ? (ExportFormat?)null : formatOverride ?? (Path.GetExtension(output).Equals(".dng", StringComparison.OrdinalIgnoreCase)
            ? ExportFormat.RenderedDng : ExportFormat.HdrJpeg);
        var camera = settings.IsHDREditing ? settings.HDR!.CameraDevelopment : null;
        if (camera is { IsDefault:false } && (!info.IsCameraRaw || info.IsProRAW))
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        if (final && info.IsProRAW && format is (ExportFormat.Jpeg or ExportFormat.HdrJpeg or ExportFormat.SdrJpeg))
        {
            using var stream = File.OpenRead(path);
            var digest = SHA256.HashData(stream);
            HDRNative.ExportProRAW(session, path, settings.HDR!, output!, digest, format!.Value == ExportFormat.HdrJpeg,
                checked((uint)Math.Clamp(longEdge ?? 0, 0, 65535)));
            return null;
        }
        var edgeValue = (uint)HDRPreviewEdge(edge);
        using var source = AcquireHDRSource(path,info,final,edgeValue,settings);
        if (!settings.IsHDREditing && formatOverride == ExportFormat.HdrJpeg)
            throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
        if (!settings.IsHDREditing)
            return RenderHDRAsSDR(path, settings, lut, edge, output, longEdge, formatOverride, source.Owner,statistics,clipping);

        using var rendered = HDRNative.Render(session, source.Owner, settings.HDR!, final ? HDRIntent.Final : HDRIntent.Preview,
            final ? checked((uint)Math.Clamp(longEdge ?? 0, 0, 65535)) : edgeValue);
        if (output != null)
        {
            var metadataSource = info.IsCameraRaw ? null : path;
            if (format == ExportFormat.HdrJpeg) HDRNative.ExportHDR(rendered, metadataSource, output, rendered.Pair.SourceSha256 ?? []);
            else HDRNative.ExportSDR(rendered, format!.Value, metadataSource, output, rendered.Pair.SourceSha256 ?? []);
            return null;
        }
        var pair = HDRDisplay.CopyPair(rendered.Pair);
        if(statistics)_ = pair.Statistics;
        var analysis = statistics || clipping ? HDRDisplay.Statistics(pair.SDR,clipping) :
            (Histogram:Array.Empty<uint>(),Shadows:0d,Highlights:0d,Clipping:(BitmapSource?)null);
        return new(pair.SDRBitmap, analysis.Clipping, analysis.Histogram, analysis.Shadows, analysis.Highlights, 0, null, LastBackend,
            NativeWidth: checked((int)pair.OutputNativeWidth), NativeHeight: checked((int)pair.OutputNativeHeight), HDR: pair);
    }

    private RenderedImage? RenderHDRAsSDR(string path, Adjustments settings, string? lut, int edge, string? output,
        int? longEdge, ExportFormat? formatOverride, HDRPairOwner source,bool statistics,bool clipping)
    {
        var pair = HDRDisplay.CopyPair(source.Pair);
        using var input = new HDRSdrInput(pair.SDR);
        var prepared = PrepareRequest(path, settings, lut, edge, false, output, longEdge, output == null, input.Buffer);
        var request = prepared.Item2;
        Native.Buffer buffer = default, mask = default;
        try
        {
            var status = Native.sony2fuji_process(session, ref request, out buffer);
            var format = output == null ? (ExportFormat?)null : formatOverride ?? ExportFormatExtensions.FromPath(output);
            if (output != null && (status == 6 || status == 3 && format != ExportFormat.RenderedDng))
                throw new OutputWriteException(Loc.Text("无法写入成片，请检查输出位置和剩余空间。"));
            Native.Check(status);
            if (output != null)
            {
                if (HDRNative.Probe(path, out var currentSource) != HDRProbeState.Supported || currentSource == null ||
                    !currentSource.SourceSha256.SequenceEqual(pair.SourceSha256))
                    throw new HDRSourceException(1, 9, 1);
                if (format != ExportFormat.RenderedDng) ExportMetadata.Preserve(path, output);
                return null;
            }
            var (nativeWidth,nativeHeight)=HDRNative.GeometrySize(pair.NativeWidth,pair.NativeHeight,settings.Geometry);
            var bins = statistics || clipping ? new uint[768] : Array.Empty<uint>(); uint shadows = 0, highlights = 0;
            var available = false;
            if(statistics || clipping) {
                available = statisticsAnalyzer(ref buffer, clipping, bins, out shadows, out highlights, out mask) == 0;
                if (!available) {bins = [];shadows=highlights=0;}
            }
            var count = Math.Max(1d, (double)buffer.Width * buffer.Height);
            return new(Bitmap(buffer), !available || mask.Data==IntPtr.Zero ? null : Bitmap(mask,false), bins, shadows / count, highlights / count, 0, null, LastBackend,
                NativeWidth: checked((int)nativeWidth), NativeHeight: checked((int)nativeHeight));
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }

    private (Adjustments,Native.Request) PrepareRequest(string path,Adjustments settings,string? lut,int edge,bool interactive,string? output,int? longEdge,bool viewportPreview,Native.Buffer? inputOverride = null)
    {
        settings = PrepareRecipe(path, settings);
        if (inputOverride == null) EnsureInput(path);
        SetProcessing(settings.Processing);SetX3f(path,settings);SetTone(settings.RenderToneControls);SetAtmosphere(settings.RenderAtmosphere);SetGrading(settings.RenderGrading);SetCurve(settings.RenderCurve);
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
        if (inputOverride is { } display) SetInput(ref request, display); else SetInput(ref request,path);
        return (settings,request);
    }
    internal HslTargetSample SampleHsl(string path,Adjustments settings,string? lut,int edge,bool interactive,HslTargetRevision revision,double x,double y)
    {
        BeginAIOperation("hsl_probe",path);
        try{return SampleHslCore(path,settings,lut,edge,interactive,revision,x,y);}
        catch(Exception error) when(settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }
    private HslTargetSample SampleHslCore(string path,Adjustments settings,string? lut,int edge,bool interactive,HslTargetRevision revision,double x,double y)
    {
        if(!double.IsFinite(x) || !double.IsFinite(y))return HslTargetSample.Unavailable(revision,HslTargetAvailability.Nonfinite);
        if(x<0 || x>1 || y<0 || y>1)return HslTargetSample.Unavailable(revision,HslTargetAvailability.Outside);
        var hdrEdge = (uint)HDRPreviewEdge(edge);
        if (settings.HDR is { Mode: HDRMode.Hdr } hdr)
        {
            if (gpuMode == 2)
                throw new HDRSourceException(HDRNative.StatusUnsupported, HDRNative.ReasonUnsupportedGpu, 6);
            HDRSourceInfo? sourceInfo;
            var status = PhotoInput.IsRaw(path) ? PhotoInput.ProbeCameraRaw(path, out sourceInfo)
                : PhotoInput.ProbeHDR(path, out sourceInfo);
            if (status != HDRProbeState.Supported || sourceInfo == null ||
                sourceInfo.IsProRAW != (settings.ProRAWDecodeVersion == HDRNative.ProRAWDecodeVersion))
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
            using var hdrSource = AcquireHDRSource(path,sourceInfo,false,hdrEdge,settings);
            var hdrProbe = HDRNative.CreateHslProbe(session, hdrSource.Owner, hdr, hdrEdge, revision);
            try { return ReadHslProbe(hdrProbe, revision, x, y); }
            finally { Native.sony2fuji_hsl_probe_destroy(hdrProbe); }
        }
        using var source=PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path,out var info)==HDRProbeState.Supported
            ? HDRSourceCache.Acquire(path,info!,false,hdrEdge,session) : null;
        using var input=source==null ? null : new HDRSdrInput(HDRDisplay.CopyPair(source.Owner.Pair).SDR);
        var prepared=PrepareRequest(path,settings,lut,edge,interactive,null,null,true,input?.Buffer);
        var request=prepared.Item2;
        IntPtr probe=IntPtr.Zero;
        try {
            aiNativeOperationStarted=true;
            var status=Native.sony2fuji_session_create_hsl_probe(session,ref request,revision.Source,revision.Request,out probe);
            if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status,session);
            return ReadHslProbe(probe, revision, x, y);
        } finally { if(probe!=IntPtr.Zero)Native.sony2fuji_hsl_probe_destroy(probe); }
    }

    private static HslTargetSample ReadHslProbe(IntPtr probe, HslTargetRevision revision, double x, double y)
    {
        var query = new Native.HslProbeQuery { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HslProbeQuery>(),
            SourceRevision = revision.Source, RequestRevision = revision.Request, X = (float)x, Y = (float)y };
        Native.Check(Native.sony2fuji_hsl_probe_sample(probe, ref query, out var sample));
        if (sample.SourceRevision != revision.Source || sample.RequestRevision != revision.Request)
            return HslTargetSample.Unavailable(revision, HslTargetAvailability.Stale);
        return new(revision, (HslTargetAvailability)sample.Availability,
            sample.Rgb.Select(v => (double)v), sample.Weights.Select(v => (double)v), sample.Quality == 1);
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
    internal static bool X3fAvailable => Native.sony2fuji_x3f_available() != 0;
    internal static X3fMode X3fDefaultMode(string path)
    {
        return PhotoInput.X3fDefaultMode(path);
    }
    private void SetX3f(string path, Adjustments settings)
    {
        if (PhotoInput.IsNormalX3f(path,settings) && settings.AIDenoiseEnabled)
            throw new AIDenoiseException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
        Native.Check(Native.sony2fuji_session_set_x3f_mode(session,settings.X3fMode));
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
        if (PhotoInput.IsNormalX3f(path,settings)) {
            var relative = settings.Clone(); relative.ResolveWhiteBalance((6500,0)); return relative;
        }
        // 配方色调属于目标 RAW 的拍摄白平衡，不沿用冻结来源的相机值。
        var source = OriginalIdentity.Read(path);
        var key = new CameraWhiteBalanceKey(source, settings.Processing, settings.X3fMode, settings.ExposureMode);
        (double Temperature, double Tint) camera;
        if (recipeWhiteBalance is { } cached && cached.Key == key) camera = cached.Value;
        else
        {
            if (recipeWhiteBalance is { } previous && sourceStamp?.Raw != source &&
                StringComparer.OrdinalIgnoreCase.Equals(previous.Key.Source.Path, source.Path) && previous.Key.Source.FileID != source.FileID)
            {
                // 直接渲染也可能遇到同名替换。原生 RAW 缓存只比较路径、大小和修改时间。
                RecreateSession();
                lensStamp = null;
            }
            var neutral = new Adjustments { ExposureMode = settings.ExposureMode, Processing = settings.Processing, X3fMode = settings.X3fMode };
            camera = Render(path, neutral, null, 32, statistics: false, clipping: false)?.WhiteBalance
                ?? throw new InvalidOperationException(Loc.Text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"));
            recipeWhiteBalance = (key, camera);
        }
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
            if (PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path, out _) == HDRProbeState.Supported)
            {
                using var decoded = HDRNative.Decode(path, HDRIntent.Preview, checked((uint)Math.Clamp(edge, 1, 65535)));
                var pair = HDRDisplay.CopyPair(decoded.Pair);
                return new(pair.SDRBitmap, pair.SDR.Width, pair.SDR.Height);
            }
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
