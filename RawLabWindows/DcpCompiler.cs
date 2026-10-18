using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

internal sealed class DcpCompileException : Exception
{
    internal DcpCompileException(DcpErrorReason reason, int status = PInvokeNative.StatusUnsupported, Exception? inner = null)
        : base(MessageFor(reason, status), inner)
    {
        Reason = reason;
        Status = status;
    }

    internal DcpErrorReason Reason { get; }
    internal int Status { get; }

    private static string MessageFor(DcpErrorReason reason, int status) => reason switch
    {
        DcpErrorReason.TooLarge => Loc.Text("DCP 文件或外观数据超过安全大小限制。"),
        DcpErrorReason.InvalidCalibration => Loc.Text("DCP 缺少唯一、有效的 D65 ColorMatrix/ForwardMatrix，无法转换。"),
        DcpErrorReason.MissingToneCurve => Loc.Text("DCP 缺少 ProfileToneCurve；无法自动推断 Adobe 默认曲线。请先用制备工具明确指定曲线。"),
        DcpErrorReason.AutomaticBlack => Loc.Text("DCP 要求自动黑位处理，自动转换暂不支持。请先用制备工具明确选择黑位策略。"),
        DcpErrorReason.TripleIlluminant => Loc.Text("DCP 使用三光源 HueSatMap，暂不支持转换。"),
        DcpErrorReason.UnsupportedStages => Loc.Text("DCP 包含暂不支持的空间增益、HDR 或 RGB 表处理，无法转换。"),
        DcpErrorReason.InvalidTable => Loc.Text("DCP 的 HueSatMap/LookTable 数据、维度或编码不受支持。"),
        DcpErrorReason.InvalidTone => Loc.Text("DCP 曲线无效；需要 2 至 8192 个有限、范围为 0 至 1 且横坐标递增的点。"),
        DcpErrorReason.InvalidExposure => Loc.Text("DCP 曝光偏移无效；需要 -16 至 +16 EV 的有限数值。"),
        _ when status == PInvokeNative.StatusOutOfMemory => Loc.Text("内存不足，请关闭其他大型应用或使用适合窗口预览。"),
        _ => Loc.Text("DCP 文件损坏，或使用了不支持的 TIFF 结构。")
    };
}

internal static class DcpCompiler
{
    // These limits are part of the shared import contract, not a Windows UI limit.
    internal const long MaxSourceBytes = 128L * 1024 * 1024;
    internal const long MaxOutputBytes = 64L * 1024 * 1024;

    internal static byte[] Compile(string source)
    {
        if (string.IsNullOrWhiteSpace(source))
            throw new DcpCompileException(DcpErrorReason.Malformed, PInvokeNative.StatusInvalidArgument);

        var sourceInfo = new FileInfo(source);
        if (!sourceInfo.Exists) throw new FileNotFoundException(Loc.Text("无法读取或写入文件，请检查路径和访问权限。"), source);
        if ((sourceInfo.Attributes & FileAttributes.Directory) != 0)
            throw new IOException(Loc.Text("无法读取或写入文件，请检查路径和访问权限。"));
        if (sourceInfo.Length > MaxSourceBytes)
            throw new DcpCompileException(DcpErrorReason.TooLarge);

        var data = ReadBounded(sourceInfo.FullName);
        PInvokeNative.DcpBlob blob = default;
        var reason = DcpErrorReason.None;
        try
        {
            var handle = default(GCHandle);
            try
            {
                if (data.Length != 0) handle = GCHandle.Alloc(data, GCHandleType.Pinned);
                var pointer = data.Length == 0 ? IntPtr.Zero : handle.AddrOfPinnedObject();
                var status = PInvokeNative.CompileDcp(pointer, checked((nuint)data.LongLength),
                    sourceInfo.Name, ref blob, ref reason);
                if (status != PInvokeNative.StatusOk)
                    throw new DcpCompileException(reason == DcpErrorReason.None ? DcpErrorReason.Malformed : reason, status);
                if (blob.Data == IntPtr.Zero || blob.SizeBytes == 0)
                    throw new DcpCompileException(DcpErrorReason.Malformed, status);
                if (blob.SizeBytes > (nuint)MaxOutputBytes)
                    throw new DcpCompileException(DcpErrorReason.TooLarge, status);

                var result = new byte[checked((int)blob.SizeBytes)];
                Marshal.Copy(blob.Data, result, 0, result.Length);
                return result;
            }
            finally
            {
                if (handle.IsAllocated) handle.Free();
            }
        }
        finally
        {
            // The native side owns the output allocation on every return path.
            PInvokeNative.ReleaseBlob(ref blob);
        }
    }

    private static byte[] ReadBounded(string source)
    {
        using var stream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var data = new MemoryStream((int)Math.Min(stream.Length, MaxSourceBytes));
        var buffer = new byte[1024 * 1024];
        while (true)
        {
            var read = stream.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            if (data.Length > MaxSourceBytes - read)
                throw new DcpCompileException(DcpErrorReason.TooLarge);
            data.Write(buffer, 0, read);
        }
        return data.ToArray();
    }
}

internal enum DcpErrorReason
{
    None = 0,
    Malformed = 1,
    TooLarge = 2,
    InvalidCalibration = 3,
    MissingToneCurve = 4,
    AutomaticBlack = 5,
    TripleIlluminant = 6,
    UnsupportedStages = 7,
    InvalidTable = 8,
    InvalidTone = 9,
    InvalidExposure = 10
}
