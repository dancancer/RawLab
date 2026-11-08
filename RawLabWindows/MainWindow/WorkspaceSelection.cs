using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly WorkspacePhotoSelection workspaceSelection = new();
    private IReadOnlyList<string> folderPhotoOrder = [];

    private void ForgetSelectionRange()
    {
        workspaceSelection.ForgetRange();
        folderPhotoOrder = [];
    }

    private void WorkspacePhotoOpened()
    {
        if (browsedFolder is not { } folder) return;
        folderPhotoOrder = folder.Photos.Select(photo => photo.Path).ToArray();
        RefreshPhotoMarks();
    }

    private void RefreshPhotoMarks()
    {
        if (browsedFolder is { } folder)
            foreach (var photo in folder.Photos)
            {
                photo.IsSelected = StringComparer.OrdinalIgnoreCase.Equals(photo.Path, file);
                photo.IsMarked = workspaceSelection.Marks.Contains(photo.Path);
            }
        RefreshSelectionCount();
    }

    private void RefreshSelectionCount()
    {
        var count = workspaceSelection.Marks.Count;
        SelectionActions.Visibility = count == 0 ? Visibility.Collapsed : Visibility.Visible;
        SelectionActions.IsEnabled = !CollectionBusy;
        WorkspaceSelectionCount.Text = Loc.Format("已选 {0} 张", count);
    }

    private void PhotoSelected(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: LibraryEntry entry } || exporting || closing || UpdateInstallationActive) return;
        if (workspaceLayout.Mode == WorkspaceMode.Selection)
        {
            workspaceSelection.Toggle(entry.Path, folderPhotoOrder, (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
            RefreshPhotoMarks();
        }
        else OpenFile(entry.Path, entry.Thumbnail);
    }

    private void PhotoTilePressed(object sender, MouseButtonEventArgs e)
    {
        if (workspaceLayout.Mode != WorkspaceMode.Selection || e.ClickCount != 2 ||
            sender is not Button { DataContext: LibraryEntry entry } || exporting || closing || UpdateInstallationActive) return;
        e.Handled = true;
        workspaceSelection.BeforeOpening(entry.Path);
        RefreshPhotoMarks();
        OpenFile(entry.Path, entry.Thumbnail);
    }

    private void OpenLibraryPhotoClicked(object sender, RoutedEventArgs e)
    {
        if (ResolveContextEntry(sender) is { IsFolder: false } photo) OpenFile(photo.Path, photo.Thumbnail);
    }

    private void ClearWorkspaceSelectionClicked(object sender, RoutedEventArgs e)
    {
        workspaceSelection.Clear();
        RefreshPhotoMarks();
    }

    private void AddWorkspaceSelectionClicked(object sender, RoutedEventArgs e)
    {
        if (CollectionBusy || workspaceSelection.Marks.Count == 0 || !CommitCollectionInputs() ||
            !ResolveTransformDraft() || !SaveEdits()) return;
        AddCollectionPhotos(workspaceSelection.Marks);
        var accepted = Collection.Photos.Where(photo => workspaceSelection.Marks.Contains(photo.Path) &&
            !Collection.Failures.ContainsKey(photo.ID)).ToArray();
        foreach (var photo in accepted) Collection.Select(photo.ID, true);
        workspaceSelection.Remove(accepted.Select(photo => photo.Path));
        RefreshPhotoMarks();
        Collection.ReturnToCollection();
        ShowCollection();
    }
}
