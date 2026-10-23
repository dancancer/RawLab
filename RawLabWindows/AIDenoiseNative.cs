using System.Runtime.InteropServices;

namespace RawLab.Windows;
internal static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct AIConfig
    {
        public uint Version,StructSize;
        public int Enabled,Backend;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string ModelDirectory;
        [MarshalAs(UnmanagedType.LPUTF8Str)] public string CacheDirectory;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int AIProgress(IntPtr context,int phase,ulong completed,ulong total);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_ai_available();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_set_ai_denoise(Session session,ref AIConfig config);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern int sony2fuji_session_prepare_ai(Session session,ref Request request,AIProgress progress,IntPtr context);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_ai_error(Session session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr sony2fuji_session_get_ai_backend(Session session);
}
