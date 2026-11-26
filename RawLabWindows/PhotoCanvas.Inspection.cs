using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed partial class PhotoCanvas
{
    private readonly DrawingVisual inspectionDrawing = new();
    private bool inspectionMonitorEnabled;
    private bool inspectionPinMode;
    private bool pendingInspectionPin;
    private bool inspectionOverlayActive;
    private IReadOnlyList<(int Index, double X, double Y, bool Selected)> inspectionMarkers = [];

    public event Action<Point?>? InspectionHoverChanged;
    public event Action<Point>? InspectionPinRequested;
    public Func<Point, bool>? InspectionAllowed { get; set; }

    public bool InspectionMonitorEnabled
    {
        get => inspectionMonitorEnabled;
        set
        {
            if (inspectionMonitorEnabled == value) return;
            inspectionMonitorEnabled = value;
            UpdateInspectionCursor();
        }
    }

    public bool InspectionPinMode
    {
        get => inspectionPinMode;
        set
        {
            if (inspectionPinMode == value) return;
            inspectionPinMode = value;
            UpdateInspectionCursor();
        }
    }

    public bool InspectionOverlayActive
    {
        get => inspectionOverlayActive;
        set
        {
            if (inspectionOverlayActive == value) return;
            inspectionOverlayActive = value;
            DrawInspectionAnchors();
        }
    }

    public void SetInspectionMarkers(IReadOnlyList<(int Index, double X, double Y, bool Selected)> markers)
    {
        inspectionMarkers = markers;
        DrawInspectionAnchors();
    }

    private void UpdateInspectionCursor()
    {
        if (!GeometryEditing)
            Cursor = WbProbeEnabled || PointColorProbeEnabled || HslTargetEnabled || inspectionPinMode ? Cursors.Cross : Cursors.Hand;
    }

    private bool HandleInspectionMove(Point point)
    {
        if (HslTargetEnabled || GeometryEditing || panning || draggingDivider ||
            image == null || ImageBounds.Width <= 0 || ImageBounds.Height <= 0 ||
            !VisibleImageBounds.Contains(point) ||
            (InspectionAllowed != null && !InspectionAllowed(point)))
        {
            InspectionHoverChanged?.Invoke(null);
            return false;
        }
        var normX = Math.Clamp((point.X - ImageBounds.X) / ImageBounds.Width, 0.0, 1.0);
        var normY = Math.Clamp((point.Y - ImageBounds.Y) / ImageBounds.Height, 0.0, 1.0);
        InspectionHoverChanged?.Invoke(new Point(normX, normY));
        return false;
    }

    private bool CanPinAt(Point point) =>
        !HslTargetEnabled && !WbProbeEnabled && !PointColorProbeEnabled && !GeometryEditing && !draggingDivider && image != null &&
        ImageBounds.Width > 0 && ImageBounds.Height > 0 &&
        (inspectionPinMode || Keyboard.Modifiers == ModifierKeys.Alt) &&
        VisibleImageBounds.Contains(point) &&
        (InspectionAllowed == null || InspectionAllowed(point));

    private void BeginPendingInspectionPin(Point point)
    {
        pendingInspectionPin = CanPinAt(point);
    }

    private void CommitInspectionPin(Point point)
    {
        if (!CanPinAt(point)) return;
        var normX = Math.Clamp((point.X - ImageBounds.X) / ImageBounds.Width, 0.0, 1.0);
        var normY = Math.Clamp((point.Y - ImageBounds.Y) / ImageBounds.Height, 0.0, 1.0);
        InspectionPinRequested?.Invoke(new Point(normX, normY));
    }

    internal IEnumerable<Rect> ActiveMarkerBounds()
    {
        if (!GeometryEditing && !inspectionOverlayActive && image != null && !ImageBounds.IsEmpty)
        {
            foreach (var marker in inspectionMarkers)
            {
                yield return new Rect(
                    ImageBounds.X + marker.X * ImageBounds.Width - 13,
                    ImageBounds.Y + marker.Y * ImageBounds.Height - 13,
                    26,
                    26);
            }
        }
        if (HslTargetEnabled && hslTargetPoint is { } tp && !ImageBounds.IsEmpty && !VisibleImageBounds.IsEmpty)
        {
            var rect = new Rect(
                ImageBounds.X + tp.X * ImageBounds.Width - 14,
                ImageBounds.Y + tp.Y * ImageBounds.Height - 14,
                28,
                28);
            rect.Intersect(VisibleImageBounds);
            if (!rect.IsEmpty) yield return rect;
        }
    }

    private void DrawInspectionAnchors()
    {
        using var dc = inspectionDrawing.RenderOpen();
        if (GeometryEditing || inspectionOverlayActive || image == null || ImageBounds.IsEmpty || inspectionMarkers.Count == 0)
            return;

        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var typeface = new Typeface(SystemFonts.MessageFontFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        foreach (var marker in inspectionMarkers)
        {
            var cx = ImageBounds.X + marker.X * ImageBounds.Width;
            var cy = ImageBounds.Y + marker.Y * ImageBounds.Height;
            var center = new Point(cx, cy);
            var fill = marker.Selected ? Brushes.Gold : new SolidColorBrush(Color.FromArgb(200, 16, 16, 18));
            var stroke = new Pen(marker.Selected ? Brushes.Black : Brushes.White, 1.5);
            dc.DrawEllipse(fill, stroke, center, 10, 10);

            var label = new FormattedText(
                marker.Index.ToString(CultureInfo.InvariantCulture),
                CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight,
                typeface,
                10,
                marker.Selected ? Brushes.Black : Brushes.White,
                dpi);
            dc.DrawText(label, new Point(cx - label.Width / 2.0, cy - label.Height / 2.0));
        }
    }
}
