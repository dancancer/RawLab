using System.IO;

namespace RawLab.Windows;

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
}

public sealed class HDRSourceException(int status, uint reason, uint field) : IOException(LocalizedMessage(status, reason))
{
    public int Status { get; } = status;
    public uint Reason { get; } = reason;
    public uint Field { get; } = field;

    private static string LocalizedMessage(int status, uint reason) => reason switch {
        HDRNative.ReasonNotHDR => Loc.Text("此照片没有可编辑的 HDR 增益图。"),
        2 or 3 or 4 => Loc.Text("不支持此 HDR 格式或颜色描述。"),
        13 => Loc.Text("HDR 编辑目前使用 CPU。请将 GPU 模式设为自动或关闭。"),
        10 => Loc.Text("内存不足，无法完整处理此 HDR 照片。请关闭其他照片后重试。"),
        11 => Loc.Text("无法写入 HDR 导出文件，请检查可用空间和目标权限。"),
        _ => Loc.Format("HDR 处理失败（{0}）。", reason)
    };
}
