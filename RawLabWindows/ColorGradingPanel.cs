using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ColorGradingPanel : StackPanel
{
    internal static readonly string[] ZoneKeys = ["阴影", "中间调", "高光"];
    private readonly ColorGradingWheelControl wheel = new();
    private readonly ParameterRow hue = new() { Compact = true }, saturation = new() { Compact = true };
    private readonly Button[] zones = new Button[3];
    private readonly Button resetZone = new(), resetAll = new();
    private readonly Grid content = new();
    private readonly StackPanel rows = new();
    private ColorGradingSettings settings = new();
    private object? source;
    private bool syncing;
    public ColorGradingZone SelectedZone { get; private set; }
    public event Action<ColorGradingSettings, bool>? Changed;
    public event Action<EditorResetScope>? ResetRequested;
    public ColorGradingPanel()
    {
        MaxWidth = 720; Margin = new Thickness(8);
        var selector = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var zone in Enum.GetValues<ColorGradingZone>()) {
            var button = new Button { MinHeight = 32, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(2) };
            button.Click += (_, _) => SelectZone(zone);
            AutomationProperties.SetAutomationId(button, "grading.zone." + zone.ToString().ToLowerInvariant());
            zones[(int)zone] = button; selector.Children.Add(button);
        }
        selector.PreviewMouseDown += (_, _) => CancelInputs();
        Children.Add(selector);
        content.ColumnDefinitions.Add(new()); content.ColumnDefinitions.Add(new());
        content.RowDefinitions.Add(new() { Height = GridLength.Auto }); content.RowDefinitions.Add(new() { Height = GridLength.Auto });
        rows.Children.Add(hue); rows.Children.Add(saturation); rows.MinWidth = 180;
        content.Children.Add(wheel); content.Children.Add(rows); Children.Add(content);
        wheel.PrepareEditing = () => hue.Commit() && saturation.Commit();
        wheel.Changed += (next, dragging) => Change(next, dragging);
        hue.Changed += (next, dragging) => { if (ColorGradingWheel.InputHue(next) is {} normalized) Change(settings[SelectedZone] with { Hue = normalized }, dragging); };
        saturation.Changed += (next, dragging) => Change(settings[SelectedZone] with { Saturation = next }, dragging);
        var resets = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        resetZone.Click += (_, _) => ResetRequested?.Invoke(new(EditorResetKind.GradingZone, Zone: SelectedZone));
        resetAll.Click += (_, _) => ResetRequested?.Invoke(new(EditorResetKind.AllGrading));
        resets.Children.Add(resetZone); resets.Children.Add(resetAll); Children.Add(resets);
        AutomationProperties.SetAutomationId(hue.Number, "grading.value.hue");
        AutomationProperties.SetAutomationId(saturation.Number, "grading.value.saturation");
        SizeChanged += (_, _) => LayoutControls();
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage(); LayoutControls();
    }
    private void LayoutControls()
    {
        var horizontal = ActualWidth >= 400 && System.Windows.Documents.TextElement.GetFontSize(this) < 20;
        content.ColumnDefinitions[0].Width = horizontal ? GridLength.Auto : new(1, GridUnitType.Star);
        content.ColumnDefinitions[1].Width = horizontal ? new(1, GridUnitType.Star) : new(0);
        Grid.SetRow(rows, horizontal ? 0 : 1); Grid.SetColumn(rows, horizontal ? 1 : 0);
        rows.VerticalAlignment = VerticalAlignment.Center;
        rows.Margin = new Thickness(horizontal ? 12 : 0, 4, 0, 4);
        wheel.HorizontalAlignment = HorizontalAlignment.Center;
    }
    public void CancelInputs() { wheel.CancelGesture(); hue.CancelInput(); saturation.CancelInput(); }
    public void SelectZone(ColorGradingZone zone)
    {
        if (!Enum.IsDefined(zone)) throw new ArgumentOutOfRangeException(nameof(zone));
        CancelInputs(); SelectedZone = zone; Refresh(settings, source);
    }
    public void RefreshLanguage()
    {
        resetZone.Content = Loc.Text("重置当前分区"); resetAll.Content = Loc.Text("重置颜色分级");
        Refresh(settings, source);
    }
    public void Refresh(ColorGradingSettings next, object? identity)
    {
        syncing = true;
        try {
            if (!Equals(source, identity)) { CancelInputs(); SelectedZone = ColorGradingZone.Shadows; }
            source = identity; settings = next;
            hue.SourceIdentity = saturation.SourceIdentity = identity;
            var selected = settings[SelectedZone];
            hue.Refresh(Loc.Text("色相"), new(0, 360), selected.Hue, 0, "°", inputScope: SelectedZone);
            saturation.Refresh(Loc.Text("饱和度"), new(0, 100), selected.Saturation, 0, "%", inputScope: SelectedZone);
            wheel.Refresh(selected, identity, SelectedZone);
            for (var i = 0; i < zones.Length; i++) {
                var zone = (ColorGradingZone)i;
                zones[i].Content = Loc.Text(ZoneKeys[i]) + (settings[zone].IsDefault ? "" : " ·");
                zones[i].Tag = zone == SelectedZone ? "selected" : null;
                AutomationProperties.SetName(zones[i], Loc.Text(ZoneKeys[i]));
                AutomationProperties.SetItemStatus(zones[i], Loc.Text(settings[zone].IsDefault ? "未调整" : "已调整"));
            }
            resetZone.IsEnabled = !selected.IsDefault; resetAll.IsEnabled = !settings.IsDefault;
        } finally { syncing = false; }
    }
    private void Change(ColorGradingWheel next, bool dragging)
    {
        if (syncing || !IsEnabled || !next.IsValid) return;
        settings = settings.With(SelectedZone, next);
        Changed?.Invoke(settings, dragging);
        Refresh(settings, source);
    }
}
