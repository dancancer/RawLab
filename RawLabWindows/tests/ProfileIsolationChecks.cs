using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using RawLab.Windows;

internal static class ProfileIsolationChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string output,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(output),Guid.NewGuid().ToString("N")[..8]);Directory.CreateDirectory(root);
        var initialize=typeof(Loc).GetMethod("Initialize",[typeof(string),typeof(string)]);
        var setPreference=typeof(Loc).GetMethod("SetPreference",[typeof(string),typeof(string)]);
        check(initialize!=null && setPreference!=null,"Language persistence accepts an explicit private file without replacing the default profile");
        var defaultPreference=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","language.txt");
        var languageBefore=Stamp(defaultPreference);var privatePreference=Path.Combine(root,"language.txt");
        setPreference!.Invoke(null,["de",privatePreference]);initialize!.Invoke(null,[null,privatePreference]);
        check(Loc.Preference=="de" && Loc.Language=="de" && File.ReadAllText(privatePreference)=="de","Private language preference survives the real persistence/reload path");
        check(languageBefore==Stamp(defaultPreference),"Private language changes leave the default preference existence, bytes and timestamp unchanged");
        Loc.Initialize("zh-Hans");
        var protectedPath=Path.Combine(root,"existing-updates.json");
        File.WriteAllText(protectedPath,"{\"Automatic\":true,\"LastAttempt\":0}");
        var before=File.ReadAllBytes(protectedPath);var written=File.GetLastWriteTimeUtc(protectedPath);
        using var handler=new Requests();using var client=new HttpClient(handler);
        var existing=new UpdateChecker("0.8.0",protectedPath,client);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        var usagePath=Path.Combine(root,"existing-usage.json");File.WriteAllText(usagePath,"{\"Enabled\":true}");
        var usageBefore=Stamp(usagePath);var transport=new UsageTransport();
        var existingUsage=new UsageAnalytics(usagePath,transport);
        var window=new MainWindow(existingUsage);typeof(MainWindow).GetField("updates",Private)!.SetValue(window,existing);
        window.UpdateNotice.Visibility=Visibility.Visible;
        try
        {
            TestWindowState.Isolate(window,root,client);
            var updates=(UpdateChecker)typeof(MainWindow).GetField("updates",Private)!.GetValue(window)!;
            var usage=(UsageAnalytics)typeof(MainWindow).GetField("usageAnalytics",Private)!.GetValue(window)!;
            check(!ReferenceEquals(existingUsage,usage) && !usage.ConsentGiven && !usage.CanEnable,
                "Every test window gets private disabled analytics instead of retaining existing consent or transport");
            check(!ReferenceEquals(existing,updates) && !updates.Automatic && window.UpdateNotice.Visibility==Visibility.Collapsed,
                "Every test window gets private disabled updates without retaining a default-profile badge");
            window.Show();window.UpdateLayout();
            check(handler.Count==0 && !updates.Checking,"Test window Loaded sends no update request");
            check(transport.Starts==0 && usageBefore==Stamp(usagePath),
                "Test window Loaded leaves existing analytics consent bytes/timestamp and transport untouched");
            var privateConsent=(string)typeof(UsageAnalytics).GetField("settingsPath",Private)!.GetValue(usage)!;
            check(File.ReadAllText(privateConsent).Contains("false") && !File.Exists(UsageAnalytics.InstallIdPathFor(privateConsent)) &&
                !File.Exists(UsageAnalytics.InstallIdPathFor(usagePath)),
                "Default-on analytics never reaches test windows: private consent is explicitly off and no install ID is created");
            check(before.SequenceEqual(File.ReadAllBytes(protectedPath)) && written==File.GetLastWriteTimeUtc(protectedPath) && !File.Exists(protectedPath+".tmp"),
                "Test window preserves existing update preferences and temporary files");
            foreach(var field in new[]{"editStore","batchJournal","library","updates","usageAnalytics"})
            {
                var value=typeof(MainWindow).GetField(field,Private)!.GetValue(window)!;
                var path=field switch {
                    "editStore"=>(string)value.GetType().GetField("path",Private)!.GetValue(value)!,
                    "batchJournal"=>((BatchJournal)value).DirectoryPath,
                    _=>(string)value.GetType().GetField("settingsPath",Private)!.GetValue(value)!
                };
                check(Path.GetFullPath(path).StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase),"Private window persistence: "+field);
            }
        }
        finally{window.Close();app.Shutdown();}
    }
    private static string? Stamp(string path)=>File.Exists(path) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)))+"/"+File.GetLastWriteTimeUtc(path).Ticks : null;
    private sealed class Requests:HttpMessageHandler
    {
        internal int Count;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken)
        { Count++;return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("{}")}); }
    }
    private sealed class UsageTransport:IUsageAnalyticsTransport
    {
        internal int Starts;
        public bool IsAvailable=>true;
        public Task StartAsync(string installId,CancellationToken cancellationToken){Starts++;return Task.CompletedTask;}
        public Task SendAsync(UsageEvent usageEvent,CancellationToken cancellationToken)=>Task.CompletedTask;
        public Task StopAsync(CancellationToken cancellationToken)=>Task.CompletedTask;
    }
}
