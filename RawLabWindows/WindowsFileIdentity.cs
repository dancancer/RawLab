using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RawLab.Windows;

internal readonly record struct WindowsFileId(uint VolumeSerialNumber, uint FileIndexHigh, uint FileIndexLow);

internal static class WindowsFileIdentity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out NativeFileInformation information);

    // Keep this handle open through rendering and publication. Omitting
    // FileShare.Delete prevents a rename or replacement through another name.
    internal static FileStream OpenReadLock(string path) => new(
        path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.SequentialScan);

    internal static bool IsSameFile(FileStream source, string candidate)
    {
        if (!File.Exists(candidate)) return false;
        using var destination = new FileStream(candidate, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
        return Read(source) == Read(destination);
    }

    internal static OriginalIdentity ReadIdentity(string path)
    {
        using var stream=OpenReadLock(path);
        if(!GetFileInformationByHandle(stream.SafeFileHandle,out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(),Loc.Text("无法读取文件身份。"));
        static long Ticks(System.Runtime.InteropServices.ComTypes.FILETIME value)=>
            DateTime.FromFileTimeUtc(((long)(uint)value.dwHighDateTime<<32)|(uint)value.dwLowDateTime).Ticks;
        return new OriginalIdentity(Path.GetFullPath(path),((long)information.FileSizeHigh<<32)|information.FileSizeLow,
            Ticks(information.LastWriteTime),Ticks(information.CreationTime)) {
            FileID=$"{information.VolumeSerialNumber:x8}-{information.FileIndexHigh:x8}-{information.FileIndexLow:x8}"
        };
    }

    private static WindowsFileId Read(FileStream stream)
    {
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), Loc.Text("无法读取文件身份。"));
        return new(information.VolumeSerialNumber, information.FileIndexHigh, information.FileIndexLow);
    }
}
