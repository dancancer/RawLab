using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ToneCurvePanel : StackPanel
{
    private readonly ToneCurveCanvas canvas = new();
    private readonly ParameterRow x = new() { Compact = true }, y = new() { Compact = true }, legacy = new();
    private readonly ComboBox points = new() { MinHeight = 30, MinWidth = 140 };
    private readonly Button switchMode = new(), add = new(), remove = new(), reset = new();
    private readonly TextBlock mode = new(), hint = new() { TextWrapping = TextWrapping.Wrap }, fixedEndpoint = new();
    private readonly Grid content = new();
    private readonly Grid exposureAxis = new() { Margin = new Thickness(12, 0, 12, 0) };
    private readonly TextBlock referenceWhite = new() { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel plot = new(), rows = new(), custom = new();
    private ToneCurveSettings settings = new();
    private double scalar;
    private object? source;
    private bool syncing, usesExposureStops;
    private int selected;
    public event Action<ToneCurveSettings, bool>? Changed;
    public event Action<double, bool>? LegacyChanged;
    public ToneCurvePanel()
    {
        MaxWidth = 720; Margin = new Thickness(12, 6, 12, 6);
        var header = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        mode.VerticalAlignment = VerticalAlignment.Center; mode.Margin = new Thickness(0, 0, 18, 0);
        header.Children.Add(mode); header.Children.Add(switchMode); Children.Add(header); Children.Add(legacy);
        content.ColumnDefinitions.Add(new()); content.ColumnDefinitions.Add(new());
        content.RowDefinitions.Add(new() { Height = GridLength.Auto }); content.RowDefinitions.Add(new() { Height = GridLength.Auto });
        rows.MinWidth = 190; rows.Children.Add(points); rows.Children.Add(x); rows.Children.Add(y); rows.Children.Add(fixedEndpoint);
        exposureAxis.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        exposureAxis.ColumnDefinitions.Add(new());
        exposureAxis.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var maximum = new TextBlock { Text = "+8 EV" };
        exposureAxis.Children.Add(new TextBlock { Text = "−8 EV" });
        exposureAxis.Children.Add(referenceWhite); Grid.SetColumn(referenceWhite, 1);
        exposureAxis.Children.Add(maximum); Grid.SetColumn(maximum, 2);
        AutomationProperties.SetAutomationId(exposureAxis, "curve.hdr.ev-axis");
        plot.Width = canvas.Width; plot.HorizontalAlignment = HorizontalAlignment.Center;
        plot.Children.Add(canvas); plot.Children.Add(exposureAxis);
        content.Children.Add(plot); content.Children.Add(rows); custom.Children.Add(content); custom.Children.Add(hint);
        var actions = new WrapPanel(); actions.Children.Add(add); actions.Children.Add(remove); actions.Children.Add(reset); custom.Children.Add(actions); Children.Add(custom);
        foreach (var button in new[] { switchMode, add, remove, reset }) { button.MinHeight = 32; button.Margin = new Thickness(2); }
        AutomationProperties.SetAutomationId(canvas, "curve.canvas"); AutomationProperties.SetAutomationId(points, "curve.points");
        AutomationProperties.SetAutomationId(switchMode, "curve.switch"); AutomationProperties.SetAutomationId(add, "curve.add");
        AutomationProperties.SetAutomationId(remove, "curve.remove"); AutomationProperties.SetAutomationId(reset, "curve.reset");
        AutomationProperties.SetAutomationId(x.Number, "curve.value.x"); AutomationProperties.SetAutomationId(y.Number, "curve.value.y");
        AutomationProperties.SetAutomationId(legacy.Number, "curve.legacy.value");
        canvas.PrepareEditing = CommitInputs;
        canvas.Changed += Change;
        canvas.SelectionChanged += index => { selected = index; RefreshRows(); };
        points.SelectionChanged += (_, _) => {
            if (syncing || points.SelectedIndex < 0) return;
            canvas.CancelGesture(); x.CancelInput(); y.CancelInput(); selected = points.SelectedIndex;
            Refresh(settings, scalar, source, usesExposureStops);
        };
        x.Changed += (next, dragging) => { if (settings.IsInterior(selected)) Change(settings.Moving(selected, Normalize(next), settings.Points[selected].Y), dragging); };
        y.Changed += (next, dragging) => { if (settings.IsInterior(selected)) Change(settings.Moving(selected, settings.Points[selected].X, Normalize(next)), dragging); };
        legacy.Changed += (next, dragging) => { if (!syncing) { scalar = next; LegacyChanged?.Invoke(next, dragging); } };
        switchMode.Click += (_, _) => {
            if (!CommitInputs()) return;
            var message = Loc.Text(settings.IsDefault ? "多点曲线将从直线开始，旧 S 曲线数值会保留。" : "切换到 S 曲线将移除当前控制点，可撤销此操作。");
            if (MessageBox.Show(Window.GetWindow(this), message, Loc.Text("切换曲线模式"), MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK) {
                selected = 0; Change(settings.IsDefault ? ToneCurveSettings.Identity : new(), false);
            }
        };
        add.Click += (_, _) => {
            if (!CommitInputs() || settings.IsDefault || settings.Points.Count >= 33) return;
            var index = Enumerable.Range(1, settings.Points.Count - 1).MaxBy(i => settings.Points[i].X - settings.Points[i - 1].X);
            var a = settings.Points[index - 1]; var b = settings.Points[index]; selected = index;
            Change(settings.Inserting(a.X + (b.X - a.X) / 2, a.Y + (b.Y - a.Y) / 2), false);
        };
        remove.Click += (_, _) => { if (CommitInputs()) Change(settings.Removing(selected), false); };
        reset.Click += (_, _) => { if (CommitInputs()) { selected = 0; Change(ToneCurveSettings.Identity, false); } };
        SizeChanged += (_, _) => LayoutControls();
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }
    public void CancelInputs() { canvas.CancelGesture(); x.CancelInput(); y.CancelInput(); legacy.CancelInput(); }
    private bool CommitInputs() => settings.IsDefault ? legacy.Commit() : x.Commit() && y.Commit();
    public void RefreshLanguage()
    {
        add.Content = Loc.Text("添加控制点"); remove.Content = Loc.Text("删除控制点"); reset.Content = Loc.Text("重置为直线");
        hint.Text = Loc.Text("点击曲线区域添加控制点，拖动中间点调整。"); fixedEndpoint.Text = Loc.Text("端点固定");
        referenceWhite.Text = "0 EV\n" + Loc.Text("参考白");
        Refresh(settings, scalar, source, usesExposureStops);
    }
    public void Refresh(ToneCurveSettings next, double legacyValue, object? identity, bool hdr = false)
    {
        var wasSyncing = syncing; syncing = true;
        try {
            if (!Equals(source, identity) || usesExposureStops != hdr) { CancelInputs(); selected = 0; }
            source = identity; settings = next; scalar = legacyValue; usesExposureStops = hdr;
            selected = Math.Clamp(selected, 0, Math.Max(0, settings.Points.Count - 1));
            mode.Text = Loc.Text(settings.IsDefault ? "S 曲线" : "多点曲线"); switchMode.Content = Loc.Text(settings.IsDefault ? "多点曲线" : "S 曲线");
            legacy.Visibility = settings.IsDefault ? Visibility.Visible : Visibility.Collapsed;
            custom.Visibility = settings.IsDefault ? Visibility.Collapsed : Visibility.Visible;
            exposureAxis.Visibility = hdr ? Visibility.Visible : Visibility.Collapsed;
            legacy.SourceIdentity = identity; legacy.Refresh(Loc.Text("S 曲线"), new(-100, 100), scalar, 0, "%");
            RefreshRows(); canvas.Refresh(settings, identity, selected); LayoutControls();
            add.IsEnabled = !settings.IsDefault && settings.Points.Count < 33; remove.IsEnabled = settings.IsInterior(selected);
            reset.IsEnabled = !settings.IsDefault && settings != ToneCurveSettings.Identity;
        } finally { syncing = wasSyncing; }
    }
    private double Normalize(double value) => usesExposureStops ? (value + 8) / 16 : value;
    private double Coordinate(double value) => usesExposureStops ? value * 16 - 8 : value;
    private void RefreshRows()
    {
        var wasSyncing = syncing; syncing = true;
        try {
            points.ItemsSource = Enumerable.Range(1, settings.Points.Count).Select(i => Loc.Format("控制点 {0}", i)).ToArray();
            if (settings.IsDefault) return;
            points.SelectedIndex = selected;
            var point = settings.Points[selected]; var enabled = settings.IsInterior(selected);
            x.SourceIdentity = y.SourceIdentity = source;
            var range = usesExposureStops ? new NumericRange(-8, 8, .01, .1, .01, AllowOffGrid: true) :
                new NumericRange(0, 1, .001, .01, .001, AllowOffGrid: true);
            var unit = usesExposureStops ? "EV" : "";
            x.Refresh(Loc.Text("输入坐标"), range, Coordinate(point.X), Coordinate(point.X), unit, enabled: enabled, inputScope: selected);
            y.Refresh(Loc.Text("输出坐标"), range, Coordinate(point.Y), Coordinate(point.X), unit, enabled: enabled, inputScope: selected);
            fixedEndpoint.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        } finally { syncing = wasSyncing; }
    }
    private void LayoutControls()
    {
        var horizontal = ActualWidth >= 470 && System.Windows.Documents.TextElement.GetFontSize(this) < 20;
        content.ColumnDefinitions[0].Width = horizontal ? GridLength.Auto : new(1, GridUnitType.Star);
        content.ColumnDefinitions[1].Width = horizontal ? new(1, GridUnitType.Star) : new(0);
        Grid.SetRow(rows, horizontal ? 0 : 1); Grid.SetColumn(rows, horizontal ? 1 : 0);
        rows.Margin = new Thickness(horizontal ? 12 : 0, 4, 0, 4);
    }
    private void Change(ToneCurveSettings next, bool dragging)
    {
        if (syncing || !IsEnabled) return;
        settings = next; Changed?.Invoke(next, dragging); Refresh(settings, scalar, source, usesExposureStops);
    }
}
