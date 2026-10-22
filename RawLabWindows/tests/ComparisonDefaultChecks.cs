using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class ComparisonDefaultChecks
{
    private static readonly BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    internal static void Run(string repo, string raw, Action<bool, string> check)
    {
        check(GpuSelection(null)==1 && GpuSelection("Cpu")==1 && GpuSelection("Auto")==0 && GpuSelection("Force")==2,
            "Native acceptance GPU selection defaults to CPU and maps explicit modes");
        var rejectedMode=false;
        try{GpuSelection("gpu");}catch(ArgumentException){rejectedMode=true;}
        check(rejectedMode,"Native acceptance rejects an unknown GPU mode");
        repo = Path.GetFullPath(repo);
        raw = Path.GetFullPath(raw);
        var output = Path.Combine(repo, "build", "comparison-default", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);

        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow { Width = 1200, Height = 800 };
        TestWindowState.Isolate(window, output);
        UseProfile(window, Path.Combine(output, "profile"));
        window.GpuMode.SelectedIndex = 1;
        check(IsMode(window,"off"),"An unloaded new window also starts in single mode");
        window.Show();
        try
        {
            check(IsMode(window, "off"),
                "A new editor window starts in single comparison mode");

            var fixtures = PrepareFixtures(raw, output);
            var folder = new LibraryEntry(output, true);
            var loading = folder.Load();
            PumpUntil(() => loading.IsCompleted, TimeSpan.FromSeconds(30));
            loading.GetAwaiter().GetResult();
            var entries = folder.Children.Where(entry => !entry.IsFolder).ToArray();
            check(entries.Any(entry => LibraryEntry.IsRaw(entry.Path)) &&
                  entries.Count(entry => LibraryEntry.IsRaster(entry.Path)) == 2 &&
                  entries.All(entry => LibraryEntry.IsImage(entry.Path)),
                "File tree classifies RAW, PNG and JPEG as supported images");
            foreach (var entry in entries)
            {
                var thumbnail = entry.LoadThumbnail();
                PumpUntil(() => thumbnail.IsCompleted, TimeSpan.FromSeconds(30));
                thumbnail.GetAwaiter().GetResult();
                check(entry.Thumbnail != null, "File tree loads a thumbnail: " + Path.GetFileName(entry.Path));
            }
            foreach (var path in new[] { fixtures.Png, fixtures.Jpeg })
            {
                var info = PhotoInfoReader.Read(path);
                check(info?.FileName == Path.GetFileName(path),
                    "Photo info reads the generated raster: " + Path.GetFileName(path));
            }

            WaitBusyThenReady(window, () => window.OpenFile(raw));
            check(IsMode(window, "off"), "Opening RAW keeps the default single mode");
            var initialSettings = (Adjustments)typeof(MainWindow).GetField("settings", Private)!.GetValue(window)!;
            check(window.ActiveFilm.Text == Loc.Text("中性") && window.CurrentLookIdentity() == null && initialSettings.MasterRecipeID == null &&
                  initialSettings[Parameter.Exposure] == 0,
                "An unseen RAW opens with neutral settings and no film or master recipe");

            window.SetComparisonMode(true, false);
            window.UpdateLayout();
            check(IsMode(window, "side"),
                "Same-image side-by-side mode is reachable through the real window");
            WaitReady(window);
            WaitBusyThenReady(window, () => window.ValueSlider.Value = .625);
            check(IsMode(window, "side"),
                "Async exposure publish preserves side-by-side mode");

            window.SetComparisonMode(true, true);
            window.UpdateLayout();
            check(IsMode(window, "swipe"),
                "Same-image swipe mode exposes the comparison canvas");
            WaitReady(window);
            WaitBusyThenReady(window, () =>
            {
                window.ResultCanvas.Divider = .35;
                window.ValueSlider.Value = .75;
            });
            check(IsMode(window, "swipe"),
                "Async exposure publish preserves swipe mode and divider support");

            WaitBusyThenReady(window, () => {window.GpuMode.SelectedIndex=2;window.OpenFile(fixtures.Png);});
            check(IsMode(window, "off") &&
                  window.LensCategory.IsEnabled == false && window.ExposureMode.IsEnabled == false &&
                  window.AsShotButton.IsEnabled == false,
                "Raster switch resets comparison and disables RAW-only controls");
            var rasterSettings = (Adjustments)typeof(MainWindow).GetField("settings", Private)!.GetValue(window)!;
            check(window.ActiveFilm.Text == Loc.Text("中性") && window.CurrentLookIdentity() == null &&
                  rasterSettings.MasterRecipeID == null && rasterSettings[Parameter.Exposure] == 0,
                "An unseen raster opens without inheriting another photo's film or adjustments");
            check(window.GpuMode.SelectedIndex==1 && !window.GpuMode.IsEnabled,
                "Opening raster from RAW Force GPU visibly selects CPU rather than failing or pretending Force succeeded");
            WaitBusyThenReady(window, () => window.OpenFile(fixtures.Jpeg));
            check(IsMode(window, "off"),
                "JPEG switch resets comparison to single mode");

            WaitBusyThenReady(window,()=>Drop(window,fixtures.Png));
            check(CurrentFile()==fixtures.Png,"Root-window drop accepts an ordinary PNG through the real handler");
            WaitBusyThenReady(window,()=>window.ValueSlider.Value=.55);
            WaitBusyThenReady(window,()=>window.OpenFile(fixtures.Jpeg));
            WaitBusyThenReady(window,()=>Drop(window.Files,fixtures.Png));
            check(CurrentFile()==fixtures.Png && Math.Abs(window.ValueSlider.Value-.55)<.001,
                "File-tree drop reopens PNG and restores its own saved adjustment");
            window.BatchExportMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            var batch=(BatchExportWindow)typeof(MainWindow).GetField("batchWindow",Private)!.GetValue(window)!;
            check(batch!=null && ReferenceEquals(batch.Owner,window),"Raster batch menu invokes the real main-window owner wiring");
            check(batch!.SourceSummary.Text.Contains(Loc.Text("不适用")) && batch.SourceSummary.Text.Contains(Loc.Text("显示图像")),
                "Raster batch has no invented camera WB or sensor baseline labels");
            var adding=batch.AddInputs([raw,fixtures.Png,fixtures.Jpeg]);
            PumpUntil(()=>adding.IsCompleted,TimeSpan.FromMinutes(3));adding.GetAwaiter().GetResult();
            check(batch.Job.SelectedCount==3 && !batch.Busy,"Actual batch preflight accepts mixed RAW, PNG and JPEG targets");
            batch.Png.IsChecked=true;batch.Job.LongEdge=64;batch.Job.OutputDirectory=Path.Combine(output,"batch-output");
            Directory.CreateDirectory(batch.Job.OutputDirectory);
            typeof(BatchExportWindow).GetMethod("Refresh",Private)!.Invoke(batch,null);
            check(batch.PrimaryAction.IsEnabled,"Mixed batch actual primary action becomes available");
            batch.PrimaryAction.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            check(batch.Running,"Actual batch primary handler owns the running state");
            PumpUntil(()=>!batch.Running,TimeSpan.FromMinutes(3));
            check(batch.Job.SucceededCount==3 && batch.Job.Items.All(item=>item.Output!=null && File.Exists(item.Output)) &&
                !Directory.EnumerateFiles(batch.Job.OutputDirectory,".rawlab-*").Any(),
                "Actual mixed batch window exports all FINAL outputs without leftover staging");
            batch.Close();

            WaitBusyThenReady(window, () => {
                window.OpenFile(raw);
                check(window.GpuMode.SelectedIndex==2 && window.GpuMode.IsEnabled,"Returning to RAW restores its GPU choice");
                window.GpuMode.SelectedIndex=1;
            });
            check(IsMode(window, "off") && Math.Abs(window.ValueSlider.Value - .75) < .001,
                "Returning to RAW restores its saved exposure and single mode");
            WaitBusyThenReady(window, () => window.OpenFile(raw));
            check(IsMode(window, "off") && Math.Abs(window.ValueSlider.Value - .75) < .001,
                "Reopening the same RAW restores history without comparison state");
            window.Close();
            ViewComparisonChecks.Run(repo,raw,check,app);
        }
        finally
        {
            if (window.IsVisible) window.Close();
            app.Shutdown();
        }

        string? CurrentFile()=>(string?)typeof(MainWindow).GetField("file",Private)!.GetValue(window);
    }

    private static void Drop(UIElement target,string path)
    {
        var data=new DataObject(DataFormats.FileDrop,new[]{path});
        var args=(DragEventArgs)Activator.CreateInstance(typeof(DragEventArgs),BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic,
            null,[data,DragDropKeyStates.None,DragDropEffects.Copy,target,new Point()],null)!;
        args.RoutedEvent=UIElement.PreviewDropEvent;target.RaiseEvent(args);
        if(!args.Handled){args.RoutedEvent=UIElement.DropEvent;target.RaiseEvent(args);}
    }

    internal static int Host(string repo, string profile)
    {
        var gpuSelection=GpuSelection(Environment.GetEnvironmentVariable("RAWLAB_COMPARISON_GPU"));
        if(Process.GetCurrentProcess().SessionId==0 || !Environment.UserInteractive)
        {
            Console.WriteLine("NOT REACHED Native acceptance requires an interactive Windows session.");
            return 2;
        }
        repo = Path.GetFullPath(repo);
        profile = Path.GetFullPath(profile);
        Directory.CreateDirectory(profile);
        var raw = ResolveRaw(repo, profile);
        var fixtures = PrepareFixtures(raw, Path.Combine(profile, "fixtures"));
        var previousRaw = Environment.GetEnvironmentVariable("RAWLAB_COMPARISON_RAW");
        Environment.SetEnvironmentVariable("RAWLAB_COMPARISON_RAW", raw);
        try
        {
            if (string.Equals(Environment.GetEnvironmentVariable("RAWLAB_COMPARISON_UI_PHASE"), "restart",
                    StringComparison.OrdinalIgnoreCase))
                return RunHostedWindow(repo, profile, raw, fixtures, "restart",gpuSelection);

            var first = RunHostedWindow(repo, profile, raw, fixtures, "first",gpuSelection);
            if (first == 2 || first != 0) return first;
            return RunRestartHost(repo, profile);
        }
        finally { Environment.SetEnvironmentVariable("RAWLAB_COMPARISON_RAW", previousRaw); }
    }

    private static int RunRestartHost(string repo, string profile)
    {
        var assembly = typeof(ComparisonDefaultChecks).Assembly.Location;
        var processPath = Environment.ProcessPath ?? throw new InvalidOperationException("Cannot resolve test host process.");
        var start = new ProcessStartInfo { FileName = processPath, UseShellExecute = false };
        if (Path.GetFileNameWithoutExtension(processPath).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(assembly);
        start.ArgumentList.Add("--comparison-ui-host");
        start.ArgumentList.Add(repo);
        start.ArgumentList.Add(profile);
        start.Environment["RAWLAB_COMPARISON_UI_PHASE"] = "restart";
        using var child = Process.Start(start) ?? throw new InvalidOperationException("Cannot restart comparison host.");
        child.WaitForExit((int)TimeSpan.FromMinutes(10).TotalMilliseconds);
        if (!child.HasExited)
        {
            child.Kill(entireProcessTree: true);
            return 1;
        }
        return child.ExitCode;
    }

    private static int GpuSelection(string? mode)=>mode?.ToLowerInvariant() switch
    {
        null or "" or "cpu"=>1,
        "auto"=>0,
        "force"=>2,
        _=>throw new ArgumentException("RAWLAB_COMPARISON_GPU must be Cpu, Auto or Force.")
    };

    private static int RunHostedWindow(string repo, string profile, string raw, Fixtures fixtures, string phase,int gpuSelection)
    {
        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow { Width = 1200, Height = 800 };
        TestWindowState.Isolate(window, Path.Combine(profile, "window-state"));
        UseProfile(window, profile);
        window.GpuMode.SelectedIndex = gpuSelection;
        Process? driver = null;
        Task<string>? driverOutput = null, driverError = null;
        DispatcherTimer? timeoutTimer = null;
        var exit = 1;
        var completed = false;
        void Complete(int code)
        {
            if (completed) return;
            completed = true;
            exit = code;
            timeoutTimer?.Stop();
            if (window.IsVisible) window.Close();
            app.Shutdown();
        }
        void DriverExited(object? sender, EventArgs _)
        {
            var code = 1;
            try
            {
                if (sender is Process process) code = process.ExitCode;
            }
            catch { }
            try
            {
                app.Dispatcher.BeginInvoke(DispatcherPriority.Send, new Action(() => Complete(code)));
            }
            catch (InvalidOperationException) { }
        }
        try
        {
            window.Show();
            timeoutTimer = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMinutes(9)
            };
            timeoutTimer.Tick += (_, _) => Complete(1);
            timeoutTimer.Start();
            app.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
            {
                try
                {
                    driver = StartDriver(repo, profile, raw, fixtures, phase, Process.GetCurrentProcess().Id);
                    driverOutput = driver.StandardOutput.ReadToEndAsync();
                    driverError = driver.StandardError.ReadToEndAsync();
                    driver.Exited += DriverExited;
                    driver.EnableRaisingEvents = true;
                    if (driver.HasExited) DriverExited(driver, EventArgs.Empty);
                }
                catch
                {
                    Complete(1);
                }
            }));
            app.Run();
            if (driver is { HasExited: true })
            {
                Console.Write(driverOutput?.GetAwaiter().GetResult());
                Console.Error.Write(driverError?.GetAwaiter().GetResult());
            }
            if (!completed) exit = 1;
            return exit;
        }
        finally
        {
            timeoutTimer?.Stop();
            if (driver != null) driver.Exited -= DriverExited;
            try
            {
                if (driver is { HasExited: false }) driver.Kill(entireProcessTree: true);
            }
            catch { }
            if (window.IsVisible) window.Close();
            if (Application.Current == app) app.Shutdown();
            driver?.Dispose();
        }
    }

    private static Process StartDriver(string repo, string profile, string raw, Fixtures fixtures,
                                       string phase, int hostPid)
    {
        var driver = ResolveDriver(repo);
        var start = new ProcessStartInfo
        {
            FileName = driver.FileName,
            WorkingDirectory = Path.GetDirectoryName(driver.Assembly ?? driver.FileName)!,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        if (driver.Assembly != null) start.ArgumentList.Add(driver.Assembly);
        foreach (var value in new[] { hostPid.ToString(), profile, raw, fixtures.Png, fixtures.Jpeg, phase })
            start.ArgumentList.Add(value);
        var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start UIA driver.");
        return process;
    }

    private static DriverPath ResolveDriver(string repo)
    {
        var directory = Path.Combine(repo, "RawLabWindows", "tests", "ui-automation", "bin", "Release", "net8.0-windows");
        var exe = Path.Combine(directory, "RawLabWindows.UiAutomation.exe");
        if (File.Exists(exe)) return new(exe, null);
        var assembly = Path.Combine(directory, "RawLabWindows.UiAutomation.dll");
        if (File.Exists(assembly))
        {
            var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet";
            return new(dotnet, assembly);
        }
        throw new FileNotFoundException("Build the external UIA driver before --comparison-ui-host.", assembly);
    }

    private static string ResolveRaw(string repo, string profile)
    {
        var candidates = new[]
        {
            Environment.GetEnvironmentVariable("RAWLAB_COMPARISON_RAW"),
            Path.Combine(profile, "source.ARW"),
            Path.Combine(profile, "fixtures", "source.ARW"),
            Path.Combine(repo, "build", "windows-fixtures", "primary.ARW")
        }.Where(path => !string.IsNullOrWhiteSpace(path)).Select(path => Path.GetFullPath(path!));
        var raw = candidates.FirstOrDefault(File.Exists);
        if (raw == null) throw new FileNotFoundException("Supply RAWLAB_COMPARISON_RAW or profile/source.ARW for UIA host.");
        return raw;
    }

    private static void UseProfile(MainWindow window, string profile)
    {
        Directory.CreateDirectory(profile);
        typeof(MainWindow).GetField("editStore", Private)!.SetValue(window,
            new EditStore(Path.Combine(profile, "edits")));
        typeof(MainWindow).GetField("batchJournal", Private)!.SetValue(window,
            new BatchJournal(Path.Combine(profile, "batch")));
    }

    private static Fixtures PrepareFixtures(string raw, string directory)
    {
        Directory.CreateDirectory(directory);
        var png = Path.Combine(directory, "comparison.png");
        var jpeg = Path.Combine(directory, "comparison.jpg");
        using var engine = new RenderEngine(0);
        var rendered = engine.Render(raw, new Adjustments(), null, 256, statistics: false, clipping: false)
            ?? throw new InvalidOperationException("Cannot render raster fixture.");
        var rgb = new FormatConvertedBitmap(rendered.Image, PixelFormats.Bgr24, null, 0);
        rgb.Freeze();
        var pngEncoder = new PngBitmapEncoder();
        pngEncoder.Frames.Add(BitmapFrame.Create(rgb));
        using (var stream = File.Create(png)) pngEncoder.Save(stream);
        var jpegEncoder = new JpegBitmapEncoder { QualityLevel = 95 };
        jpegEncoder.Frames.Add(BitmapFrame.Create(rgb));
        using (var stream = File.Create(jpeg)) jpegEncoder.Save(stream);
        var source = Path.Combine(directory, "source.ARW");
        if (!Path.GetFullPath(raw).Equals(Path.GetFullPath(source), StringComparison.OrdinalIgnoreCase))
            File.Copy(raw, source, true);
        return new(png, jpeg);
    }

    private static string Mode(MainWindow window)
    {
        var status = AutomationProperties.GetItemStatus(window.CompareButton);
        if(status==Loc.Text("关闭对比"))return "off";
        if(status==Loc.Text("并排"))return "side";
        if(status==Loc.Text("分割线"))return "swipe";
        if (window.CompareOff.IsChecked == true) return "off";
        if (window.CompareSwipe.IsChecked == true) return "swipe";
        if (window.CompareSide.IsChecked == true) return "side";
        return "unknown";
    }

    private static bool IsMode(MainWindow window, string mode)
    {
        var off = mode == "off";
        var side = mode == "side";
        var swipe = mode == "swipe";
        var buttonTag = window.CompareButton.Tag as string;
        return Mode(window) == mode &&
               window.CompareOff.IsChecked == off &&
               window.CompareSide.IsChecked == side &&
               window.CompareSwipe.IsChecked == swipe &&
               window.MenuCompareOff.IsChecked == off &&
               window.MenuCompareSide.IsChecked == side &&
               window.MenuCompareSwipe.IsChecked == swipe &&
               string.Equals(buttonTag, off ? null : "selected", StringComparison.Ordinal) &&
               (window.NeutralCanvas.Visibility == Visibility.Visible) == side &&
               window.ResultCanvas.ComparisonEnabled == swipe;
    }

    private static void WaitReady(MainWindow window)
    {
        PumpUntil(() => window.ExportPng.IsEnabled, TimeSpan.FromMinutes(3));
    }

    private static void WaitBusyThenReady(MainWindow window, Action action)
    {
        var busy = !window.ExportPng.IsEnabled;
        DependencyPropertyChangedEventHandler handler = (_, _) =>
        {
            if (!window.ExportPng.IsEnabled) busy = true;
        };
        window.ExportPng.IsEnabledChanged += handler;
        try
        {
            action();
            PumpUntil(() => busy || !window.ExportPng.IsEnabled, TimeSpan.FromSeconds(10));
            WaitReady(window);
        }
        finally
        {
            window.ExportPng.IsEnabledChanged -= handler;
        }
    }

    private static void PumpUntil(Func<bool> condition, TimeSpan timeout)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > timeout) throw new TimeoutException("Comparison default render timed out.");
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
            timer.Start();
            Dispatcher.PushFrame(frame);
        }
    }

    private sealed record Fixtures(string Png, string Jpeg);

    private readonly record struct DriverPath(string FileName, string? Assembly);
}
