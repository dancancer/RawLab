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
        try
        {
            using var lease = new UpdateRunLease(UpdateStore.DefaultDirectory);
            var app = new App(); app.InitializeComponent(); app.Run();
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
