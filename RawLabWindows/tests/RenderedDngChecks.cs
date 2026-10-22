using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class RenderedDngChecks
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string fileName, string existingFileName, IntPtr securityAttributes);

    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
        Console.WriteLine("PASS " + message);
    }

    private static byte[] Digest(string path)
    {
        using var stream = File.OpenRead(path);
        return SHA256.HashData(stream);
    }

    private static string StatusMessage(int status)
    {
        try { Native.Check(status); }
        catch (InvalidOperationException error) { return error.Message; }
        throw new ArgumentOutOfRangeException(nameof(status));
    }

    private static void Reject(int status, Action action, string message)
    {
        var rejected = false;
        try { action(); }
        catch (InvalidOperationException error) when (error.Message == StatusMessage(status)) { rejected = true; }
        Check(rejected, message);
    }

    private static Adjustments Settings()
    {
        var settings = new Adjustments { Denoise = DenoiseSettings.Clean, DisplayChromaDenoise = 2,
            Effects = new PhotoEffectsSettings(-30, 42, -15, 65, 35, 20, 38, 65) };
        foreach (var (parameter, value) in new[] {
            (Parameter.Strength, 65d), (Parameter.Exposure, .35), (Parameter.Temperature, 5800d),
            (Parameter.Tint, 8d), (Parameter.Highlights, 20d), (Parameter.Shadows, 15d),
            (Parameter.Contrast, 10d), (Parameter.ToneCurve, 15d),
            (Parameter.Saturation, -10d), (Parameter.Sharpening, 20d)
        }) settings.Set(parameter, value);
        settings.Hsl = settings.Hsl.WithValue(0, 2, 12).WithValue(1, 4, -15).WithValue(2, 6, 8);
        return settings;
    }

    private static int ExportPair(RenderEngine engine, string raw, Adjustments settings, string look,
        string output, string name)
    {
        var dng = Path.Combine(output, name + ".dng");
        var png = Path.Combine(output, name + ".png");
        engine.Render(raw, settings, look, 0, output: dng, longEdge: 128);
        var backend = engine.LastBackend;
        var header = File.ReadAllBytes(dng);
        Check(header.Length > 1024 && header[0] == 'I' && header[1] == 'I' && header[2] == 42 && header[3] == 0,
            name + " writes a real classic TIFF DNG through the production FILE path");
        engine.Render(raw, settings, look, 0, output: png, longEdge: 128);
        Check(engine.LastBackend == backend, name + " DNG and PNG use the same actual backend");
        Check(File.ReadAllBytes(png)[24] == 16, name + " reference has actual sixteen-bit PNG channels");
        using var stream = File.OpenRead(png);
        var image = new PngBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        Check(Math.Max(image.PixelWidth, image.PixelHeight) == 128, name + " FINAL reference obeys the requested long edge");
        Console.WriteLine($"BACKEND {name}={backend}; PNG dimensions={image.PixelWidth}x{image.PixelHeight}");
        return backend;
    }

    private static void PumpUntil(Func<bool> condition, Func<string?> error, TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.Elapsed > timeout) throw new TimeoutException("DNG WPF worker timed out: " + error());
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(30) };
            timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
            timer.Start(); Dispatcher.PushFrame(frame);
        }
    }

    private static void Capture(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight),
            96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path); encoder.Save(stream);
    }

    internal static void Run(string repository, string fixture)
    {
        repository = Path.GetFullPath(repository); fixture = Path.GetFullPath(fixture);
        var output = Path.Combine(repository, "build", "rendered-dng-verification", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        Console.WriteLine("ARTIFACTS " + output);
        var fixtureHash = Digest(fixture);
        var source = Path.Combine(output, "source.ARW"); File.Copy(fixture, source);
        var targets = new[] { "target-a.ARW", "target-b.ARW" }.Select(name => Path.Combine(output, name)).ToArray();
        foreach (var target in targets) File.Copy(fixture, target);
        var settings = Settings(); var frozen = settings.Capture();
        var look = Path.Combine(repository, "lutools", "flog-2-new", "FLog2_to_Velvia_65grid_V.1.00.cube");
        var job = BatchJob.Create(source, frozen, look, "Velvia");
        job.OutputDirectory = output; job.LongEdge = 128;
        job.Items = targets.Select(target => BatchItem.Create(target) with { Selected = true }).ToList();
        var journal = new BatchJournal(Path.Combine(output, "journal")); journal.FreezeLook(job);
        look = job.Look!;
        var storePath = Path.Combine(output, "edits"); var store = new EditStore(storePath);
        var targetSettings = new Adjustments(); targetSettings.Set(Parameter.Exposure, -.75);
        var targetSnapshot = targetSettings.Capture();
        foreach (var target in targets) store.Save(target, targetSnapshot, null);
        store.Save(source, frozen, "validation-look");
        var editHash = Digest(Path.Combine(storePath, "edits.json"));
        FeatureRegressionChecks.Run(Check);
        using (var cpu = new RenderEngine(0))
        {
            Check(ExportPair(cpu, source, settings, look, output, "cpu") == 0, "CPU DNG export reports the CPU backend");
            Reject(1, () => cpu.Render(source, settings, look, 0, output: source), "Direct input overwrite is rejected");
            var existing = Path.Combine(output, "cpu.dng"); var hash = Digest(existing);
            var missingRejected=false;
            try { cpu.Render(Path.Combine(output, "missing.ARW"), settings, look, 0, output: existing); }
            catch(FileNotFoundException) { missingRejected=true; }
            Check(missingRejected,"Missing source is rejected by the managed input check before native export");
            Check(hash.SequenceEqual(Digest(existing)), "Failed input cannot replace a completed DNG");
            var alias = Path.Combine(output, "source-alias.dng");
            if (CreateHardLink(alias, source, IntPtr.Zero))
            {
                using (var sourceLock = WindowsFileIdentity.OpenReadLock(source))
                {
                    Check(WindowsFileIdentity.IsSameFile(sourceLock, alias), "Actual RAW hard-link alias is identified");
                    var blocked = false;
                    try { File.Move(source, source + ".moved"); } catch (IOException) { blocked = true; }
                    Check(blocked, "The production source handle prevents rename during publication");
                    Reject(1, () => cpu.Render(source, settings, look, 0, output: alias), "DNG source alias overwrite is rejected");
                }
                File.Delete(alias);
            }
            else Console.WriteLine("SKIP actual RAW hard-link guard: Win32 error=" + Marshal.GetLastWin32Error());
        }
        using (var auto = new RenderEngine(1))
        {
            var backend = ExportPair(auto, source, settings, look, output, "auto");
            Check(backend is 0 or 3, "Auto DNG reports CPU fallback or actual Direct3D 11");
            auto.SetGpuMode(2);
            var rejected = false; var forced = Path.Combine(output, "force.dng");
            try { auto.Render(source, settings, look, 0, output: forced, longEdge: 128); }
            catch (InvalidOperationException error) when (error.Message == StatusMessage(2) || error.Message == StatusMessage(4))
            { rejected = true; Console.WriteLine("FORCE rejection=" + error.Message); }
            Check(rejected && !File.Exists(forced), "Force cannot publish CPU C5 as GPU output");
        }
        Check(frozen.SameAs(settings.Capture()), "Native exports do not change the frozen adjustments");
        var sentinel = Path.Combine(output, "target-a-Velvia.dng"); File.WriteAllText(sentinel, "existing output");
        var sentinelHash = Digest(sentinel); var single = File.ReadAllBytes(Path.Combine(output, "auto.dng"));
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        foreach (var resource in new[] { "FileTreeStyles.xaml", "Controls.xaml" })
            app.Resources.MergedDictionaries.Add(new ResourceDictionary {
                Source = new Uri("/RawLab;component/" + resource, UriKind.Relative)
            });
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var batch = new BatchExportWindow(job, journal);
        try
        {
            batch.Show(); batch.Dng.IsChecked = true;
            Check(batch.Job.Format == ExportFormat.RenderedDng && batch.PrimaryAction.IsEnabled,
                "The real batch DNG option enables the configured file export");
            Capture(batch, Path.Combine(output, "batch-before.png"));
            batch.PrimaryAction.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            PumpUntil(() => !batch.Running && batch.Job.Started, () => batch.Job.Error, TimeSpan.FromMinutes(10));
            var completed = batch.Job;
            Check(completed.Error == null && completed.SucceededCount == 2 && completed.FailedCount == 0,
                "Actual WPF DNG worker publishes both targets: " + completed.Error);
            Check(completed.LongEdge == 128 && completed.Settings.SameAs(frozen), "Batch retains FINAL size and all frozen settings");
            Check(sentinelHash.SequenceEqual(Digest(sentinel)), "Batch collision leaves the existing output unchanged");
            foreach (var item in completed.Items)
            {
                Check(item.Output != null && item.Output.EndsWith(".dng", StringComparison.OrdinalIgnoreCase) &&
                    single.SequenceEqual(File.ReadAllBytes(item.Output)), "Single and actual batch DNG have identical FINAL bytes");
                Check(!File.Exists(completed.TemporaryPath(item)), "Published DNG has no known batch staging file");
            }
            Capture(batch, Path.Combine(output, "batch-completed.png"));
            var identities = completed.Items.ToDictionary(item => item.Id, item => OriginalIdentity.Read(item.Output!));
            completed.Items = completed.Items.Select(item => item with { Status = BatchStatus.Publishing }).ToList();
            journal.Save(completed); var recovered = journal.Load()!;
            Check(recovered.Items.All(item => item.Status == BatchStatus.Succeeded), "Publishing journal verifies completed DNG files");
            var renderCalls = 0;
            BatchRunner.Run(recovered, journal, true, CancellationToken.None, (_, _) => { },
                (_, _, _, _, _) => { renderCalls++; throw new Exception("Completed DNG rerendered"); });
            Check(renderCalls == 0 && recovered.SucceededCount == 2, "Retry skips recovered completed DNG output");
            Check(recovered.Items.All(item => identities[item.Id].SameContent(OriginalIdentity.Read(item.Output!)) &&
                single.SequenceEqual(File.ReadAllBytes(item.Output!))), "Recovery does not replace bytes or file timestamps");
            var partialJob = BatchJob.Create(source, frozen, look, "Velvia");
            partialJob.Format = ExportFormat.RenderedDng; partialJob.OutputDirectory = output; partialJob.Started = true;
            partialJob.Items = [BatchItem.Create(targets[0]) with { Selected = true, Status = BatchStatus.Running }];
            var partialJournal = new BatchJournal(Path.Combine(output, "partial-journal"));
            var temporary = partialJob.TemporaryPath(partialJob.Items[0]); File.WriteAllBytes(temporary, [1, 2, 3]);
            partialJournal.Save(partialJob); var pending = partialJournal.Load()!;
            Check(pending.Items[0].Status == BatchStatus.Waiting && !File.Exists(temporary),
                "Simulated running journal removes its known partial DNG and restores waiting");
            partialJournal.Discard(pending);
            var reopened = new EditStore(storePath);
            Check(editHash.SequenceEqual(Digest(Path.Combine(storePath, "edits.json"))) &&
                targets.All(target => reopened.Find(target)!.Settings.SameAs(targetSnapshot)) &&
                reopened.Find(source)!.Settings.SameAs(frozen), "Single and batch preserve source and target edit records");
            Check(new[] { fixture, source }.Concat(targets).All(path => fixtureHash.SequenceEqual(Digest(path))),
                "Fixture and every source RAW remain byte-identical");
            Console.WriteLine("SOURCE_SHA256 " + Convert.ToHexString(fixtureHash));
            Console.WriteLine("PASS Windows rendered DNG runtime regression");
            Console.WriteLine("NOT REACHED MainWindow SaveFileDialog and Explorer desktop integration");
        }
        finally { batch.Close(); app.Shutdown(); }
    }
}
