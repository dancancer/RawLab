using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly HashSet<ContextMenu> viewingMenus=[];
    private bool beforeKeyDown;
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    // 窗口外松键不会清掉 WPF 的 repeat 缓存；激活和焦点恢复时以真实键状态同步。
    private void SyncBeforeKeyState()=>beforeKeyDown=(GetAsyncKeyState(0xdc)&0x8000)!=0;
    static MainWindow()
    {
        EventManager.RegisterClassHandler(typeof(ContextMenu),ContextMenu.OpenedEvent,new RoutedEventHandler(ViewContextMenuChanged),true);
        EventManager.RegisterClassHandler(typeof(ContextMenu),ContextMenu.ClosedEvent,new RoutedEventHandler(ViewContextMenuChanged),true);
    }
    private static void ViewContextMenuChanged(object sender,RoutedEventArgs e)
    {
        if(sender is not ContextMenu menu || menu.PlacementTarget==null || Window.GetWindow(menu.PlacementTarget) is not MainWindow window)return;
        if(e.RoutedEvent==ContextMenu.OpenedEvent){window.viewingMenus.Add(menu);window.CancelViewingInput();}
        else window.viewingMenus.Remove(menu);
    }
    private OriginalIdentity? CurrentViewSource
    {
        get {if(file==null)return null;try{return OriginalIdentity.Read(file);}catch(IOException){return null;}catch(UnauthorizedAccessException){return null;}}
    }
    private bool ReferenceCurrent=>neutralResult!=null && neutralRevision==openRevision && acceptedAfter==acceptedReference &&
        NeutralReference.Matches(acceptedReference,CurrentViewSource,settings.Processing,settings.Geometry,settings.Lens,RenderEdge(interacting));
    private bool ViewInputBlocked=>Keyboard.FocusedElement is TextBoxBase or ComboBox ||
        OwnedWindows.Cast<Window>().Any(window=>window.IsVisible) ||
        MainMenu.Items.OfType<MenuItem>().Any(item=>item.IsSubmenuOpen) || viewingMenus.Count>0;
    private void PhotoAreaSizeChanged(object sender,SizeChangedEventArgs e)
    {CancelViewingInput();RefreshComparisonLayout();}
    private void CompareModeClicked(object sender,RoutedEventArgs e)=>ZoomClicked(CompareButton,e);
    private void BeforeViewClicked(object sender,RoutedEventArgs e)
    {if(view.HoldingBefore)EndHoldingBefore();else BeginHoldingBeforeCore(true);}
    private void BeginHoldingBefore()=>BeginHoldingBeforeCore(false);
    private void BeginHoldingBeforeCore(bool semanticAction)
    {
        if(hslTargetEnabled || file==null || exporting || closing || !semanticAction && ViewInputBlocked || !view.BeginHold(transform.Active))return;
        RefreshViewingFrames();RefreshComparisonSelection();
        if(!ReferenceCurrent)Schedule();
    }
    private void EndHoldingBefore()
    {
        if(!view.HoldingBefore)return;
        view.EndHold();RefreshViewingFrames();RefreshComparisonSelection();
    }
    private void CancelViewingInput()
    {
        EndHoldingBefore();ResultCanvas.CancelPointer();NeutralCanvas.CancelPointer();
    }
    private static Key ViewingKey(KeyEventArgs e)=>e.Key==Key.ImeProcessed ? e.ImeProcessedKey : e.Key;
    private void ViewKeyReleased(object sender,KeyEventArgs e)
    {if(ViewingKey(e)==Key.Oem5){beforeKeyDown=false;EndHoldingBefore();e.Handled=true;}}
    private void PhotoMarginClicked(object sender,RoutedEventArgs e)=>SetPhotoMargin(!view.PhotoMargin);
    private void SetPhotoMargin(bool enabled)
    {
        CancelViewingInput();view.PhotoMargin=enabled;
        NeutralCanvas.PhotoMargin=ResultCanvas.PhotoMargin=enabled;
        MenuPhotoMargin.IsChecked=ZoomPhotoMargin.IsChecked=enabled;
        RefreshPhotoLabels();
    }
    private void RefreshViewingFrames()
    {
        var reference=ReferenceCurrent ? neutralResult : null;
        NeutralCanvas.SetImage(reference?.Image,reference?.Clipping);
        ResultCanvas.SetComparison(reference?.Image,reference?.Clipping);
        ResultCanvas.ShowingBefore=view.HoldingBefore && reference!=null;
        var shown=view.HoldingBefore ? reference : result;
        Histogram.Bins=shown?.Histogram is { Length:768 } bins ? bins : null;Histogram.InvalidateVisual();
        HistogramSource.Text=Loc.Text(view.HoldingBefore ? "调整前" : "调整后");
        ClipStats.Text=shown?.Histogram.Length==768 ? Loc.Format("暗部 {0:P1}   高光 {1:P1} · 显示图统计",shown.Shadows,shown.Highlights) : Loc.Text("统计不可用");
        RefreshPhotoLabels();
    }
    private void RefreshPhotoLabels()
    {
        if(PhotoLabels==null || !IsLoaded)return;
        var visible=ReferenceCurrent && file!=null && (compare || view.HoldingBefore);
        NeutralLabel.Visibility=visible ? Visibility.Visible : Visibility.Collapsed;
        FilmLabel.Visibility=visible && compare ? Visibility.Visible : Visibility.Collapsed;
        if(!visible)return;
        void Place(Border label,PhotoCanvas canvas,bool right)
        {
            var bounds=canvas.VisibleImageBounds;
            if(bounds.IsEmpty || bounds.Width<24 || bounds.Height<24){label.Visibility=Visibility.Collapsed;return;}
            label.MaxWidth=Math.Max(1,bounds.Width-16);label.MaxHeight=Math.Max(1,bounds.Height-16);
            label.Measure(new Size(label.MaxWidth,label.MaxHeight));
            var point=canvas.TranslatePoint(bounds.TopLeft,PhotoLabels);
            Canvas.SetLeft(label,point.X+(right ? Math.Max(8,bounds.Width-label.DesiredSize.Width-8) : 8));
            Canvas.SetTop(label,point.Y+Math.Max(8,bounds.Height-label.DesiredSize.Height-8));
        }
        Place(NeutralLabel,compare && !swipe ? NeutralCanvas : ResultCanvas,false);
        Place(FilmLabel,ResultCanvas,swipe);
        if(swipe && NeutralLabel.Visibility==Visibility.Visible && FilmLabel.Visibility==Visibility.Visible &&
            NeutralLabel.DesiredSize.Width+FilmLabel.DesiredSize.Width+24>ResultCanvas.VisibleImageBounds.Width)
        {
            var visiblePhoto=ResultCanvas.VisibleImageBounds;
            var photo=new Rect(ResultCanvas.TranslatePoint(visiblePhoto.TopLeft,PhotoLabels),visiblePhoto.Size);
            var after=new Rect(new Point(Canvas.GetLeft(FilmLabel),Canvas.GetTop(FilmLabel)),FilmLabel.DesiredSize);
            var info=InfoEntryButton.IsVisible ? new Rect(InfoEntryButton.TranslatePoint(new Point(),PhotoLabels),InfoEntryButton.RenderSize) : Rect.Empty;
            var image=ResultCanvas.ImageBounds;
            var center=ResultCanvas.TranslatePoint(new Point(image.X+image.Width*ResultCanvas.Divider,visiblePhoto.Y+visiblePhoto.Height/2),PhotoLabels);
            var handle=new Rect(center.X-16,center.Y-16,32,32);
            foreach(var x in new[]{photo.Left+8,photo.Right-NeutralLabel.DesiredSize.Width-8})
            {
                var candidate=new Rect(new Point(x,photo.Top+8),NeutralLabel.DesiredSize);
                if(!photo.Contains(candidate) || candidate.IntersectsWith(after) || candidate.IntersectsWith(info) || candidate.IntersectsWith(handle))continue;
                Canvas.SetLeft(NeutralLabel,candidate.Left);Canvas.SetTop(NeutralLabel,candidate.Top);break;
            }
        }
    }
}
