using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Automation;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RawLab.Windows;
public partial class MainWindow
{
    private void CompareClicked(object sender,RoutedEventArgs e)
    {if(compare)SetComparisonMode(false,false);else SetComparisonMode(true,view.PreferredMode==ComparisonMode.Wipe);}
    private void ExportMenuClicked(object sender,RoutedEventArgs e)=>ZoomClicked(sender,e);
    private void CompareOffClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(false,false);
    private void CompareSideClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,false);
    private void CompareSwipeClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,true);
    internal void SetComparisonMode(bool enabled,bool sliding)
    {
        if(transform.Active || file==null || exporting){RefreshComparisonSelection();return;}
        CancelViewingInput();
        if(enabled)view.Select(sliding ? ComparisonMode.Wipe : ComparisonMode.SideBySide);else view.SetEnabled(false);
        RefreshComparisonLayout();RefreshComparisonToolTip();RefreshControls();RefreshViewingFrames();
        if(view.NeedsReference && !ReferenceCurrent)Schedule();
    }
    private void RefreshComparisonSelection()
    {

        CompareOff.IsChecked=MenuCompareOff.IsChecked=!compare;
        CompareSide.IsChecked=MenuCompareSide.IsChecked=compare && !swipe;
        CompareSwipe.IsChecked=MenuCompareSwipe.IsChecked=swipe;
        CompareButton.Tag=compare ? "selected" : null;
        AutomationProperties.SetItemStatus(CompareButton,Loc.Text(!compare ? "关闭对比" : swipe ? "分割线" : "并排"));
        CompareButton.ToolTip=Loc.Text(compare ? "关闭对比" : "开启对比");AutomationProperties.SetName(CompareButton,(string)CompareButton.ToolTip);
        BeforeViewMenu.IsChecked=view.HoldingBefore;
        BeforeViewMenu.Header=Loc.Text(view.HoldingBefore ? "返回调整后" : "查看调整前");
        BeforeViewMenu.IsEnabled=file!=null && !transform.Active && !compare && !exporting;
        CompareModeButton.IsEnabled=CompareButton.IsEnabled;
        CompareOff.IsEnabled=CompareSide.IsEnabled=CompareSwipe.IsEnabled=MenuCompareOff.IsEnabled=MenuCompareSide.IsEnabled=MenuCompareSwipe.IsEnabled=file!=null && !transform.Active && !exporting;
    }
    private void RefreshComparisonLayout()
    {
        var sideBySide=file!=null && compare && !swipe;
        var vertical=sideBySide && PhotoArea.ActualHeight>PhotoArea.ActualWidth;
        NeutralCanvas.Visibility=sideBySide ? Visibility.Visible : Visibility.Collapsed;
        NeutralColumn.Width=sideBySide && !vertical ? new(1,GridUnitType.Star) : new(0);
        NeutralRow.Height=vertical ? new(1,GridUnitType.Star) : new(0);
        Grid.SetRow(NeutralCanvas,vertical ? 0 : 1);Grid.SetRow(ResultCanvas,1);
        Grid.SetColumn(NeutralCanvas,vertical ? 1 : 0);
        ResultCanvas.ComparisonEnabled=file!=null && swipe && ReferenceCurrent;
        RefreshPhotoLabels();
    }
    private void RefreshComparisonToolTip() => ResultCanvas.ToolTip=file==null ? null : swipe ? Loc.Text("拖动分隔线对比；方向键微调，Home 居中。拖动照片平移，滚轮缩放。") : Loc.Text("拖动平移，滚轮缩放，双击适合窗口。");
    private void RefreshCopyLabels()
    {
        ExportJpeg.Header=Loc.Text("JPEG…");
        ExportPng.Header=Loc.Text("PNG · 16-bit…");
        foreach(var (button,direction,group) in new[] {
            (FilmScrollLeft,"向左滚动{0}","胶片"),(FilmScrollRight,"向右滚动{0}","胶片"),
            (RecipeScrollLeft,"向左滚动{0}","大师配方"),(RecipeScrollRight,"向右滚动{0}","大师配方") })
        {
            var label=Loc.Format(direction,Loc.Text(group));
            button.ToolTip=label;
            AutomationProperties.SetName(button,label);
        }
        RefreshStateToolTips();
    }
    private void RefreshStateToolTips()
    {
        HistogramButton.ToolTip=HistogramSurface.Visibility==Visibility.Visible ?
            Loc.Text(HistogramPanel.Visibility==Visibility.Visible ? "收起直方图" : "展开直方图") : null;
        AdjustToggleButton.ToolTip=Loc.Text(AdjustmentPanel.Visibility==Visibility.Visible ? "收起调整栏" : "展开调整栏");
    }
    private EditorAdjustmentTool? hiddenTransformTool;
    private void DockToggle(object sender,RoutedEventArgs e)
    {
        if(file==null || pendingAllReset!=null)return;
        CancelParameterInputs();
        var visible=AdjustmentPanel.Visibility==Visibility.Visible;
        if(visible) {
            var previousTool=transform.Active ? CurrentTool : (EditorAdjustmentTool?)null;
            var previousGroup=expandedGroup;
            if(!ResolveTransformDraft())return;
            hiddenTransformTool=previousTool;expandedGroup=previousGroup;
        } else if(hiddenTransformTool is {} tool) {
            hiddenTransformTool=null;SelectTool(tool);
        }
        if(visible && expandedGroup!=null)dockHeight=DockRow.ActualHeight;
        AdjustmentPanel.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        AdjustmentSplitter.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        DockRow.MinHeight=visible || expandedGroup==null ? 0 : 216;
        DockRow.Height=visible ? new(0) : expandedGroup==null ? GridLength.Auto : new(dockHeight);
        AdjustmentSplitter.Visibility=visible || expandedGroup==null ? Visibility.Collapsed : Visibility.Visible;
        SplitterRow.Height=new(visible || expandedGroup==null ? 0 : 6);
        RefreshControls();
        RefreshStateToolTips();
        UpdateDockMinimum();
    }
    private void UpdateDockMinimum()
    {
        if(AdjustmentPanel.Visibility==Visibility.Visible && expandedGroup!=null && EditorArea.ActualHeight>0)
        {
            DockRow.MinHeight=216;
            DockRow.MaxHeight=Math.Max(216,EditorArea.ActualHeight-166);
            if(DockRow.Height.Value>DockRow.MaxHeight)DockRow.Height=new(DockRow.MaxHeight);
        }
    }
    private void HistogramClicked(object sender,RoutedEventArgs e)
    {
        HistogramPanel.Visibility=HistogramPanel.Visibility==Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        RefreshStateToolTips();
    }
    private void ClippingClicked(object sender,RoutedEventArgs e) { clipping=!clipping;NeutralCanvas.ShowClipping=ResultCanvas.ShowClipping=clipping;NeutralCanvas.InvalidateVisual();ResultCanvas.InvalidateVisual();RefreshControls();Schedule(); }
    // 工具栏下拉菜单贴着按钮下沿弹出；默认的 MousePoint 在键盘打开时会跑到鼠标所在的任意位置
    private void ZoomClicked(object sender,RoutedEventArgs e) { if(sender is Button button && button.ContextMenu is {} menu){menu.PlacementTarget=button;menu.Placement=PlacementMode.Bottom;menu.IsOpen=true;} }
    private void FitClicked(object sender,RoutedEventArgs e) {CancelViewingInput();if(!transform.Active)viewport.Fit();}
    private void ActualClicked(object sender,RoutedEventArgs e) {CancelViewingInput();if(!transform.Active)viewport.Actual();}
    private void ZoomInClicked(object sender,RoutedEventArgs e) {CancelViewingInput();if(!transform.Active)viewport.Magnify(1.25);}
    private void ZoomOutClicked(object sender,RoutedEventArgs e) {CancelViewingInput();if(!transform.Active)viewport.Magnify(.8);}
    private void KeyPressed(object sender,KeyEventArgs e)
    {
        if(e.OriginalSource is TextBoxBase or ComboBox || Keyboard.FocusedElement is TextBoxBase or ComboBox)return;
        if((e.Key is Key.I or Key.Oem5) && (ViewInputBlocked || Keyboard.Modifiers!=ModifierKeys.None))return;
        if(e.Key==Key.Oem5){if(!e.IsRepeat)BeginHoldingBefore();e.Handled=true;return;}
        if(e.Key==Key.O && Keyboard.Modifiers==ModifierKeys.Control)OpenClicked(sender,e);
        else if(e.Key==Key.F)FitClicked(sender,e); else if(e.Key==Key.D1)ActualClicked(sender,e);
        else if(e.Key is Key.Add or Key.OemPlus)ZoomInClicked(sender,e); else if(e.Key is Key.Subtract or Key.OemMinus)ZoomOutClicked(sender,e);
        else if(e.Key==Key.I)InfoClicked(sender,e);
    }
    private void ExportJpegClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.Jpeg);
    private void ExportPngClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.Png);
    private void ExportDngClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.RenderedDng);
    private void ExportOriginalSizeClicked(object sender,RoutedEventArgs e) { exportLongEdge=null; RefreshExportSizeMenu(); }
    private void ExportSizeClicked(object sender,RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string text } && int.TryParse(text, out var edge))
        {
            exportLongEdge=ExportSize.IsValid(edge) ? edge : null;
            RefreshExportSizeMenu();
        }
    }
    private void ExportCustomSizeClicked(object sender,RoutedEventArgs e)
    {
        var value=LongEdgeDialog.Show(this,exportLongEdge);
        if (value is not null) { exportLongEdge=value; RefreshExportSizeMenu(); }
    }
    private void RefreshExportSizeMenu()
    {
        if (ExportOriginalSize == null) return;
        ExportOriginalSize.IsChecked=exportLongEdge == null;
        ExportSize2048.IsChecked=exportLongEdge == 2048;
        ExportSize3000.IsChecked=exportLongEdge == 3000;
        ExportSize4096.IsChecked=exportLongEdge == 4096;
        ExportCustomSize.IsChecked=exportLongEdge.HasValue && exportLongEdge != 2048 && exportLongEdge != 3000 && exportLongEdge != 4096;
        ExportCustomSize.Header=ExportCustomSize.IsChecked == true ? Loc.Format("自定义 {0} px", exportLongEdge) : Loc.Text("自定义…");
    }
    private async void Export(ExportFormat format)
    {
        if(!exactReady || scheduler.Busy || previewResize.IsEnabled || exporting || file==null || engine==null)return;
        var suffix=format.Suffix();
        var dialog=new SaveFileDialog{Title=Loc.Text("导出"),Filter=format switch {
                ExportFormat.Jpeg => format.Title()+"|*.jpg;*.jpeg",
                ExportFormat.Png => format.Title()+"|*.png",
                ExportFormat.RenderedDng => Loc.Text("DNG · 渲染型")+"|*.dng",
                _ => throw new ArgumentOutOfRangeException(nameof(format))
            },DefaultExt="."+suffix,AddExtension=true,OverwritePrompt=true,
            FileName=Path.GetFileNameWithoutExtension(file)+"-"+LookTitle};
        dialog.FileOk += (_, args) => {
            if (!format.AcceptsPath(dialog.FileName))
            {
                args.Cancel = true;
                MessageBox.Show(this, Loc.Format("请选择 {0} 文件扩展名。", format.Title()), Loc.Text("导出"),
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        if(dialog.ShowDialog(this)!=true)return;
        await ExportPhoto(format,dialog.FileName);
    }
    internal async Task ExportPhoto(ExportFormat format,string destination)
    {
        if(!exactReady || scheduler.Busy || previewResize.IsEnabled || exporting || file==null || engine==null || closing)return;
        if(Path.GetFullPath(destination).Equals(Path.GetFullPath(file),StringComparison.OrdinalIgnoreCase)){SetStatus(() => Loc.Text("不能覆盖原始文件。"),true);return;}
        var input=file;var adjustment=settings.Clone();var film=lut;
        // Render to a sibling temporary file, then replace only after encoding succeeds.
        var temp=Path.Combine(Path.GetDirectoryName(destination)!,".rawlab-"+Guid.NewGuid().ToString("N")+"."+format.Suffix());
        var size=exportLongEdge;
        foregroundBusy=true;RefreshControls();SetStatus(() => Loc.Text("正在导出…"));
        try
        {
            using var sourceLock = WindowsFileIdentity.OpenReadLock(input);
            if (WindowsFileIdentity.IsSameFile(sourceLock, destination))
            {
                SetStatus(() => Loc.Text("不能覆盖原始文件。"), true);
                return;
            }
            await Task.Run(()=>engine.Render(input,adjustment,film,0,false,temp,longEdge:size));
            if (WindowsFileIdentity.IsSameFile(sourceLock, destination))
            {
                SetStatus(() => Loc.Text("不能覆盖原始文件。"), true);
                return;
            }
            File.Move(temp,destination,true);
            usageAnalytics.Record(new ExportCompletedEvent());
            lastExportedPath=destination;ExportRevealButton.Visibility=Visibility.Visible;
            SetStatus(() => Loc.Format("已导出（{0}）：{1}", (engine.LastBackend==3 ? "Direct3D 11" : "CPU"), destination));
        }
        catch(Exception ex){Report(ex);}
        finally {try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){} foregroundBusy=false;RefreshControls();if(closing)FinishClose();else ResumePreview();}
    }
    private static bool IsBuiltInLook(string path) => StringComparer.OrdinalIgnoreCase.Equals(
        Path.GetFullPath(Path.GetDirectoryName(path) ?? ""), Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "LUTs")));
    private void WindowClosing(object? sender,CancelEventArgs e)
    {
        CancelParameterInputs();CancelViewingInput();
        if(!ResolveTransformDraft() || !SaveEdits()){e.Cancel=true;return;}
        closing=true;
        previewResize.Stop();
        if(batchWindow is {} batch)
        {
            batch.Close();
            if(batch.IsVisible && !batch.Busy){e.Cancel=true;RecoverFailedClose(batch);return;}
        }
        thumbnailRefresh.Stop();foreach(var entry in visibleThumbnails)entry.ReleaseThumbnail();visibleThumbnails.Clear();
        if(scheduler.Busy || exporting){e.Cancel=true;closing=true;IsEnabled=false;SetStatus(() => Loc.Text("正在完成当前任务后关闭…"));return;}
        e.Cancel = true;
        Dispatcher.BeginInvoke(new Action(FinishClose));
    }
    private async void FinishClose()
    {
        // 关闭时不再启动排队预览，只等待实际运行的 worker 释放引擎。
        if (closeFinished || analyticsDisposed || scheduler.Active!=null || exporting) return;
        analyticsDisposed = true;
        IsEnabled = false;
        // 离线时 SDK 关闭可能一直等网络：最多等 ShutdownLimit，之后照常退出
        await usageAnalytics.CloseAsync(UsageAnalytics.ShutdownLimit);
        closeFinished=true;engine?.Dispose();engine=null;Closing-=WindowClosing;Close();
    }
}
