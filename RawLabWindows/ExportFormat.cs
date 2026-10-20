using System.IO;

namespace RawLab.Windows;

public enum ExportFormat
{
    Jpeg,
    Png,
    RenderedDng
}

public static class ExportFormatExtensions
{
    public static string Suffix(this ExportFormat format) => format switch
    {
        ExportFormat.Jpeg => "jpg",
        ExportFormat.Png => "png",
        ExportFormat.RenderedDng => "dng",
        _ => throw new ArgumentOutOfRangeException(nameof(format))
    };

    public static int NativeValue(this ExportFormat format) => format switch
    {
        ExportFormat.Jpeg => 0,
        ExportFormat.Png => 1,
        ExportFormat.RenderedDng => 4,
        _ => throw new ArgumentOutOfRangeException(nameof(format))
    };

    public static ExportFormat FromPath(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".png" => ExportFormat.Png,
        ".dng" => ExportFormat.RenderedDng,
        _ => ExportFormat.Jpeg
    };

    public static bool AcceptsPath(this ExportFormat format, string path) => format switch
    {
        ExportFormat.Jpeg => Path.GetExtension(path).Equals(".jpg", StringComparison.OrdinalIgnoreCase) ||
            Path.GetExtension(path).Equals(".jpeg", StringComparison.OrdinalIgnoreCase),
        ExportFormat.Png => Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase),
        ExportFormat.RenderedDng => Path.GetExtension(path).Equals(".dng", StringComparison.OrdinalIgnoreCase),
        _ => throw new ArgumentOutOfRangeException(nameof(format))
    };

    public static string Title(this ExportFormat format) => format switch
    {
        ExportFormat.Jpeg => "JPEG",
        ExportFormat.Png => Loc.Text("16-bit PNG"),
        ExportFormat.RenderedDng => Loc.Text("DNG · 渲染型"),
        _ => throw new ArgumentOutOfRangeException(nameof(format))
    };
}
