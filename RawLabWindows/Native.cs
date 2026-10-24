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
    internal struct GpuConfig { public uint Version,StructSize; public int Mode; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct WaveletConfig { public uint Version,StructSize; public int Enabled; public float Luma,Chroma,Coarse; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ColorGradingConfig { public uint Version, StructSize; public float ShadowsHue, ShadowsSaturation, MidtonesHue, MidtonesSaturation, HighlightsHue, HighlightsSaturation; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ToneControlsConfig { public uint Version, StructSize; public float BlackPoint, WhitePoint, Vibrance; }
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
    internal static string Text(byte[]? value)
    {
        if (value == null) return "";
        var end = Array.IndexOf(value, (byte)0);
        return System.Text.Encoding.UTF8.GetString(value, 0, end >= 0 ? end : value.Length);
    }
    internal sealed class Session : SafeHandleZeroOrMinusOneIsInvalid
    {
        public Session() : base(true) { Check(sony2fuji_session_create(out var value)); SetHandle(value); }
        protected override bool ReleaseHandle() => sony2fuji_session_destroy(handle) == 0;
    }
    internal static void Check(int status)
    {
        if (status != 0) throw new InvalidOperationException(status switch {
            1 => Loc.Text("参数或输出路径无效。"), 2 => Loc.Text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。"),
            3 => Loc.Text("无法读取或写入文件，请检查路径和访问权限。"), 5 => Loc.Text("内存不足，请关闭其他大型应用或使用适合窗口预览。"), _ => Loc.Text("照片处理失败。") });
    }
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_create(out IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_destroy(IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_raw_exposure_mode(Session session,int mode);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_processing_version(Session session,int version);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_lens_database(Session session,[MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_lens_correction(Session session,ref LensConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_lens_report(Session session,out LensReport report);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_inspect_lens(Session session,[MarshalAs(UnmanagedType.LPUTF8Str)] string input,out LensReport report,[Out] LensProfile[]? profiles,uint capacity,out uint count);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_hsl(Session session,ref HslConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_create_hsl_probe(Session session,ref Request request,ulong sourceRevision,ulong requestRevision,out IntPtr probe);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_hsl_probe_sample(IntPtr probe,ref HslProbeQuery query,out HslProbeResult result);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_hsl_probe_destroy(IntPtr probe);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_geometry(Session session,ref GeometryConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_perspective(Session session,ref PerspectiveConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_geometry_size(Session session,out uint width,out uint height);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_estimate_auto_exposure(Session session,ref Request request,out float exposure);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_gpu_config(Session session,ref GpuConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_last_backend(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_interactive_preview(Session session,int enabled);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_chroma_denoise(Session session,int mode);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_viewport_preview(Session session,int enabled);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_wavelet_denoise(Session session,ref WaveletConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_color_grading(Session session,ref ColorGradingConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_tone_controls(Session session,ref ToneControlsConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_photo_effects(Session session,ref PhotoEffectsConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_exposure(Session session,out float baseline,out float metadata);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_white_balance(Session session,out float temperature,out float tint);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_process(Session session,ref Request request,out Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_release_buffer(ref Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_analyze_image(ref Buffer buffer,int mode,[Out] uint[] bins,out uint shadows,out uint highlights,out Buffer mask);
    [DllImport(Dll, EntryPoint="sony2fuji_analyze_image", CallingConvention=CallingConvention.Cdecl)] internal static extern int AnalyzeWithoutMask(ref Buffer buffer,int mode,[Out] uint[] bins,out uint shadows,out uint highlights,IntPtr mask);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_thumbnail([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out Buffer buffer,out int kind,out int flip);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_preview([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out Buffer buffer,out int kind,out int flip,out int width,out int height);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_load_display_image([MarshalAs(UnmanagedType.LPUTF8Str)] string path,ref Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_display_preview([MarshalAs(UnmanagedType.LPUTF8Str)] string path,uint edge,ref Buffer buffer,out uint width,out uint height);
}
