namespace RawLab.Windows;

// A null long edge is the native renderer's original-size mode. The bounded
// value is only used for final exports; preview requests keep their own edge.
public static class ExportSize
{
    public const int MinimumLongEdge = 1;
    public const int MaximumLongEdge = 65535;

    public static bool IsValid(int value) => value is >= MinimumLongEdge and <= MaximumLongEdge;
    public static int? Parse(string? value) => int.TryParse(value, out var edge) && IsValid(edge) ? edge : null;
    public static string Label(int? longEdge) => longEdge is null ? "原尺寸" : $"长边 {longEdge} px";
}
