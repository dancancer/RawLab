using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly InspectionSessionState inspection = new();
    private bool inspectionBodyCollapsed;
    private (int Width, int Height)? sourceNativeSize;
    private readonly InspectionOverlayCache inspectionOverlayCache = new(maxEntries: 4);

    private void InitializeInspection()
    {
        bool PointAllowed(PhotoCanvas canvas, Point point) => new FrameworkElement[]
        {
            NeutralLabel, FilmLabel, InfoOverlay, ExternalReloadBanner, HslTargetBanner, InspectionOverlayChip, InspectionHud
        }.All(element => !element.IsVisible || !new Rect(element.TranslatePoint(new Point(), canvas), element.RenderSize).Contains(point));

        ResultCanvas.InspectionAllowed = p => PointAllowed(ResultCanvas, p);
        NeutralCanvas.InspectionAllowed = p => PointAllowed(NeutralCanvas, p);
        ResultCanvas.InspectionHoverChanged += pt => UpdateInspectionHover(pt);
        NeutralCanvas.InspectionHoverChanged += pt => UpdateInspectionHover(pt);
        ResultCanvas.InspectionPinRequested += pt => PinInspectionAnchor(pt.X, pt.Y);
        NeutralCanvas.InspectionPinRequested += pt => PinInspectionAnchor(pt.X, pt.Y);
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
            inspectionBodyCollapsed = false;
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
        if (baseBitmap == null || inspection.Overlay == InspectionOverlayMode.None || (transform.Active && transform.Tool == TransformTool.Geometry))
            return baseBitmap;
        var mode = inspection.Overlay;
        if (mode == InspectionOverlayMode.NeutralGray50)
            return InspectionOverlayRenderer.CreateOverlayBitmap(baseBitmap, InspectionOverlayMode.NeutralGray50);

        if (inspectionOverlayCache.TryGet(baseBitmap, mode, out var cached))
            return cached;

        if (inspectionOverlayCache.TryBeginRender(baseBitmap, mode))
        {
            var capturedRevision = openRevision;
            _ = Task.Run(() => InspectionOverlayRenderer.CreateOverlayBitmap(baseBitmap, mode))
                .ContinueWith(task => Dispatcher.BeginInvoke(() =>
                {
                    if (!closing && openRevision == capturedRevision && task.IsCompletedSuccessfully)
                    {
                        inspectionOverlayCache.CompleteRender(baseBitmap, mode, task.Result);
                        RefreshViewingFrames();
                    }
                    else
                    {
                        inspectionOverlayCache.CancelRender(baseBitmap, mode);
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
            InspectionLiveRgb.Text = $"RGB {s.RgbText}";
            InspectionLiveHsb.Text = $"HSB {s.HsbText}";
        }
        else
        {
            InspectionSwatch.Background = Brushes.Transparent;
            InspectionLiveRgb.Text = "RGB -- -- --";
            InspectionLiveHsb.Text = "HSB --° --% --%";
        }
    }

    private void RefreshInspection()
    {
        if (!IsLoaded && InspectionHud == null) return;
        var hasResult = result != null && file != null;
        var geometryEditing = transform.Active && transform.Tool == TransformTool.Geometry;

        ResultCanvas.InspectionMonitorEnabled = inspection.MonitorEnabled && hasResult && !geometryEditing;
        NeutralCanvas.InspectionMonitorEnabled = inspection.MonitorEnabled && hasResult && !geometryEditing;
        ResultCanvas.InspectionPinMode = inspection.PinModeEnabled && hasResult && !geometryEditing;
        NeutralCanvas.InspectionPinMode = inspection.PinModeEnabled && hasResult && !geometryEditing;
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

        var overlay = inspection.Overlay;
        InspectionMonitorMenu.IsEnabled = hasResult && !geometryEditing;
        InspectionOverlayMenu.IsEnabled = hasResult && !geometryEditing;
        ToolbarInspectionMonitor.IsEnabled = hasResult && !geometryEditing;
        InspectionMonitorMenu.IsChecked = inspection.MonitorEnabled;
        ToolbarInspectionMonitor.IsChecked = inspection.MonitorEnabled;
        ToolbarInspectionPin.IsChecked = inspection.PinModeEnabled;
        ToolbarInspectionPin.IsEnabled = hasResult && !geometryEditing && (inspection.CanPinMore || inspection.PinModeEnabled);
        ToolbarInspectionClear.IsEnabled = inspection.Anchors.Count > 0;
        InspectionPinModeButton.IsChecked = inspection.PinModeEnabled;
        InspectionPinModeButton.IsEnabled = hasResult && !geometryEditing && (inspection.CanPinMore || inspection.PinModeEnabled);
        InspectionClearAnchorsButton.Visibility = inspection.Anchors.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        MenuOverlayNone.IsChecked = ToolbarOverlayNone.IsChecked = overlay == InspectionOverlayMode.None;
        MenuOverlaySketch.IsChecked = ToolbarOverlaySketch.IsChecked = overlay == InspectionOverlayMode.SketchLuminance;
        MenuOverlayWarmCool.IsChecked = ToolbarOverlayWarmCool.IsChecked = overlay == InspectionOverlayMode.WarmCoolBW;
        MenuOverlayHeatmap.IsChecked = ToolbarOverlayHeatmap.IsChecked = overlay == InspectionOverlayMode.OversaturationHeatmap;
        MenuOverlaySkin.IsChecked = ToolbarOverlaySkin.IsChecked = overlay == InspectionOverlayMode.SkinHueAmplification;
        MenuOverlayGray50.IsChecked = ToolbarOverlayGray50.IsChecked = overlay == InspectionOverlayMode.NeutralGray50;
        InspectionGray50Button.IsEnabled = hasResult && !geometryEditing;
        InspectionOverlayButton.IsEnabled = hasResult && !geometryEditing;
        InspectionGray50Button.Tag = overlay == InspectionOverlayMode.NeutralGray50 ? "selected" : null;
        InspectionOverlayButton.Tag = inspection.MonitorEnabled || inspection.PinModeEnabled || overlay.IsActive() ? "selected" : null;

        if (hasResult && !geometryEditing && overlay.IsActive())
        {
            InspectionOverlayChip.Visibility = Visibility.Visible;
            InspectionOverlayLabel.Text = OverlayModeTitle(overlay);
        }
        else
        {
            InspectionOverlayChip.Visibility = Visibility.Collapsed;
        }

        InspectionAnchorsPanel.Children.Clear();
        var reference = ReferenceCurrent ? neutralResult : null;
        for (var i = 0; i < inspection.Anchors.Count; i++)
        {
            var anchor = inspection.Anchors[i];
            var isSelected = inspection.SelectedAnchorId == anchor.Id;
            var pt = InspectionDisplayPoint(anchor);
            var before = pt is { } bp && reference?.Image is { } bi ? InspectionOverlayRenderer.SampleBitmap(bi, bp.X, bp.Y) : null;
            var after = pt is { } ap && result?.Image is { } ai ? InspectionOverlayRenderer.SampleBitmap(ai, ap.X, ap.Y) : null;

            var card = new Border
            {
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 4, 6, 4),
                Margin = new Thickness(0, 3, 0, 0),
                BorderThickness = new Thickness(1),
            };
            if (isSelected)
            {
                card.SetResourceReference(Border.BackgroundProperty, "SelectedSurface");
                card.SetResourceReference(Border.BorderBrushProperty, "Accent");
            }
            else
            {
                card.Background = Brushes.Transparent;
                card.BorderBrush = Brushes.Transparent;
            }

            var row = new DockPanel();
            var remove = new Button
            {
                Content = "×",
                Padding = new Thickness(5, 0, 5, 0),
                MinHeight = 22,
                ToolTip = Loc.Text("移除"),
                Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Tag = anchor.Id,
            };
            remove.SetResourceReference(FrameworkElement.StyleProperty, "QuietButton");
            remove.Click += (_, _) =>
            {
                inspection.RemoveAnchor(anchor.Id);
                RefreshInspection();
            };
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);

            var beforeText = before is { } bs ? $"{bs.RgbText} · {bs.HsbText}" : "--";
            var afterText = after is { } asmp ? $"{asmp.RgbText} · {asmp.HsbText}" : "--";
            var textStack = new StackPanel
            {
                Background = Brushes.Transparent,
                Cursor = System.Windows.Input.Cursors.Hand,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var beforeLine = new TextBlock
            {
                Text = $"#{i + 1} {Loc.Text("调整前")} {beforeText}",
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            beforeLine.SetResourceReference(TextBlock.FontSizeProperty, "EditorCaptionSize");
            beforeLine.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            Typography.SetNumeralAlignment(beforeLine, FontNumeralAlignment.Tabular);

            var afterLine = new TextBlock
            {
                Text = $"   {Loc.Text("调整后")} {afterText}",
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 1, 0, 0),
            };
            afterLine.SetResourceReference(TextBlock.FontSizeProperty, "EditorCaptionSize");
            afterLine.SetResourceReference(TextBlock.ForegroundProperty, "Foreground");
            Typography.SetNumeralAlignment(afterLine, FontNumeralAlignment.Tabular);

            textStack.Children.Add(beforeLine);
            textStack.Children.Add(afterLine);
            textStack.MouseLeftButtonDown += (_, _) =>
            {
                inspection.SelectedAnchorId = anchor.Id;
                RefreshInspection();
            };
            row.Children.Add(textStack);
            card.Child = row;
            InspectionAnchorsPanel.Children.Add(card);
        }

        RefreshInspectionReadoutAndCursor();

        var docked = ShowsInspector;
        if (inspection.Anchors.Count == 0)
            inspectionBodyCollapsed = false;
        var bodyVisible = !inspectionBodyCollapsed && (inspection.MonitorEnabled || inspection.Anchors.Count > 0);
        if (docked && !ReferenceEquals(InspectionContent.Parent, InspectionInlineHost))
        {
            if (InspectionHud.Child == InspectionContent) InspectionHud.Child = null;
            InspectionInlineHost.Children.Add(InspectionContent);
        }
        else if (!docked && !ReferenceEquals(InspectionContent.Parent, InspectionHud))
        {
            if (InspectionContent.Parent == InspectionInlineHost) InspectionInlineHost.Children.Remove(InspectionContent);
            InspectionHud.Child = InspectionContent;
        }

        InspectionSurface.Visibility = docked && hasResult && !geometryEditing ? Visibility.Visible : Visibility.Collapsed;
        InspectionInlineHost.Visibility = bodyVisible ? Visibility.Visible : Visibility.Collapsed;
        InspectionFloatingTitle.Visibility = docked ? Visibility.Collapsed : Visibility.Visible;
        InspectionChevron.RenderTransform = bodyVisible ? Transform.Identity : new RotateTransform(-90);
        InspectionInlineButton.ToolTip = Loc.Text(bodyVisible ? "收起取样监视" : "展开取样监视");
        InspectionAnchorCountBadge.Text = inspection.Anchors.Count > 0
            ? $"{inspection.Anchors.Count.ToString(CultureInfo.InvariantCulture)}/{InspectionAnchor.MaxCount.ToString(CultureInfo.InvariantCulture)}"
            : "";

        InspectionHud.Margin = (compare || view.HoldingBefore) ? new Thickness(14, 14, 14, 48) : new Thickness(14);
        InspectionHud.Visibility = !docked && hasResult && !geometryEditing && bodyVisible ? Visibility.Visible : Visibility.Collapsed;
        RefreshHDRPresentation();
    }

    private void InspectionMonitorClicked(object sender, RoutedEventArgs e)
    {
        if (ReferenceEquals(sender, InspectionInlineButton))
        {
            var expanded = !inspectionBodyCollapsed && (inspection.MonitorEnabled || inspection.Anchors.Count > 0);
            if (expanded)
            {
                inspection.MonitorEnabled = false;
                inspection.PinModeEnabled = false;
                inspectionBodyCollapsed = true;
            }
            else
            {
                inspectionBodyCollapsed = false;
                inspection.MonitorEnabled = true;
            }
        }
        else
        {
            inspection.MonitorEnabled = !inspection.MonitorEnabled;
            if (inspection.MonitorEnabled)
            {
                inspectionBodyCollapsed = false;
            }
            else
            {
                inspection.PinModeEnabled = false;
                if (inspection.Anchors.Count > 0)
                    inspectionBodyCollapsed = true;
            }
        }
        var hadReference = ReferenceCurrent;
        RefreshInspection();
        if (inspection.MonitorEnabled && !hadReference) Schedule();
    }

    private void InspectionPinModeClicked(object sender, RoutedEventArgs e)
    {
        inspectionBodyCollapsed = false;
        inspection.MonitorEnabled = true;
        inspection.PinModeEnabled = !inspection.PinModeEnabled;
        if (inspection.PinModeEnabled)
        {
            CancelWbProbe();
            SetCurveTargetMode(false, curveTargetChannel);
            SetHslTargetMode(false, hslTargetAxis);
        }
        RefreshInspection();
    }

    private void InspectionClearAnchorsClicked(object sender, RoutedEventArgs e)
    {
        inspectionBodyCollapsed = false;
        inspection.ClearAnchors();
        RefreshInspection();
    }

    private void InspectionMenuButtonClicked(object sender, RoutedEventArgs e) =>
        ZoomClicked(InspectionOverlayButton, e);

    private void InspectionOverlayItemClicked(object sender, RoutedEventArgs e)
    {
        if (result == null || (transform.Active && transform.Tool == TransformTool.Geometry)) return;
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
        if (transform.Active && transform.Tool == TransformTool.Geometry) return;
        inspection.SelectOverlay(InspectionOverlayMode.None);
        RefreshViewingFrames();
    }
}
