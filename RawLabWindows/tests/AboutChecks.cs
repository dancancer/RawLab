using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using TextRun = System.Windows.Documents.Run;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AboutChecks
{
    internal static void Run(Action<bool, string> check)
    {
        // Startup can recover an existing batch and clean its temporary exports. Use a clean test account.
        if (File.Exists(Path.Combine(BatchJournal.DefaultDirectory, "job.json")))
            throw new InvalidOperationException("Run --about with no saved batch job; existing batch data must remain untouched.");

        var directory = Path.Combine(Path.GetTempPath(), "rawlab-about-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown";
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
            window = TestWindowState.CreateIsolatedWindow(directory);
            window.Files.ItemsSource = Array.Empty<LibraryEntry>();
            window.Show();
            Pump();
            check(window.Welcome.Visibility == Visibility.Visible && !window.ExportButton.IsEnabled &&
                  window.CurrentFile == null,
                "Empty editor startup needs no RAW fixture");

            AboutWindow OpenAbout()
            {
                // The workspace redesign (8b55219a) moved About from the old toolbar button into the Help menu.
                // Anchor the menu item by its localized screen-reader name and raise the menu item's own click.
                var aboutItem = Descendants(window).OfType<MenuItem>().Single(candidate =>
                    UIElementAutomationPeer.CreatePeerForElement(candidate)?.GetName() == Loc.Text("关于 RawLab"));
                aboutItem.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                Pump();
                return window.OwnedWindows.OfType<AboutWindow>().Single();
            }

            var about = OpenAbout();
            CheckAbout(about, version, "en", "Version", check);
            foreach (var (language, label) in new[] {
                ("zh-Hans", "版本"), ("en", "Version"), ("de", "Version"),
                ("fr", "Version"), ("ja", "バージョン"), ("es", "Versión") })
            {
                // Reload and notify the same subscribers as SetPreference, without writing language.txt.
                Loc.Initialize(language);
                Loc.NotifyChangedForTests();
                Pump();
                CheckAbout(about, version, language, label, check);
                var closed = about;
                Descendants(about).OfType<Button>().Single(button => button.IsCancel)
                    .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Pump();
                check(!closed.IsVisible && !window.OwnedWindows.OfType<AboutWindow>().Any(),
                    $"About close removes the owned window ({language})");
                about = OpenAbout();
                check(!ReferenceEquals(about, closed) && about.IsVisible && window.IsVisible,
                    $"About button reopens a new window from the empty editor ({language})");
                CheckAbout(about, version, language, label, check);
            }
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
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void CheckAbout(AboutWindow about, string currentVersion, string language, string label,
        Action<bool, string> check)
    {
        var versionRun = (TextRun)about.FindName("VersionRun")!;
        var versionText = (TextBlock)versionRun.Parent;
        var expectedVersion = Loc.Format("版本 {0}", currentVersion);
        check(about.IsVisible && versionRun.Text == expectedVersion,
            $"About displays the current version ({language})");
        var actualText = new TextRange(versionText.ContentStart, versionText.ContentEnd).Text;
        var selectedLanguage = ((ComboBox)about.FindName("LanguageBox")!).SelectedValue?.ToString();
        var localized = about.Title == Loc.Text("关于 RawLab") &&
                        actualText == expectedVersion && selectedLanguage == language;
        if (!localized) Console.WriteLine("About values: " + System.Text.Json.JsonSerializer.Serialize(new {
            about.Title, ExpectedTitle = Loc.Text("关于 RawLab"),
            Text = actualText, ExpectedText = expectedVersion, Language = selectedLanguage, ExpectedLanguage = language }));
        check(localized,
            $"About title, version label and language selection follow the {language} catalog");
        var texts = Descendants(about).OfType<TextBlock>().Select(text => text.Text).ToList();
        var privacy = texts.IndexOf(Loc.Text("开启后，由阿里云处理功能使用次数，数据存储在中国大陆；SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。"));
        check(privacy >= 0 && privacy + 1 < texts.Count &&
              texts[privacy + 1] == Loc.Text("为统计活跃设备数，应用会在本机保存一个随机生成的安装标识，不含个人信息；关闭统计时一并删除。"),
            $"About explains the random install ID right after the privacy paragraph ({language})");
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
