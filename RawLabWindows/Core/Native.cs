using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RawLab.Windows;
internal static partial class Native
{
    private const string Dll = "sony2fuji.dll";
    [StructLayout(LayoutKind.Sequential)]
    internal struct Request
    {
        public uint Version, StructSize;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? InputPath;
        public int InputType; public IntPtr InputPixels;
        public uint InputWidth, InputHeight; public int InputPixelFormat, InputColorSpace, InputIsLinear;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? LutPath;
        public float LutStrength; public int WbMode;
        public float Wb0,Wb1,Wb2,Wb3,ExposureEv,Brightness,Contrast,Saturation,Temperature,Tint,Highlights,Shadows,ToneCurve,NoiseReduction,Sharpening;
        public int SizeMode; public uint TargetWidth,TargetHeight,LongEdge,ShortEdge;
        public int OutputTarget;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? OutputPath;
        public int OutputFormat; public uint JpegQuality; public int Intent; public uint PreviewLongEdge;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Buffer { public IntPtr Data; public nuint Size; public uint Width,Height,Stride; public int PixelFormat; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRDiagnostic { public uint Version, StructSize, Reason, Field; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRSourceInfo
    {
        public uint Version, StructSize, Width, Height, Orientation, Container, Protocol, ColorDescription;
        public float ContentHeadroom;
        public uint HeadroomKind;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32, ArraySubType = UnmanagedType.U1)] public byte[] SourceSha256;
        public uint CameraCapabilities;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRDecodeOptions { public uint Version, StructSize, Intent, LongEdge; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRCameraDevelopment
    {
        public uint Version, StructSize, WhiteBalance, ExposureReference;
        public float Temperature, Tint;
        public uint FbddLevel, LensFlags;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? LensProfile;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRCameraDevelopmentV2
    {
        public HDRCameraDevelopment Base;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string ProfilePath;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 65, ArraySubType = UnmanagedType.U1)] public byte[] ProfileSha256;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRCameraProfileInfo
    {
        public uint Version, StructSize;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64, ArraySubType = UnmanagedType.U1)] public byte[] CameraModel;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 65, ArraySubType = UnmanagedType.U1)] public byte[] Sha256;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRBuffer
    {
        public uint Version, StructSize;
        public IntPtr Data;
        public ulong SizeBytes;
        public uint Width, Height;
        public ulong StrideBytes;
        public uint PixelFormat, ColorEncoding;
        public float ContentHeadroom;
        public uint HeadroomKind;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRImagePair
    {
        public uint Version, StructSize;
        public HDRBuffer Hdr, Sdr;
        public uint NativeWidth, NativeHeight, OrientationApplied;
        public uint SourceIntent, RenderIntent, IsProxy;
        public ulong DecodeRevision;
        public float SourceHeadroom;
        public uint SourceHeadroomKind;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32, ArraySubType = UnmanagedType.U1)] public byte[] SourceSha256;
        public ulong OwnerToken;
        public uint OutputNativeWidth, OutputNativeHeight;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequest
    {
        public uint Version, StructSize, HDRProcessingVersion, Intent;
        public float ExposureEv, Temperature, Tint, Contrast, Highlights, Shadows, Saturation;
        public float CropX, CropY, CropWidth, CropHeight;
        public int QuarterTurns;
        public uint FlipHorizontal, FlipVertical;
        public float StraightenDegrees, PerspectiveHorizontal, PerspectiveVertical;
        public uint LongEdge;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV2
    {
        public HDRRequest Base;
        public float BlackPoint, WhitePoint, CurveStrength;
        public uint Reserved;
        public ToneCurveConfig Curve;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV3
    {
        public HDRRequestV2 Base;
        public float Vibrance;
        public uint Reserved;
        public HslConfig Hsl;
        public ColorGradingConfig Grading;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV4
    {
        public HDRRequestV3 Base;
        public float PeakLimitEV, SdrExposureEV, SdrContrast, SdrSaturation;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV5
    {
        public HDRRequestV4 Base;
        public PhotoEffectsConfig Effects;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV6
    {
        public HDRRequestV5 Base;
        public float Sharpening, Clarity, Dehaze, Denoise;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV7
    {
        public HDRRequestV6 Base;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? LookPath;
        public float LookStrength;
        public uint Reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 65)] public byte[] LookSha256;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV8 {
        public HDRRequestV7 Base;
        public ToneCurveConfig Red, Green, Blue;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRRequestV9 {
        public HDRRequestV8 Base;
        public int CurveApplyToLuminosity;
        public uint OutputSharpening;
        public ToneCurveParametricConfig ParametricCurve;
        public ColorGradingV2Config GradingV2;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRLookInfo
    {
        public uint Version, StructSize, GridSize, Reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] DomainMin;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] DomainMax;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 65)] public byte[] Sha256;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRExportConfig
    {
        public uint Version, StructSize, JpegQuality, BaseColor, MetadataPolicy;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? MetadataSourcePath;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32, ArraySubType = UnmanagedType.U1)] public byte[] SourceSha256;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRSdrExportConfig
    {
        public uint Version, StructSize, OutputFormat, Quality;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? MetadataSourcePath;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32, ArraySubType = UnmanagedType.U1)] public byte[] SourceSha256;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int HDRReadRowsCallback(IntPtr context, uint hdr, uint firstRow, uint rowCount, IntPtr output);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int HDRFinishDecodeCallback(IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int CancellationCallback(IntPtr context);
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRStreamSource
    {
        public uint Version, StructSize, NativeWidth, NativeHeight, OrientationApplied, SourceIntent;
        public ulong DecodeRevision;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? DecoderIdentifier;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32, ArraySubType = UnmanagedType.U1)] public byte[] SourceSha256;
        public IntPtr Context;
        public HDRReadRowsCallback? ReadRows;
        public HDRFinishDecodeCallback? FinishDecode;
        public CancellationCallback? IsCancelled;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HDRStreamResult
    {
        public uint Version, StructSize, Width, Height, NativeWidth, NativeHeight, OutputNativeWidth, OutputNativeHeight;
        public ulong DecodeRevision;
        public float SourceHeadroom, EditedHeadroom;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct GpuConfig { public uint Version,StructSize; public int Mode; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct WaveletConfig { public uint Version,StructSize; public int Enabled; public float Luma,Chroma,Coarse; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ColorGradingConfig { public uint Version, StructSize; public float ShadowsHue, ShadowsSaturation, MidtonesHue, MidtonesSaturation, HighlightsHue, HighlightsSaturation; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ColorGradingV2Config {
        public uint Version, StructSize;
        public float ShadowsHue, ShadowsSaturation, ShadowsLuminance;
        public float MidtonesHue, MidtonesSaturation, MidtonesLuminance;
        public float HighlightsHue, HighlightsSaturation, HighlightsLuminance;
        public float GlobalHue, GlobalSaturation, GlobalLuminance;
        public float Blending, Balance;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct AtmosphereConfig { public uint Version, StructSize; public float Clarity, Dehaze; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneControlsConfig { public uint Version, StructSize; public float BlackPoint, WhitePoint, Vibrance; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessingMigrationResult
    {
        public uint Version, StructSize;
        public int SourceVersion, TargetVersion, Disposition;
        public uint EvaluationCount;
        public float ExposureEv, Contrast, Highlights, Shadows, Saturation;
        public float BlackPoint, WhitePoint, Vibrance, Clarity, Dehaze;
        public float RgbRmse, P99Error, WorstTileRmse, DetailRmse;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct RecipeWbRequest
    {
        public uint Version, StructSize;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string? InputPath;
        public int ProcessingVersion, X3fMode, ExposureMode, RecipeActive;
        public float RecipeStrength;
        public int CustomWb;
        public float Temperature, Tint;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct RecipeWbResult
    {
        public uint Version, StructSize;
        public int WbMode;
        public float Temperature, Tint, CameraTemperature, CameraTint;
        public int CameraCalibrated;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneCurveConfig {
        public uint Version, StructSize; public int Mode; public uint Count;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=66)] public double[] Points;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneCurveParametricConfig {
        public uint Version, StructSize;
        public float Highlights, Lights, Darks, Shadows;
        public float SplitShadow, SplitMidtone, SplitHighlight;
        public uint Reserved;
    }
    internal enum WbProbeAvailability { Available = 0, Overexposed = 1, Outside = 2, Unavailable = 3 }
    [StructLayout(LayoutKind.Sequential)]
    internal struct WbProbeQuery {
        public uint Version, StructSize;
        public float NormX, NormY;
        public uint WindowSize, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct WbProbeResult {
        public uint Version, StructSize;
        public int Availability;
        public uint ValidPixelCount, RejectedOverexposedCount;
        public float Temperature, Tint;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] SampledRgb;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] WbMul;
        public uint Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneCurveSetConfig {
        public uint Version, StructSize;
        public ToneCurveConfig Master, Red, Green, Blue;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneCurveParametricConfig {
        public uint Version, StructSize;
        public float Highlights, Lights, Darks, Shadows;
        public float SplitShadow, SplitMidtone, SplitHighlight;
        public uint Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneCurveSetV2Config {
        public uint Version, StructSize;
        public int ApplyToLuminosity;
        public uint Reserved;
        public ToneCurveConfig Master, Red, Green, Blue;
        public ToneCurveParametricConfig Parametric;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct PhotoEffectsConfig
    {
        public uint Version,StructSize;
        public float VignetteAmount,VignetteMidpoint,VignetteRoundness,VignetteFeather,VignetteHighlights;
        public float GrainAmount,GrainSize,GrainRoughness;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct GeometryConfig
    {
        public uint Version, StructSize;
        public float CropX, CropY, CropWidth, CropHeight;
        public int QuarterTurns, FlipHorizontal, FlipVertical;
        public float StraightenDegrees;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct PerspectiveConfig
    {
        public uint Version,StructSize;
        public float Horizontal,Vertical;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HslConfig
    {
        public uint Version, StructSize;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public float[] Hue;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public float[] Saturation;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public float[] Lightness;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HslProbeQuery
    {
        public uint Version,StructSize;
        public ulong SourceRevision,RequestRevision;
        public float X,Y;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct HslProbeResult
    {
        public uint Version,StructSize;
        public ulong SourceRevision,RequestRevision;
        public uint Width,Height;
        public int Availability,Quality;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=3)] public float[] Rgb;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=3)] public float[] Hsl;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=8)] public float[] Weights;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct LensConfig {
        public uint Version, StructSize;
        public int Distortion, Tca, AutoCrop;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string ProfileId;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct LensConfigV2 { public LensConfig Base; public int Vignetting; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct LensProfile {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=512)] public byte[] Id;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=128)] public byte[] Maker;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=256)] public byte[] Model;
        public int HasDistortion, HasTca, IsMatch;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct LensReport {
        public int State;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=128)] public byte[] CameraMake;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=128)] public byte[] CameraModel;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=256)] public byte[] LensModel;
        public float FocalLength;
        public LensProfile Profile;
        public int AppliedDistortion, AppliedTca;
        public float CropScale;
    }
    internal const int StatusOk = 0;
    internal const int StatusInvalidArgument = 1;
    internal const int StatusUnsupported = 2;
    internal const int StatusIoError = 3;
    internal const int StatusOutOfMemory = 5;
    internal const int StatusCancelled = 7;

    [StructLayout(LayoutKind.Sequential)]
    internal struct DcpBlob
    {
        public IntPtr Data;
        public nuint SizeBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AIConfig
    {
        public uint Version, StructSize;
        public int Enabled, Backend;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string ModelDirectory;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string CacheDirectory;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int AIProgress(IntPtr context, int phase, ulong completed, ulong total);

    internal static string Text(byte[]? value)
    {
        if (value == null) return "";
        var end = Array.IndexOf(value, (byte)0);
        return System.Text.Encoding.UTF8.GetString(value, 0, end >= 0 ? end : value.Length);
    }
    internal sealed class Session : SafeHandleZeroOrMinusOneIsInvalid
    {
        public Session() : base(true) { CheckWithoutSession(sony2fuji_session_create(out var value)); SetHandle(value); }
        protected override bool ReleaseHandle() => sony2fuji_session_destroy(handle) == 0;
    }
    internal enum UnsupportedReason
    {
        None = 0,
        ForceGpu = 1,
    }
    internal enum GpuFallbackReason
    {
        None = 0,
        BasicV3Controls = 1,
        Atmosphere = 2,
        Curves = 3,
        C5Wavelet = 4,
        DcpLook = 5,
        LutContract = 6,
        Geometry = 7,
        DisplayInput = 8,
        GpuDisabled = 9,
        NoAdapter = 10,
        Cooldown = 11,
        DeviceError = 12,
        FilterError = 13,
        UnsupportedCapability = 14,
    }
    internal static string FormatErrorMessage(
        int status,
        string? x3fDetail,
        UnsupportedReason unsupportedReason = UnsupportedReason.None,
        string? gpuError = null)
    {
        if (status != 0 && !string.IsNullOrEmpty(x3fDetail))
            return Loc.Format("无法正常显影 X3F：{0}", x3fDetail);
        return status switch {
            1 => Loc.Text("参数或输出路径无效。"),
            2 => unsupportedReason == UnsupportedReason.ForceGpu
                ? Loc.Text("当前照片、外观或处理方式不支持强制 GPU，可切换为自动（Auto）回退。")
                : Loc.Text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"),
            3 => Loc.Text("无法读取或写入文件，请检查路径和访问权限。"),
            4 => !string.IsNullOrWhiteSpace(gpuError)
                ? Loc.Format("照片处理失败：{0}", gpuError)
                : Loc.Text("照片处理失败。"),
            5 => Loc.Text("内存不足，请关闭其他大型应用或使用适合窗口预览。"),
            _ => Loc.Text("照片处理失败。")
        };
    }
    internal static void Check(int status, Session session)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (status == 0) return;
        if (status == StatusCancelled) throw new OperationCanceledException();
        var detail = Marshal.PtrToStringUTF8(sony2fuji_session_x3f_error(session));
        var unsupportedReason = status == 2
            ? (UnsupportedReason)sony2fuji_session_get_unsupported_reason(session)
            : UnsupportedReason.None;
        var gpuError = Marshal.PtrToStringUTF8(sony2fuji_session_get_gpu_error(session));
        var fallbackReason = (GpuFallbackReason)sony2fuji_session_get_gpu_fallback_reason(session);
        if (fallbackReason != GpuFallbackReason.None || !string.IsNullOrWhiteSpace(gpuError))
            Trace.WriteLine($"Native GPU failure status={status} unsupported={unsupportedReason} fallback={fallbackReason} detail={gpuError}");
        throw new InvalidOperationException(FormatErrorMessage(status, detail, unsupportedReason, gpuError));
    }

    internal static void CheckWithoutSession(int status)
    {
        if (status == 0) return;
        if (status == StatusCancelled) throw new OperationCanceledException();
        throw new InvalidOperationException(FormatErrorMessage(status, null, UnsupportedReason.None));
    }
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_create(out IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_destroy(IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_apply_params(
        Session session, [MarshalAs(UnmanagedType.LPUTF8Str)] string recipeJson);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_x3f_available();
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_x3f_default_mode(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string input, out X3fMode mode);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_is_normal_x3f(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? input, X3fMode mode);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_x3f_error(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_lens_database(Session session,[MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [StructLayout(LayoutKind.Sequential)]
    internal struct LensReportV2 { public LensReport Base; public int HasVignetting, AppliedVignetting; }
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_lens_report_v2(Session session, out LensReportV2 report);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_lens_report(Session session,out LensReport report);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_inspect_lens(Session session,[MarshalAs(UnmanagedType.LPUTF8Str)] string input,out LensReport report,[Out] LensProfile[]? profiles,uint capacity,out uint count);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_create_hsl_probe(Session session,ref Request request,ulong sourceRevision,ulong requestRevision,out IntPtr probe);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hsl_probe_sample(IntPtr probe,ref HslProbeQuery query,out HslProbeResult result);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_hsl_probe_destroy(IntPtr probe);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_geometry_size(Session session,out uint width,out uint height);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_estimate_auto_exposure(Session session,ref Request request,out float exposure);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_gpu_config(Session session,ref GpuConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_cancellation_callback(
        Session session, CancellationCallback? callback, IntPtr context);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_last_backend(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_unsupported_reason(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_gpu_fallback_reason(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_gpu_error(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_interactive_preview(Session session,int enabled);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_viewport_preview(Session session,int enabled);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_sample_tone_curve(ref ToneCurveConfig config,[In] double[] x,[Out] double[] y,uint count);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_sample_tone_curve_v2(
        ref ToneCurveConfig config, ref ToneCurveParametricConfig parametric, [In] double[] x, [Out] double[] y, uint count);
    [DllImport(Dll, EntryPoint="sony2fuji_sample_tone_curve_v2", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int SampleToneCurveV2WithoutParametric(
        ref ToneCurveConfig config, IntPtr parametric, [In] double[] x, [Out] double[] y, uint count);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_tone_curves_v2(
        Session session, ref ToneCurveSetV2Config config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_exposure(Session session,out float baseline,out float metadata);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_white_balance(Session session,out float temperature,out float tint);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_effective_raw_white_balance(Session session,out float temperature,out float tint);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_resolve_recipe_wb(Session session,ref RecipeWbRequest request,out RecipeWbResult result);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_sample_wb_probe(Session session, ref Request request, ref WbProbeQuery query, ref WbProbeResult result);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_process(Session session,ref Request request,out Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_migrate_processing(Session session,ref Request request,ref ProcessingMigrationResult result);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_release_buffer(ref Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_analyze_image(ref Buffer buffer,int mode,[Out] uint[] bins,out uint shadows,out uint highlights,out Buffer mask);
    [DllImport(Dll, EntryPoint="sony2fuji_analyze_image", CallingConvention=CallingConvention.Cdecl)] internal static extern int AnalyzeWithoutMask(ref Buffer buffer,int mode,[Out] uint[] bins,out uint shadows,out uint highlights,IntPtr mask);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_thumbnail([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out Buffer buffer,out int kind,out int flip);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_preview([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out Buffer buffer,out int kind,out int flip,out int width,out int height);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_load_display_image([MarshalAs(UnmanagedType.LPUTF8Str)] string path,ref Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_display_preview([MarshalAs(UnmanagedType.LPUTF8Str)] string path,uint edge,ref Buffer buffer,out uint width,out uint height);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_probe(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRSourceInfo info, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_probe_camera_raw_with_processing(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, int processingVersion, ref HDRSourceInfo info, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_decode(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options, ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_decode_camera_raw(
        Session? session, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options,
        ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_decode_camera_raw_with_development(
        Session? session, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options,
        ref HDRCameraDevelopment development, ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, EntryPoint="sony2fuji_hdr_decode_camera_raw_with_development", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int DecodeWithHDRCameraProfile(Session? session,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options,
        ref HDRCameraDevelopmentV2 development, ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_probe_camera_profile(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRCameraProfileInfo info, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_probe_proraw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRSourceInfo info, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_decode_proraw(
        Session? session, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string temporaryRoot, ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_export_proraw(
        Session session, [MarshalAs(UnmanagedType.LPUTF8Str)] string sourcePath, ref HDRRequestV9 request,
        ref HDRExportConfig config, uint keepHdr, [MarshalAs(UnmanagedType.LPUTF8Str)] string temporaryRoot,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRStreamResult result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_geometry_size(
        uint nativeWidth, uint nativeHeight, ref HDRRequest request, out uint width, out uint height, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_render(
        Session session, ref HDRImagePair source, ref HDRRequestV9 request, ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_create_hsl_probe(
        Session session, ref HDRImagePair source, ref HDRRequestV9 request, ulong sourceRevision, ulong requestRevision,
        out IntPtr probe, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_estimate_auto_exposure(
        ref HDRImagePair source, float temperature, float tint, out float exposure, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_export_jpeg(
        ref HDRImagePair image, ref HDRExportConfig config, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_export_sdr(
        ref HDRImagePair image, ref HDRSdrExportConfig config, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_export_stream(
        Session session, ref HDRStreamSource source, ref HDRRequestV9 request, ref HDRExportConfig config, uint keepHdr,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string temporaryRoot, [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        ref HDRStreamResult result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_hdr_release_pair(ref HDRImagePair image);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hdr_probe_look(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRLookInfo info, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    internal static extern int sony2fuji_hdr_prepare_camera_raw_ai(Session session,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, AIProgress progress, IntPtr context, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    internal static extern int sony2fuji_hdr_camera_ai_key(Session session,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, [Out] byte[] key, uint capacity, ref HDRDiagnostic diagnostic);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    internal static extern int sony2fuji_hdr_decode_camera_raw_with_ai(Session? session,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref HDRDecodeOptions options, ref HDRCameraDevelopment development,
        ref HDRImagePair result, ref HDRDiagnostic diagnostic);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_ai_available();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_ai_hardware_available();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_ai_get_devices();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_ai_device(
        Session session,[MarshalAs(UnmanagedType.LPUTF8Str)] string deviceID);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_ai_diagnostics(Session session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_ai_denoise(Session session,ref AIConfig config);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_ai_denoise_blend(Session session, float strength);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_prepare_ai(Session session,ref Request request,AIProgress progress,IntPtr context);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_ai_error(Session session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_ai_backend(Session session);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int sony2fuji_preview_lut_compatibility(Session session, ref Request request,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configuration, ref Buffer output);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int sony2fuji_compare_lut_previews(ref Buffer candidate, ref Buffer reference,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string conditions, ref DcpBlob output);
    [DllImport(Dll, EntryPoint = "sony2fuji_compile_dcp", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int CompileDcp(
        IntPtr source,
        nuint sourceSizeBytes,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceName,
        ref DcpBlob output,
        ref DcpErrorReason reason);
    [DllImport(Dll, EntryPoint = "sony2fuji_compile_dcp_with_options", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int CompileDcpWithOptions(
        IntPtr source,
        nuint sourceSizeBytes,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceName,
        IntPtr toneCurveJson,
        nuint toneCurveSizeBytes,
        uint omitAutomaticBlack,
        ref DcpBlob output,
        ref DcpErrorReason reason);
    [DllImport(Dll, EntryPoint = "sony2fuji_release_blob", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void ReleaseBlob(ref DcpBlob blob);
    [DllImport(Dll, EntryPoint = "sony2fuji_validate_look", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int ValidateLook(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        out LookFormat format,
        out uint formatVersion);
    [DllImport(Dll, EntryPoint = "sony2fuji_inspect_lut_color", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int InspectLutColor([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Dll, EntryPoint = "sony2fuji_inspect_lut_compatibility", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int InspectLutCompatibility([MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref DcpBlob output);
    [DllImport(Dll, EntryPoint = "sony2fuji_prepare_lut_compatibility", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int PrepareLutCompatibility([MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string request, ref DcpBlob output);
}
