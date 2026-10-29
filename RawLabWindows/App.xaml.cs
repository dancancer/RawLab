using System.Windows;

namespace RawLab.Windows;
public partial class App : Application
{
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
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var version = typeof(App).Assembly.GetName().Version;
        var current = version?.ToString(3) ?? "unknown";
        var legacy = new UpdateChecker(current);
        var adapter = await Task.Run(() => VelopackUpdateAdapter.Create(current));
        var fileVersion=System.Diagnostics.FileVersionInfo.GetVersionInfo(typeof(App).Assembly.Location);
        var updates = new DesktopUpdateController(adapter, new(), new(UpdateStore.DefaultDirectory), current,
            fileVersion.FilePrivatePart.ToString(), legacy.Automatic);
        MainWindow? editor = null;
        if (updates.StorageError == null && !updates.RequiresRecovery)
        {
            editor = new MainWindow(new UsageAnalytics(), null, desktopUpdates: updates);
            await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
        }
        if (updates.StorageError != null || updates.RequiresRecovery || updates.RequiresStartupHealthCheck)
        {
            var recovery = new SoftwareUpdateWindow(updates, legacy) { Title = Loc.Text("更新恢复需要处理，编辑暂未开放") };
            MainWindow = recovery;
            updates.RetryStartup = async () => {
                if (editor == null || updates.CheckingStartupTrust) return;
                await updates.FinishStartupHealthCheckAsync(editor.UpdateDataHealthy);
                if (updates.BlocksEditing) return;
                updates.RetryStartup = null;
                MainWindow = editor; editor.Show(); recovery.Close();
            };
            recovery.Show();
        }
        else { MainWindow = editor; editor!.Show(); }
        ShutdownMode = ShutdownMode.OnMainWindowClose;
    }
}
