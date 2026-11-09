using System.IO;
using System.Windows;
using Velopack;

namespace RawLab.Windows;

internal static class Program
{
    [STAThread]
    public static void Main()
    {
        VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
        Loc.Initialize();
        var paths = SystemPhotoOpen.Paths(Environment.GetCommandLineArgs().Skip(1));
        var pipeName = SystemPhotoOpen.PipeName(UpdateStore.DefaultDirectory);
        try
        {
            using var lease = SystemPhotoOpen.AcquireOrForwardAsync(UpdateStore.DefaultDirectory, pipeName, paths).GetAwaiter().GetResult();
            if (lease == null) return;
            var app = new App(); app.InitializeComponent();
            app.EnqueueSystemPhotos(paths);
            using var server = new SystemPhotoOpenServer(pipeName, app.EnqueueSystemPhotos);
            app.Run();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            var message = error.Message == "other_instance"
                ? Loc.Text("请先退出其他 RawLab 实例")
                : Loc.Text("请保留现有应用和数据，处理问题后重新启动。");
            MessageBox.Show(message + "\n" + error.Message, "RawLab");
        }
    }
}
