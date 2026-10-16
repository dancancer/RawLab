namespace RawLab.Windows;

internal enum FilmGroup { Fuji, Kodak, Other }
internal sealed record FilmStripItem<T>(T Value, bool StartsGroup);

internal static class FilmGrouping
{
    internal static FilmGroup ForBuiltIn(string fileName)
    {
        if (BundledLook.All.TryGetValue(fileName, out var look))
            return look.Id.StartsWith("RawLab_look_", StringComparison.Ordinal) ||
                look.Id == "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65" ? FilmGroup.Kodak : FilmGroup.Other;
        return fileName.StartsWith("FLog2_to_", StringComparison.Ordinal) ? FilmGroup.Fuji : FilmGroup.Other;
    }

    internal static IReadOnlyList<FilmStripItem<T>> Arrange<T>(IEnumerable<T> values, Func<T, bool> neutral, Func<T, FilmGroup> group)
    {
        FilmGroup? previous = null;
        return values.OrderBy(value => neutral(value) ? -1 : (int)group(value)).Select(value => {
            var current = neutral(value) ? (FilmGroup?)null : group(value);
            var separator = current.HasValue && previous.HasValue && current != previous;
            if (current.HasValue) previous = current;
            return new FilmStripItem<T>(value, separator);
        }).ToArray();
    }
}
