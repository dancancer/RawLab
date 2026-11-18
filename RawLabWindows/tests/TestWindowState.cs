using System.IO;
using System.Net.Http;
using System.Windows;
using RawLab.Windows;

internal static class TestWindowState
{
    internal static System.Windows.Application CreateApplication()
    {
        var app=new System.Windows.Application{ShutdownMode=System.Windows.ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        return app;
    }
    internal static void PreserveExistingBatch(string directory)
    {
        var path=Path.Combine(directory,"job.json");
        if(File.Exists(path))throw new InvalidOperationException("Preserve existing batch job: "+path+". Use an isolated test account.");
    }
    internal static AppPaths CreateIsolatedPaths(string output)
    {
        var paths=AppPaths.CreateIsolated(output);
        Directory.CreateDirectory(paths.Root);
        return paths;
    }
    internal static UsageAnalytics CreateDisabledAnalytics(AppPaths paths)
    {
        Directory.CreateDirectory(paths.Root);
        File.WriteAllText(paths.UsageSettingsPath,"{\"Enabled\":false}");
        return new UsageAnalytics(paths.UsageSettingsPath,new UnavailableUsageAnalyticsTransport());
    }
    internal static MainWindow CreateIsolatedWindow(
        string output,
        string? lookLibraryDirectory=null,
        AIDenoiseJob? aiJob=null,
        DesktopUpdateController? desktopUpdates=null,
        string? editDirectory=null,
        UsageAnalytics? usageAnalytics=null,
        double? width=null,
        double? height=null)
    {
        var paths=CreateIsolatedPaths(output);
        var analytics=usageAnalytics ?? CreateDisabledAnalytics(paths);
        var updates=desktopUpdates ?? new DesktopUpdateController(
            new UnavailableUpdateAdapter("configuration"),
            new(),
            new(paths.UpdatesDirectory),
            typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown",
            "",
            automaticCheck:false);
        var edits=new EditStore(editDirectory ?? paths.EditsDirectory);
        var window=new MainWindow(
            paths,
            analytics,
            lookLibraryDirectory ?? paths.LooksDirectory,
            aiJob,
            updates,
            edits);
        window.UpdateNotice.Visibility=Visibility.Collapsed;
        if(width is {} w)window.Width=w;
        if(height is {} h)window.Height=h;
        return window;
    }
    internal static void Isolate(MainWindow window,string output,HttpClient? updatesClient=null,string? editDirectory=null)
    {
        var paths=CreateIsolatedPaths(output);
        // 统计默认开启；测试窗口显式写入私有的“关闭”，既不沿用默认同意，也不生成安装标识
        var analytics=CreateDisabledAnalytics(paths);
        window.IsolateForTests(paths,analytics,editDirectory);
    }
}
