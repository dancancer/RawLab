namespace RawLab.Windows;

internal sealed class WorkspacePhotoSelection
{
    private readonly HashSet<string> marks = new(StringComparer.OrdinalIgnoreCase);
    private string? anchor;
    private SelectionChange? previousClick;

    private sealed record SelectionChange(string Path, string? PreviousAnchor, IReadOnlyList<string> Added, bool Removed);

    internal IReadOnlySet<string> Marks => marks;

    internal void Toggle(string path, IReadOnlyList<string> photos, bool extend)
    {
        var added = new List<string>();
        var removed = false;
        if (extend && anchor != null && IndexOf(photos, anchor) is var first && first >= 0 &&
            IndexOf(photos, path) is var last && last >= 0)
        {
            for (var i = Math.Min(first, last); i <= Math.Max(first, last); i++)
                if (marks.Add(photos[i])) added.Add(photos[i]);
        }
        else if (marks.Add(path)) added.Add(path);
        else removed = marks.Remove(path);
        previousClick = new(path, anchor, added, removed);
        anchor = path;
    }

    internal void BeforeOpening(string path)
    {
        if (previousClick is { } previous && StringComparer.OrdinalIgnoreCase.Equals(previous.Path, path))
        {
            marks.ExceptWith(previous.Added);
            if (previous.Removed) marks.Add(path);
            anchor = previous.PreviousAnchor;
        }
        previousClick = null;
    }

    internal void ForgetRange()
    {
        anchor = null;
        previousClick = null;
    }

    internal void Remove(IEnumerable<string> paths)
    {
        marks.ExceptWith(paths);
        ForgetRange();
    }

    internal void Clear()
    {
        marks.Clear();
        ForgetRange();
    }

    private static int IndexOf(IReadOnlyList<string> photos, string path)
    {
        for (var i = 0; i < photos.Count; i++)
            if (StringComparer.OrdinalIgnoreCase.Equals(photos[i], path)) return i;
        return -1;
    }
}
