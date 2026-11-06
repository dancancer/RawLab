using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class WorkspaceLookChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(MainWindow window,string name)=>(T)typeof(MainWindow).GetField(name,Private)!.GetValue(window)!;
    private static void Set(MainWindow window,string name,object value)=>typeof(MainWindow).GetField(name,Private)!.SetValue(window,value);
    private static object? Invoke(MainWindow window,string name,params object[] args)=>typeof(MainWindow).GetMethod(name,Private)!.Invoke(window,args);
    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var output=Path.Combine(Path.GetFullPath(repo),".cache","tmp","workspace-looks",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);var source=Path.Combine(output,"source.dng");File.Copy(raw,source);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow();TestWindowState.Isolate(window,output);
        var storePath=Path.Combine(output,"edits");var store=new EditStore(storePath);Set(window,"editStore",store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(source);Ready(window);
            foreach(var language in new[]{"en","de"}) {
                Loc.SetPreference(language,Path.Combine(output,"language.txt"));foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                var surface=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
                Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);window.UpdateLayout();
                check(!window.LibraryPanel.IsVisible && Math.Abs(window.AdjustmentPanel.ActualWidth - 280) < 1,
                    "A narrow window opens a 280 DIP inspector with the library drawer initially closed: " + language);
                var canvas = window.PhotoArea.RenderSize;
                check(canvas.Width >= 700 && canvas.Height >= 500 &&
                    window.AdjustmentPanel.TranslatePoint(new Point(), window.WorkspaceBody).X >= canvas.Width - 1,
                    "The inspector keeps the preview's full workspace height: " + language);
                check(window.HistogramPanel.Parent == window.HistogramHost && window.Histogram.IsVisible,
                    "The adjustment inspector hosts the visible histogram");
                Click(window.HistogramInlineButton);
                check(!window.Histogram.IsVisible, "Inline histogram collapses independently of the inspector");
                Click(window.HistogramInlineButton);
                Click(window.AdjustToggleButton); window.UpdateLayout();
                check(!window.AdjustmentPanel.IsVisible && window.HistogramPanel.Parent == window.HistogramPopupContent,
                    "Hiding the inspector keeps the histogram available from the toolbar");
                if (language == "en") {
                    Click(window.HistogramButton); window.UpdateLayout();
                    check(window.HistogramPopup.IsOpen, "The toolbar opens the histogram popup");
                }
                window.HistogramPopup.IsOpen = false;
                Click(window.AdjustToggleButton);
                var row = window.OrdinaryParameter;
                var rail = row.Slider.TransformToAncestor(row).TransformBounds(new Rect(row.Slider.RenderSize));
                var field = row.Number.TransformToAncestor(row).TransformBounds(new Rect(row.Number.RenderSize));
                check(rail.Top >= field.Bottom && rail.Width >= row.ActualWidth - 2 && rail.Width >= 220,
                    "Narrow Exposure puts a full-width slider below its numeric field: " + language);
                EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,"exposure-"+language+".png"));
            }
            EditorShellChecks.ArrangeLayout(window, new Size(1440, 920));
            var modes = new[] { window.EditingWorkspaceButton, window.SelectionWorkspaceButton, window.PreviewWorkspaceButton };
            check(modes.All(WorkspaceModeGapIsClickable), "The space between the icon and text belongs to each workspace button");
            var layout = Get<WorkspaceLayout>(window, "workspaceLayout");
            layout.ResizeInspector(334);
            Invoke(window, "RefreshWorkspace");
            Invoke(window, "SelectTool", EditorAdjustmentTool.Hsl); window.UpdateLayout();
            check(Math.Abs(window.AdjustmentPanel.ActualWidth - 334) < 1, "Inspector width survives a tool change");
            Click(window.SelectionWorkspaceButton); window.UpdateLayout();
            check(window.SelectionWorkspace.IsVisible && !window.PhotoArea.IsVisible && !window.AdjustmentPanel.IsVisible &&
                window.LibraryPanel.IsVisible && !window.ExportPng.IsEnabled, "Select keeps folders and fills the center with the contact sheet");
            Click(window.PreviewWorkspaceButton); window.UpdateLayout();
            check(window.PhotoArea.IsVisible && !window.LibraryPanel.IsVisible && !window.AdjustmentPanel.IsVisible,
                "Preview uses the whole photo area");
            Invoke(window, "DismissWorkspaceTransient"); window.UpdateLayout();
            check(window.SelectionWorkspace.IsVisible, "Escape returns from Preview to Select");
            Click(window.EditingWorkspaceButton);
            EditorShellChecks.ArrangeLayout(window, new Size(1024, 720));
            var previewSize = window.PhotoArea.RenderSize;
            Click(window.LibraryToggleButton); window.UpdateLayout();
            check(window.LibraryOverlay.IsVisible && window.LibraryPanel.Parent == window.LibraryDrawer &&
                window.PhotoArea.RenderSize == previewSize, "Compact library overlays the preview without resizing it");
            Invoke(window, "DismissWorkspaceTransient"); window.UpdateLayout();
            check(!window.LibraryOverlay.IsVisible && Math.Abs(window.AdjustmentPanel.ActualWidth - 280) < 1,
                "Escape closes the drawer and retains the narrow inspector");
            Invoke(window, "SelectTool", EditorAdjustmentTool.Geometry);
            window.GeometryEditor.ShowPerspective = true;
            Click(window.PreviewWorkspaceButton);
            check(!window.DraftActions.IsVisible, "Preview ends the clean geometry draft");
            Invoke(window, "DismissWorkspaceTransient");
            window.UpdateLayout();
            check(window.GeometrySurface.IsVisible && window.GeometryEditor.ShowPerspective && window.DraftActions.IsVisible,
                "Returning to Edit restores the geometry subtool and fixed draft actions");
            Click(window.CancelDraftButton);
            CheckNarrowControls(window, output, check);
            CheckFolderWorkspace(window, output, check);
            Invoke(window,"SelectTool",EditorAdjustmentTool.Film);window.UpdateLayout();
            var edits=Get<Adjustments>(window,"settings");edits.Set(Parameter.Exposure,.1);Invoke(window,"MarkEdited");
            var acros=Path.Combine(AppContext.BaseDirectory,"LUTs","FLog2_to_ACROS_65grid_V.1.00.cube");
            check(File.Exists(acros),"Native test uses bundled ACROS asset");
            window.LookSearch.Text="acros";window.UpdateLayout();
            var choices=Get<Dictionary<string,Button>>(window,"filmButtons");
            check(choices.Count==1 && choices.ContainsKey(acros),"Case-insensitive search narrows the live native list");
            using(var held=new FileStream(Path.Combine(storePath,"edits.json"),FileMode.Open,FileAccess.Read,FileShare.Read)) {
                choices[acros].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                check(Get<RecentLooks>(window,"recentLooks").IDs.Count==0 && window.RetrySave.IsVisible,"Failed look save is excluded from Recent");
            }
            Invoke(window,"SaveEdits");Ready(window);
            var recent=Get<RecentLooks>(window,"recentLooks");
            check(recent.IDs.SequenceEqual(new[]{"builtin:"+Path.GetFileName(acros)}),"Successful retry records the stable built-in identity once");
            var saved=store.VersionedState(source);window.LookSearch.Text="no matching look";window.UpdateLayout();
            check(window.LookEmpty.IsVisible && window.LookImport.IsVisible && window.LookImport.IsEnabled && store.VersionedState(source).SameAs(saved),
                "Empty search retains the committed look and fixed import action");
            window.LookEmptyAction.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.LookCategory.SelectedIndex=(int)LookBrowserCategory.Recent;window.UpdateLayout();
            check(Get<Dictionary<string,Button>>(window,"filmButtons").Keys.SequenceEqual(new[]{acros}),"Recent filters only the successfully saved look");
            Invoke(window,"LoadRecentLooks");check(Get<RecentLooks>(window,"recentLooks").IDs.SequenceEqual(recent.IDs),"Recent preferences survive reload independently of photo data");
            var final=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
            check(window.LookImport.TransformToAncestor(window).Transform(new Point(window.LookImport.ActualWidth,window.LookImport.ActualHeight)).X<=window.ActualWidth,
                "Fixed import action stays inside narrow native window");
            EditorShellChecks.CaptureLayout(window,final,Path.Combine(output,"recent-de.png"));
            Invoke(window,"SelectTool",EditorAdjustmentTool.MasterRecipe);window.UpdateLayout();
            var recipes=Get<Dictionary<string,Button>>(window,"recipeButtons");
            recipes.Values.Last().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            check(Get<Dictionary<string,TextBlock>>(window,"recipeSelectionMarkers").Values.Count(marker=>marker.Visibility==Visibility.Visible)==1,
                "Applied recipe has one visible non-color selection mark");
            var recipeSurface=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
            EditorShellChecks.CaptureLayout(window,recipeSurface,Path.Combine(output,"recipe-selected-de.png"));
            var lens=new LensPanel();
            lens.Refresh(new LensSettings(Distortion:true),new LensInfo(6,"","",false,false,1,[new("fixture","Fixture","24mm",false,false,true)]));
            var distortion=(CheckBox)lens.FindName("Distortion");var tca=(CheckBox)lens.FindName("Tca");
            check(distortion.IsEnabled && !tca.IsEnabled && !string.IsNullOrEmpty(System.Windows.Automation.AutomationProperties.GetHelpText(tca)),
                "Unavailable lens calibration explains why while retained correction can be disabled");
            distortion.IsChecked=false;check(!distortion.IsEnabled,"Turning off a retained unavailable correction prevents re-enabling it");
            Console.WriteLine("Workspace artifacts: "+output);
        } finally {window.Close();app.Shutdown();}
    }
    private static bool WorkspaceModeGapIsClickable(Button button)
    {
        var content = (StackPanel)button.Content;
        var icon = (FrameworkElement)content.Children[0];
        var title = (TextBlock)content.Children[1];
        var gapStart = icon.TranslatePoint(new Point(icon.ActualWidth, 0), button).X;
        var gapEnd = title.TranslatePoint(new Point(), button).X;
        var hit = button.InputHitTest(new Point((gapStart + gapEnd) / 2, button.ActualHeight / 2));
        return hit is Visual visual && (visual == button || visual.IsDescendantOf(button));
    }

    private static void CheckNarrowControls(MainWindow window, string output, Action<bool,string> check)
    {
        Invoke(window, "SelectTool", EditorAdjustmentTool.Hsl);
        window.UpdateLayout();
        var swatches = PhotoFeatureChecks.Descendants<Button>(window.HslEditor)
            .Where(button => AutomationProperties.GetAutomationId(button).StartsWith("hsl.channel.")).ToArray();
        var bounds = swatches.Select(button => button.TransformToAncestor(window.HslEditor)
            .TransformBounds(new Rect(button.RenderSize))).ToArray();
        check(bounds.Length == 8 && bounds.All(rect => rect.Left >= 0 && rect.Right <= window.HslEditor.ActualWidth + 1 &&
            Math.Abs(rect.Top - bounds[0].Top) < 1), "All eight HSL colors fit on one row in a 280 DIP inspector");
        window.HslEditor.SelectChannel(0);
        Press(swatches[0], Key.Left);
        check(window.HslEditor.SelectedChannel == 7, "HSL keyboard navigation wraps from the first color to the last");
        Press(swatches[7], Key.Right);
        check(window.HslEditor.SelectedChannel == 0, "HSL keyboard navigation wraps from the last color to the first");
        EditorShellChecks.CaptureLayout(window, (FrameworkElement)window.Content, Path.Combine(output, "hsl-narrow.png"));

        Invoke(window, "SelectTool", EditorAdjustmentTool.Denoise);
        var panel = window.DenoiseEditor;
        var toggle = (FrameworkElement)panel.FindName("EnabledBox");
        var preset = (ComboBox)panel.FindName("PresetBox");
        ((Expander)panel.FindName("Details")).IsExpanded = true;
        preset.SelectedIndex = 1;
        window.UpdateLayout();
        var switchBounds = toggle.TransformToAncestor(panel).TransformBounds(new Rect(toggle.RenderSize));
        var presetBounds = preset.TransformToAncestor(panel).TransformBounds(new Rect(preset.RenderSize));
        check(presetBounds.Top > switchBounds.Bottom && presetBounds.Right <= panel.ActualWidth + 1,
            "The translated denoise preset fits on a separate line");
        var sliders = PhotoFeatureChecks.Descendants<ParameterRow>(panel).Where(row => row.IsVisible).ToArray();
        check(sliders.Length == 3 && sliders.All(row => row.Slider.ActualWidth >= row.ActualWidth - 2),
            "All three denoise sliders use the full narrow content width");
        EditorShellChecks.CaptureLayout(window, EditorShellChecks.ArrangeLayout(window, new Size(1024, 720)), Path.Combine(output, "denoise-narrow.png"));
    }

    private static void Press(Button button, Key key)
    {
        var source = PresentationSource.FromVisual(button)!;
        button.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) {
            RoutedEvent = Keyboard.PreviewKeyDownEvent
        });
    }

    private static void CheckFolderWorkspace(MainWindow window, string output, Action<bool, string> check)
    {
        var rootPath = Path.Combine(output, "library");
        var nestedPath = Path.Combine(rootPath, "nested");
        Directory.CreateDirectory(nestedPath);
        var image = Png(16, 12);
        Array.Resize(ref image, image.Length + 256);
        for (var i = 0; i < 180; i++) File.WriteAllBytes(Path.Combine(rootPath, $"image-{i:D3}.png"), image);
        File.WriteAllBytes(Path.Combine(nestedPath, "another.png"), image);
        var library = Get<Library>(window, "library");
        var root = new LibraryEntry(rootPath, true);
        library.Roots.Add(root);
        InteractionChecks.PumpUntil(() => root.Photos.Count == 180);
        check(root.Folders.Count == 1 && root.Folders[0].IsFolder,
            "A folder with 180 photos adds only its subdirectory to the tree");
        Click(window.LibraryToggleButton);
        window.UpdateLayout();
        check(window.LibraryOverlay.IsVisible && window.SidebarGallery.IsVisible, "The compact drawer exposes the photo list");
        Click(window.RevealFolderButton);
        window.UpdateLayout();
        root.IsExpanded = true;
        var browse = (Task)Invoke(window, "BrowseFolder", root.Folders[0], false)!;
        InteractionChecks.PumpUntil(() => browse.IsCompleted);
        var activePhoto = Get<string>(window, "file");
        Click(window.CollapseFoldersButton);
        check(!root.IsExpanded && window.FolderBreadcrumb.Text.EndsWith("nested", StringComparison.Ordinal) &&
            Get<string>(window, "file") == activePhoto, "Collapse all preserves the browsed folder and the current photo");
        Click(window.UpFolderButton);
        InteractionChecks.PumpUntil(() => window.FolderPhotoCount.Text == Loc.Format("{0} 张照片", 180));
        check(Get<string>(window, "file") == activePhoto, "Navigating up repopulates only the thumbnail list");
        var rows = window.SidebarGallery.Items.OfType<MainWindow.WorkspacePhotoRow>().ToArray();
        check(rows.Length == 90 && rows.All(row => row.Columns == 2 && row.Photos.Count == 2),
            "The separate sidebar photo viewport keeps two equal columns");
        FlushGalleryLayout();
        var scroller = PhotoFeatureChecks.Descendants<ScrollViewer>(window.SidebarGallery).First();
        scroller.ScrollToVerticalOffset(2592);
        FlushGalleryLayout();
        var before = scroller.VerticalOffset;
        check(before > 2500, $"The gallery scrolls by pixels through its virtual rows ({before}/{scroller.ExtentHeight}, viewport {scroller.ViewportHeight})");
        var enter = (Task)Invoke(window, "BrowseFolder", root.Folders[0], false)!;
        InteractionChecks.PumpUntil(() => enter.IsCompleted);
        Click(window.UpFolderButton);
        FlushGalleryLayout();
        check(Math.Abs(scroller.VerticalOffset - before) < 1,
            $"Returning to the folder restores the thumbnail scroll position ({before} -> {scroller.VerticalOffset})");
        var anchoredPhoto = rows[24].Photos[0];
        var neighbor = rows[24].Photos[1];
        InteractionChecks.PumpUntil(() => anchoredPhoto.Thumbnail != null && neighbor.Thumbnail != null);
        check(root.Photos.Count(entry => entry.Thumbnail != null) < root.Photos.Count,
            "The browser decodes thumbnails for the visible gallery without loading the whole folder");
        var unchangedThumbnail = neighbor.Thumbnail;
        var beforeReplacement = OriginalIdentity.Read(anchoredPhoto.Path);
        var replacement = Png(32, 12);
        Array.Resize(ref replacement, image.Length);
        var incoming = Path.Combine(rootPath, "incoming.tmp");
        File.WriteAllBytes(incoming, replacement);
        File.Move(incoming, anchoredPhoto.Path, overwrite: true);
        File.SetLastWriteTimeUtc(anchoredPhoto.Path, new DateTime(beforeReplacement.Modified, DateTimeKind.Utc));
        File.SetCreationTimeUtc(anchoredPhoto.Path, new DateTime(beforeReplacement.Created, DateTimeKind.Utc));
        var afterReplacement = OriginalIdentity.Read(anchoredPhoto.Path);
        check(beforeReplacement.Length == afterReplacement.Length && beforeReplacement.Modified == afterReplacement.Modified &&
            beforeReplacement.Created == afterReplacement.Created && beforeReplacement.FileID != afterReplacement.FileID,
            "The replacement keeps its name, length and timestamps but has a different file ID");
        var refreshTimer = Get<DispatcherTimer>(window, "thumbnailRefresh");
        var refreshInterval = refreshTimer.Interval;
        // Complete the reload before the debounce can observe the temporarily empty gallery.
        refreshTimer.Interval = TimeSpan.FromSeconds(10);
        try
        {
            var reload = (Task)Invoke(window, "BrowseFolder", root, true)!;
            InteractionChecks.PumpUntil(() => reload.IsCompleted);
            reload.GetAwaiter().GetResult();
            FlushGalleryLayout();
            window.RefreshVisibleThumbnails();
            var refreshed = root.Photos.Single(entry => entry.Path == anchoredPhoto.Path);
            InteractionChecks.PumpUntil(() => refreshed.Thumbnail != null);
            check(refreshed.Thumbnail?.PixelWidth == 32,
                "Reload refreshes the visible thumbnail for a same-path replacement");
            check(root.Photos.Contains(neighbor) && ReferenceEquals(neighbor.Thumbnail, unchangedThumbnail),
                "Reload preserves an unchanged visible thumbnail");
            anchoredPhoto = refreshed;
        }
        finally
        {
            refreshTimer.Stop();
            refreshTimer.Interval = refreshInterval;
        }
        var tile = PhotoFeatureChecks.Descendants<Button>(window.SidebarGallery).First(button => button.DataContext == anchoredPhoto);
        tile.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Right) {
            RoutedEvent = UIElement.PreviewMouseRightButtonDownEvent
        });
        var menu = tile.ContextMenu!;
        check(menu.IsOpen && menu.PlacementTarget == tile &&
            Get<string>(window, "file") == activePhoto, "Photo right-click opens its context menu and leaves the current photo unchanged");
        menu.IsOpen = false;
        Click(window.LibraryToggleButton);
        Click(window.SelectionWorkspaceButton);
        FlushGalleryLayout();
        check(window.SelectionGallery.Items.OfType<MainWindow.WorkspacePhotoRow>().First().Columns >= 3,
            "The contact sheet adds columns when it uses the center of the window");
        var photo = PhotoFeatureChecks.Descendants<Button>(window.SelectionGallery)
            .First(button => button.DataContext is LibraryEntry);
        Click(photo);
        check(window.SelectionActions.IsVisible && window.WorkspaceSelectionCount.Text == Loc.Format("已选 {0} 张", 1) &&
            Get<string>(window, "file") == activePhoto, "Clicking a contact sheet photo marks it without changing the current photo");
        Click(window.EditingWorkspaceButton);
        FlushGalleryLayout();

        void FlushGalleryLayout()
        {
            window.UpdateLayout();
            window.Dispatcher.Invoke(() => { }, DispatcherPriority.Background);
            window.UpdateLayout();
        }

        static byte[] Png(int width, int height)
        {
            var pixels = Enumerable.Repeat((byte)120, width * height * 3).ToArray();
            var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Rgb24, null, pixels, width * 3);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var fixture = new MemoryStream();
            encoder.Save(fixture);
            return fixture.ToArray();
        }
    }
}
