using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RawLab.Windows;
internal static class Native
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
    internal sealed class Session : SafeHandleZeroOrMinusOneIsInvalid
    {
        public Session() : base(true) { Check(sony2fuji_session_create(out var value)); SetHandle(value); }
        protected override bool ReleaseHandle() => sony2fuji_session_destroy(handle) == 0;
    }
    internal static void Check(int status)
    {
        if (status != 0) throw new InvalidOperationException(status switch {
            1 => "参数或输出路径无效，不能覆盖原始 RAW。", 2 => "不支持此 RAW 或外观文件。请选择声明兼容输入和 BT.709 输出的富士 CUBE，或有效的 .rlook 文件。",
            3 => "无法读取或写入文件，请检查路径与权限。", 5 => "内存不足，请关闭其他大型应用或使用适合窗口预览。", _ => "RAW 显影失败。" });
    }
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_create(out IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] private static extern int sony2fuji_session_destroy(IntPtr session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_raw_exposure_mode(Session session,int mode);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_gpu_config(Session session,ref GpuConfig config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_last_backend(Session session);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_interactive_preview(Session session,int enabled);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_exposure(Session session,out float baseline,out float metadata);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_get_raw_white_balance(Session session,out float temperature,out float tint);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_process(Session session,ref Request request,out Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern void sony2fuji_release_buffer(ref Buffer buffer);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_analyze_image(ref Buffer buffer,int mode,[Out] uint[] bins,out uint shadows,out uint highlights,out Buffer mask);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] internal static extern int rawlab_thumbnail([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out Buffer buffer,out int kind,out int flip);
}
