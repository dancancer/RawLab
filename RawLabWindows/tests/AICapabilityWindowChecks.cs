using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using RawLab.Windows;

internal static class AICapabilityWindowChecks
{
    internal static void Run(string raw,string output,bool hardwareExpected,Action<bool,string> check)
    {
        var app=Application.Current ?? TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new System.Windows.Threading.DispatcherSynchronizationContext());
        var window=new MainWindow(new UsageAnalytics());TestWindowState.Isolate(window,output);window.Show();
        try {
            window.GpuMode.SelectedIndex=1;window.OpenFile(raw);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var toggle=(CheckBox)window.DenoiseEditor.FindName("AIEnabledBox");
            var status=(TextBlock)window.DenoiseEditor.FindName("AIStatus");
            check(toggle.IsEnabled==hardwareExpected,"AI toggle reflects the machine's hardware D3D12 capability before preparation");
            check(status.Text.Contains(Loc.Text(hardwareExpected ? "普通显影使用 CPU；AI 降噪仍使用硬件 GPU。" : "AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。")),
                "AI panel explains the hardware requirement in the current language");
            if(hardwareExpected) {
                var backend=typeof(MainWindow).GetProperty("RequestedAIBackend",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(window);
                check(Equals(backend,2),"CPU photo rendering still selects GPU Auto for AI");
                window.GpuMode.SelectedIndex=0;
                check(!status.Text.Contains(Loc.Text("普通显影使用 CPU；AI 降噪仍使用硬件 GPU。")),"Changing the photo backend refreshes the AI explanation immediately");
            }
        } finally {window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);app.Shutdown();}
    }
}
