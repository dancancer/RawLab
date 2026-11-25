using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ToneCurveCanvas : FrameworkElement
{
    public const double DragOutDeleteMargin = 0.12;
    private const long DoubleClickDeleteWindowMs = 350;
    private const double SignificantMoveThreshold = 0.02;

    private ToneCurveSettings value = new();
    private IReadOnlyList<ToneCurvePoint> samples = [];
    private sealed record Drag(
        ToneCurveSettings Before,
        ToneCurveSettings Initial,
        int Index,
        Point Origin,
        bool Fine,
        bool HitExistingInterior,
        long StartTickMs);
    private sealed record ArmedDelete(
        object? Source,
        ToneCurveChannel Channel,
        int Index,
        ToneCurvePoint Point,
        long TickMs);
    private Drag? drag;
    private ArmedDelete? armedDelete;
    private bool changed, showSplitMarkers, dragMovedSignificantly, dragRemovedByDragOut;
    private ToneCurvePoint dragLatestPoint;
    private object? source;
    private int selected;
    private ToneCurveChannel channel = ToneCurveChannel.Rgb;
    private bool IsParametricView => showSplitMarkers && channel == ToneCurveChannel.Rgb;
    public Func<bool>? PrepareEditing { get; set; }
    public event Action<ToneCurveSettings, bool>? Changed;
    public event Action<int>? SelectionChanged;
    public ToneCurveCanvas()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch; MaxWidth = 232; MinWidth = 160; Height = 164; Focusable = true;
        AutomationProperties.SetAutomationId(this, "curve.canvas");
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelGesture(); };
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelGesture(); InvalidateVisual(); };
        Unloaded += (_, _) => CancelGesture();
    }
    public void Refresh(ToneCurveSettings next, object? identity, int index,
        ToneCurveChannel nextChannel = ToneCurveChannel.Rgb, bool nextShowSplitMarkers = false)
    {
        if (!Equals(source, identity) || value.Mode != next.Mode || channel != nextChannel || showSplitMarkers != nextShowSplitMarkers) {
            armedDelete = null;
            CancelGesture();
        }
        source = identity; selected = index;
        var channelOrSplitChanged = channel != nextChannel || showSplitMarkers != nextShowSplitMarkers;
        channel = nextChannel; showSplitMarkers = nextShowSplitMarkers;
        SetValue(next, forceResample: channelOrSplitChanged);
        AutomationProperties.SetName(this, Loc.Text(IsParametricView ? "参数曲线" : "曲线"));
        AutomationProperties.SetHelpText(this, IsParametricView ? "" : Loc.Text("点击添加控制点；双击控制点或拖出画布可删除。"));
        AutomationProperties.SetItemStatus(this, IsParametricView
            ? Loc.Text(next.Parametric.IsDefault ? "未调整" : "已调整")
            : Loc.Format("多点曲线（{0} 个控制点）", next.Points.Count));
    }
    private void SetValue(ToneCurveSettings next, bool forceResample = false)
    {
        if (value != next || forceResample) {
            value = next;
            if (IsParametricView) {
                var parametricOnly = new ToneCurveSettings(ToneCurveMode.Custom, ToneCurveShape.Identity.Points, parametric: next.Parametric);
                samples = ToneCurveSampling.Samples(parametricOnly, ToneCurveChannel.Rgb, includeParametric: true);
            } else {
                samples = (next.Mode == ToneCurveMode.Legacy)
                    ? []
                    : ToneCurveSampling.Samples(next, ToneCurveChannel.Rgb, includeParametric: false);
            }
        }
        InvalidateVisual();
    }
    private static bool IsOutsideDeleteBounds(Point p) =>
        p.X < -DragOutDeleteMargin || p.X > 1.0 + DragOutDeleteMargin ||
        p.Y < -DragOutDeleteMargin || p.Y > 1.0 + DragOutDeleteMargin;
    private Point Normalized(Point point) => new((point.X - 12) / Math.Max(1, ActualWidth - 24), 1 - (point.Y - 12) / Math.Max(1, ActualHeight - 24));
    private Point CanvasPoint(ToneCurvePoint p) => new(12 + p.X * (ActualWidth - 24), 12 + (1 - p.Y) * (ActualHeight - 24));
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!IsEnabled || value.Mode == ToneCurveMode.Legacy || IsParametricView || PrepareEditing?.Invoke() == false) return;
        var location = e.GetPosition(this); var origin = Normalized(location);
        var nowMs = Environment.TickCount64;
        var armed = armedDelete;
        armedDelete = null;
        double Distance(int index) { var p = CanvasPoint(value.Points[index]) - location; return p.LengthSquared; }

        if (armed is not null &&
            Equals(armed.Source, source) &&
            armed.Channel == channel &&
            (e.ClickCount >= 2 || (nowMs >= armed.TickMs && nowMs - armed.TickMs <= DoubleClickDeleteWindowMs)) &&
            armed.Index >= 0 && armed.Index < value.Points.Count &&
            value.IsInterior(armed.Index) &&
            value.Points[armed.Index] == armed.Point &&
            Distance(armed.Index) <= 144) {
            var removed = value.Removing(armed.Index);
            if (removed != value) {
                Focus();
                selected = Math.Min(armed.Index, Math.Max(0, removed.Points.Count - 1));
                SelectionChanged?.Invoke(selected);
                RaiseEvent(new RoutedEventArgs(ParameterRow.GestureStartedEvent));
                SetValue(removed);
                Changed?.Invoke(removed, false);
                RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCompletedEvent));
                e.Handled = true;
                return;
            }
        }

        var index = Enumerable.Range(0, value.Points.Count).MinBy(Distance);
        var hitExisting = Distance(index) <= 144;
        var hitExistingInterior = hitExisting && value.IsInterior(index);
        var before = value; var initial = hitExisting ? value : value.Inserting(origin.X, origin.Y);
        if (initial != value) index = initial.Points.ToList().FindIndex(p => p.X == origin.X);
        else if (!hitExisting) return;
        if (!CaptureMouse()) return;
        Focus(); selected = index; SelectionChanged?.Invoke(index);
        drag = new(before, initial, index, origin, (Keyboard.Modifiers & ModifierKeys.Shift) != 0, hitExistingInterior, nowMs);
        dragMovedSignificantly = false;
        dragRemovedByDragOut = false;
        dragLatestPoint = initial.Points[index];
        changed = false;
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureStartedEvent));
        Publish(initial, true); e.Handled = true;
    }
    protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
    {
        if (!IsEnabled || value.Mode == ToneCurveMode.Legacy || IsParametricView || PrepareEditing?.Invoke() == false) {
            base.OnMouseRightButtonDown(e);
            return;
        }
        CancelGesture();
        armedDelete = null;
        var location = e.GetPosition(this);
        double Distance(int index) { var p = CanvasPoint(value.Points[index]) - location; return p.LengthSquared; }
        var index = Enumerable.Range(0, value.Points.Count).MinBy(Distance);
        if (Distance(index) <= 144 && value.IsInterior(index)) {
            var removed = value.Removing(index);
            if (removed != value) {
                Focus();
                selected = Math.Min(index, Math.Max(0, removed.Points.Count - 1));
                SelectionChanged?.Invoke(selected);
                RaiseEvent(new RoutedEventArgs(ParameterRow.GestureStartedEvent));
                SetValue(removed);
                Changed?.Invoke(removed, false);
                RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCompletedEvent));
                e.Handled = true;
                return;
            }
        }
        base.OnMouseRightButtonDown(e);
    }
    private void Move(Point p)
    {
        if (drag is not {} active) return;
        var dx = p.X - active.Origin.X; var dy = p.Y - active.Origin.Y;
        if (Math.Sqrt(dx * dx + dy * dy) > SignificantMoveThreshold) dragMovedSignificantly = true;
        if (active.Initial.IsInterior(active.Index) && IsOutsideDeleteBounds(p)) {
            var removed = active.Initial.Removing(active.Index);
            dragRemovedByDragOut = true;
            var nextSelected = Math.Min(active.Index, Math.Max(0, removed.Points.Count - 1));
            if (selected != nextSelected) {
                selected = nextSelected;
                SelectionChanged?.Invoke(selected);
            }
            Publish(removed, true);
            return;
        }
        if (dragRemovedByDragOut) {
            dragRemovedByDragOut = false;
            if (selected != active.Index) {
                selected = active.Index;
                SelectionChanged?.Invoke(selected);
            }
        }
        var start = active.Initial.Points[active.Index]; var scale = active.Fine ? .25 : 1;
        var moved = active.Initial.Moving(active.Index, start.X + dx * scale, start.Y + dy * scale);
        dragLatestPoint = moved.Points[active.Index];
        Publish(moved, true);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (drag == null) return;
        if (e.LeftButton != MouseButtonState.Pressed) { CancelGesture(); return; }
        Move(Normalized(e.GetPosition(this))); e.Handled = true;
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (drag is not {} active) return;
        Move(Normalized(e.GetPosition(this)));
        var shouldArm = active.HitExistingInterior && !dragMovedSignificantly && !dragRemovedByDragOut;
        armedDelete = shouldArm
            ? new ArmedDelete(source, channel, active.Index, dragLatestPoint, active.StartTickMs)
            : null;
        drag = null; ReleaseMouseCapture();
        if (changed) Changed?.Invoke(value, false);
        changed = false; RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCompletedEvent)); e.Handled = true;
    }
    public void CancelGesture()
    {
        armedDelete = null;
        if (drag is not {} active) return;
        drag = null; changed = false; dragRemovedByDragOut = false; ReleaseMouseCapture(); SetValue(active.Before);
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCancelledEvent));
    }
    protected override void OnLostMouseCapture(MouseEventArgs e) { CancelGesture(); base.OnLostMouseCapture(e); }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        armedDelete = null;
        if (e.Key == Key.Escape) { CancelGesture(); e.Handled = true; return; }
        if (drag != null) { if (e.Key is Key.LeftShift or Key.RightShift) CancelGesture(); e.Handled = true; return; }
        if (!IsEnabled || IsParametricView ||
            e.Key is not (Key.Left or Key.Right or Key.Up or Key.Down or Key.Delete or Key.Back) ||
            PrepareEditing?.Invoke() == false) { base.OnKeyDown(e); return; }
        var blocked = e.Key switch {
            Key.Up or Key.Down => !value.CanMoveY(selected),
            Key.Left or Key.Right => !value.CanMoveX(selected),
            _ => !value.IsInterior(selected)
        };
        if (blocked) { base.OnKeyDown(e); return; }
        var point = value.Points[selected]; var step = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? .001 : .01;
        var next = e.Key switch {
            Key.Left => value.Moving(selected, point.X - step, point.Y), Key.Right => value.Moving(selected, point.X + step, point.Y),
            Key.Up => value.Moving(selected, point.X, point.Y + step), Key.Down => value.Moving(selected, point.X, point.Y - step),
            _ => value.Removing(selected)
        };
        Publish(next, false); e.Handled = true;
    }
    protected override void OnKeyUp(KeyEventArgs e)
    { if (drag != null && e.Key is Key.LeftShift or Key.RightShift) CancelGesture(); base.OnKeyUp(e); }
    private void Publish(ToneCurveSettings next, bool interactive)
    {
        if (next == value) return;
        if (interactive) changed = true;
        SetValue(next); Changed?.Invoke(next, interactive);
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);
    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        if ((value.Mode == ToneCurveMode.Legacy) && !IsParametricView) return;
        dc.PushOpacity(IsEnabled ? 1 : .4);
        var grid = new Pen(new SolidColorBrush(Color.FromArgb(45, 150, 150, 150)), 1);
        for (var i = 0; i <= 4; i++) {
            var t = i / 4.0;
            dc.DrawLine(grid, CanvasPoint(new(t, 0)), CanvasPoint(new(t, 1)));
            dc.DrawLine(grid, CanvasPoint(new(0, t)), CanvasPoint(new(1, t)));
        }
        if (IsParametricView) {
            var splitPen = new Pen(new SolidColorBrush(Color.FromArgb(110, 180, 180, 180)), 1) { DashStyle = DashStyles.Dot };
            dc.DrawLine(splitPen, CanvasPoint(new(value.Parametric.SplitShadow, 0)), CanvasPoint(new(value.Parametric.SplitShadow, 1)));
            dc.DrawLine(splitPen, CanvasPoint(new(value.Parametric.SplitMidtone, 0)), CanvasPoint(new(value.Parametric.SplitMidtone, 1)));
            dc.DrawLine(splitPen, CanvasPoint(new(value.Parametric.SplitHighlight, 0)), CanvasPoint(new(value.Parametric.SplitHighlight, 1)));
        }
        dc.DrawLine(new Pen(Brushes.Gray, 1) { DashStyle = DashStyles.Dash }, CanvasPoint(new(0, 0)), CanvasPoint(new(1, 1)));
        var curve = new StreamGeometry();
        using (var context = curve.Open()) {
            if (samples.Count > 0) { context.BeginFigure(CanvasPoint(samples[0]), false, false); context.PolyLineTo(samples.Skip(1).Select(CanvasPoint).ToArray(), true, false); }
        }
        var foreground = TryFindResource("Foreground") as Brush ?? Brushes.White;
        var stroke = channel switch {
            ToneCurveChannel.Red => Brushes.IndianRed,
            ToneCurveChannel.Green => Brushes.MediumSeaGreen,
            ToneCurveChannel.Blue => Brushes.CornflowerBlue,
            _ => foreground
        };
        var indicator = TryFindResource("Indicator") as Brush ?? Brushes.Gold;
        dc.DrawGeometry(null, new Pen(stroke, 2), curve);
        if (!IsParametricView) {
            for (var i = 0; i < value.Points.Count; i++) {
                var radius = i == selected ? 6 : 4;
                dc.DrawEllipse(i == selected ? indicator : stroke, new Pen(Brushes.Black, 1), CanvasPoint(value.Points[i]), radius, radius);
            }
        }
        dc.Pop();
    }
}
