using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace RawLab.Windows;

internal partial class LUTPhotoLibraryPicker : Window
{
    internal string? SelectedPhoto { get; private set; }
    private readonly HashSet<LibraryEntry> visiblePhotos = [];
    private bool closed;

    internal LUTPhotoLibraryPicker(Window owner, IReadOnlyList<string> folders)
    {
        InitializeComponent(); Owner = owner; Title = Loc.Text("从照片库选择");
        // 独立目录节点拥有自己的展开、选择和缩略图状态，不改主窗口照片库。
        Photos.ItemsSource = folders.Select(path => new LibraryEntry(path, true) { IsExpanded = true }).ToArray();
        if (folders.Count == 0) Notice.Text = Loc.Text("照片库为空，请先在主窗口添加照片目录。");
        Closed += (_, _) => {
            closed = true;
            foreach (var entry in visiblePhotos) entry.ReleaseThumbnail();
            visiblePhotos.Clear();
        };
    }

    private async void FolderExpanded(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not TreeViewItem { DataContext: LibraryEntry entry } || !entry.IsFolder) return;
        try { await entry.Load(); if (!closed) Notice.Text = entry.Children.Count == 0 ? Loc.Text("无照片") : ""; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) {
            if (!closed) Notice.Text = error.Message;
        }
    }
    private void PhotoSelected(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        SelectedPhoto = e.NewValue is LibraryEntry { IsFolder: false } entry && LibraryEntry.IsImage(entry.Path) ? entry.Path : null;
        Confirm.IsEnabled = SelectedPhoto != null;
    }
    private async void ThumbnailLoaded(object sender, RoutedEventArgs e)
    {
        if (closed || sender is not Image { DataContext: LibraryEntry { IsFolder: false } entry }) return;
        visiblePhotos.Add(entry); await entry.LoadThumbnail();
    }
    private void ThumbnailUnloaded(object sender, RoutedEventArgs e)
    {
        if (sender is Image { DataContext: LibraryEntry entry }) { entry.ReleaseThumbnail(); visiblePhotos.Remove(entry); }
    }
    private void ConfirmClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedPhoto != null) DialogResult = true;
    }
}
