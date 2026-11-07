using System.IO;

namespace RawLab.Windows;

// Camera RAW probing deliberately does not hash or unpack the source. The
// stamp is therefore part of the managed cache identity until decode returns
// the actual SHA-256 digest.
internal sealed record HDRFileStamp(long Length, long Modified, long Created)
{
    internal static HDRFileStamp Read(string path)
    {
        var file = new FileInfo(Path.GetFullPath(path));
        if (!file.Exists) throw new FileNotFoundException(Loc.Text("无法访问原始照片。"), path);
        return new(file.Length, file.LastWriteTimeUtc.Ticks, file.CreationTimeUtc.Ticks);
    }
}

public enum HDRProbeState { NotHDR, Supported }

public sealed record HDRSourceInfo(
    HDRProbeState State,
    uint Width,
    uint Height,
    uint Orientation,
    uint Container,
    uint Protocol,
    uint ColorDescription,
    float ContentHeadroom,
    uint HeadroomKind,
    byte[] SourceSha256)
{
    public bool IsHDR => State == HDRProbeState.Supported;
    public bool IsProRAW => Container == HDRNative.ContainerProRAW;
    public bool IsCameraRaw => Container is HDRNative.ContainerCameraRaw or HDRNative.ContainerProRAW;
    internal bool SupportsBayerDevelopment { get; init; }

    // Camera RAW and ProRAW probes do not hash or unpack the source. Keep the
    // file stamp in the preview cache key until decode returns the SHA-256.
    internal HDRFileStamp? CameraStamp { get; init; }
    internal string CacheIdentity => IsCameraRaw
        ? $"camera:{CameraStamp?.Length}:{CameraStamp?.Modified}:{CameraStamp?.Created}"
        : Convert.ToHexString(SourceSha256 ?? []);
}

public sealed class HDRSourceException(int status, uint reason, uint field) : IOException(LocalizedMessage(status, reason))
{
    public int Status { get; } = status;
    public uint Reason { get; } = reason;
    public uint Field { get; } = field;

    private static string LocalizedMessage(int status, uint reason) => reason switch {
        HDRNative.ReasonNotHDR => Loc.Text("此照片没有可编辑的 HDR 增益图。"),
        2 or 3 or 4 => Loc.Text("不支持此 HDR 格式或颜色描述。"),
        HDRNative.ReasonUnsupportedRaw => Loc.Text("不支持此相机 RAW 的 HDR 显影。"),
        13 => Loc.Text("HDR 编辑目前使用 CPU。请将 GPU 模式设为自动或关闭。"),
        10 => Loc.Text("内存不足，无法完整处理此 HDR 照片。请关闭其他照片后重试。"),
        11 => Loc.Text("无法写入 HDR 导出文件，请检查可用空间和目标权限。"),
        18 => Loc.Text("无法读取外观文件。"),
        19 => Loc.Text("无效或不可用的镜头校正设置"),
        21 when status == 3 => Loc.Text("找不到 HDR 相机配置，请重新导入。"),
        21 => Loc.Text("无法读取 HDR 相机配置，或配置与当前相机不匹配。"),
        _ => Loc.Format("HDR 处理失败（{0}）。", reason)
    };
}
