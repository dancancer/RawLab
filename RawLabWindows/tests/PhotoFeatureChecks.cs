using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Automation;
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

    internal static object? Field(object value, string name) => value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(value);
    private static void SetField(object value, string name, object? data) => value.GetType()
        .GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(value, data);
    internal static void Click(ButtonBase button) => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
    internal static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
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
        var extension = Path.GetExtension(fixture);
        var source = Path.Combine(targets, "source" + extension); File.Copy(fixture, source);
        var target = Path.Combine(targets, "target" + extension); File.Copy(fixture, target);
        var second = Path.Combine(targets, "second" + extension); File.Copy(fixture, second);
        var excluded = Path.Combine(nested, "excluded" + extension); File.Copy(fixture, excluded);
        File.WriteAllText(Path.Combine(targets, "ignored.txt"), "not a photo");
        var rasterTarget = Path.Combine(targets, "ordinary.png");
        var bitmap=BitmapSource.Create(8,6,96,96,PixelFormats.Bgr24,null,Enumerable.Repeat((byte)120,8*6*3).ToArray(),8*3);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var stream=File.Create(rasterTarget))encoder.Save(stream);
        var hashes = new[] { source, target, second, rasterTarget, excluded }.ToDictionary(path => path, path => SHA256.HashData(File.ReadAllBytes(path)));
        Console.WriteLine("ExifTool: " + ExportMetadata.VerifyAvailable());
        var info = PhotoInfoReader.Read(source);
        Check(!string.IsNullOrWhiteSpace(info?.Camera) && !string.IsNullOrWhiteSpace(info?.Shutter),
            "Production ExifTool reads actual RAW camera and shutter");
        Check(info!.DisplayWidth > 0 && info.DisplayHeight > 0 && info.CaptureTime != null,
            "Production ExifTool reports oriented source dimensions and capture time");
        // 固定镜头 RAW 可以没有 LensModel；用已知 EXIF 的副本保留镜头读取的集成检查。
        var metadataSource = Path.Combine(output, "metadata.png"); File.Copy(rasterTarget, metadataSource);
        ExportMetadata.Run(["-overwrite_original", "-EXIF:Make=RawLab", "-EXIF:Model=Fixture camera",
            "-EXIF:LensMake=RawLab", "-EXIF:LensModel=Fixture lens", "-EXIF:ExposureTime=1/125", metadataSource]);
        var metadata = PhotoInfoReader.Read(metadataSource);
        Check(metadata is { Camera: "RawLab Fixture camera", Lens: "RawLab Fixture lens", Shutter: "1/125" },
            "Production ExifTool reads exact camera, lens and shutter from controlled EXIF");

        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow { Width = 1200, Height = 800 };
        TestWindowState.Isolate(window,output);
        var store = new EditStore(Path.Combine(output, "edits")); SetField(window, "editStore", store);
        window.GpuMode.SelectedIndex = 1;
        window.Show();
        try
        {
            var invalidRaw=Path.Combine(output,"invalid.ARW");File.WriteAllText(invalidRaw,"not a RAW file");
            var frozen=new Adjustments();frozen.Set(Parameter.Exposure,.37);
            var preflightJob=BatchJob.Create(source,frozen.Capture(),null,"Neutral");
            var preflightJournal=new BatchJournal(Path.Combine(output,"preflight-journal"));
            var preflightWindow=new BatchExportWindow(preflightJob,preflightJournal){Owner=window};preflightWindow.Show();
            var busyEvents=new List<bool>();preflightWindow.BusyChanged+=busyEvents.Add;
            var validation=preflightWindow.AddInputs([invalidRaw,target]);
            Check(preflightWindow.Busy && !preflightWindow.PrimaryAction.IsEnabled && !preflightWindow.SelectionActions.IsEnabled,
                "RAW preflight locks export and selection until validation finishes");
            InteractionChecks.PumpUntil(()=>validation.IsCompleted);validation.GetAwaiter().GetResult();
            Check(preflightJob.SelectedCount==1 && preflightJob.Items.Single(item=>item.Input==target).CanSelect,
                "RAW preflight accepts a decodable target");
            Check(busyEvents.SequenceEqual(new[]{true,false}),"RAW preflight reports its full busy lifetime to the main-window gate");
            Check(preflightJob.Items.Single(item=>item.Input==invalidRaw) is {CanSelect:false,Selected:false,ValidationError:not null},
                "RAW preflight retains a failed target as unselectable with an error");
            preflightWindow.GetType().GetMethod("SelectAll",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(preflightWindow,[true]);
            Check(!preflightJob.Items.Single(item=>item.Input==invalidRaw).Selected && preflightJob.Settings.SameAs(frozen.Capture()),
                "Select-all cannot bypass RAW validation or mutate frozen settings");
            preflightWindow.Close();
            Check(preflightWindow.Discarded && preflightJournal.Load()==null,"Closing an unstarted batch discards its draft journal");

            var closingJob=BatchJob.Create(source,frozen.Capture(),null,"Neutral");
            var closingJournal=new BatchJournal(Path.Combine(output,"closing-preflight-journal"));
            var closingWindow=new BatchExportWindow(closingJob,closingJournal){Owner=window};closingWindow.Show();
            closingJournal.Save(closingJob);
            using(var journalLock=new FileStream(Path.Combine(closingJournal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
            {
                var closingValidation=closingWindow.AddInputs([target]);closingWindow.Close();
                InteractionChecks.PumpUntil(()=>closingValidation.IsCompleted);closingValidation.GetAwaiter().GetResult();
                Check(closingWindow.IsVisible && closingWindow.CloseFailed && !closingWindow.Discarded && closingWindow.Job.Error!=null,
                    "A failed journal cleanup keeps the batch visible for retry after validation");
            }
            closingWindow.Close();
            Check(!closingWindow.IsVisible && closingWindow.Discarded && closingJournal.Load()==null,
                "Close during RAW validation waits for native work and does not recreate a discarded journal");

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
            window.ExportPhoto(ExportFormat.Png,source).GetAwaiter().GetResult();
            Check(window.Status.Text==Loc.Text("不能覆盖原始文件。"),"RAW export uses the dedicated original-file protection message");
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
            Check(window.InfoFileText.Text.Contains(Path.GetFileName(source)) && window.InfoFileText.Text.Contains(info.CaptureTime!), "Real WPF file overlay uses source metadata");
            Click(window.InfoButton);
            Check(window.InfoCaptureText.Text == info.CaptureLine, "Real WPF capture overlay shows the actual capture metadata");
            Screenshot(window, Path.Combine(output, "info.png"));
            window.LibraryColumn.Width = new GridLength(288); window.UpdateLayout();
            Check(window.InfoOverlay.ActualWidth + 28 <= window.EditorArea.ActualWidth + 1, "Info overlay stays within the photo column");
            Click(window.InfoButton); Check(window.InfoOverlay.Visibility == Visibility.Collapsed, "WPF info action cycles back to hidden");
            window.OpenFile(target); window.OpenFile(source);
            Click(window.InfoButton);
            InteractionChecks.PumpUntil(() => window.InfoFileText.Text.Contains(Path.GetFileName(source)));
            Check(!window.InfoFileText.Text.Contains(Path.GetFileName(target)), "Rapid photo switches never publish the previous file metadata");
            ToolGroupChecks.RunAssertions(window, output, Check);
            Click(Descendants<Button>(window.PhotoEffectsEditor).Single(button =>
                AutomationProperties.GetName(button) == "重置当前效果"));
            InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
            Check(((Adjustments)Field(window, "settings")!).Effects.VignetteAmount == 0,
                "Current effect reset clears the vignette edited by the tool-group checks");
            Click(window.FilmCategory);
            var films = (Dictionary<string, Button>)Field(window, "filmButtons")!;
            Click(films.First(pair => File.Exists(pair.Key) && StringComparer.OrdinalIgnoreCase.Equals(
                Path.GetDirectoryName(pair.Key), Path.Combine(AppContext.BaseDirectory, "LUTs"))).Value);
            InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
            var current = ((Adjustments)Field(window, "settings")!).Capture();
            var currentLook = window.CurrentLookIdentity();
            Check(currentLook != null && current.CameraWhiteBalance && current.MasterRecipeID == null,
                "Folder fixture has a real look and camera white balance compatible with RAW and raster targets");
            Check((bool)window.GetType().GetMethod("SaveEdits", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, null)!,
                "Folder fixture saves the source before copying adjustments");
            var sourceState = store.ReadState(source);
            var directTargets = new[] { target, second, rasterTarget };
            var targetGeometry = new GeometrySettings(FlipHorizontal: true);
            foreach (var path in directTargets)
                store.Save(path, new Adjustments { Geometry = targetGeometry, ExposureMode = PhotoInput.IsRaw(path) ? 1 : 2 }.Capture(), null);
            var folder = new LibraryEntry(targets, true);
            var library = (Library)Field(window, "library")!;
            library.Roots.Add(folder);
            if (!window.LibraryPanel.IsVisible) Click(window.LibraryToggleButton);
            InteractionChecks.PumpUntil(() => Descendants<Button>(window.SidebarGallery).Any(button => button.DataContext is LibraryEntry entry && entry.Path == target));
            var tile = Descendants<Button>(window.SidebarGallery).Single(button => button.DataContext is LibraryEntry entry && entry.Path == target);
            var root = (TreeViewItem)window.Files.ItemContainerGenerator.ContainerFromItem(folder);
            OpenContext(window, tile);
            Check(tile.ContextMenu!.IsOpen && tile.ContextMenu.Items.OfType<MenuItem>().Count() == 3, "Photo right-click opens the native photo context actions");
            Check((string?)Field(window, "file") == source, "Photo right-click preserves current settings source");
            tile.ContextMenu.IsOpen = false;
            OpenContext(window, root);
            Check(window.FileTreeContextMenu.IsOpen && window.ApplyTreeEntryMenu.IsEnabled, "Folder context menu offers enabled apply-current-settings action");
            window.FileTreeContextMenu.IsOpen = false;
            ApplyFolderSettings(window, directTargets);
            var expected = AdjustmentTransferValues.Values(new(sourceState.Identity, current, currentLook), new(source, true));
            foreach (var path in directTargets)
            {
                var saved = store.Find(path);
                Check(saved != null, "Confirmed folder action saves the direct child: " + Path.GetFileName(path));
                var raster = PhotoInput.IsRaster(path);
                var actual = AdjustmentTransferValues.Values(saved!, new(path, !raster));
                // Standard 不包含几何；普通图片的曝光基准和白平衡按目标能力归一化。
                var matches = AdjustmentFields.Common.All(field => AdjustmentPayload.Same(actual[field],
                    raster && field == AdjustmentField.ExposureMode ? AdjustmentPayload.Value("sensor") :
                    raster && field == AdjustmentField.WhiteBalanceMode ? AdjustmentPayload.Value("none") : expected[field]));
                Check(matches && saved!.Settings.Geometry == targetGeometry,
                    "Folder action copies Standard fields and preserves target geometry: " + Path.GetFileName(path));
            }
            Check(store.Find(excluded) == null && store.ReadState(source).SameAs(sourceState) &&
                  ((Adjustments)Field(window, "settings")!).Capture().SameAs(current) && (string?)Field(window, "file") == source,
                "Folder action excludes nested files and never changes the source photo");
            Check(directTargets.All(path => store.Find(path)?.Look == currentLook), "Apply-current-settings also copies the current look identity");
            Screenshot(window, Path.Combine(output, "context.png"));
            if (Process.GetCurrentProcess().SessionId != 0)
            {
                dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!)!;
                dynamic? explorer = null;
                try
                {
                    OpenContext(window, tile);
                    var openItem = tile.ContextMenu!.Items.OfType<MenuItem>()
                        .Single(item => Equals(item.Header, Loc.Text("在资源管理器中打开")));
                    var resolved = (LibraryEntry?)window.GetType().GetMethod("ResolveContextEntry", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, [openItem]);
                    Check(resolved?.Path == target, "Explorer menu resolves the clicked photo rather than the previous folder");
                    Console.WriteLine("Explorer action header=" + openItem.Header + "; placement=" + ((LibraryEntry)((FrameworkElement)tile.ContextMenu.PlacementTarget).DataContext).Path);
                    window.Dispatcher.Invoke(() => {
                        Console.WriteLine("Explorer handler context=" + SynchronizationContext.Current?.GetType().Name);
                        openItem.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
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
            var rasterGuard=Path.Combine(output,"overwrite-raster.png");
            File.Copy(rasterTarget,rasterGuard);
            window.OpenFile(rasterGuard);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            window.ExportPhoto(ExportFormat.Png,rasterGuard).GetAwaiter().GetResult();
            Check(window.Status.Text==Loc.Text("不能覆盖原始文件。"),"Raster export uses the same original-file protection message");
            window.OpenFile(source);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
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
        (target is Button ? target : window.Files).RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Right) {
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

    internal static void Screenshot(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render((Visual)window.Content);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path); encoder.Save(stream);
    }

    private static void ApplyFolderSettings(MainWindow window, string[] targets)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        var clock = Stopwatch.StartNew();
        Exception? failure = null;
        AdjustmentResultDialog? dialog = null;
        var completed = false;
        timer.Tick += (_, _) => {
            try
            {
                if (clock.Elapsed > TimeSpan.FromSeconds(90)) throw new TimeoutException("Folder adjustment results did not appear within 90s");
                dialog = Application.Current.Windows.OfType<AdjustmentResultDialog>().SingleOrDefault(candidate => candidate.IsVisible && candidate.Owner == window);
                if (dialog == null) return;
                timer.Stop(); dialog.UpdateLayout();
                T Find<T>(string id) where T : DependencyObject => Descendants<T>(dialog).Single(control => AutomationProperties.GetAutomationId(control) == id);
                var summary = Find<TextBlock>("adjustment.results.summary");
                Check(summary.Text.EndsWith(Loc.Format("已预检 {0} 张照片。确认后保存所选调整。", targets.Length), StringComparison.Ordinal),
                    "Folder adjustment preflight reports exactly three targets");
                Check(Descendants<TextBlock>(dialog).Where(text => text.ToolTip is string path && targets.Contains(path)).Count() == targets.Length,
                    "Folder preflight lists only the direct RAW and raster targets");
                var apply = Find<Button>("adjustment.results.apply");
                Check(apply.IsEnabled, "Folder adjustment preflight enables Apply");
                Click(apply);
                Check(summary.Text.EndsWith(Loc.Format("已保存 {0} 张 · 未变化 {1} 张 · 已跳过 {2} 张 · 已撤销 {3} 张 · 未完成 {4} 张", targets.Length, 0, 0, 0, 0), StringComparison.Ordinal),
                    "Folder adjustment results report three saved photos");
                Click(Find<Button>("adjustment.results.close"));
                completed = !dialog.IsVisible;
            }
            catch (Exception error)
            {
                failure = error; timer.Stop();
                foreach (var visible in Application.Current.Windows.OfType<AdjustmentResultDialog>().Where(candidate => candidate.Owner == window).ToArray()) visible.Close();
            }
        };
        timer.Start();
        try
        {
            window.ApplyTreeEntryMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            InteractionChecks.PumpUntil(() => completed || failure != null);
            if (failure != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
            Check(completed, "Folder adjustment results close after applying");
        }
        finally { timer.Stop(); if (dialog?.IsVisible == true) dialog.Close(); }
    }
}
