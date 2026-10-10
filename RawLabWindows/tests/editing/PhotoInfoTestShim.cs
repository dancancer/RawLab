namespace RawLab.Windows;

// The pure editing target exercises JSON parsing without requiring WPF or a
// packaged ExifTool executable. The production reader still calls the real
// ExportMetadata.Run implementation.
internal static class ExportMetadata
{
    internal static string Run(IEnumerable<string> arguments) => "[]";
}
