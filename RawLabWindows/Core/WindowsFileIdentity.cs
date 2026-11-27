using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RawLab.Windows;

internal readonly record struct WindowsFileId(uint VolumeSerialNumber, uint FileIndexHigh, uint FileIndexLow);

internal readonly record struct WindowsStatSnapshot(
    long Length,
    long ModifiedTicks,
    long CreatedTicks,
    long ChangeTicks,
    long Usn,
    string FileId);

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

    [StructLayout(LayoutKind.Sequential)]
    private struct FileBasicInfo
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    private const int FileBasicInfoClass = 0;
    private const uint FsctlReadFileUsnData = 0x000900eb;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out NativeFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file, int fileInformationClass, out FileBasicInfo fileInformation, uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        IntPtr lpInBuffer,
        uint nInBufferSize,
        [Out] byte[] lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

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
        return ReadIdentityFromStream(path, stream);
    }

    internal static OriginalIdentity ReadCacheIdentity(string path)
    {
        using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.None);
        return ReadIdentityFromStream(path, stream);
    }

    internal static bool TryReadStat(string path, out WindowsStatSnapshot snapshot,
        Func<SafeFileHandle, (long ChangeTicks, long Usn)>? readChangeMarkers = null)
    {
        try
        {
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.None);
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            {
                snapshot = default;
                return false;
            }

            var (changeTicks, usn) = (readChangeMarkers ?? ReadChangeMarkers)(stream.SafeFileHandle);

            var length = ((long)information.FileSizeHigh << 32) | information.FileSizeLow;
            var fileId = $"{information.VolumeSerialNumber:x8}-{information.FileIndexHigh:x8}-{information.FileIndexLow:x8}";
            snapshot = new(
                length,
                FileTimeTicks(information.LastWriteTime),
                FileTimeTicks(information.CreationTime),
                changeTicks,
                usn,
                fileId);
            // 原地覆写可保留尺寸、mtime 和 FileID；没有独立变化标记时不能复用摘要。
            return changeTicks > 0 || usn > 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception)
        {
            snapshot = default;
            return false;
        }
    }

    private static (long ChangeTicks, long Usn) ReadChangeMarkers(SafeFileHandle file)
    {
        long changeTicks = 0;
        if (GetFileInformationByHandleEx(
            file, FileBasicInfoClass, out var basic, (uint)Marshal.SizeOf<FileBasicInfo>()))
        {
            changeTicks = basic.ChangeTime > 0 ? DateTime.FromFileTimeUtc(basic.ChangeTime).Ticks : 0;
        }

        long usn = 0;
        var usnBuffer = new byte[1024];
        if (DeviceIoControl(file, FsctlReadFileUsnData, IntPtr.Zero, 0,
            usnBuffer, (uint)usnBuffer.Length, out var returned, IntPtr.Zero) && returned >= 32)
        {
            var major = BitConverter.ToUInt16(usnBuffer, 4);
            if (major == 2) usn = BitConverter.ToInt64(usnBuffer, 24);
            else if (major == 3 && returned >= 48) usn = BitConverter.ToInt64(usnBuffer, 40);
        }
        return (changeTicks, usn);
    }

    private static OriginalIdentity ReadIdentityFromStream(string path, FileStream stream)
    {
        if(!GetFileInformationByHandle(stream.SafeFileHandle,out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(),Loc.Text("无法读取文件身份。"));
        return new OriginalIdentity(Path.GetFullPath(path),((long)information.FileSizeHigh<<32)|information.FileSizeLow,
            FileTimeTicks(information.LastWriteTime),FileTimeTicks(information.CreationTime)) {
            FileID=$"{information.VolumeSerialNumber:x8}-{information.FileIndexHigh:x8}-{information.FileIndexLow:x8}"
        };
    }

    private static long FileTimeTicks(System.Runtime.InteropServices.ComTypes.FILETIME value) =>
        DateTime.FromFileTimeUtc(((long)(uint)value.dwHighDateTime << 32) | (uint)value.dwLowDateTime).Ticks;

    private static WindowsFileId Read(FileStream stream)
    {
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error(), Loc.Text("无法读取文件身份。"));
        return new(information.VolumeSerialNumber, information.FileIndexHigh, information.FileIndexLow);
    }

    internal static bool TryGetLinkCount(string path, out uint linkCount)
    {
        linkCount = 0;
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.None);
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information)) return false;
            linkCount = information.NumberOfLinks;
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception)
        {
            return false;
        }
    }
}
