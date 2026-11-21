using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using RawLab.Windows;

internal static class CopyCompletionChecks
{
    internal static void Run(MainWindow window,string language,Action<bool,string> check)
    {
        void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        window.RefreshCopyLabelsForTests();
        foreach (var (button, title) in new[] {
            (window.EditingWorkspaceButton, "编辑"), (window.SelectionWorkspaceButton, "选片"), (window.PreviewWorkspaceButton, "纯预览") })
            check(AutomationProperties.GetName(button) == Loc.Text(title), "Workspace tab uses the selected language: " + language);
        check(Equals(window.ExportJpeg.Header,Loc.Text("JPEG…")) && Equals(window.ExportPng.Header,Loc.Text("PNG · 16-bit…")) &&
              ExportFormat.Jpeg.Title()=="JPEG" && ExportFormat.Png.Title()==Loc.Text("16-bit PNG"),
            "Export action labels are separate from bare file filter names: "+language);
        foreach(var (status,expected) in new[] {
            (1,"参数或输出路径无效。"),(2,"不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。") })
        {
            try { Native.CheckWithoutSession(status);check(false,"Native error is rejected"); }
            catch(InvalidOperationException error) { check(error.Message==Loc.Text(expected),"Accurate native status message: "+language); }
        }
        check(Native.FormatErrorMessage(2, null, Native.UnsupportedReason.ForceGpu) ==
              Loc.Text("当前照片、外观或处理方式不支持强制 GPU，可切换为自动（Auto）回退。"),
            "Force GPU unsupported status uses its dedicated localized message: " + language);
        check(window.HistogramSurface.Visibility == Visibility.Collapsed && window.HistogramButton.ToolTip == null,
            "No result exposes no hidden-histogram action tooltip");
        var previous = window.CurrentFile;
        try
        {
            window.CurrentFile = "copy-completion-test.ARW";
            window.RefreshWorkspaceForTests();
            check(Equals(window.AdjustToggleButton.ToolTip, Loc.Text("收起调整栏")), "Visible adjustments offer collapse");
            Click(window.AdjustToggleButton);
            check(Equals(window.AdjustToggleButton.ToolTip, Loc.Text("展开调整栏")), "Hidden adjustments offer expand");
            Click(window.AdjustToggleButton);
            check(Equals(window.AdjustToggleButton.ToolTip, Loc.Text("收起调整栏")), "Adjustment action follows the second toggle");
        }
        finally
        {
            window.CurrentFile = previous;
            window.RefreshWorkspaceForTests();
        }
        check(AutomationProperties.GetName(window.ResetAllButton)==Loc.Text("重置调整"),"Reset icon names adjustments");
    }
}
