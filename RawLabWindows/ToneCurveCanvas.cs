using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ToneCurveCanvas : FrameworkElement
{
    private ToneCurveSettings value = new();
    private IReadOnlyList<ToneCurvePoint> samples = [];
    private sealed record Drag(ToneCurveSettings Before, ToneCurveSettings Initial, int Index, Point Origin, bool Fine);
    private Drag? drag;
    private bool changed;
    private object? source;
    private int selected;
    public Func<bool>? PrepareEditing { get; set; }
    public event Action<ToneCurveSettings, bool>? Changed;
    public event Action<int>? SelectionChanged;
    public ToneCurveCanvas()
    {
        Width = 232; Height = 164; Focusable = true;
        AutomationProperties.SetAutomationId(this, "curve.canvas");
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelGesture(); };
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelGesture(); InvalidateVisual(); };
        Unloaded += (_, _) => CancelGesture();
    }
    public void Refresh(ToneCurveSettings next, object? identity, int index)
    {
        if (!Equals(source, identity) || value.Mode != next.Mode) CancelGesture();
        source = identity; selected = index;
        SetValue(next);
        AutomationProperties.SetName(this, Loc.Text("曲线"));
        AutomationProperties.SetHelpText(this, Loc.Text("点击曲线区域添加控制点，拖动中间点调整。"));
        AutomationProperties.SetItemStatus(this, Loc.Format("多点曲线（{0} 个控制点）", next.Points.Count));
    }
    private void SetValue(ToneCurveSettings next)
    {
        if (value != next) { value = next; samples = next.IsDefault ? [] : ToneCurveSampling.Samples(next); }
        InvalidateVisual();
    }
    private Point Normalized(Point point) => new((point.X - 12) / Math.Max(1, ActualWidth - 24), 1 - (point.Y - 12) / Math.Max(1, ActualHeight - 24));
    private Point CanvasPoint(ToneCurvePoint p) => new(12 + p.X * (ActualWidth - 24), 12 + (1 - p.Y) * (ActualHeight - 24));
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!IsEnabled || value.IsDefault || PrepareEditing?.Invoke() == false) return;
        var location = e.GetPosition(this); var origin = Normalized(location);
        double Distance(int index) { var p = CanvasPoint(value.Points[index]) - location; return p.LengthSquared; }
        var index = Enumerable.Range(0, value.Points.Count).MinBy(Distance);
        var before = value; var initial = Distance(index) <= 144 ? value : value.Inserting(origin.X, origin.Y);
        if (initial != value) index = initial.Points.ToList().FindIndex(p => p.X == origin.X);
        else if (Distance(index) > 144) return;
        if (!CaptureMouse()) return;
        Focus(); selected = index; SelectionChanged?.Invoke(index);
        drag = new(before, initial, index, origin, (Keyboard.Modifiers & ModifierKeys.Shift) != 0); changed = false;
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureStartedEvent));
        Publish(initial, true); e.Handled = true;
    }
    private void Move(Point p)
    {
        if (drag is not {} active) return;
        var start = active.Initial.Points[active.Index]; var scale = active.Fine ? .25 : 1;
        Publish(active.Initial.Moving(active.Index, start.X + (p.X - active.Origin.X) * scale, start.Y + (p.Y - active.Origin.Y) * scale), true);
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (drag == null) return;
        if (e.LeftButton != MouseButtonState.Pressed) { CancelGesture(); return; }
        Move(Normalized(e.GetPosition(this))); e.Handled = true;
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (drag == null) return;
        Move(Normalized(e.GetPosition(this))); drag = null; ReleaseMouseCapture();
        if (changed) Changed?.Invoke(value, false);
        changed = false; RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCompletedEvent)); e.Handled = true;
    }
    public void CancelGesture()
    {
        if (drag is not {} active) return;
        drag = null; changed = false; ReleaseMouseCapture(); SetValue(active.Before);
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCancelledEvent));
    }
    protected override void OnLostMouseCapture(MouseEventArgs e) { CancelGesture(); base.OnLostMouseCapture(e); }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { CancelGesture(); e.Handled = true; return; }
        if (drag != null) { if (e.Key is Key.LeftShift or Key.RightShift) CancelGesture(); e.Handled = true; return; }
        if (!IsEnabled || !value.IsInterior(selected) || e.Key is not (Key.Left or Key.Right or Key.Up or Key.Down or Key.Delete or Key.Back) ||
            PrepareEditing?.Invoke() == false) { base.OnKeyDown(e); return; }
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
        if (value.IsDefault) return;
        dc.PushOpacity(IsEnabled ? 1 : .4);
        var grid = new Pen(new SolidColorBrush(Color.FromArgb(45, 150, 150, 150)), 1);
        for (var i = 0; i <= 4; i++) {
            var t = i / 4.0;
            dc.DrawLine(grid, CanvasPoint(new(t, 0)), CanvasPoint(new(t, 1)));
            dc.DrawLine(grid, CanvasPoint(new(0, t)), CanvasPoint(new(1, t)));
        }
        dc.DrawLine(new Pen(Brushes.Gray, 1) { DashStyle = DashStyles.Dash }, CanvasPoint(new(0, 0)), CanvasPoint(new(1, 1)));
        var curve = new StreamGeometry();
        using (var context = curve.Open()) {
            if (samples.Count > 0) { context.BeginFigure(CanvasPoint(samples[0]), false, false); context.PolyLineTo(samples.Skip(1).Select(CanvasPoint).ToArray(), true, false); }
        }
        var foreground = TryFindResource("Foreground") as Brush ?? Brushes.White;
        var indicator = TryFindResource("Indicator") as Brush ?? Brushes.Gold;
        dc.DrawGeometry(null, new Pen(foreground, 2), curve);
        for (var i = 0; i < value.Points.Count; i++) {
            var radius = i == selected ? 6 : 4;
            dc.DrawEllipse(i == selected ? indicator : foreground, new Pen(Brushes.Black, 1), CanvasPoint(value.Points[i]), radius, radius);
        }
        dc.Pop();
    }
}
