using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace RawLab.Windows;
public partial class App : Application
{
#if RAWLAB_RUM_SDK
    [System.Runtime.CompilerServices.ModuleInitializer]
    internal static void RegisterUsageAnalyticsTransport() =>
        UsageAnalytics.DefaultTransportFactory = RumUsageAnalyticsTransport.CreateDefault;
#endif
    private static App? currentApp;
    private static int processHooksInstalled;
    private readonly AppPaths appPaths;
    private readonly bool automaticUpdateCheck;
    private readonly UsageAnalytics? injectedUsageAnalytics;
    private readonly UnhandledExceptionCoordinator coordinator;
    private readonly SystemPhotoOpenQueue systemPhotoRequests = new();
    private MainWindow? systemEditor;
    private DispatcherTimer? systemPhotoTimer;
    private bool drainingSystemPhotos;
    private bool startupCompleted;
    internal bool StartupCompleted { get => startupCompleted; set => startupCompleted = value; }

    public App() : this(null, null) { }

    internal App(AIDiagnosticStore? diagnosticStore = null, AppPaths? appPaths = null, bool automaticUpdateCheck = true, UsageAnalytics? usageAnalytics = null)
    {
        currentApp = this;
        this.appPaths = appPaths ?? AppPaths.Default;
        this.automaticUpdateCheck = automaticUpdateCheck;
        injectedUsageAnalytics = usageAnalytics;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        coordinator = new UnhandledExceptionCoordinator(
            diagnosticStore ?? new(this.appPaths.AiDiagnosticsDirectory),
            () => new(startupCompleted, Dispatcher.HasShutdownStarted, Dispatcher.HasShutdownFinished,
                this.MainWindow is MainWindow { IsVisible: true, IsEnabled: true }),
            ShowUnhandledExceptionDialog,
            code => { systemPhotoTimer?.Stop(); SetSystemPhotoAdmission(false); Shutdown(code); });
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        InstallProcessHooks();
    }

    private static void InstallProcessHooks()
    {
        if (Interlocked.Exchange(ref processHooksInstalled, 1) != 0) return;
        TaskScheduler.UnobservedTaskException += (_, e) =>
            (currentApp?.coordinator ?? CreateFallbackCoordinator()).HandleUnobservedTaskException(e);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            (currentApp?.coordinator ?? CreateFallbackCoordinator()).HandleAppDomainException(e);
    }

    private static UnhandledExceptionCoordinator CreateFallbackCoordinator() =>
        new(AIDiagnosticStore.Default, static () => default, static (_, _, _, _) => UnhandledUiDecision.Exit, static _ => { });

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        coordinator.HandleUiException(e.Exception);
    }

    private UnhandledUiDecision ShowUnhandledExceptionDialog(
        Exception error, string? reportPath, bool saveFailed, bool canContinue)
    {
        if (!canContinue && !Dispatcher.HasShutdownStarted && !Dispatcher.HasShutdownFinished)
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (Loc.Strings.Count == 0) try { Loc.Initialize(); } catch { }
        var notice = !saveFailed && reportPath != null
            ? Loc.Text("失败时自动保存本地诊断；导出后可手动发送，不包含照片内容。") + "\n" + reportPath
            : Loc.Text("无法保存诊断包，请检查磁盘空间和写入权限。");
        var summary = string.IsNullOrWhiteSpace(error.Message) ? error.GetType().Name : error.Message;
        var detail = error.ToString();
        if (detail.Length > 8192) detail = detail[..8192] + " [truncated]";
        try
        {
            var owner = MainWindow is { IsLoaded: true, IsVisible: true } window ? window : null;
            var dialog = new Window { Title = "RawLab", Width = 540, MinWidth = 420, SizeToContent = SizeToContent.Height,
                ResizeMode = ResizeMode.NoResize, ShowInTaskbar = owner == null, Owner = owner,
                WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen };
            if (TryFindResource(typeof(Window)) is Style style) dialog.Style = style;
            AutomationProperties.SetAutomationId(dialog, "app.unhandledException");
            KeyboardNavigation.SetTabNavigation(dialog, KeyboardNavigationMode.Cycle);
            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(new TextBlock { Text = Loc.Text("请保留现有应用和数据，处理问题后重新启动。"),
                FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
            panel.Children.Add(new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
            var noticeBlock = new TextBlock { Text = notice, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) };
            if (TryFindResource("Muted") is System.Windows.Media.Brush muted) noticeBlock.Foreground = muted;
            panel.Children.Add(noticeBlock);
            var header = new TextBlock { Text = Loc.Text("错误详情"), TextWrapping = TextWrapping.Wrap };
            var details = new TextBox { Text = detail, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                MaxHeight = 200, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 0) };
            var expander = new Expander { Header = header, Content = details, Margin = new Thickness(0, 0, 0, 16) };
            expander.SizeChanged += (_, _) => header.MaxWidth = Math.Max(100, expander.ActualWidth - 32);
            panel.Children.Add(expander);
            var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
            if (canContinue)
            {
                var keep = new Button { Content = Loc.Text("继续编辑"), Margin = new Thickness(0, 0, 8, 0) };
                AutomationProperties.SetAutomationId(keep, "app.unhandledException.continue");
                keep.Click += (_, _) => dialog.DialogResult = true;
                actions.Children.Add(keep);
            }
            var exit = new Button { Content = Loc.Text("退出"), IsDefault = true, IsCancel = !canContinue };
            AutomationProperties.SetAutomationId(exit, "app.unhandledException.exit");
            exit.Click += (_, _) => dialog.DialogResult = false;
            actions.Children.Add(exit);
            panel.Children.Add(actions);
            dialog.Content = panel;
            return dialog.ShowDialog() == true && canContinue ? UnhandledUiDecision.Continue : UnhandledUiDecision.Exit;
        }
        catch
        {
            try { MessageBox.Show(Loc.Text("请保留现有应用和数据，处理问题后重新启动。") + "\n\n" + notice + "\n\n" + summary, "RawLab", MessageBoxButton.OK, MessageBoxImage.Error); }
            catch { }
            return UnhandledUiDecision.Exit;
        }
    }

    internal bool EnqueueSystemPhotos(string[] paths)
    {
        if (Dispatcher.HasShutdownStarted || !systemPhotoRequests.Enqueue(paths, DateTimeOffset.UtcNow)) return false;
        if (paths.Length > 0)
        {
            try
            {
                if (Dispatcher.BeginInvoke(new Action(() => systemPhotoTimer?.Start())).Status == DispatcherOperationStatus.Aborted)
                    return false;
            }
            catch (InvalidOperationException) { return false; }
        }
        return true;
    }
    internal void SetSystemPhotoAdmission(bool accepting) => systemPhotoRequests.Accepting = accepting;

    private void DrainSystemPhotos()
    {
        if (drainingSystemPhotos) return;
        drainingSystemPhotos = true;
        try
        {
            while (systemEditor?.IsLoaded == true && systemPhotoRequests.Peek(DateTimeOffset.UtcNow) is { } paths)
            {
                if (!systemEditor.TryOpenSystemPhotos(paths)) break;
                systemPhotoRequests.RemoveFirst();
            }
            if (!systemPhotoRequests.HasRequests) systemPhotoTimer?.Stop();
        }
        finally { drainingSystemPhotos = false; }
    }

    private void ShowSystemEditor(MainWindow editor)
    {
        systemEditor = editor;
        editor.Show();
        DrainSystemPhotos();
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        Exit+=(_,_)=>HDRSourceCache.Clear();
        Loc.Initialize(null, appPaths.LanguagePreferencePath);
        void ApplyLanguage() { foreach (var pair in Loc.Strings) Resources[pair.Key] = pair.Value; }
        ApplyLanguage();
        Loc.Changed += ApplyLanguage;
        void ApplyAppearance()=>EditorAppearance.Apply(Resources);
        ApplyAppearance();
        System.ComponentModel.PropertyChangedEventHandler parametersChanged=(_,_)=>Dispatcher.Invoke(ApplyAppearance);
        Microsoft.Win32.UserPreferenceChangedEventHandler preferencesChanged=(_,_)=>Dispatcher.Invoke(ApplyAppearance);
        SystemParameters.StaticPropertyChanged+=parametersChanged;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged+=preferencesChanged;
        Exit+=(_,_)=>{SystemParameters.StaticPropertyChanged-=parametersChanged;Microsoft.Win32.SystemEvents.UserPreferenceChanged-=preferencesChanged;};
        base.OnStartup(e);
        systemPhotoTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background,
            (_, _) => DrainSystemPhotos(), Dispatcher);
        systemPhotoTimer.Start();
        Exit += (_, _) => SetSystemPhotoAdmission(false);
        var version = typeof(App).Assembly.GetName().Version;
        var current = version?.ToString(3) ?? "unknown";
        // 启动清扫（临时目录前缀通配枚举 + 过期树递归删除）不挡首屏：先派发到工作线程，
        // 主窗口创建与显示不再等待它。清扫只删超过保留期且 owner 进程已死的本应用前缀
        // 目录；首窗之后本实例创建的 UUID 新目录 mtime 晚于清扫起点、在保留期内，且带
        // 存活的 owner 标记，不会被误删；分析缓存目录另有 in-use 短路，导出 staging 按
        // 租约进程存活判断，与并发窗口创建互不干扰。
        var analytics = injectedUsageAnalytics ?? new UsageAnalytics(appPaths.UsageSettingsPath);
        var analyticsCache = analytics.CacheDirectory;
        var exportStaging = appPaths.ExportStagingDirectory;
        var startupSweep = Task.Run(() => TempCleanup.SweepStartup(
            Path.GetTempPath(), analyticsCache, exportStaging, DateTime.UtcNow, TempCleanup.DefaultRetention));
        var adapter = await Task.Run(() => VelopackUpdateAdapter.Create(current, appPaths));
        var fileVersion=System.Diagnostics.FileVersionInfo.GetVersionInfo(typeof(App).Assembly.Location);
        var privateBuild = fileVersion.FilePrivatePart.ToString();
        var updates = await Task.Run(() => new DesktopUpdateController(adapter, new(), new(appPaths.UpdatesDirectory), current,
            privateBuild, automaticCheck: automaticUpdateCheck));
        MainWindow? editor = null;
        if (!updates.RequiresRecovery)
        {
            editor = new MainWindow(appPaths, analytics, desktopUpdates: updates);
            await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
        }
        if (updates.BlocksEditing)
        {
            SoftwareUpdateWindow? recovery = null;
            if (editor != null)
            {
                updates.RetryStartup = async () => {
                    if (updates.CheckingStartupTrust) return;
                    await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
                    if (updates.BlocksEditing) return;
                    updates.RetryStartup = null;
                    MainWindow = editor; ShowSystemEditor(editor); recovery?.Close();
                };
            }
            recovery = new SoftwareUpdateWindow(updates) { Title = Loc.Text("更新恢复需要处理，编辑暂未开放") };
            MainWindow = recovery;
            recovery.Show();
        }
        else { MainWindow = editor; ShowSystemEditor(editor!); }
        startupCompleted = true;
        ShutdownMode = ShutdownMode.OnMainWindowClose;
        // 首屏已就绪；等待后台清扫完成以保留异常观察（SweepStartup 已兜底常规 IO 异常，
        // 仅 OOM/StackOverflow 会在此上抛，与此前同步 await 时的语义一致）。
        await startupSweep;
    }
}
