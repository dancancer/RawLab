using System.Runtime.InteropServices;

namespace RawLab.Windows;

// DCP import bindings are kept separate from the long-lived render ABI. The
// shared core owns parsing and RLOOK serialization; Windows only owns the
// bounded byte buffer and the managed file transaction around it.
internal static class PInvokeNative
{
    private const string Dll = "sony2fuji.dll";

    internal const int StatusOk = 0;
    internal const int StatusInvalidArgument = 1;
    internal const int StatusUnsupported = 2;
    internal const int StatusIoError = 3;
    internal const int StatusOutOfMemory = 5;

    [StructLayout(LayoutKind.Sequential)]
    internal struct DcpBlob
    {
        public IntPtr Data;
        public nuint SizeBytes;
    }

    [DllImport(Dll, EntryPoint = "sony2fuji_compile_dcp", ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int CompileDcp(
        IntPtr source,
        nuint sourceSizeBytes,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sourceName,
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
