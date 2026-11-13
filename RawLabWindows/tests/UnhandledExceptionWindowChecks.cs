using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class UnhandledExceptionWindowChecks
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;

    internal static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-unhandled-ui-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var diagnostics = new AIDiagnosticStore(Path.Combine(root, "diagnostics"));
        var previousLanguage = Loc.Preference;
        var previousContext = SynchronizationContext.Current;
        int? observedExitCode = null;
        var app = new App(diagnostics);
        app.Exit += (_, e) => { observedExitCode = e.ApplicationExitCode; e.ApplicationExitCode = 0; };
        app.InitializeComponent();
        foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(app.Dispatcher));
        MainWindow? window = null;
        DispatcherTimer? dialogDriver = null;

        try
        {
            // 1. Early startup ShutdownMode guard: closing a transient dialog before MainWindow exists
            //    must not trigger OnLastWindowClose Shutdown(0) ahead of coordinator Shutdown(1).
            check(app.ShutdownMode == ShutdownMode.OnExplicitShutdown,
                "App constructor sets OnExplicitShutdown before hooks or windows");
            var probe = new Window { Width = 120, Height = 80, ShowInTaskbar = false, WindowStyle = WindowStyle.None, Opacity = 0 };
            probe.Show();
            probe.Close();
            Pump(app.Dispatcher);
            check(observedExitCode == null,
                "Closing transient window before MainWindow does not prematurely shut down App with code 0");

            // 2. Real async void -> BrowseFolder unhandled exception -> App.OnDispatcherUnhandledException ->
            //    ShowUnhandledExceptionDialog ("继续编辑") -> readingFolder & heading recover cleanly.
            window = new MainWindow();
            TestWindowState.Isolate(window, root);
            app.MainWindow = window;
            window.Show();
            typeof(App).GetField("startupCompleted", PrivateInstance)!.SetValue(app, true);
            Pump(app.Dispatcher);

            var validParentDir = Path.Combine(root, "LibraryRoot");
            Directory.CreateDirectory(validParentDir);
            var validParent = new LibraryEntry(validParentDir, true);
            validParent.Load().GetAwaiter().GetResult();

            var brokenChild = new LibraryEntry("   ", true);
            typeof(LibraryEntry).GetProperty("Parent")!.SetValue(brokenChild, validParent);
            typeof(MainWindow).GetField("browsedFolder", PrivateInstance)!.SetValue(window, brokenChild);

            var continueDialogHandled = false;
            var continueButtonPresent = false;
            dialogDriver = new DispatcherTimer(DispatcherPriority.Background, app.Dispatcher) { Interval = TimeSpan.FromMilliseconds(20) };
            dialogDriver.Tick += (_, _) =>
            {
                var dialog = app.Windows.OfType<Window>().FirstOrDefault(candidate =>
                    candidate.IsVisible && AutomationProperties.GetAutomationId(candidate) == "app.unhandledException");
                if (dialog == null) return;
                dialogDriver.Stop();
                var keep = Descendants(dialog).OfType<Button>().FirstOrDefault(button =>
                    AutomationProperties.GetAutomationId(button) == "app.unhandledException.continue");
                continueButtonPresent = keep != null;
                var target = keep ?? Descendants(dialog).OfType<Button>().Single(button =>
                    AutomationProperties.GetAutomationId(button) == "app.unhandledException.exit");
                target.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                continueDialogHandled = true;
            };
            dialogDriver.Start();

            window.RetryFolderButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            PumpUntil(app.Dispatcher, () => continueDialogHandled, "Timed out waiting for unhandled exception Continue dialog");

            check(continueButtonPresent && observedExitCode == null && window.IsVisible,
                "Interactive editor unhandled exception shows Continue and keeps MainWindow open");
            var dispatcherReport = diagnostics.Latest();
            check(dispatcherReport != null, "App.OnDispatcherUnhandledException writes a diagnostic file");
            using (var doc = JsonDocument.Parse(File.ReadAllText(dispatcherReport!)))
            {
                check(doc.RootElement.GetProperty("operation").GetString() == "unhandled.dispatcher" &&
                      doc.RootElement.GetProperty("error_type").GetString() == typeof(ArgumentException).FullName,
                    "App.OnDispatcherUnhandledException records async void fault as unhandled.dispatcher");
            }
            check(!(bool)typeof(MainWindow).GetField("readingFolder", PrivateInstance)!.GetValue(window)! &&
                  window.SidebarGalleryNotice.Text != Loc.Text("正在读取目录…"),
                "BrowseFolder finally resets readingFolder and clears the loading notice after unhandled exception");

            window.UpFolderButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            PumpUntil(app.Dispatcher, () =>
                ReferenceEquals(typeof(MainWindow).GetField("browsedFolder", PrivateInstance)!.GetValue(window), validParent) &&
                !(bool)typeof(MainWindow).GetField("readingFolder", PrivateInstance)!.GetValue(window)!,
                "Timed out navigating to parent folder after recovery");
            check(window.FolderBreadcrumb.Text == "LibraryRoot",
                "Folder browser remains operable after unhandled BrowseFolder exception");

            // 3. PumpEmbedded FormatException / COMException fallback:
            //    When embedded preview decoding throws FormatException, PumpEmbedded must catch,
            //    log and degrade to no-preview without propagating an unhandled exception to AppDispatcher.
            var embeddedFallbackLogged = false;
            using var traceListener = new FallbackTraceListener(line => {
                if (line.Contains("Embedded preview fallback")) embeddedFallbackLogged = true;
            });
            Trace.Listeners.Add(traceListener);
            try
            {
                window.ReadEmbeddedPreviewHook = _ => throw new FormatException("Simulated corrupted EXIF/preview stream");
                var dummyPhoto = Path.Combine(root, "bad-embedded.ARW");
                File.WriteAllBytes(dummyPhoto, [1, 2, 3]);
                window.OpenFile(dummyPhoto);
                PumpUntil(app.Dispatcher, () => embeddedFallbackLogged, "Timed out waiting for embedded preview fallback");
                check(observedExitCode == null, "PumpEmbedded FormatException does not crash the application");
                check(typeof(MainWindow).GetField("openingPreview", PrivateInstance)!.GetValue(window) == null,
                    "Embedded preview degrades to no preview state upon FormatException");
            }
            finally
            {
                Trace.Listeners.Remove(traceListener);
                window.ReadEmbeddedPreviewHook = RenderEngine.ReadEmbeddedPreview;
            }

            // 4. Early startup unhandled exception (startupCompleted == false, no MainWindow):
            //    hides Continue button and exits with code 1 instead of OnLastWindowClose code 0.
            window.Close();
            window = null;
            app.MainWindow = null;
            typeof(App).GetField("startupCompleted", PrivateInstance)!.SetValue(app, false);

            var startupDialogHandled = false;
            var startupContinueHidden = false;
            dialogDriver = new DispatcherTimer(DispatcherPriority.Background, app.Dispatcher) { Interval = TimeSpan.FromMilliseconds(20) };
            dialogDriver.Tick += (_, _) =>
            {
                var dialog = app.Windows.OfType<Window>().FirstOrDefault(candidate =>
                    candidate.IsVisible && AutomationProperties.GetAutomationId(candidate) == "app.unhandledException");
                if (dialog == null) return;
                dialogDriver.Stop();
                startupContinueHidden = !Descendants(dialog).OfType<Button>().Any(button =>
                    AutomationProperties.GetAutomationId(button) == "app.unhandledException.continue");
                var exit = Descendants(dialog).OfType<Button>().Single(button =>
                    AutomationProperties.GetAutomationId(button) == "app.unhandledException.exit");
                exit.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                startupDialogHandled = true;
            };
            dialogDriver.Start();

            app.Dispatcher.BeginInvoke(new Action(() => throw new InvalidOperationException("early startup fault")));
            PumpUntil(app.Dispatcher, () => startupDialogHandled && observedExitCode != null,
                "Timed out waiting for startup unhandled exception shutdown");

            check(startupContinueHidden && observedExitCode == 1,
                "Early startup unhandled exception hides Continue and shuts down with exit code 1");
            check(Directory.GetFiles(diagnostics.DirectoryPath, "*.json").Any(path =>
                  {
                      using var doc = JsonDocument.Parse(File.ReadAllText(path));
                      return doc.RootElement.GetProperty("operation").GetString() == "unhandled.startup" &&
                             doc.RootElement.GetProperty("error_type").GetString() == typeof(InvalidOperationException).FullName;
                  }),
                "Early startup unhandled exception records unhandled.startup diagnostic");
        }
        finally
        {
            dialogDriver?.Stop();
            if (window != null)
            {
                foreach (var owned in window.OwnedWindows.OfType<Window>().ToArray()) owned.Close();
                window.Close();
            }
            Loc.Initialize(previousLanguage);
            SynchronizationContext.SetSynchronizationContext(previousContext);
            if (observedExitCode == null) app.Shutdown();
            Environment.ExitCode = 0;
            try { Directory.Delete(root, recursive: true); } catch (IOException) { }
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }

    private static void Pump(Dispatcher dispatcher)
    {
        var frame = new DispatcherFrame();
        dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private static void PumpUntil(Dispatcher dispatcher, Func<bool> condition, string timeoutMessage)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.Elapsed > TimeSpan.FromSeconds(10)) throw new TimeoutException(timeoutMessage);
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
            timer.Start();
            Dispatcher.PushFrame(frame);
        }
    }

    private sealed class FallbackTraceListener : TraceListener
    {
        private readonly Action<string> onLine;
        public FallbackTraceListener(Action<string> onLine) => this.onLine = onLine;
        public override void Write(string? message) { if (message != null) onLine(message); }
        public override void WriteLine(string? message) { if (message != null) onLine(message); }
    }
}
