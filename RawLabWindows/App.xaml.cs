using System.Windows;
using System.Windows.Threading;

namespace RawLab.Windows;
public partial class App : Application
{
    private readonly SystemPhotoOpenQueue systemPhotoRequests = new();
    private MainWindow? systemEditor;
    private DispatcherTimer? systemPhotoTimer;
    private bool drainingSystemPhotos;

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
        Loc.Initialize();
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
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var version = typeof(App).Assembly.GetName().Version;
        var current = version?.ToString(3) ?? "unknown";
        var legacy = new UpdateChecker(current);
        var adapter = await Task.Run(() => VelopackUpdateAdapter.Create(current));
        var fileVersion=System.Diagnostics.FileVersionInfo.GetVersionInfo(typeof(App).Assembly.Location);
        var updates = new DesktopUpdateController(adapter, new(), new(UpdateStore.DefaultDirectory), current,
            fileVersion.FilePrivatePart.ToString(), legacy.Automatic);
        MainWindow? editor = null;
        if (updates.UnavailableReason != "storage" && !updates.RequiresRecovery)
        {
            editor = new MainWindow(new UsageAnalytics(), null, desktopUpdates: updates);
            await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
        }
        if (updates.BlocksEditing)
        {
            var recovery = new SoftwareUpdateWindow(updates, legacy) { Title = Loc.Text("更新恢复需要处理，编辑暂未开放") };
            MainWindow = recovery;
            updates.RetryStartup = async () => {
                if (editor == null || updates.CheckingStartupTrust) return;
                await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
                if (updates.BlocksEditing) return;
                updates.RetryStartup = null;
                MainWindow = editor; ShowSystemEditor(editor); recovery.Close();
            };
            recovery.Show();
        }
        else { MainWindow = editor; ShowSystemEditor(editor!); }
        ShutdownMode = ShutdownMode.OnMainWindowClose;
    }
}
