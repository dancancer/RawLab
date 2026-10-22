using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly HashSet<ContextMenu> viewingMenus=[];
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
        if(file==null || exporting || closing || !semanticAction && ViewInputBlocked || !view.BeginHold(transform.Active))return;
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
    private void ViewKeyReleased(object sender,KeyEventArgs e)
    {if(e.Key==Key.Oem5){EndHoldingBefore();e.Handled=true;}}
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
        ClipStats.Text=shown?.Histogram.Length==768 ? Loc.Format("暗部 {0:P1}   高光 {1:P1} · 显示图统计",shown.Shadows,shown.Highlights) : "";
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
    }
}
