using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public sealed class ColorGradingWheelControl : FrameworkElement
{
    private static readonly BitmapSource face = CreateFace();
    private ColorGradingWheel value = new();
    private ColorGradingDrag? drag;
    private bool changed;
    private object? source;
    private ColorGradingZone zone;
    public ColorGradingWheel Value => value;
    public Func<bool>? PrepareEditing { get; set; }
    public event Action<ColorGradingWheel, bool>? Changed;
    public ColorGradingWheelControl()
    {
        Width = Height = 156; Focusable = true;
        AutomationProperties.SetAutomationId(this, "grading.wheel");
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelGesture(); };
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelGesture(); InvalidateVisual(); };
        Unloaded += (_, _) => CancelGesture();
    }
    public void Refresh(ColorGradingWheel next, object? sourceIdentity, ColorGradingZone selected)
    {
        if (!Equals(source, sourceIdentity) || zone != selected) CancelGesture();
        source = sourceIdentity; zone = selected; value = next;
        AutomationProperties.SetName(this, Loc.Text("颜色分级") + " · " + Loc.Text(ColorGradingPanel.ZoneKeys[(int)zone]));
        AutomationProperties.SetItemStatus(this, Loc.Text("色相") + " " + value.Hue.ToString("0.0", CultureInfo.GetCultureInfo(Loc.Language)) + "°, "
            + Loc.Text("饱和度") + " " + value.Saturation.ToString("0.0", CultureInfo.GetCultureInfo(Loc.Language)) + "%");
        InvalidateVisual();
    }
    private Point Normalized(Point p)
    {
        var radius = Math.Max(1, (Math.Min(ActualWidth, ActualHeight) - 20) / 2);
        return new((p.X - ActualWidth / 2) / radius, (p.Y - ActualHeight / 2) / radius);
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!IsEnabled || PrepareEditing?.Invoke() == false || !CaptureMouse()) return;
        Focus();
        var p = Normalized(e.GetPosition(this));
        drag = new(value, p.X, p.Y, (Keyboard.Modifiers & ModifierKeys.Shift) != 0); changed = false;
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureStartedEvent));
        UpdatePointer(p); e.Handled = true;
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (drag == null) return;
        if (e.LeftButton != MouseButtonState.Pressed) { CancelGesture(); return; }
        UpdatePointer(Normalized(e.GetPosition(this))); e.Handled = true;
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (drag == null) return;
        UpdatePointer(Normalized(e.GetPosition(this)));
        drag = null; ReleaseMouseCapture();
        if (changed) Changed?.Invoke(value, false);
        changed = false; RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCompletedEvent)); e.Handled = true;
    }
    private void UpdatePointer(Point point)
    {
        if (drag == null) return;
        var next = drag.Value(point.X, point.Y);
        if (next == value) return;
        value = next; changed = true; InvalidateVisual(); Changed?.Invoke(next, true);
    }
    public void CancelGesture()
    {
        if (drag == null) return;
        var initial = drag.Initial; drag = null; changed = false;
        ReleaseMouseCapture(); value = initial;
        RaiseEvent(new RoutedEventArgs(ParameterRow.GestureCancelledEvent)); InvalidateVisual();
    }
    protected override void OnLostMouseCapture(MouseEventArgs e) { CancelGesture(); base.OnLostMouseCapture(e); }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { CancelGesture(); e.Handled = true; return; }
        if (drag != null && e.Key is Key.LeftShift or Key.RightShift) { CancelGesture(); return; }
        if (drag != null && e.Key is Key.Left or Key.Right or Key.Up or Key.Down) { e.Handled = true; return; }
        if (!IsEnabled || e.Key is not (Key.Left or Key.Right or Key.Up or Key.Down) || PrepareEditing?.Invoke() == false) { base.OnKeyDown(e); return; }
        var step = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? .1 : 1;
        var next = e.Key switch {
            Key.Left => value with { Hue = (value.Hue - step + 360) % 360 },
            Key.Right => value with { Hue = (value.Hue + step) % 360 },
            Key.Up => value with { Saturation = Math.Min(100, value.Saturation + step) },
            _ => value with { Saturation = Math.Max(0, value.Saturation - step) }
        };
        Publish(next); e.Handled = true;
    }
    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (drag != null && e.Key is Key.LeftShift or Key.RightShift) CancelGesture();
        base.OnKeyUp(e);
    }
    private void Publish(ColorGradingWheel next)
    {
        if (next == value) return;
        value = next; InvalidateVisual(); Changed?.Invoke(next, false);
    }
    internal void SetSaturation(double saturation)
    {
        if (!IsEnabled) throw new ElementNotEnabledException();
        if (!double.IsFinite(saturation) || saturation is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(saturation));
        if (PrepareEditing?.Invoke() != false) Publish(value with { Saturation = saturation });
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new WheelPeer(this);
    private sealed class WheelPeer(ColorGradingWheelControl owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => nameof(ColorGradingWheelControl);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.RangeValue ? this : base.GetPattern(pattern);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 10;
        public double SmallChange => .1;
        public double Maximum => 100;
        public double Minimum => 0;
        public double Value => owner.Value.Saturation;
        public void SetValue(double value) => owner.SetSaturation(value);
    }
    protected override void OnRender(DrawingContext dc)
    {
        var radius = Math.Max(1, (Math.Min(ActualWidth, ActualHeight) - 20) / 2);
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        dc.PushOpacity(IsEnabled ? 1 : .4);
        dc.DrawImage(face, new Rect(center.X - radius, center.Y - radius, radius * 2, radius * 2));
        dc.DrawEllipse(null, new Pen(Brushes.Gray, 1), center, radius, radius);
        var p = value.Point; var handle = new Point(center.X + p.X * radius, center.Y + p.Y * radius);
        dc.DrawEllipse(null, new Pen(Brushes.Black, 4), handle, 8, 8);
        dc.DrawEllipse(null, new Pen(Brushes.White, 2), handle, 8, 8);
        dc.Pop();
    }
    private static BitmapSource CreateFace()
    {
        const int side = 256;
        var pixels = new byte[side * side * 4];
        for (var y = 0; y < side; y++) for (var x = 0; x < side; x++) {
            var dx = (x + .5 - side / 2.0) / (side / 2.0); var dy = (y + .5 - side / 2.0) / (side / 2.0);
            var radius = Math.Sqrt(dx * dx + dy * dy); if (radius > 1) continue;
            var hue = (Math.Atan2(dy, dx) * 180 / Math.PI + 360) % 360 / 60;
            var secondary = 1 - Math.Abs(hue % 2 - 1);
            var rgb = (int)hue switch { 0 => (1.0, secondary, 0.0), 1 => (secondary, 1.0, 0.0), 2 => (0.0, 1.0, secondary),
                3 => (0.0, secondary, 1.0), 4 => (secondary, 0.0, 1.0), _ => (1.0, 0.0, secondary) };
            byte Channel(double v) => (byte)Math.Round(255 * (.5 * (1 - radius) + .9 * v * radius));
            var offset = (y * side + x) * 4;
            pixels[offset] = Channel(rgb.Item3); pixels[offset + 1] = Channel(rgb.Item2); pixels[offset + 2] = Channel(rgb.Item1); pixels[offset + 3] = 255;
        }
        var image = BitmapSource.Create(side, side, 96, 96, PixelFormats.Bgra32, null, pixels, side * 4); image.Freeze(); return image;
    }
}
