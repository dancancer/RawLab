using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class PhotoFeatureChecks
{
    private static int checks;
    private static void Check(bool value, string name)
    {
        if (!value) throw new Exception(name);
        Console.WriteLine("PASS " + name); checks++;
    }

    private static object? Field(object value, string name) => value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(value);
    private static void SetField(object value, string name, object? data) => value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(value, data);
    private static void Click(ButtonBase button) => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T item) yield return item;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }

    internal static void Run(string repo, string fixture)
    {
        repo = Path.GetFullPath(repo);
        fixture = Path.GetFullPath(fixture);
        var output = Path.Combine(repo, "build", "photo-feature-verification", DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(output);
        var targets = Path.Combine(output, "targets"); Directory.CreateDirectory(targets);
        var nested = Path.Combine(targets, "nested"); Directory.CreateDirectory(nested);
        var source = Path.Combine(output, "source.ARW"); File.Copy(fixture, source);
        var target = Path.Combine(targets, "target.ARW"); File.Copy(fixture, target);
        var second = Path.Combine(targets, "second.ARW"); File.Copy(fixture, second);
        var excluded = Path.Combine(nested, "excluded.ARW"); File.Copy(fixture, excluded);
        File.WriteAllText(Path.Combine(targets, "ignored.jpg"), "not RAW");
        var hashes = new[] { source, target, second, excluded }.ToDictionary(path => path, path => SHA256.HashData(File.ReadAllBytes(path)));
        var info = PhotoInfoReader.Read(source);
        Check(info?.Camera?.Contains("SONY", StringComparison.OrdinalIgnoreCase) == true && info.Lens != null && info.Shutter != null,
            "Production ExifTool reads actual RAW camera, lens and shutter");
        Check(info!.DisplayWidth > 0 && info.DisplayHeight > 0 && info.CaptureTime != null,
            "Production ExifTool reports oriented source dimensions and capture time");

        var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow { Width = 1200, Height = 800 };
        var store = new EditStore(Path.Combine(output, "edits")); SetField(window, "editStore", store);
        window.GpuMode.SelectedIndex = 1;
        window.Show();
        try
        {
            var job = BatchJob.Create(source, new Adjustments().Capture(), null, "Neutral");
            job.OutputDirectory = output; job.Items = [BatchItem.Create(target) with { Selected = true }];
            var journal = new BatchJournal(Path.Combine(output, "journal"));
            var batch = new BatchExportWindow(job, journal) { Owner = window };
            batch.Show();
            batch.SizeSelection.SelectedIndex = 4;
            batch.CustomLongEdge.Text = "100000";
            Check(!batch.PrimaryAction.IsEnabled, "Invalid custom batch size disables export before focus leaves the field");
            batch.Png.IsChecked = true;
            Check(batch.CustomLongEdge.Text == "100000" && batch.SizeSelection.SelectedIndex == 4 && !batch.PrimaryAction.IsEnabled,
                "Changing output format does not discard or accept an invalid custom size");
            batch.Jpeg.IsChecked = true;
            batch.CustomLongEdge.Text = "512";
            Click(batch.PrimaryAction);
            InteractionChecks.PumpUntil(() => !batch.Running && batch.Job.Started);
            Check(batch.Job.SucceededCount == 1 && batch.Job.LongEdge == 512, "Batch button commits the current custom size and exports it");
            Check(journal.Load()?.LongEdge == 512, "Actual batch journal preserves chosen long edge");
            CheckImage(batch.Job.Items.Single().Output!, 512, info.CaptureTime!, false);
            batch.Close();

            window.OpenFile(source); InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
            window.ExportSize2048.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            Check((int?)Field(window, "exportLongEdge") == 2048 && window.ExportSize2048.IsChecked, "Single export preset updates the real menu state");
            window.ExportOriginalSize.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            Check(Field(window, "exportLongEdge") == null && window.ExportOriginalSize.IsChecked, "Single export can return to original dimensions");
            var custom = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
            custom.Tick += (_, _) => {
                var dialog = app.Windows.OfType<Window>().FirstOrDefault(candidate => candidate.Title == "自定义导出尺寸");
                if (dialog == null) return;
                var field = Descendants<TextBox>(dialog).Single();
                var accept = Descendants<Button>(dialog).Single(button => button.Content?.ToString() == "确定");
                field.Text = "100000"; Click(accept);
                Check(dialog.IsVisible && Descendants<TextBlock>(dialog).Any(text => text.Text.Contains("1 到 65535")), "Single custom size rejects an out-of-range value without closing");
                field.Text = "512"; custom.Stop(); Click(accept);
            };
            custom.Start(); window.ExportCustomSize.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); custom.Stop();
            Check((int?)Field(window, "exportLongEdge") == 512 && window.ExportCustomSize.IsChecked, "Single custom dialog commits a valid pixel size");
            Click(window.InfoButton);
            InteractionChecks.PumpUntil(() => window.InfoOverlay.Visibility == Visibility.Visible);
            Check(window.InfoFileText.Text.Contains("source.ARW") && window.InfoFileText.Text.Contains(info.CaptureTime!), "Real WPF file overlay uses source metadata");
            Click(window.InfoButton);
            Check(window.InfoCaptureText.Text.Contains("SONY", StringComparison.OrdinalIgnoreCase), "Real WPF capture overlay shows camera metadata");
            Screenshot(window, Path.Combine(output, "info.png"));
            window.LibraryColumn.Width = new GridLength(520); window.UpdateLayout();
            Check(window.InfoOverlay.ActualWidth + 268 <= window.EditorArea.ActualWidth + 1, "Info overlay reserves histogram space at wide file-tree width");
            Click(window.InfoButton); Check(window.InfoOverlay.Visibility == Visibility.Collapsed, "WPF info action cycles back to hidden");
            window.OpenFile(target); window.OpenFile(source);
            Click(window.InfoButton);
            InteractionChecks.PumpUntil(() => window.InfoFileText.Text.Contains("source.ARW"));
            Check(!window.InfoFileText.Text.Contains("target.ARW"), "Rapid photo switches never publish the previous file metadata");
            window.ValueSlider.Value = .625; InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
            var current = ((Adjustments)Field(window, "settings")!).Capture();
            var folder = new LibraryEntry(targets, true);
            window.Files.ItemsSource = new[] { folder };
            var loading = folder.Load(); InteractionChecks.PumpUntil(() => loading.IsCompleted); loading.GetAwaiter().GetResult();
            window.UpdateLayout();
            var root = (TreeViewItem)window.Files.ItemContainerGenerator.ContainerFromIndex(0);
            root.IsExpanded = true; window.UpdateLayout();
            InteractionChecks.PumpUntil(() => Descendants<Button>(window.Files).Any(button => button.DataContext is LibraryEntry entry && entry.Path == target));
            var tile = Descendants<Button>(window.Files).Single(button => button.DataContext is LibraryEntry entry && entry.Path == target);
            OpenContext(window, tile);
            Check(tile.ContextMenu!.IsOpen && tile.ContextMenu.Items.OfType<MenuItem>().Count() == 2, "Photo right-click opens the two native context actions");
            Check((string?)Field(window, "file") == source, "Photo right-click preserves current settings source");
            tile.ContextMenu.IsOpen = false;
            OpenContext(window, root);
            Check(window.FileTreeContextMenu.IsOpen && window.ApplyTreeEntryMenu.IsEnabled, "Folder context menu offers enabled apply-current-settings action");
            window.FileTreeContextMenu.IsOpen = false;
            var confirmation = ConfirmApply(2);
            window.ApplyTreeEntryMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            InteractionChecks.PumpUntil(() => window.Status.Text.Contains("已应用当前设置到 2"));
            confirmation.Stop();
            Check(store.Find(target)?.Settings.SameAs(current) == true && store.Find(second)?.Settings.SameAs(current) == true,
                "Confirmed folder action writes current settings to direct RAW children");
            Check(store.Find(excluded) == null && (string?)Field(window, "file") == source,
                "Folder action excludes nested files and never changes the source photo");
            Check(store.Find(target)?.Look == window.CurrentLookIdentity(), "Apply-current-settings also copies the current look identity");
            Screenshot(window, Path.Combine(output, "context.png"));
            if (Process.GetCurrentProcess().SessionId != 0)
            {
                dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!)!;
                dynamic? explorer = null;
                try
                {
                    OpenContext(window, tile);
                    var openItem = tile.ContextMenu!.Items.OfType<MenuItem>().First();
                    var resolved = (LibraryEntry?)window.GetType().GetMethod("ResolveContextEntry", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, [openItem]);
                    Check(resolved?.Path == target, "Explorer menu resolves the clicked photo rather than the previous folder");
                    Console.WriteLine("Explorer action header=" + tile.ContextMenu!.Items.OfType<MenuItem>().First().Header + "; placement=" + ((LibraryEntry)((FrameworkElement)tile.ContextMenu.PlacementTarget).DataContext).Path);
                    window.Dispatcher.Invoke(() => {
                        Console.WriteLine("Explorer handler context=" + SynchronizationContext.Current?.GetType().Name);
                        tile.ContextMenu!.Items.OfType<MenuItem>().First().RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                    });
                    tile.ContextMenu.IsOpen = false;
                    Console.WriteLine($"Explorer probe session={Process.GetCurrentProcess().SessionId}, target={target}, status={window.Status.Text}");
                    var seenExplorer = new HashSet<string>();
                    DateTime? selectionSince = null;
                    InteractionChecks.PumpUntil(() => {
                        foreach (dynamic candidate in shell.Windows())
                        {
                            try
                            {
                                string candidatePath = candidate.Document.Folder.Self.Path;
                                if (seenExplorer.Add(candidatePath)) Console.WriteLine("Explorer window: " + candidatePath);
                                if (!StringComparer.OrdinalIgnoreCase.Equals(candidatePath, targets)) continue;
                                if (candidate.Document.Folder.ParseName(Path.GetFileName(target)) == null) continue;
                                dynamic selected = candidate.Document.SelectedItems();
                                int count = selected.Count;
                                string? selectedPath = count == 1 ? (string)selected.Item(0).Path : null;
                                string selection = $"{candidatePath}: count={count}, selected={selectedPath}";
                                if (seenExplorer.Add(selection)) Console.WriteLine("Explorer selection " + selection);
                                if (count != 1 || !StringComparer.OrdinalIgnoreCase.Equals(selectedPath, target)) { selectionSince = null; continue; }
                                selectionSince ??= DateTime.UtcNow;
                                if (DateTime.UtcNow - selectionSince.Value < TimeSpan.FromMilliseconds(500)) continue;
                                explorer = candidate; return true;
                            }
                            catch (COMException error) { if (seenExplorer.Add(error.Message)) Console.WriteLine("Explorer COM: " + error.Message); }
                        }
                        return false;
                    });
                    Check(explorer != null, "Photo context action opens Explorer and selects exactly the clicked file on the logged-in desktop");
                    var nestedFolder = new LibraryEntry(nested, true);
                    window.Files.ItemsSource = new[] { nestedFolder }; window.UpdateLayout();
                    var nestedItem = (TreeViewItem)window.Files.ItemContainerGenerator.ContainerFromIndex(0);
                    OpenContext(window, nestedItem);
                    window.OpenTreeEntryMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                    window.FileTreeContextMenu.IsOpen = false;
                    dynamic? openedFolder = null;
                    InteractionChecks.PumpUntil(() => {
                        foreach (dynamic candidate in shell.Windows())
                            try { if (StringComparer.OrdinalIgnoreCase.Equals((string)candidate.Document.Folder.Self.Path, nested)) { openedFolder = candidate; return true; } }
                            catch (COMException) { }
                        return false;
                    });
                    Check(openedFolder != null, "Folder context action opens its own directory rather than the photo parent");
                    openedFolder!.Quit();
                }
                finally { if (explorer != null) explorer.Quit(); }
            }
            else Console.WriteLine("NOT REACHED Explorer desktop interaction: process is in session 0");

            using var engine = new RenderEngine(0);
            foreach (var png in new[] { false, true })
            {
                var destination = Path.Combine(output, png ? "limited.png" : "limited.jpg");
                engine.Render(source, current.Restore(), null, 0, output: destination, longEdge: 2048);
                CheckImage(destination, 2048, info.CaptureTime!, png);
            }
            var native = engine.Render(source, current.Restore(), null, 0)!;
            var large = Path.Combine(output, "no-enlargement.jpg");
            engine.Render(source, current.Restore(), null, 0, output: large, longEdge: 65535);
            var largeImage = ReadImage(large);
            Check(largeImage.PixelWidth == native.Image.PixelWidth && largeImage.PixelHeight == native.Image.PixelHeight,
                "Windows actual RAW export never enlarges smaller sources");
            foreach (var path in hashes.Keys) Check(hashes[path].SequenceEqual(SHA256.HashData(File.ReadAllBytes(path))), "RAW byte identity preserved: " + Path.GetFileName(path));
            Console.WriteLine($"PASS {checks} photo feature checks; artifacts: {output}");
        }
        finally { window.Close(); app.Shutdown(); }
    }

    private static void OpenContext(MainWindow window, FrameworkElement target)
    {
        window.Files.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Right) {
            RoutedEvent = UIElement.PreviewMouseRightButtonDownEvent, Source = target
        });
    }

    private static BitmapFrame ReadImage(string path)
    {
        using var stream = File.OpenRead(path);
        return BitmapFrame.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
    }

    private static void CheckImage(string path, int edge, string capture, bool png)
    {
        var image = ReadImage(path);
        Check(Math.Max(image.PixelWidth, image.PixelHeight) == edge, "Actual encoded output honors long-edge cap: " + Path.GetFileName(path));
        var tags = PhotoInfoReader.Read(path)!;
        Check(tags.CaptureTime == capture && tags.DisplayWidth == image.PixelWidth && tags.DisplayHeight == image.PixelHeight,
            "Sized output keeps capture EXIF and updates dimensions: " + Path.GetFileName(path));
        if (png) Check(File.ReadAllBytes(path)[24] == 16, "Sized PNG retains sixteen-bit channels");
    }

    private static void Screenshot(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render((Visual)window.Content);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path); encoder.Save(stream);
    }

    private static DispatcherTimer ConfirmApply(int count)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) => {
            var dialog = IntPtr.Zero;
            EnumWindows((candidate, _) => {
                GetWindowThreadProcessId(candidate, out var pid);
                var title = new StringBuilder(1024); GetWindowText(candidate, title, title.Capacity);
                if (pid == Environment.ProcessId && title.ToString() == "应用当前设置") { dialog = candidate; return false; }
                return true;
            }, IntPtr.Zero);
            if (dialog == IntPtr.Zero) return;
            var text = new StringBuilder();
            EnumChildWindows(dialog, (child, _) => { var part = new StringBuilder(1024); GetWindowText(child, part, part.Capacity); text.Append(part); return true; }, IntPtr.Zero);
            var valid = text.ToString().Contains($"{count} 张照片");
            SendMessage(GetDlgItem(dialog, valid ? 6 : 7), 0x00F5, IntPtr.Zero, IntPtr.Zero);
            timer.Stop();
            Check(valid, "Native confirmation shows the actual target count");
        };
        timer.Start(); return timer;
    }

    private delegate bool EnumWindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr window, EnumWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr window, int item);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
