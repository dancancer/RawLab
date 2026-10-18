using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using RawLab.Windows;

internal static class CopyCompletionChecks
{
    private const BindingFlags Instance=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(MainWindow window,string language,Action<bool,string> check)
    {
        void Refresh()=>typeof(MainWindow).GetMethod("RefreshCopyLabels",Instance)!.Invoke(window,null);
        void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Refresh();
        foreach(var (button,direction,group) in new[] {
            (window.FilmScrollLeft,"向左滚动{0}","胶片"),(window.FilmScrollRight,"向右滚动{0}","胶片"),
            (window.RecipeScrollLeft,"向左滚动{0}","大师配方"),(window.RecipeScrollRight,"向右滚动{0}","大师配方") })
        {
            var expected=Loc.Format(direction,Loc.Text(group));
            check(AutomationProperties.GetName(button)==expected && Equals(button.ToolTip,expected),
                "Scroll direction and group are localized together: "+language);
        }
        check(Equals(window.ExportJpeg.Header,Loc.Text("JPEG…")) && Equals(window.ExportPng.Header,Loc.Text("PNG · 16-bit…")) &&
              ExportFormat.Jpeg.Title()=="JPEG" && ExportFormat.Png.Title()==Loc.Text("16-bit PNG"),
            "Export action labels are separate from bare file filter names: "+language);
        foreach(var (status,expected) in new[] {
            (1,"参数或输出路径无效。"),(2,"不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。") })
        {
            try { Native.Check(status);check(false,"Native error is rejected"); }
            catch(InvalidOperationException error) { check(error.Message==Loc.Text(expected),"Accurate native status message: "+language); }
        }
        var histogram=window.HistogramPanel.Visibility;
        var surface=window.HistogramSurface.Visibility;
        var panel=window.AdjustmentPanel.Visibility;
        var splitter=window.AdjustmentSplitter.Visibility;
        var file=typeof(MainWindow).GetField("file",Instance)!;
        var previous=file.GetValue(window);
        try
        {
            check(window.HistogramSurface.Visibility==Visibility.Collapsed && window.HistogramButton.ToolTip==null,
                "No result exposes no hidden-histogram action tooltip");
            window.HistogramSurface.Visibility=Visibility.Visible;
            window.HistogramPanel.Visibility=Visibility.Visible;Refresh();
            check(Equals(window.HistogramButton.ToolTip,Loc.Text("收起直方图")),"Visible histogram offers collapse");
            Click(window.HistogramButton);
            check(Equals(window.HistogramButton.ToolTip,Loc.Text("展开直方图")),"Hidden histogram offers expand");
            typeof(MainWindow).GetMethod("UpdateBusy",Instance)!.Invoke(window,null);
            check(window.HistogramSurface.Visibility==Visibility.Collapsed && window.HistogramButton.ToolTip==null,
                "Losing a render result clears the previously visible histogram action");
            file.SetValue(window,"copy-completion-test.ARW");
            window.AdjustmentPanel.Visibility=Visibility.Collapsed;Refresh();
            check(Equals(window.AdjustToggleButton.ToolTip,Loc.Text("展开调整栏")),"Hidden adjustments offer expand");
            Click(window.AdjustToggleButton);
            check(Equals(window.AdjustToggleButton.ToolTip,Loc.Text("收起调整栏")),"Visible adjustments offer collapse");
            Click(window.AdjustToggleButton);
            check(Equals(window.AdjustToggleButton.ToolTip,Loc.Text("展开调整栏")),"Adjustment action follows the second toggle");
        }
        finally
        {
            file.SetValue(window,previous);
            window.HistogramPanel.Visibility=histogram;
            window.HistogramSurface.Visibility=surface;
            window.AdjustmentPanel.Visibility=panel;
            window.AdjustmentSplitter.Visibility=splitter;
            Refresh();
        }
        check(AutomationProperties.GetName(window.ResetAllButton)==Loc.Text("重置调整"),"Reset icon names adjustments");
    }
}
