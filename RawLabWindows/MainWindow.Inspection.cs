using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly InspectionSessionState inspection = new();
    private (int Width, int Height)? sourceNativeSize;
    private (BitmapSource Source, InspectionOverlayMode Mode, BitmapSource Transformed)? inspectionOverlayCache;
    private bool inspectionOverlayPending;

    private void InitializeInspection()
    {
        bool PointAllowed(PhotoCanvas canvas, Point point) => new FrameworkElement[]
        {
            NeutralLabel, FilmLabel, InfoOverlay, InfoEntryButton, HslTargetBanner, InspectionHud
        }.All(element => !element.IsVisible || !new Rect(element.TranslatePoint(new Point(), canvas), element.RenderSize).Contains(point));

        ResultCanvas.InspectionAllowed = p => PointAllowed(ResultCanvas, p);
        NeutralCanvas.InspectionAllowed = p => PointAllowed(NeutralCanvas, p);
        ResultCanvas.InspectionHoverChanged += pt => UpdateInspectionHover(pt);
        NeutralCanvas.InspectionHoverChanged += pt => UpdateInspectionHover(pt);
        ResultCanvas.InspectionPinRequested += pt => PinInspectionAnchor(pt.X, pt.Y);
        RefreshInspection();
    }

    private (int Width, int Height)? EffectiveInspectionSourceSize()
    {
        if (sourceNativeSize is { } size) return size;
        if (result is { } r)
        {
            var w = r.NativeWidth > 0 ? r.NativeWidth : r.Image.PixelWidth;
            var h = r.NativeHeight > 0 ? r.NativeHeight : r.Image.PixelHeight;
            return GeometryCoordinateMapper.InferSourceSize(w, h, settings.Geometry);
        }
        return null;
    }

    private void UpdateInspectionHover(Point? normPoint)
    {
        (double X, double Y)? next = normPoint is { } p ? (p.X, p.Y) : null;
        if (inspection.LiveOutputPoint == next) return;
        inspection.LiveOutputPoint = next;
        RefreshInspectionReadoutAndCursor();
    }

    private void PinInspectionAnchor(double outX, double outY)
    {
        if (EffectiveInspectionSourceSize() is not { } srcSize) return;
        var src = GeometryCoordinateMapper.OutputNormToSourceNorm(outX, outY, srcSize.Width, srcSize.Height, settings.Geometry);
        if (src is not { } s) return;
        if (inspection.PinAnchor(s.X, s.Y) != null)
        {
            var hadReference = ReferenceCurrent;
            RefreshInspection();
            if (!hadReference) Schedule();
        }
    }

    private (double X, double Y)? InspectionDisplayPoint(InspectionAnchor anchor)
    {
        if (EffectiveInspectionSourceSize() is not { } srcSize) return null;
        return GeometryCoordinateMapper.SourceNormToOutputNorm(anchor.SourceX, anchor.SourceY, srcSize.Width, srcSize.Height, settings.Geometry);
    }

    private InspectionColorSample? SampleInspectionLive(bool showingBefore)
    {
        if (transform.Active && transform.Tool == TransformTool.Geometry) return null;
        var reference = ReferenceCurrent ? neutralResult : null;
        var targetImage = showingBefore ? reference?.Image : result?.Image;
        if (targetImage == null) return null;

        if (inspection.LiveOutputPoint is { } live)
            return InspectionOverlayRenderer.SampleBitmap(targetImage, live.X, live.Y);

        if (inspection.SelectedAnchorId is { } selectedId)
        {
            var anchor = inspection.Anchors.FirstOrDefault(a => a.Id == selectedId);
            if (anchor.Id == selectedId && InspectionDisplayPoint(anchor) is { } outPt)
                return InspectionOverlayRenderer.SampleBitmap(targetImage, outPt.X, outPt.Y);
        }
        return null;
    }

    private BitmapSource? EnsureInspectionOverlayBitmap(BitmapSource? baseBitmap)
    {
        if (baseBitmap == null || inspection.Overlay == InspectionOverlayMode.None)
            return baseBitmap;
        if (inspection.Overlay == InspectionOverlayMode.NeutralGray50)
            return InspectionOverlayRenderer.CreateOverlayBitmap(baseBitmap, InspectionOverlayMode.NeutralGray50);

        if (inspectionOverlayCache is { } cached &&
            ReferenceEquals(cached.Source, baseBitmap) &&
            cached.Mode == inspection.Overlay)
            return cached.Transformed;

        if (!inspectionOverlayPending)
        {
            inspectionOverlayPending = true;
            var mode = inspection.Overlay;
            _ = Task.Run(() => InspectionOverlayRenderer.CreateOverlayBitmap(baseBitmap, mode))
                .ContinueWith(task => Dispatcher.BeginInvoke(() =>
                {
                    inspectionOverlayPending = false;
                    if (!closing && task.IsCompletedSuccessfully)
                    {
                        inspectionOverlayCache = (baseBitmap, mode, task.Result);
                        RefreshViewingFrames();
                    }
                }), TaskScheduler.Default);
        }
        return baseBitmap;
    }

    private static string OverlayModeTitle(InspectionOverlayMode mode) => mode switch
    {
        InspectionOverlayMode.SketchLuminance => Loc.Text("素描明度"),
        InspectionOverlayMode.WarmCoolBW => Loc.Text("冷暖反差黑白"),
        InspectionOverlayMode.OversaturationHeatmap => Loc.Text("过饱和熔断热力图"),
        InspectionOverlayMode.SkinHueAmplification => Loc.Text("肤色色相放大"),
        InspectionOverlayMode.NeutralGray50 => Loc.Text("50% 中性灰"),
        _ => Loc.Text("关闭观察层"),
    };

    private void RefreshInspectionReadoutAndCursor()
    {
        var showingBefore = view.HoldingBefore && ReferenceCurrent;
        var live = SampleInspectionLive(showingBefore);
        Histogram.SetLuminanceCursor(live?.Luminance);
        if (live is { } s)
        {
            InspectionSwatch.Background = new SolidColorBrush(Color.FromRgb(s.R, s.G, s.B));
            InspectionLiveReadout.Text = $"RGB {s.RgbText} · {s.HsbText}";
        }
        else
        {
            InspectionSwatch.Background = Brushes.Transparent;
            InspectionLiveReadout.Text = "RGB -- -- -- · --° --% --%";
        }
    }

    private void RefreshInspection()
    {
        if (!IsLoaded && InspectionHud == null) return;
        var hasResult = result != null && file != null;
        var geometryEditing = transform.Active && transform.Tool == TransformTool.Geometry;

        ResultCanvas.InspectionMonitorEnabled = inspection.MonitorEnabled && hasResult && !geometryEditing;
        ResultCanvas.InspectionPinMode = inspection.PinModeEnabled && hasResult && !geometryEditing;
        ResultCanvas.InspectionOverlayActive = inspection.Overlay.IsActive() && hasResult && !geometryEditing;
        NeutralCanvas.InspectionOverlayActive = inspection.Overlay.IsActive() && hasResult && !geometryEditing;

        var markers = new List<(int Index, double X, double Y, bool Selected)>();
        for (var i = 0; i < inspection.Anchors.Count; i++)
        {
            var anchor = inspection.Anchors[i];
            if (InspectionDisplayPoint(anchor) is { } pt)
                markers.Add((i + 1, pt.X, pt.Y, inspection.SelectedAnchorId == anchor.Id));
        }
        ResultCanvas.SetInspectionMarkers(markers);

        InspectionMonitorMenu.IsChecked = inspection.MonitorEnabled;
        ToolbarInspectionMonitor.IsChecked = inspection.MonitorEnabled;
        ToolbarInspectionPin.IsEnabled = hasResult && !geometryEditing && inspection.CanPinMore;
        ToolbarInspectionClear.IsEnabled = inspection.Anchors.Count > 0;
        InspectionPinModeButton.IsEnabled = hasResult && !geometryEditing && inspection.CanPinMore;
        InspectionClearAnchorsButton.Visibility = inspection.Anchors.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        var overlay = inspection.Overlay;
        MenuOverlayNone.IsChecked = ToolbarOverlayNone.IsChecked = overlay == InspectionOverlayMode.None;
        MenuOverlaySketch.IsChecked = ToolbarOverlaySketch.IsChecked = overlay == InspectionOverlayMode.SketchLuminance;
        MenuOverlayWarmCool.IsChecked = ToolbarOverlayWarmCool.IsChecked = overlay == InspectionOverlayMode.WarmCoolBW;
        MenuOverlayHeatmap.IsChecked = ToolbarOverlayHeatmap.IsChecked = overlay == InspectionOverlayMode.OversaturationHeatmap;
        MenuOverlaySkin.IsChecked = ToolbarOverlaySkin.IsChecked = overlay == InspectionOverlayMode.SkinHueAmplification;
        MenuOverlayGray50.IsChecked = ToolbarOverlayGray50.IsChecked = overlay == InspectionOverlayMode.NeutralGray50;
        InspectionGray50Button.IsEnabled = hasResult && !geometryEditing;
        InspectionOverlayButton.IsEnabled = hasResult && !geometryEditing;

        if (overlay.IsActive())
        {
            InspectionOverlayBanner.Visibility = Visibility.Visible;
            InspectionOverlayLabel.Text = OverlayModeTitle(overlay);
        }
        else
        {
            InspectionOverlayBanner.Visibility = Visibility.Collapsed;
        }

        InspectionAnchorsPanel.Children.Clear();
        var reference = ReferenceCurrent ? neutralResult : null;
        for (var i = 0; i < inspection.Anchors.Count; i++)
        {
            var anchor = inspection.Anchors[i];
            var pt = InspectionDisplayPoint(anchor);
            var before = pt is { } bp && reference?.Image is { } bi ? InspectionOverlayRenderer.SampleBitmap(bi, bp.X, bp.Y) : null;
            var after = pt is { } ap && result?.Image is { } ai ? InspectionOverlayRenderer.SampleBitmap(ai, ap.X, ap.Y) : null;

            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 0) };
            var remove = new Button
            {
                Content = "×",
                Padding = new Thickness(5, 0, 5, 0),
                ToolTip = Loc.Text("移除"),
                Margin = new Thickness(6, 0, 0, 0),
                Tag = anchor.Id,
            };
            remove.Click += (_, _) =>
            {
                inspection.RemoveAnchor(anchor.Id);
                RefreshInspection();
            };
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);

            var beforeText = before is { } bs ? $"{bs.RgbText} {bs.HsbText}" : "--";
            var afterText = after is { } asmp ? $"{asmp.RgbText} {asmp.HsbText}" : "--";
            var text = new TextBlock
            {
                Text = $"#{i + 1} {Loc.Text("调整前")} {beforeText} | {Loc.Text("调整后")} {afterText}",
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            text.MouseLeftButtonDown += (_, _) =>
            {
                inspection.SelectedAnchorId = anchor.Id;
                RefreshInspection();
            };
            row.Children.Add(text);
            InspectionAnchorsPanel.Children.Add(row);
        }

        RefreshInspectionReadoutAndCursor();
        var showHud = hasResult && !geometryEditing && (inspection.MonitorEnabled || inspection.Anchors.Count > 0 || overlay.IsActive());
        InspectionHud.Visibility = showHud ? Visibility.Visible : Visibility.Collapsed;
    }

    private void InspectionMonitorClicked(object sender, RoutedEventArgs e)
    {
        inspection.MonitorEnabled = !inspection.MonitorEnabled;
        if (!inspection.MonitorEnabled)
            inspection.PinModeEnabled = false;
        var hadReference = ReferenceCurrent;
        RefreshInspection();
        if (inspection.MonitorEnabled && !hadReference) Schedule();
    }

    private void InspectionPinModeClicked(object sender, RoutedEventArgs e)
    {
        inspection.MonitorEnabled = true;
        inspection.PinModeEnabled = !inspection.PinModeEnabled;
        RefreshInspection();
    }

    private void InspectionPinNowClicked(object sender, RoutedEventArgs e)
    {
        var pt = inspection.LiveOutputPoint ?? (0.5, 0.5);
        PinInspectionAnchor(pt.X, pt.Y);
    }

    private void InspectionClearAnchorsClicked(object sender, RoutedEventArgs e)
    {
        inspection.ClearAnchors();
        RefreshInspection();
    }

    private void InspectionMenuButtonClicked(object sender, RoutedEventArgs e) =>
        ZoomClicked(InspectionOverlayButton, e);

    private void InspectionOverlayItemClicked(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string tag } && Enum.TryParse<InspectionOverlayMode>(tag, out var mode))
        {
            inspection.SelectOverlay(mode);
            RefreshViewingFrames();
        }
    }

    private void ToggleGray50Clicked(object sender, RoutedEventArgs e)
    {
        if (result == null || (transform.Active && transform.Tool == TransformTool.Geometry)) return;
        inspection.ToggleNeutralGray50();
        RefreshViewingFrames();
    }

    private void InspectionOverlayClearClicked(object sender, RoutedEventArgs e)
    {
        inspection.SelectOverlay(InspectionOverlayMode.None);
        RefreshViewingFrames();
    }
}
