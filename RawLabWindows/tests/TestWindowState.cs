using System.IO;
using System.Net.Http;
using System.Reflection;
using RawLab.Windows;

internal static class TestWindowState
{
    internal static void PreserveExistingBatch(string directory)
    {
        var path=Path.Combine(directory,"job.json");
        if(File.Exists(path))throw new InvalidOperationException("Preserve existing batch job: "+path+". Use an isolated test account.");
    }
    internal static void Isolate(MainWindow window,string output,HttpClient? updatesClient=null)
    {
        var root=Path.Combine(Path.GetFullPath(output),"profile-"+Guid.NewGuid().ToString("N")[..8]);Directory.CreateDirectory(root);
        const BindingFlags flags=BindingFlags.Instance|BindingFlags.NonPublic;
        void Set(string field,object value)=>typeof(MainWindow).GetField(field,flags)!.SetValue(window,value);
        var previous=(UpdateChecker)typeof(MainWindow).GetField("updates",flags)!.GetValue(window)!;
        var path=Path.Combine(root,"updates.json");File.WriteAllText(path,"{\"Automatic\":false,\"LastAttempt\":0}");
        var updates=new UpdateChecker(previous.CurrentVersion,path,updatesClient);Set("updates",updates);
        var notice=(System.Windows.FrameworkElement)window.FindName("UpdateNotice");notice.DataContext=updates;
        notice.Visibility=updates.HasUpdate ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        updates.PropertyChanged+=(_,_)=>notice.Visibility=updates.HasUpdate ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        Set("editStore",new EditStore(Path.Combine(root,"edits")));
        Set("batchJournal",new BatchJournal(Path.Combine(root,"batch")));
        var library=typeof(MainWindow).GetField("library",flags)!.GetValue(window)!;
        library.GetType().GetField("settingsPath",flags)!.SetValue(library,Path.Combine(root,"folders.json"));
        ((System.Collections.IList)library.GetType().GetProperty("Roots")!.GetValue(library)!).Clear();
    }
}
