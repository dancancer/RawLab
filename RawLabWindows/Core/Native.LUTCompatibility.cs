using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal static partial class Native
{
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int sony2fuji_preview_lut_compatibility(Session session, ref Request request,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configuration, ref Buffer output);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int sony2fuji_compare_lut_previews(ref Buffer candidate, ref Buffer reference,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string conditions, ref PInvokeNative.DcpBlob output);
}
