using System.Windows;
using System.Windows.Input;
using System.Windows.Controls;
using System.Windows.Automation;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly WorkspaceLayout workspaceLayout=new();
    private bool resizingDock;
    private bool histogramCompact;
    private bool histogramExpanded=true;
    private void RefreshUnavailableToolReasons()
    {
        var hdr=settings.IsHDREditing;
        var raster=file!=null && LibraryEntry.IsRaster(file);
        foreach(var button in Tools.Children.OfType<Button>()) {
            string? reason=null;
            if(file!=null && !exporting) {
                if(hdr && !button.IsEnabled)reason="HDR 模式暂不支持此工具。";
                else if(ReferenceEquals(button,LensCategory) && PhotoInput.IsNormalX3f(file,settings))reason="此输入不支持镜头校正";
                else if(ReferenceEquals(button,LensCategory) && raster)reason="仅 RAW 照片支持镜头校正。";
                else if(ReferenceEquals(button,WhiteBalanceCategory) && !hdr && settings.AsShot==null)reason="此照片没有可用的相机白平衡校准。";
            }
            AutomationProperties.SetHelpText(button,reason==null ? "" : Loc.Text(reason));
            ToolTipService.SetShowOnDisabled(button,true);
            if(reason!=null)button.ToolTip=Loc.Text(reason);
            else if(ReferenceEquals(button,GeometryCategory))button.SetResourceReference(ToolTipProperty,"裁切、旋转、翻转和拉直");
            else if(ReferenceEquals(button,LensCategory))button.SetResourceReference(ToolTipProperty,"镜头匹配");
            else if(ReferenceEquals(button,FilmCategory))button.SetResourceReference(ToolTipProperty,"选择胶片模拟");
            else if(ReferenceEquals(button,MasterRecipeCategory))button.SetResourceReference(ToolTipProperty,"选择大师配方");
            else button.ToolTip=AutomationProperties.GetName(button);
        }
    }
    private void InitializeWorkspace()
    {
        SizeChanged+=(_,_)=>RefreshWorkspace();
        library.Roots.CollectionChanged+=(_,_)=>RefreshWorkspace();
        AdjustmentSplitter.DragStarted+=(_,_)=>resizingDock=true;
        AdjustmentSplitter.DragCompleted+=(_,_)=>{workspaceLayout.Resize(DockRow.ActualHeight,EditorArea.ActualHeight);resizingDock=false;UpdateDockMinimum();};
        AdjustmentSplitter.KeyUp+=(_,e)=>{
            if(e.Key is Key.Up or Key.Down){workspaceLayout.Resize(DockRow.ActualHeight,EditorArea.ActualHeight);UpdateDockMinimum();}
        };
        Loaded+=(_,_)=>RefreshWorkspace();
    }
    private void RefreshWorkspace()
    {
        var show=workspaceLayout.ShowsFiles(ActualWidth,library.Roots.Count>0);
        SetFileTreeVisible(show);
        UpdateDockMinimum();RefreshHistogramWorkspace();
    }
    private void SetFileTreeVisible(bool show)
    {
        if(show==(LibraryPanel.Visibility==Visibility.Visible))return;
        if(!show)libraryWidth=LibraryColumn.ActualWidth>0 ? LibraryColumn.ActualWidth : libraryWidth;
        LibraryPanel.Visibility=LibrarySplitter.Visibility=show ? Visibility.Visible : Visibility.Collapsed;
        LibraryColumn.MinWidth=show ? 180 : 0;LibraryColumn.Width=new(show ? libraryWidth : 0);
        LibrarySplitterColumn.Width=new(show ? 5 : 0);LibraryToggleButton.Tag=show ? "selected" : null;
        QueueThumbnailRefresh();
    }
    private void RestoreAutomaticPanel(object sender,RoutedEventArgs e){workspaceLayout.RestoreAutomatic();UpdateDockMinimum();}
    private void RefreshHistogramWorkspace()
    {
        if(PhotoArea.ActualWidth<=0 || PhotoArea.ActualHeight<=0)return;
        var compact=WorkspaceLayout.CompactHistogram(PhotoArea.ActualWidth,PhotoArea.ActualHeight);
        if(compact!=histogramCompact)
        {
            HistogramPopup.IsOpen=false;
            if(compact){HistogramHost.Children.Remove(HistogramPanel);HistogramPopupContent.Child=HistogramPanel;}
            else{HistogramPopupContent.Child=null;HistogramHost.Children.Add(HistogramPanel);}
            histogramCompact=compact;
        }
        HistogramSurface.Width=compact ? 48 : 220;
        HistogramPanel.Visibility=compact || histogramExpanded ? Visibility.Visible : Visibility.Collapsed;
        RefreshStateToolTips();
    }
}
