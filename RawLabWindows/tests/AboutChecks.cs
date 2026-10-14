using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using TextRun = System.Windows.Documents.Run;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AboutChecks
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;

    internal static void Run(Action<bool, string> check)
    {
        // Startup can recover an existing batch and clean its temporary exports. Use a clean test account.
        if (File.Exists(Path.Combine(BatchJournal.DefaultDirectory, "job.json")))
            throw new InvalidOperationException("Run --about with no saved batch job; existing batch data must remain untouched.");

        var directory = Path.Combine(Path.GetTempPath(), "rawlab-about-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var settingsPath = Path.Combine(directory, "updates.json");
        const string preferences = "{\"Automatic\":false}";
        File.WriteAllText(settingsPath, preferences);
        using var handler = new NoNetworkHandler();
        using var client = new HttpClient(handler);
        var version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown";
        var updates = new UpdateChecker(version, settingsPath, client);
        var previousLanguage = Loc.Preference;
        var previousContext = SynchronizationContext.Current;
        // A test application owns the production windows without launching App's automatic startup window.
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/RawLab;component/FileTreeStyles.xaml", UriKind.Relative) });
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/RawLab;component/Controls.xaml", UriKind.Relative) });
        void ApplyLanguage() { foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value; }
        Loc.Changed += ApplyLanguage;
        MainWindow? window = null;
        try
        {
            Loc.Initialize("en");
            ApplyLanguage();
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
            window = new MainWindow();
            // Keep startup updates on the real path, with isolated settings and no network access.
            typeof(MainWindow).GetField("updates", PrivateInstance)!.SetValue(window, updates);
            window.UpdateNotice.DataContext = updates;
            window.Files.ItemsSource = Array.Empty<LibraryEntry>();
            window.Show();
            Pump();
            check(window.Welcome.Visibility == Visibility.Visible && !window.ExportButton.IsEnabled &&
                  typeof(MainWindow).GetField("file", PrivateInstance)!.GetValue(window) == null,
                "Empty editor startup needs no RAW fixture");

            AboutWindow OpenAbout()
            {
                var button = Descendants(window).OfType<Button>().Single(candidate =>
                    AutomationProperties.GetName(candidate) == Loc.Text("关于 RawLab"));
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Pump();
                return window.OwnedWindows.OfType<AboutWindow>().Single();
            }

            var about = OpenAbout();
            CheckAbout(about, updates, "en", "Version", check);
            foreach (var (language, label) in new[] {
                ("zh-Hans", "版本"), ("en", "Version"), ("de", "Version"),
                ("fr", "Version"), ("ja", "バージョン"), ("es", "Versión") })
            {
                // Reload and notify the same subscribers as SetPreference, without writing language.txt.
                Loc.Initialize(language);
                ((Action?)typeof(Loc).GetField("Changed", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null))?.Invoke();
                Pump();
                CheckAbout(about, updates, language, label, check);
                var closed = about;
                Descendants(about).OfType<Button>().Single(button => button.IsCancel)
                    .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Pump();
                check(!closed.IsVisible && !window.OwnedWindows.OfType<AboutWindow>().Any(),
                    $"About close removes the owned window ({language})");
                about = OpenAbout();
                check(!ReferenceEquals(about, closed) && about.IsVisible && window.IsVisible,
                    $"About button reopens a new window from the empty editor ({language})");
                CheckAbout(about, updates, language, label, check);
            }
            check(handler.Requests == 0 && File.ReadAllText(settingsPath) == preferences,
                "About lifecycle sends no update requests and preserves isolated update preferences");
        }
        finally
        {
            if (window != null)
            {
                foreach (var about in window.OwnedWindows.OfType<AboutWindow>().ToArray()) about.Close();
                window.Close();
            }
            Loc.Changed -= ApplyLanguage;
            Loc.Initialize(previousLanguage);
            SynchronizationContext.SetSynchronizationContext(previousContext);
            app.Shutdown();
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void CheckAbout(AboutWindow about, UpdateChecker updates, string language, string label,
        Action<bool, string> check)
    {
        var versionText = Descendants(about).OfType<TextBlock>().Single(text => text.Inlines.OfType<TextRun>().Any(run =>
            BindingOperations.GetBinding(run, TextRun.TextProperty)?.Path?.Path == nameof(UpdateChecker.CurrentVersion)));
        var versionRun = versionText.Inlines.OfType<TextRun>().Single(run =>
            BindingOperations.GetBinding(run, TextRun.TextProperty)?.Path?.Path == nameof(UpdateChecker.CurrentVersion));
        check(about.IsVisible && ReferenceEquals(about.DataContext, updates) && versionRun.Text == updates.CurrentVersion &&
              BindingOperations.GetBinding(versionRun, TextRun.TextProperty)!.Mode == BindingMode.OneWay &&
              BindingOperations.GetBindingExpression(versionRun, TextRun.TextProperty)!.Status == BindingStatus.Active,
            $"About displays the current version through an active OneWay binding ({language})");
        var actualLabel = versionText.Inlines.OfType<TextRun>().First().Text;
        var actualText = new TextRange(versionText.ContentStart, versionText.ContentEnd).Text;
        var selectedLanguage = ((ComboBox)about.FindName("LanguageBox")!).SelectedValue?.ToString();
        var localized = about.Title == Loc.Text("关于 RawLab") && actualLabel == label &&
                        actualText == label + " " + updates.CurrentVersion && selectedLanguage == language;
        if (!localized) Console.WriteLine("About values: " + System.Text.Json.JsonSerializer.Serialize(new {
            about.Title, ExpectedTitle = Loc.Text("关于 RawLab"), Label = actualLabel, ExpectedLabel = label,
            Text = actualText, ExpectedText = label + " " + updates.CurrentVersion, Language = selectedLanguage, ExpectedLanguage = language }));
        check(localized,
            $"About title, version label and language selection follow the {language} catalog");
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }

    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private sealed class NoNetworkHandler : HttpMessageHandler
    {
        internal int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            throw new InvalidOperationException("The about regression must not send update requests.");
        }
    }
}
