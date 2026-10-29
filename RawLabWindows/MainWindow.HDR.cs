using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private HDRSourceInfo? hdrSource;
    private bool hdrSdrPreview, hdrFalseColor;
    private readonly DispatcherTimer hdrDisplayTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<HDRFloatImage, BitmapSource> hdrFalseColorCache = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<HDRFloatImage> hdrFalseColorPending = new(ReferenceEqualityComparer.Instance);
    private int hdrPresentationRevision;
    private CancellationTokenSource hdrPresentationCancellation = new();
    private HDRRenderedPair? hdrPresentationResult, hdrPresentationReference;
    private float hdrPresentationHeadroom = 1;

    private void InitializeHDRPresentation()
    {
        LayoutUpdated += (_, _) => RefreshHDRPresentation();
        hdrDisplayTimer.Tick += (_, _) => {
            ResultHDRSurface.RefreshCapabilities(); NeutralHDRSurface.RefreshCapabilities();
            var headroom = ResultHDRSurface.Headroom;
            if (headroom != hdrPresentationHeadroom) {
                hdrPresentationHeadroom = headroom; InvalidateHDRFalseColor(); RefreshViewingFrames();
            } else RefreshHDRPresentation();
        };
        Closed += (_, _) => { hdrDisplayTimer.Stop(); InvalidateHDRFalseColor(); };
    }
    private void InvalidateHDRFalseColor()
    {
        hdrPresentationRevision++; hdrPresentationCancellation.Cancel();hdrPresentationCancellation.Dispose();hdrPresentationCancellation=new();
        hdrFalseColorCache.Clear(); hdrFalseColorPending.Clear();
    }
    private void PrepareHDRFrames()
    {
        if (!ReferenceEquals(hdrPresentationResult,result?.HDR) || !ReferenceEquals(hdrPresentationReference,neutralResult?.HDR)) {
            hdrPresentationResult=result?.HDR; hdrPresentationReference=neutralResult?.HDR; InvalidateHDRFalseColor();
        }
    }
    private BitmapSource? HDRPresentationBitmap(RenderedImage? frame)
    {
        var image=frame?.HDR?.HDR;
        if (!hdrFalseColor || !settings.IsHDREditing || image==null) return frame?.Image;
        if (hdrFalseColorCache.TryGetValue(image,out var bitmap)) return bitmap;
        if (hdrFalseColorPending.Add(image)) {
            var revision=hdrPresentationRevision; var headroom=hdrPresentationHeadroom;
            var cancellation=hdrPresentationCancellation.Token;
            _=Task.Run(()=>HDRDisplay.FalseColor(image,headroom,cancellation),cancellation).ContinueWith(task=>Dispatcher.InvokeAsync(()=> {
                if(revision!=hdrPresentationRevision)return;
                hdrFalseColorPending.Remove(image);
                if(task.IsCompletedSuccessfully) { hdrFalseColorCache[image]=task.Result; RefreshViewingFrames(); }
                else if(task.Exception!=null) Report(task.Exception.GetBaseException());
            }),TaskScheduler.Default);
        }
        return frame?.Image;
    }
    private void RefreshHDRPresentation()
    {
        if (!IsLoaded) return;
        var active=settings.IsHDREditing && result?.HDR!=null;
        if(active && !hdrDisplayTimer.IsEnabled) {
            ResultHDRSurface.RefreshCapabilities();NeutralHDRSurface.RefreshCapabilities();hdrDisplayTimer.Start();
        } else if(!active)hdrDisplayTimer.Stop();
        var overlays=new FrameworkElement[]{NeutralLabel,FilmLabel,InfoEntryButton,InfoOverlay,HistogramSurface,BusyIndicator,HslTargetBanner};
        var resultPresented=false;
        void Present(HDRSurface surface,PhotoCanvas canvas,HDRFloatImage? image,HDRFloatImage? reference) {
            Grid.SetRow(surface,Grid.GetRow(canvas));Grid.SetColumn(surface,Grid.GetColumn(canvas));
            Grid.SetRowSpan(surface,Grid.GetRowSpan(canvas));Grid.SetColumnSpan(surface,Grid.GetColumnSpan(canvas));
            surface.Visibility=active && !hdrSdrPreview && surface.Available && !canvas.GeometryEditing && !canvas.ShowClipping
                ? canvas.Visibility : Visibility.Collapsed;
            var presented=surface.ShowFrame(active ? image : null,reference,canvas,hdrSdrPreview,hdrFalseColor,overlays);
            if(ReferenceEquals(surface,ResultHDRSurface))resultPresented=presented;
        }
        var reference=ReferenceCurrent ? neutralResult?.HDR?.HDR : null;
        Present(ResultHDRSurface,ResultCanvas,result?.HDR?.HDR,reference);
        Present(NeutralHDRSurface,NeutralCanvas,reference,null);
        var shown=view.HoldingBefore && ReferenceCurrent ? neutralResult?.HDR : result?.HDR;
        Histogram.HDRBins=active ? shown?.Statistics.Bins : null;
        Histogram.HDRHeadroom=ResultHDRSurface.Headroom;Histogram.InvalidateVisual();
        if(active && shown!=null) {
            HistogramTitle.Text=Loc.Text("HDR 亮度直方图");
            HistogramSource.Text=Loc.Text(hdrFalseColor ? "HDR 假色" : hdrSdrPreview ? "SDR 兼容预览" : resultPresented ? "自动 HDR" : "HDR 显示不可用，当前显示 SDR。");
            ClipStats.Text=Loc.Format("参考白以上 {0}",shown.Statistics.AboveWhite.ToString("P1",System.Globalization.CultureInfo.CurrentCulture));
        } else HistogramTitle.Text=Loc.Text("RGB 直方图");
    }

    private void RefreshHDRControls()
    {
        HDREditMenu.IsEnabled = file != null && hdrSource != null && !exporting && !transform.Active && !adjustmentReloadRequired;
        HDREditMenu.IsChecked = settings.IsHDREditing;
        HDRPreviewMenu.IsEnabled = HDRSdrPreviewMenu.IsEnabled = HDRFalseColorMenu.IsEnabled = settings.IsHDREditing;
        HDRPreviewMenu.IsChecked = !hdrSdrPreview; HDRSdrPreviewMenu.IsChecked = hdrSdrPreview;
        HDRFalseColorMenu.IsChecked = hdrFalseColor;
    }

    private void HDREditClicked(object sender, RoutedEventArgs e)
    {
        if (file == null || hdrSource == null) { RefreshHDRControls(); return; }
        CancelParameterInputs();
        if (!ResolveTransformDraft() || !SaveEdits()) { RefreshHDRControls(); return; }
        var before = settings;
        try {
            var candidate = settings.Clone();
            if (HDREditMenu.IsChecked && lut != null && candidate.HDR == null)
                throw new HDRModeException(HDRModeFailure.Conflicts, ["look"]);
            candidate.SetHDRMode(HDREditMenu.IsChecked, true);
            settings = candidate; MarkEdited();
            if (!SaveEdits()) { settings = before; RefreshControls(); return; }
            RefreshControls(); Schedule();
        } catch (Exception error) { settings = before; RefreshControls(); Report(error); }
    }

    private void HDRPreviewClicked(object sender, RoutedEventArgs e) { hdrSdrPreview = false; RefreshHDRControls(); RefreshViewingFrames(); }
    private void HDRSdrPreviewClicked(object sender, RoutedEventArgs e) { hdrSdrPreview = true; RefreshHDRControls(); RefreshViewingFrames(); }
    private void HDRFalseColorClicked(object sender, RoutedEventArgs e) { hdrFalseColor = HDRFalseColorMenu.IsChecked; RefreshViewingFrames(); }
}
