using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Windows;
using RawLab.Windows;

internal static class ProfileIsolationChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(output),Guid.NewGuid().ToString("N")[..8]);Directory.CreateDirectory(root);
        var defaultPreference=AppPaths.Default.LanguagePreferencePath;
        var languageBefore=Stamp(defaultPreference);var privatePreference=Path.Combine(root,"language.txt");
        Loc.SetPreference("de",privatePreference);Loc.Initialize(null,privatePreference);
        check(Loc.Preference=="de" && Loc.Language=="de" && File.ReadAllText(privatePreference)=="de","Private language preference survives the real persistence/reload path");
        check(languageBefore==Stamp(defaultPreference),"Private language changes leave the default preference existence, bytes and timestamp unchanged");
        Loc.Initialize("zh-Hans");
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        var initialPaths=TestWindowState.CreateIsolatedPaths(root);
        var usagePath=Path.Combine(root,"existing-usage.json");File.WriteAllText(usagePath,"{\"Enabled\":true}");
        var usageBefore=Stamp(usagePath);var transport=new UsageTransport();
        var existingUsage=new UsageAnalytics(usagePath,transport);
        var window=new MainWindow(initialPaths,existingUsage);
        var existingUpdates=window.DesktopUpdates;
        var existingStore=existingUpdates.Store;
        window.UpdateNotice.Visibility=Visibility.Visible;
        try
        {
            TestWindowState.Isolate(window,root);
            var updates=window.DesktopUpdates;
            var isolatedStore=updates.Store;
            var usage=window.UsageAnalyticsInstance;
            check(!ReferenceEquals(existingUsage,usage) && !usage.ConsentGiven && !usage.CanEnable,
                "Every test window gets private disabled analytics instead of retaining existing consent or transport");
            check(!ReferenceEquals(existingStore,isolatedStore) && !updates.Preferences.AutomaticCheck && window.UpdateNotice.Visibility==Visibility.Collapsed,
                "Every test window gets private disabled updates without retaining a default-profile badge");
            window.Show();window.UpdateLayout();
            check(transport.Starts==0 && usageBefore==Stamp(usagePath),
                "Test window Loaded leaves existing analytics consent bytes/timestamp and transport untouched");
            var privateConsent=usage.SettingsPath;
            check(File.ReadAllText(privateConsent).Contains("false") && !File.Exists(UsageAnalytics.InstallIdPathFor(privateConsent)) &&
                !File.Exists(UsageAnalytics.InstallIdPathFor(usagePath)),
                "Default-on analytics never reaches test windows: private consent is explicitly off and no install ID is created");
            check(isolatedStore.DirectoryPath.StartsWith(Path.GetFullPath(root),StringComparison.OrdinalIgnoreCase),
                "Test window isolates update store under private test directory");
            foreach(var (field, path) in new (string, string)[]{
                ("editStore", window.EditStoreInstance!.RegistryPath),
                ("batchJournal", window.BatchJournalInstance.DirectoryPath),
                ("library", window.LibraryInstance.SettingsPath),
                ("usageAnalytics", window.UsageAnalyticsInstance.SettingsPath)
            })
            {
                check(Path.GetFullPath(path).StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase),"Private window persistence: "+field);
            }
        }
        finally{window.Close();app.Shutdown();}
        var folderRoot=Path.Combine(root,"folders-p108");
        var foldersPath=Path.Combine(folderRoot,"folders.json");
        var folderMoves=0;
        var folderElapsed=TimeSpan.Zero;
        var folderDelays=new List<int>();
        var library=new Library(foldersPath,
            (src,dst)=>{ if(++folderMoves<=2)throw new System.IO.IOException("Sharing violation",unchecked((int)0x80070020)); File.Move(src,dst,true); },
            delay=>{ folderDelays.Add((int)delay.TotalMilliseconds); folderElapsed+=delay; },
            ()=>folderElapsed);
        library.Add(root);
        check(folderMoves==3 && folderDelays.SequenceEqual(new[]{10,50}) &&
            File.Exists(foldersPath) && Directory.GetFiles(folderRoot,"*.tmp").Length==0,
            "P1-08 FileLibrary.Library atomic write retries sharing violation 0x80070020 and cleans temp files");
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
