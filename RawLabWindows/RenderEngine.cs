using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
internal sealed record RenderedImage(BitmapSource Image, BitmapSource? Clipping, uint[] Histogram, double Shadows, double Highlights, float Baseline, (double Temperature,double Tint)? WhiteBalance, int Backend, LensInfo? Lens = null, int NativeWidth = 0, int NativeHeight = 0, HDRRenderedPair? HDR = null, Native.GpuFallbackReason FallbackReason = Native.GpuFallbackReason.None, string? GpuError = null);
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
        int ExposureMode,HslSettings Hsl,LensSettings Lens,GeometrySettings Geometry,ProcessingIdentity Processing,X3fMode X3fMode,int RecipeSettingsVersion,double Strength,bool AIEnabled,double AIBlend,int Mode,OriginalIdentity Raw,OriginalIdentity? Lut,HDRSettings? HDR,int? ProRAWDecodeVersion,string? SourceFingerprint);
    private readonly string lensDatabase;
    private readonly AppPaths appPaths;
    private Stamp? lensStamp;
    private LensCandidate[] lensCandidates = [];
    private string? lastSourceFingerprint;
    private (OriginalIdentity Raw,OriginalIdentity? Lut)? sourceStamp;
    private ((NeutralReferenceKey Reference, int GpuMode, int? ProRAWDecodeVersion) Key, RenderedImage Frame)? original;
    private readonly PreviewRevisionCache<(PreviewKey Key, int Edge), PreviewFrame> previewCache =
        new(256L * 1024 * 1024, FrameBytes, maximumEntries: 16);
    internal Native.Session Session => session;
    internal Native.CancellationCallback? CancellationCallback { get => cancellationCallback; set => cancellationCallback = value; }
    internal bool HasOriginal => original != null;
    // The optional result cache is separate from the active comparison image.
    internal long CachedPreviewBytes => previewCache.TotalBytes;
    private static long ImageBytes(RenderedImage value)=>(long)value.Image.PixelWidth*value.Image.PixelHeight*4*(value.Clipping==null ? 1 : 2) +
        (value.HDR is { } pair ? (long)pair.HDR.RGB.Length * sizeof(float) + (long)pair.SDR.RGB.Length * sizeof(float) : 0);
    private static long FrameBytes(PreviewFrame frame)=>ImageBytes(frame.Result)+
        (ReferenceEquals(frame.Neutral,frame.Result) ? 0 : ImageBytes(frame.Neutral));
    public int LastBackend => Native.sony2fuji_session_get_last_backend(session);
    internal Native.GpuFallbackReason LastFallbackReason => (Native.GpuFallbackReason)Native.sony2fuji_session_get_gpu_fallback_reason(session);
    internal string? LastGpuError => Marshal.PtrToStringUTF8(Native.sony2fuji_session_get_gpu_error(session));
    public RenderEngine(int gpuMode=1, string? lensDatabase=null,StatisticsAnalyzer? statisticsAnalyzer=null,string? aiModelDirectory=null,string? aiCacheDirectory=null,int? aiBackend=null,
        string aiDeviceID="",AIDiagnosticStore? aiDiagnostics=null,AppPaths? appPaths=null)
    {
        this.appPaths=appPaths ?? AppPaths.Default;
        this.statisticsAnalyzer=statisticsAnalyzer ?? AnalyzeStatistics;
        this.lensDatabase = lensDatabase ?? Path.Combine(AppContext.BaseDirectory,"Lensfun");
        this.aiModelDirectory=aiModelDirectory ?? BundledAIModel;
        this.aiCacheDirectory=aiCacheDirectory ?? this.appPaths.DualDnCacheDirectory;
        aiBackendOverride=aiBackend;
        this.aiDeviceID=aiDeviceID;aiDiagnosticStore=aiDiagnostics ?? (appPaths != null ? new(this.appPaths.AiDiagnosticsDirectory) : AIDiagnosticStore.Default);
        try { InitializeSession(); SetGpuMode(gpuMode); }
        catch { session.Dispose(); throw; }
    }
    private void InitializeSession() => Native.Check(Native.sony2fuji_session_set_lens_database(session,lensDatabase), session);
    public void SetGpuMode(int mode) { var config=new Native.GpuConfig{Version=1,StructSize=12,Mode=mode};Native.Check(Native.sony2fuji_session_set_gpu_config(session,ref config), session);gpuMode=mode; }
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
                    GCHandle.ToIntPtr(cancellationHandle)), session);
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
            GCHandle.ToIntPtr(cancellationHandle)), session);
    }
    private void ClearCancellation()
    {
        if (!session.IsInvalid && !session.IsClosed)
            Native.Check(Native.sony2fuji_session_set_cancellation_callback(session, null, IntPtr.Zero), session);
        cancellationCallback = null;
        if (cancellationHandle.IsAllocated) cancellationHandle.Free();
    }
    private sealed record CancellationState(CancellationToken Token);
    public void Dispose() { ClearCancellation(); previewCache.Clear(); original=null; Native.sony2fuji_release_buffer(ref displayInput); inputStamp=null; session.Dispose(); }
    public double AutoExposure(string path, Adjustments settings)
    {
        BeginAIOperation("auto_exposure",path);
        try{return AutoExposureCore(path,settings);}
        catch(Exception error) when(settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }

    internal Native.ProcessingMigrationResult MigrateProcessing(string path, Adjustments settings, string? lut,
        CancellationToken cancellationToken)
    {
        if (settings.IsHDREditing || settings.HDR != null || settings.ActiveAIDenoise || settings.MasterRecipeID != null ||
            settings.Processing.Version is not (1 or 2))
            throw new InvalidOperationException(Loc.Text("此照片的调整保留原处理版本。"));
        cancellationToken.ThrowIfCancellationRequested();
        var (options, editStateJson) = PrepareExecution(path, settings, lut, 0, false, null, null, false);
        try
        {
            SetCancellation(cancellationToken);
            var result = new Native.ProcessingMigrationResult {
                Version = 1, StructSize = (uint)Marshal.SizeOf<Native.ProcessingMigrationResult>()
            };
            var status = Native.sony2fuji_session_migrate_processing_json(session, ref options, editStateJson, ref result);
            if (status == 7) throw new OperationCanceledException(cancellationToken);
            Native.Check(status, session);
            return result;
        }
        finally { ClearCancellation(); }
    }

    internal static void ValidateHDRRender(Adjustments settings, bool? sourceIsProRAW = null) =>
        settings.RequireActiveHDRDecodeVersion(sourceIsProRAW);

    private double AutoExposureCore(string path, Adjustments settings)
    {
        if (settings.HDR is { Mode: HDRMode.Hdr } hdr)
        {
            ValidateHDRRender(settings);
            if (gpuMode == 2)
                throw new HDRSourceException(HDRNative.StatusUnsupported, HDRNative.ReasonUnsupportedGpu, 6);
            HDRSourceInfo? sourceInfo;
            var probe = PhotoInput.IsRaw(path) ? PhotoInput.ProbeCameraRaw(path, out sourceInfo, settings.Processing.Version)
                : PhotoInput.ProbeHDR(path, out sourceInfo);
            if (probe != HDRProbeState.Supported || sourceInfo == null)
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
            ValidateHDRRender(settings, sourceInfo.IsProRAW);
            using var source = AcquireHDRSource(path,sourceInfo,false,1280,settings);
            return HDRNative.EstimateAutoExposure(source.Owner, hdr);
        }
        if (PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path, out var info) == HDRProbeState.Supported)
            return AutoExposureHDRSource(path, settings, info!);
        var (options, editStateJson) = PrepareExecution(path, settings, null, 0, false, null, null, false, includeDenoise: false);
        aiNativeOperationStarted = true;
        var status = Native.sony2fuji_session_estimate_auto_exposure_json(session, ref options, editStateJson, out var ev);
        if (settings.AIDenoiseEnabled) CheckAI(status); else Native.Check(status, session);
        return ev;
    }

    private double AutoExposureHDRSource(string path, Adjustments settings, HDRSourceInfo info)
    {
        using var source = HDRSourceCache.Acquire(path, info, false, 256, session,
            temporaryRoot: appPaths.HdrCacheDirectory, cameraProfileDirectory: appPaths.HdrCameraProfilesDirectory);
        var pair = HDRDisplay.CopySDROnly(source.Owner.Pair);
        using var input = new HDRSdrInput(pair.SDR);
        var (options, editStateJson) = PrepareExecution(path, settings, null, 256, false, null, null, true, input.Buffer);
        var status = Native.sony2fuji_session_estimate_auto_exposure_json(session, ref options, editStateJson, out var ev);
        if (settings.AIDenoiseEnabled) CheckAI(status); else Native.Check(status, session);
        return ev;
    }
    public PreviewFrame RenderPreview(string path,Adjustments settings,string? lut,int edge,bool interactive,bool compare,bool clipping,Action? renderStarted=null,Func<bool>? shouldCancel=null)
    {
        if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
        ValidateHDRRender(settings);
        settings=PrepareInputSettings(path,settings);
        var previousCallback = cancellationCallback;
        var previousHandle = cancellationHandle;
        var ticketHandle = default(GCHandle);
        if (shouldCancel != null)
        {
            ticketHandle = GCHandle.Alloc(shouldCancel);
            cancellationHandle = ticketHandle;
            cancellationCallback = static context =>
            {
                try
                {
                    return GCHandle.FromIntPtr(context).Target is Func<bool> predicate && predicate() ? 1 : 0;
                }
                catch
                {
                    return 0;
                }
            };
        }
        try
        {
            if (shouldCancel != null)
                Native.Check(Native.sony2fuji_session_set_cancellation_callback(session, cancellationCallback,
                    GCHandle.ToIntPtr(ticketHandle)), session);
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
                PhotoInput.ProbeCameraRaw(path, out var cameraInfo, settings.Processing.Version) == HDRProbeState.Supported)
                sourceFingerprint = cameraInfo!.CacheIdentity;
            var preparedRecipe = settings.IsHDREditing ? (PreparedRecipeSettings?)null : PrepareRecipe(path, settings);
            var keySettings = preparedRecipe?.Settings ?? settings;
            var key=new PreviewKey(
                preparedRecipe is { } resolved ? resolved.Request(path,lut,2000,null) : settings.Request(path,lut,2000,null),
                keySettings.Denoise,keySettings.Effects,keySettings.ToneControls,keySettings.Atmosphere,keySettings.ColorGrading,keySettings.Curve,keySettings.DisplayChromaDenoise,
                keySettings.ExposureMode,keySettings.Hsl,keySettings.Lens,keySettings.Geometry,keySettings.Processing,keySettings.X3fMode,keySettings.MasterRecipeSettingsVersion,keySettings[Parameter.Strength],keySettings.ActiveAIDenoise,keySettings.AIDenoiseStrength,gpuMode,rawStamp,lutStamp,keySettings.HDR,keySettings.ProRAWDecodeVersion,sourceFingerprint);
            var fingerprintChanged = lastSourceFingerprint != sourceFingerprint;
            lastSourceFingerprint = sourceFingerprint;
            // HDR previews have a 2000px ceiling, including the viewport's native-size request.
            var cacheEdge=settings.IsHDREditing && sourceFingerprint!=null ? HDRPreviewEdge(edge) : edge;
            var cacheKey = (key, cacheEdge);
            var referenceKey=(new NeutralReferenceKey(rawStamp,PhotoInput.IsRaster(path),settings.Processing,
                settings.Geometry,settings.Lens,cacheEdge,settings.IsHDREditing,settings.X3fMode,NeutralReference.HDRCameraSettings(settings.IsHDREditing ? settings.HDR : null)),gpuMode,settings.ProRAWDecodeVersion);
            if(original?.Key!=referenceKey || fingerprintChanged)original=null;
            // AI 模型或磁盘结果可在 WPF 帧之外变化，必须经过 native 的完整性与身份检查。
            PreviewFrame? cached = null;
            if(!settings.ActiveAIDenoise) previewCache.TryGet(cacheKey, out cached);
            if(cached!=null && !compare)
            {
                if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
                return WithMask(ReferenceEquals(cached.Neutral,cached.Result) ? cached : new(cached.Result,cached.Result));
            }
            if(cached!=null && !ReferenceEquals(cached.Neutral,cached.Result))
            {
                if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
                original=(referenceKey,cached.Neutral);
                return WithMask(cached);
            }
            var neutral=compare ? original?.Frame : null;
            if(cached==null || (compare && neutral==null))renderStarted?.Invoke();
            if(compare && neutral==null)
            {
                if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
                neutral=Render(path,NeutralReference.Settings(path,settings),null,edge,clipping:false,viewportPreview:true)!;
                if(neutral.Histogram.Length==768)original=(referenceKey,neutral);
            }
            if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
            var result=cached?.Result ?? Render(path,settings,lut,edge,interactive,clipping:false,viewportPreview:true)!;
            var frame=new PreviewFrame(neutral ?? result,result);
            if(!interactive && !settings.ActiveAIDenoise && result.Histogram.Length==768 && (!compare || neutral?.Histogram.Length==768))
            {
                previewCache.Set(cacheKey, frame);
            }
            return WithMask(frame);
        }
        finally
        {
            if (shouldCancel != null)
            {
                if (!session.IsInvalid && !session.IsClosed)
                {
                    if (previousCallback != null)
                    {
                        var ptr = previousHandle.IsAllocated ? GCHandle.ToIntPtr(previousHandle) : IntPtr.Zero;
                        _ = Native.sony2fuji_session_set_cancellation_callback(session, previousCallback, ptr);
                    }
                    else
                    {
                        _ = Native.sony2fuji_session_set_cancellation_callback(session, null, IntPtr.Zero);
                    }
                }
                cancellationCallback = previousCallback;
                cancellationHandle = previousHandle;
                if (ticketHandle.IsAllocated) ticketHandle.Free();
            }
        }

        PreviewFrame WithMask(PreviewFrame preview)
        {
            if (shouldCancel?.Invoke() == true) throw new OperationCanceledException();
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

    internal static (byte[] Bgra8, int Width, int Height, int Stride) ExtractBGRA8Preview(BitmapSource image)
    {
        var bgra = image.Format == PixelFormats.Bgra32 || image.Format == PixelFormats.Pbgra32
            ? image
            : new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var width = bgra.PixelWidth;
        var height = bgra.PixelHeight;
        var stride = checked(width * 4);
        var pixels = new byte[checked(stride * height)];
        bgra.CopyPixels(pixels, stride, 0);
        return (pixels, width, height, stride);
    }

    internal static unsafe BitmapSource? RenderSharpenMaskPreview(
        byte[] bgra8, int width, int height, int stride, double radius, double masking)
    {
        if (width <= 0 || height <= 0 || stride < width * 4 || bgra8.Length < checked(stride * height))
            return null;
        Native.Buffer outMask = default;
        try
        {
            fixed (byte* ptr = bgra8)
            {
                var src = new Native.Buffer
                {
                    Data = (IntPtr)ptr,
                    Size = (nuint)bgra8.Length,
                    Width = (uint)width,
                    Height = (uint)height,
                    Stride = (uint)stride,
                    PixelFormat = 3 // SONY2FUJI_PIXEL_BGRA8
                };
                Native.CheckWithoutSession(Native.sony2fuji_render_sharpen_mask_preview(
                    ref src, (float)radius, (float)masking, out outMask));
            }
            if (outMask.Data == IntPtr.Zero || outMask.Width == 0 || outMask.Height == 0)
                return null;
            return Bitmap(outMask);
        }
        finally
        {
            Native.sony2fuji_release_buffer(ref outMask);
        }
    }
    public RenderedImage? Render(string path, Adjustments settings, string? lut, int edge, bool interactive = false, string? output = null, bool statistics = true, bool clipping = true, int? longEdge = null, bool viewportPreview = false, ExportFormat? formatOverride = null, OutputSharpening outputSharpening = OutputSharpening.Off)
    {
        BeginAIOperation(output==null ? "preview" : "export",path);
        try{return RenderCore(path,settings,lut,edge,interactive,output,statistics,clipping,longEdge,viewportPreview,formatOverride,outputSharpening);}
        catch(Exception error) when(settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {CaptureAIFailure(error);throw;}
    }
    private RenderedImage? RenderCore(string path,Adjustments settings,string? lut,int edge,bool interactive,string? output,bool statistics,bool clipping,int? longEdge,bool viewportPreview,ExportFormat? formatOverride,OutputSharpening outputSharpening)
    {
        if (output != null && formatOverride == ExportFormat.HdrJpeg &&
            (settings.HDR is not { Mode: HDRMode.Hdr } ||
             !(PhotoInput.IsHDRContainer(path) || PhotoInput.IsRaw(path))))
            throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
        ValidateHDRRender(settings);
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
            if (probe == HDRProbeState.Supported) return RenderHDR(path, settings, lut, edge, output, longEdge, formatOverride,info!,statistics,clipping,outputSharpening);
            if (settings.IsHDREditing) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        else if (settings.IsHDREditing && PhotoInput.IsRaw(path))
        {
            var probe = PhotoInput.ProbeCameraRaw(path, out var info, settings.Processing.Version);
            if (probe == HDRProbeState.Supported) return RenderHDR(path, settings, lut, edge, output, longEdge, formatOverride, info!, statistics, clipping,outputSharpening);
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        var format=output==null ? (ExportFormat?)null : formatOverride ?? ExportFormatExtensions.FromPath(output);
        var effectiveSharpening = output == null || format == ExportFormat.RenderedDng ? OutputSharpening.Off : outputSharpening;
        var (options, editStateJson) = PrepareExecution(path, settings, lut, edge, interactive, output, longEdge, viewportPreview, outputSharpening: effectiveSharpening);
        Native.Buffer buffer = default, mask = default;
        try
        {
            aiNativeOperationStarted=true;
            var status = Native.sony2fuji_session_render(session, ref options, editStateJson, out buffer, IntPtr.Zero);
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
            Native.Check(Native.sony2fuji_session_get_geometry_size(session,out var nativeWidth,out var nativeHeight), session);
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
            float baseline=0,temperature=0,tint=0;
            var raster=LibraryEntry.IsRaster(path);
            if(!raster)Native.Check(Native.sony2fuji_session_get_raw_exposure(session,out baseline,out _), session);
            var calibrated = !raster && Native.sony2fuji_session_get_effective_raw_white_balance(session,out temperature,out tint) == 0;
            var normalX3f = !raster && Native.sony2fuji_is_normal_x3f(path,settings.X3fMode) != 0;
            var count = (double)buffer.Width * buffer.Height;
            var fallbackReason = LastFallbackReason;
            var gpuError = LastGpuError;
            if (gpuMode != 0 && LastBackend != 3 && (fallbackReason != Native.GpuFallbackReason.None || !string.IsNullOrWhiteSpace(gpuError)))
                Trace.WriteLine($"GPU fell back to CPU (mode={gpuMode}, reason={fallbackReason}, detail={gpuError})");
            // Statistics consume RGBA before the private output buffers are swizzled for WPF.
            return new(Bitmap(buffer),!statisticsAvailable || mask.Data==IntPtr.Zero ? null : Bitmap(mask,false),bins,shadows/count,highlights/count,baseline,
                calibrated ? ((double)temperature,(double)tint) : null,LastBackend,raster || normalX3f ? null : ReadLens(path),checked((int)nativeWidth),checked((int)nativeHeight),
                FallbackReason: fallbackReason, GpuError: string.IsNullOrWhiteSpace(gpuError) ? null : gpuError);
        }
        finally { Native.sony2fuji_release_buffer(ref buffer); Native.sony2fuji_release_buffer(ref mask); }
    }

    private static int HDRPreviewEdge(int edge) => Math.Clamp(edge <= 0 ? 2000 : edge, 1, 2000);
    private RenderedImage? RenderHDR(string path, Adjustments settings, string? lut, int edge, string? output,
        int? longEdge, ExportFormat? formatOverride,HDRSourceInfo info,bool statistics,bool clipping,OutputSharpening outputSharpening = OutputSharpening.Off)
    {
        ValidateHDRRender(settings, info.IsProRAW);
        var final = output != null;
        var format = output == null ? (ExportFormat?)null : formatOverride ?? (Path.GetExtension(output).Equals(".dng", StringComparison.OrdinalIgnoreCase)
            ? ExportFormat.RenderedDng : ExportFormat.HdrJpeg);
        var effectiveSharpening = final && format != ExportFormat.RenderedDng ? outputSharpening : OutputSharpening.Off;
        var camera = settings.IsHDREditing ? settings.HDR!.CameraDevelopment : null;
        if (camera is { IsDefault:false } && (!info.IsCameraRaw || info.IsProRAW))
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        if (final && info.IsProRAW && format is (ExportFormat.Jpeg or ExportFormat.HdrJpeg or ExportFormat.SdrJpeg))
        {
            using var stream = File.OpenRead(path);
            var digest = SHA256.HashData(stream);
            HDRNative.ExportProRAW(session, path, settings.HDR!, output!, digest, format!.Value == ExportFormat.HdrJpeg,
                checked((uint)Math.Clamp(longEdge ?? 0, 0, 65535)), temporaryRoot: appPaths.HdrCacheDirectory, outputSharpening: effectiveSharpening);
            return null;
        }
        var edgeValue = (uint)HDRPreviewEdge(edge);
        using var source = AcquireHDRSource(path,info,final,edgeValue,settings);
        if (!settings.IsHDREditing && formatOverride == ExportFormat.HdrJpeg)
            throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
        if (!settings.IsHDREditing)
            return RenderHDRAsSDR(path, settings, lut, edge, output, longEdge, formatOverride, source.Owner,statistics,clipping,effectiveSharpening);

        using var rendered = HDRNative.Render(session, source.Owner, settings.HDR!, final ? HDRIntent.Final : HDRIntent.Preview,
            final ? checked((uint)Math.Clamp(longEdge ?? 0, 0, 65535)) : edgeValue, appPaths.HdrLooksDirectory, effectiveSharpening);
        if (output != null)
        {
            var metadataSource = info.IsCameraRaw ? null : path;
            if (format == ExportFormat.HdrJpeg) HDRNative.ExportHDR(rendered, metadataSource, output, rendered.Pair.SourceSha256 ?? []);
            else HDRNative.ExportSDR(rendered, format!.Value, metadataSource, output, rendered.Pair.SourceSha256 ?? []);
            return null;
        }
        var pair = HDRDisplay.CopyPair(rendered.Pair);
        if(statistics)_ = pair.Statistics;
        BitmapSource image;
        uint[] histogram = [];
        double shadows = 0, highlights = 0;
        BitmapSource? clippingMask = null;
        if (statistics || clipping)
        {
            (image, histogram, shadows, highlights, clippingMask) = HDRDisplay.RenderSDRWithStatistics(pair.SDR, clipping);
            pair.SeedSDRBitmap(image);
        }
        else
        {
            image = pair.SDRBitmap;
        }
        return new(image, clippingMask, histogram, shadows, highlights, 0, null, LastBackend,
            NativeWidth: checked((int)pair.OutputNativeWidth), NativeHeight: checked((int)pair.OutputNativeHeight), HDR: pair);
    }

    private RenderedImage? RenderHDRAsSDR(string path, Adjustments settings, string? lut, int edge, string? output,
        int? longEdge, ExportFormat? formatOverride, HDRPairOwner source,bool statistics,bool clipping,OutputSharpening outputSharpening = OutputSharpening.Off)
    {
        var pair = HDRDisplay.CopySDROnly(source.Pair);
        using var input = new HDRSdrInput(pair.SDR);
        var format = output == null ? (ExportFormat?)null : formatOverride ?? ExportFormatExtensions.FromPath(output);
        var effectiveSharpening = (output == null || format == ExportFormat.RenderedDng) ? OutputSharpening.Off : outputSharpening;
        var (options, editStateJson) = PrepareExecution(path, settings, lut, edge, false, output, longEdge, output == null, input.Buffer, outputSharpening: effectiveSharpening);
        Native.Buffer buffer = default, mask = default;
        try
        {
            var status = Native.sony2fuji_session_render(session, ref options, editStateJson, out buffer, IntPtr.Zero);
            if (output != null && (status == 6 || status == 3 && format != ExportFormat.RenderedDng))
                throw new OutputWriteException(Loc.Text("无法写入成片，请检查输出位置和剩余空间。"));
            Native.Check(status, session);
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

    private static Native.RenderOptions BuildRenderOptions(string path, int edge, string? output, int? longEdge, bool interactive, bool viewportPreview)
    {
        if (longEdge is { } requested && !ExportSize.IsValid(requested))
            throw new ArgumentOutOfRangeException(nameof(longEdge), Loc.Text("导出长边必须为 1-65535 像素。"));
        var limitedFinal = output != null && longEdge.HasValue;
        return new Native.RenderOptions
        {
            Version = 1,
            StructSize = (uint)Marshal.SizeOf<Native.RenderOptions>(),
            InputPath = path,
            Intent = output != null || edge == 0 ? 1 : 0,
            SizeMode = limitedFinal ? 4 : 3,
            LongEdge = limitedFinal ? (uint)longEdge!.Value : 0,
            PreviewLongEdge = (uint)edge,
            InteractivePreview = interactive && edge > 0 && output == null ? 1 : 0,
            ViewportPreview = viewportPreview && edge > 0 && output == null ? 1 : 0,
            OutputTarget = output == null ? 1 : 0,
            OutputFormat = output == null ? 3 : ExportFormatExtensions.FromPath(output).NativeValue(),
            OutputPath = output,
            JpegQuality = 95
        };
    }

    private (Native.RenderOptions Options, string EditStateJson) PrepareExecution(string path, Adjustments settings, string? lut, int edge,
        bool interactive, string? output, int? longEdge, bool viewportPreview, Native.Buffer? inputOverride = null,
        OutputSharpening outputSharpening = OutputSharpening.Off, bool includeDenoise = true)
    {
        var prepared = PrepareRecipe(path, settings);
        settings = prepared.Settings;
        if (inputOverride == null) EnsureInput(path);
        if (settings.AIDenoiseEnabled && Native.sony2fuji_is_normal_x3f(path, settings.X3fMode) != 0)
            throw new AIDenoiseException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
        ConfigureAI(settings.AIDenoiseEnabled);
        var options = BuildRenderOptions(path, edge, output, longEdge, interactive, viewportPreview);
        if (inputOverride is { } display) SetInput(ref options, display); else SetInput(ref options, path);
        var isRaster = inputOverride != null || PhotoInput.IsRaster(path);
        var editStateJson = CanonicalEditRecipe.EncodeState(settings, isRaster, includeDenoise, outputSharpening, lut);
        return (options, editStateJson);
    }
    internal sealed record WbProbeSample(Native.WbProbeAvailability Availability, double Temperature, double Tint, uint ValidPixelCount, uint RejectedOverexposedCount);
    internal WbProbeSample SampleWhiteBalance(string path, Adjustments settings, string? lut, int edge, double x, double y, uint windowSize = 3)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y) || x < 0 || x > 1 || y < 0 || y > 1)
            return new(Native.WbProbeAvailability.Outside, 6500, 0, 0, 0);
        BeginAIOperation("wb_probe", path);
        try
        {
            var (options, editStateJson) = PrepareExecution(path, settings, lut, edge, false, null, null, true);
            var query = new Native.WbProbeQuery {
                Version = 1, StructSize = (uint)Marshal.SizeOf<Native.WbProbeQuery>(),
                NormX = (float)x, NormY = (float)y, WindowSize = windowSize, Reserved = 0
            };
            var result = new Native.WbProbeResult {
                Version = 1, StructSize = (uint)Marshal.SizeOf<Native.WbProbeResult>(),
                SampledRgb = new float[3], WbMul = new float[3]
            };
            aiNativeOperationStarted = true;
            var status = Native.sony2fuji_session_sample_wb_probe_json(session, ref options, editStateJson, ref query, ref result);
            if (settings.AIDenoiseEnabled) CheckAI(status); else Native.Check(status, session);
            return new((Native.WbProbeAvailability)result.Availability, result.Temperature, result.Tint, result.ValidPixelCount, result.RejectedOverexposedCount);
        }
        catch (Exception error) when (settings.ActiveAIDenoise && error is not OperationCanceledException && error is not AINotReadyException)
        {
            CaptureAIFailure(error);
            throw;
        }
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
            ValidateHDRRender(settings);
            if (gpuMode == 2)
                throw new HDRSourceException(HDRNative.StatusUnsupported, HDRNative.ReasonUnsupportedGpu, 6);
            HDRSourceInfo? sourceInfo;
            var status = PhotoInput.IsRaw(path) ? PhotoInput.ProbeCameraRaw(path, out sourceInfo, settings.Processing.Version)
                : PhotoInput.ProbeHDR(path, out sourceInfo);
            if (status != HDRProbeState.Supported || sourceInfo == null)
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
            ValidateHDRRender(settings, sourceInfo.IsProRAW);
            using var hdrSource = AcquireHDRSource(path,sourceInfo,false,hdrEdge,settings);
            var hdrProbe = HDRNative.CreateHslProbe(session, hdrSource.Owner, hdr, hdrEdge, revision);
            try { return ReadHslProbe(hdrProbe, revision, x, y); }
            finally { Native.sony2fuji_hsl_probe_destroy(hdrProbe); }
        }
        using var source=PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path,out var info)==HDRProbeState.Supported
            ? HDRSourceCache.Acquire(path,info!,false,hdrEdge,session,
                temporaryRoot:appPaths.HdrCacheDirectory,cameraProfileDirectory:appPaths.HdrCameraProfilesDirectory) : null;
        using var input=source==null ? null : new HDRSdrInput(HDRDisplay.CopySDROnly(source.Owner.Pair).SDR);
        var (options, editStateJson) = PrepareExecution(path, settings, lut, edge, interactive, null, null, true, input?.Buffer);
        IntPtr probe = IntPtr.Zero;
        try {
            aiNativeOperationStarted = true;
            var status = Native.sony2fuji_session_create_hsl_probe_json(session, ref options, editStateJson, revision.Source, revision.Request, out probe);
            if(settings.AIDenoiseEnabled)CheckAI(status);else Native.Check(status,session);
            return ReadHslProbe(probe, revision, x, y);
        } finally { if(probe!=IntPtr.Zero)Native.sony2fuji_hsl_probe_destroy(probe); }
    }

    private static HslTargetSample ReadHslProbe(IntPtr probe, HslTargetRevision revision, double x, double y)
    {
        var query = new Native.HslProbeQuery { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HslProbeQuery>(),
            SourceRevision = revision.Source, RequestRevision = revision.Request, X = (float)x, Y = (float)y };
        Native.CheckWithoutSession(Native.sony2fuji_hsl_probe_sample(probe, ref query, out var sample));
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
    private void ApplyProcessingOnly(ProcessingIdentity value) =>
        Native.Check(Native.sony2fuji_apply_params(session,
            CanonicalEditRecipe.ProcessingStateJson(ProcessingIdentity.Require(value).Version)), session);
    internal static bool X3fAvailable => Native.sony2fuji_x3f_available() != 0;
    internal static X3fMode X3fDefaultMode(string path)
    {
        return PhotoInput.X3fDefaultMode(path);
    }
    private LensInfo ReadLens(string path) {
        var file = new FileInfo(path);
        var stamp = new Stamp(file.FullName, file.Length, file.LastWriteTimeUtc.Ticks);
        if (stamp != lensStamp) {
            Native.Check(Native.sony2fuji_session_inspect_lens(session, path, out _, null, 0, out var count), session);
            var profiles = new Native.LensProfile[checked((int)count)];
            Native.Check(Native.sony2fuji_session_inspect_lens(session, path, out _, profiles, count, out _), session);
            lensCandidates = profiles.Select(p => new LensCandidate(Native.Text(p.Id), Native.Text(p.Maker), Native.Text(p.Model), p.HasDistortion != 0, p.HasTca != 0, p.IsMatch != 0)).ToArray();
            lensStamp = stamp;
        }
        Native.Check(Native.sony2fuji_session_get_lens_report_v2(session, out var extended), session);
        var report = extended.Base;
        return new(report.State, Native.Text(report.LensModel), Native.Text(report.Profile.Model), report.AppliedDistortion != 0,
            report.AppliedTca != 0, report.CropScale, lensCandidates, extended.AppliedVignetting != 0);
    }
    // internal：tests 的 AgentRecipeTestTool（Q9 测试工具）经 InternalsVisibleTo 复用同一冻结入口。
    internal PreparedRecipeSettings PrepareRecipe(string path, Adjustments settings)
    {
        if (LibraryEntry.IsRaster(path)) return new(PrepareInputSettings(path, settings), null);
        if (settings.MasterRecipeID == null) return new(settings, null);
        var req = new Native.RecipeWbRequest
        {
            Version = 1,
            StructSize = (uint)Marshal.SizeOf<Native.RecipeWbRequest>(),
            InputPath = path,
            ProcessingVersion = ProcessingIdentity.Require(settings.Processing).Version,
            X3fMode = (int)settings.X3fMode,
            ExposureMode = settings.ExposureMode,
            RecipeActive = 1,
            RecipeStrength = (float)settings[Parameter.Strength],
            CustomWb = settings.CameraWhiteBalance ? 0 : 1,
            Temperature = (float)settings[Parameter.Temperature],
            Tint = (float)settings[Parameter.Tint],
        };
        var status = Native.sony2fuji_session_resolve_recipe_wb(session, ref req, out var res);
        if (status == 2) throw new InvalidOperationException(Loc.Text("此 RAW 无法解析拍摄白平衡，不能应用配方色调。"));
        Native.Check(status, session);
        var prepared = settings.Clone();
        if (res.CameraCalibrated != 0) prepared.ResolveWhiteBalance((res.CameraTemperature, res.CameraTint));
        var whiteBalance = new ResolvedNativeWhiteBalance(
            res.WbMode,
            res.WbMode == 3 ? res.Temperature : 6500f,
            res.WbMode == 3 ? res.Tint : 0f);
        return new(prepared, whiteBalance);
    }
    internal static unsafe BitmapSource Bitmap(Native.Buffer buffer,bool opaque=true)
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
    public static BitmapSource? Thumbnail(string path, AppPaths? appPaths = null)=>ReadEmbeddedPreview(path,180,appPaths).Image;
    public static EmbeddedPreview ReadEmbeddedPreview(string path,int edge=1600,AppPaths? appPaths=null)
    {
        if (edge <= 0) return new(null, 0, 0);
        var paths = appPaths ?? AppPaths.Default;
        Native.Buffer buffer = default;
        return ReadEmbeddedPreviewCore(() =>
        {
            if (PhotoInput.IsHDRContainer(path) && PhotoInput.ProbeHDR(path, out _) == HDRProbeState.Supported)
            {
                using var decoded = HDRNative.Decode(path, HDRIntent.Preview, checked((uint)Math.Clamp(edge, 1, 65535)),
                    temporaryRoot: paths.HdrCacheDirectory, cameraProfileDirectory: paths.HdrCameraProfilesDirectory);
                var pair = HDRDisplay.CopySDROnly(decoded.Pair);
                return new(pair.SDRBitmap, pair.SDR.Width, pair.SDR.Height);
            }
            if(LibraryEntry.IsRaster(path))
            {
                if(Native.sony2fuji_load_display_preview(path,(uint)edge,ref buffer,out var sourceWidth,out var sourceHeight)!=0)return new(null,0,0);
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
        }, path, () => Native.sony2fuji_release_buffer(ref buffer));
    }
    internal static EmbeddedPreview ReadEmbeddedPreviewCore(Func<EmbeddedPreview> decode, string path, Action? release = null)
    {
        try
        {
            return PreviewFallback.ExecuteEmbedded(
                decode,
                new EmbeddedPreview(null, 0, 0),
                ex => System.Diagnostics.Trace.WriteLine($"Embedded preview fallback for {path}: {ex.Message}"));
        }
        finally { release?.Invoke(); }
    }
}
