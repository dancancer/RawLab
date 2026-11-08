using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private LibraryEntry? browsedFolder;
    private long browseRevision;
    private bool readingFolder;
    private Exception? folderError;
    private bool revealingFolder;
    private Gallery[] galleries = [];

    internal sealed record WorkspacePhotoRow(IReadOnlyList<LibraryEntry> Photos, int Columns, double RowHeight);
    private sealed class Gallery(ListBox view, bool contactSheet)
    {
        internal ListBox View { get; } = view;
        internal bool ContactSheet { get; } = contactSheet;
        internal Dictionary<string, string> Anchors { get; } = new(StringComparer.OrdinalIgnoreCase);
        internal IReadOnlyList<LibraryEntry> Photos = [];
        internal int Columns;
        internal bool Restoring;
        internal double RowHeight => ContactSheet ? 144 : 108;
    }

    private void InitializeWorkspaceBrowser()
    {
        galleries = [new(SidebarGallery, false), new(SelectionGallery, true)];
        Files.ItemsSource = library.Roots;
        Files.PreviewKeyDown += FilesContextKeyDown;
        library.Roots.CollectionChanged += (_, _) => ReconcileFolders();
        LibraryBody.SizeChanged += (_, _) => SizeFolderTree();
        Files.AddHandler(TreeViewItem.CollapsedEvent, new RoutedEventHandler((_, _) => RefreshCollapseButton()));
        foreach (var gallery in galleries)
        {
            gallery.View.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) => {
                if (e.VerticalChange != 0) RememberGalleryAnchor(gallery, e.VerticalOffset);
                QueueThumbnailRefresh();
            }));
            gallery.View.SizeChanged += (_, _) => RefreshGallery(gallery);
            gallery.View.IsVisibleChanged += (_, _) => {
                if (gallery.View.IsVisible) RestoreGalleryAnchor(gallery);
                QueueThumbnailRefresh();
            };
        }
        ReconcileFolders();
    }

    private void RefreshWorkspaceBrowserLayout()
    {
        if (galleries.Length == 0) return;
        var selecting = workspaceLayout.Mode == WorkspaceMode.Selection;
        var headingHost = selecting ? SelectionHeadingHost : SidebarHeadingHost;
        if (headingHost.Child == null)
        {
            (selecting ? SidebarHeadingHost : SelectionHeadingHost).Child = null;
            headingHost.Child = BrowserHeading;
        }
        SidebarPhotos.Visibility = selecting ? Visibility.Collapsed : Visibility.Visible;
        FolderTreeRow.Height = selecting ? new(1, GridUnitType.Star) : GridLength.Auto;
        SizeFolderTree();
        RefreshFolderHeading();
        QueueThumbnailRefresh();
    }

    private void SizeFolderTree() => Files.MaxHeight = workspaceLayout.Mode == WorkspaceMode.Selection
        ? double.PositiveInfinity : Math.Min(220, LibraryBody.ActualHeight * .34);

    private void ReconcileFolders()
    {
        var folder = browsedFolder;
        while (folder?.Parent is { } parent && !parent.Folders.Contains(folder)) folder = parent;
        if (folder != null)
        {
            var root = folder;
            while (root.Parent is { } parent) root = parent;
            if (!library.Roots.Contains(root)) folder = null;
        }
        _ = BrowseFolder(folder ?? library.Roots.FirstOrDefault());
        RefreshCollapseButton();
    }

    private async Task BrowseFolder(LibraryEntry? folder, bool reload = false)
    {
        if (closing || (ReferenceEquals(folder, browsedFolder) && !reload)) return;
        var revision = ++browseRevision;
        browsedFolder = folder;
        ForgetSelectionRange();
        readingFolder = folder != null;
        folderError = null;
        RefreshFolderHeading();
        foreach (var gallery in galleries) RefreshGallery(gallery);
        try
        {
            if (folder != null)
            {
                if (reload) await folder.Reload();
                else await folder.Load();
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (revision == browseRevision) folderError = error;
        }
        if (closing || revision != browseRevision) return;
        readingFolder = false;
        RefreshFolderHeading();
        WorkspacePhotoOpened();
        foreach (var gallery in galleries) RefreshGallery(gallery);
    }

    private void RefreshFolderHeading()
    {
        var folder = browsedFolder;
        var notice = readingFolder ? Loc.Text("正在读取目录…") : folderError != null ?
            Loc.Format("无法读取目录：{0}", folderError.Message) :
            folder != null && folder.Photos.Count == 0 ? Loc.Text("无照片") : "";
        SidebarGalleryNotice.Text = SelectionGalleryNotice.Text = notice;
        SelectionAddDirectory.Visibility = folder == null ? Visibility.Visible : Visibility.Collapsed;
        RetryFolderButton.Visibility = folderError == null ? Visibility.Collapsed : Visibility.Visible;
        BrowserHeading.Visibility = folder == null ? Visibility.Collapsed : Visibility.Visible;
        FolderPhotoCount.Text = folder == null || readingFolder || folderError != null
            ? "" : Loc.Format("{0} 张照片", folder.Photos.Count);
        FolderBreadcrumb.Text = folder?.Parent is { } parent ? parent.Name + " / " + folder.Name : folder?.Name ?? "";
        FolderBreadcrumb.ToolTip = folder?.Path;
        UpFolderButton.IsEnabled = folder?.Parent != null;
        RevealFolderButton.IsEnabled = folder != null;
        RefreshSelectionCount();
    }

    private void RefreshGallery(Gallery gallery)
    {
        var photos = !readingFolder && folderError == null && browsedFolder is { } folder ? folder.Photos : [];
        var columns = gallery.ContactSheet ? Math.Max(1, (int)((gallery.View.ActualWidth - 22) / 145)) : 2;
        if (ReferenceEquals(photos, gallery.Photos) && columns == gallery.Columns) return;
        gallery.Photos = photos;
        gallery.Columns = columns;
        gallery.Restoring = true;
        gallery.View.ItemsSource = photos.Chunk(columns)
            .Select(row => new WorkspacePhotoRow(row, columns, gallery.RowHeight)).ToArray();
        RestoreGalleryAnchor(gallery);
    }

    private void RememberGalleryAnchor(Gallery gallery, double offset)
    {
        if (gallery.Restoring || !gallery.View.IsVisible || browsedFolder == null || gallery.Photos.Count == 0) return;
        var index = Math.Clamp((int)(offset / gallery.RowHeight) * gallery.Columns, 0, gallery.Photos.Count - 1);
        gallery.Anchors[browsedFolder.Path] = gallery.Photos[index].Path;
    }

    private void RestoreGalleryAnchor(Gallery gallery)
    {
        var items = gallery.View.ItemsSource;
        var folder = browsedFolder;
        gallery.Restoring = true;
        Dispatcher.InvokeAsync(() => {
            if (closing || folder != browsedFolder || !ReferenceEquals(items, gallery.View.ItemsSource)) return;
            if (gallery.View.IsVisible && Descendant<ScrollViewer>(gallery.View) is { } scroll)
            {
                var index = 0;
                if (folder != null && gallery.Anchors.TryGetValue(folder.Path, out var anchor))
                    while (index < gallery.Photos.Count && !StringComparer.OrdinalIgnoreCase.Equals(gallery.Photos[index].Path, anchor)) index++;
                var offset = index < gallery.Photos.Count ? index / gallery.Columns * gallery.RowHeight : 0;
                if (scroll.VerticalOffset != offset)
                {
                    scroll.ScrollToVerticalOffset(offset);
                    scroll.UpdateLayout();
                }
            }
            gallery.Restoring = false;
            QueueThumbnailRefresh();
        }, DispatcherPriority.Loaded);
    }

    private static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T target) return target;
            if (Descendant<T>(child) is { } nested) return nested;
        }
        return null;
    }

    private async void FolderExpanded(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not TreeViewItem { DataContext: LibraryEntry { IsFolder: true } entry }) return;
        RefreshCollapseButton();
        try { await entry.Load(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            if (entry != browsedFolder) SetStatus(() => Loc.Format("无法读取目录：{0}", error.Message), true);
        }
    }

    private void FolderSelected(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (revealingFolder || e.NewValue is not LibraryEntry { IsFolder: true } folder) return;
        // TreeView selects the collapsed ancestor when it hides the selected child.
        for (var parent = (e.OldValue as LibraryEntry)?.Parent; parent != null; parent = parent.Parent)
            if (parent == folder && !folder.IsExpanded) return;
        _ = BrowseFolder(folder);
    }

    private async void BrowseFolderClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button { DataContext: LibraryEntry { IsFolder: true } folder })
        {
            if (FindParent<TreeViewItem>((Button)sender) is { } item) item.IsSelected = true;
            await BrowseFolder(folder);
        }
    }

    private void CollapseFoldersClicked(object sender, RoutedEventArgs e)
    {
        revealingFolder = true;
        try { foreach (var folder in FolderNodes(library.Roots)) folder.IsExpanded = false; }
        finally { revealingFolder = false; }
        Descendant<ScrollViewer>(Files)?.ScrollToTop();
        RefreshCollapseButton();
    }

    private void RefreshCollapseButton() =>
        CollapseFoldersButton.IsEnabled = FolderNodes(library.Roots).Any(folder => folder.IsExpanded);

    private static IEnumerable<LibraryEntry> FolderNodes(IEnumerable<LibraryEntry> roots)
    {
        foreach (var folder in roots)
        {
            if (!folder.IsFolder) continue;
            yield return folder;
            foreach (var child in FolderNodes(folder.Folders)) yield return child;
        }
    }

    private async void UpFolderClicked(object sender, RoutedEventArgs e)
    {
        if (browsedFolder?.Parent is { } parent)
        {
            await BrowseFolder(parent);
            if (parent == browsedFolder && LibraryPanel.IsVisible) RevealBrowsedFolder();
        }
    }

    private async void RetryFolderClicked(object sender, RoutedEventArgs e) => await BrowseFolder(browsedFolder, reload: true);

    private void RevealFolderClicked(object sender, RoutedEventArgs e)
    {
        if (!LibraryPanel.IsVisible) LibraryToggle(sender, e);
        RevealBrowsedFolder();
    }

    private void RevealBrowsedFolder()
    {
        if (browsedFolder == null) return;
        var path = new Stack<LibraryEntry>();
        for (var entry = browsedFolder; entry != null; entry = entry.Parent) path.Push(entry);
        revealingFolder = true;
        try
        {
            ItemsControl host = Files;
            while (path.TryPop(out var entry))
            {
                host.ApplyTemplate();
                host.UpdateLayout();
                if (host.ItemContainerGenerator.ContainerFromItem(entry) == null &&
                    Descendant<ItemsPresenter>(host) is { } presenter &&
                    Descendant<VirtualizingPanel>(presenter) is { } panel)
                {
                    var index = host.Items.IndexOf(entry);
                    if (index >= 0) panel.BringIndexIntoViewPublic(index);
                }
                if (host.ItemContainerGenerator.ContainerFromItem(entry) is not TreeViewItem item) break;
                item.BringIntoView();
                if (path.Count == 0) item.IsSelected = true;
                else { item.IsExpanded = true; host = item; }
            }
        }
        finally { revealingFolder = false; }
        RefreshCollapseButton();
    }

    private void QueueThumbnailRefresh()
    {
        if (closing) return;
        thumbnailRefresh.Stop();
        thumbnailRefresh.Start();
    }

    private void ThumbnailLoaded(object sender, RoutedEventArgs e) => QueueThumbnailRefresh();
    private void ThumbnailUnloaded(object sender, RoutedEventArgs e) => QueueThumbnailRefresh();

    internal void RefreshVisibleThumbnails()
    {
        var visible = new HashSet<LibraryEntry>();
        foreach (var gallery in galleries)
        {
            if (!gallery.View.IsVisible || Descendant<ScrollContentPresenter>(gallery.View) is not { } viewport) continue;
            var clip = new Rect(viewport.RenderSize);
            Visit(viewport, viewport, clip);
        }
        foreach (var entry in visibleThumbnails.Except(visible)) entry.ReleaseThumbnail();
        foreach (var entry in visible.Except(visibleThumbnails)) _ = entry.LoadThumbnail();
        visibleThumbnails.Clear();
        visibleThumbnails.UnionWith(visible);

        void Visit(DependencyObject node, FrameworkElement viewport, Rect clip)
        {
            if (node is Image { DataContext: LibraryEntry entry } image &&
                VisualTreeHelper.GetParent(image) is FrameworkElement tile && tile.RenderSize.Width > 0 &&
                clip.IntersectsWith(tile.TransformToAncestor(viewport).TransformBounds(new Rect(tile.RenderSize))))
                visible.Add(entry);
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
                Visit(VisualTreeHelper.GetChild(node, i), viewport, clip);
        }
    }
}
