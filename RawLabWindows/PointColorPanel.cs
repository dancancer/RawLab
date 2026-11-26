using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class PointColorPanel : StackPanel
{
    private PointColorSettings settings = new();
    private int selectedIndex;
    private object? source;
    private bool syncing;

    private readonly ToggleButton eyedropper = new() { Margin = new Thickness(0, 0, 6, 4) };
    private readonly Button addSwatch = new() { Margin = new Thickness(0, 0, 6, 4) };
    private readonly Button deleteSwatch = new() { Margin = new Thickness(0, 0, 6, 4) };
    private readonly Button reset = new() { Margin = new Thickness(0, 0, 0, 4) };
    private readonly TextBlock probeStatus = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 6), TextWrapping = TextWrapping.Wrap };
    private readonly WrapPanel swatchStrip = new() { Margin = new Thickness(0, 2, 0, 6) };
    private readonly StackPanel editorBody = new();

    private readonly Border beforeSwatch = new() { Width = 28, Height = 20, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1), BorderBrush = Brushes.Gray };
    private readonly Border afterSwatch = new() { Width = 28, Height = 20, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1), BorderBrush = Brushes.Gray };
    private readonly TextBlock beforeLabel = new() { Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock afterLabel = new() { Margin = new Thickness(6, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock swatchReadout = new() { Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly CheckBox swatchEnabled = new() { Margin = new Thickness(0, 4, 0, 4) };

    private readonly ParameterRow hueShift = new();
    private readonly ParameterRow saturationShift = new();
    private readonly ParameterRow luminanceShift = new();
    private readonly ParameterRow variance = new();
    private readonly ParameterRow range = new();
    private readonly ParameterRow hueRange = new();
    private readonly ParameterRow satRange = new();
    private readonly ParameterRow lumRange = new();

    public event Action<PointColorSettings, bool>? Changed;
    public event Action? ResetRequested;
    public event Action<bool>? EyedropperToggled;

    public int SelectedSwatchIndex => settings.Swatches.Count == 0
        ? 0
        : Math.Clamp(selectedIndex, 0, settings.Swatches.Count - 1);

    public void SelectSwatch(int index)
    {
        if (settings.Swatches.Count == 0) return;
        var clamped = Math.Clamp(index, 0, settings.Swatches.Count - 1);
        if (selectedIndex == clamped) return;
        CancelInputs();
        selectedIndex = clamped;
        Refresh(settings, source, eyedropper.IsChecked == true, eyedropper.IsEnabled, probeStatus.Visibility == Visibility.Visible ? probeStatus.Text : null);
    }

    public PointColorPanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);

        probeStatus.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        swatchReadout.SetResourceReference(TextBlock.ForegroundProperty, "Muted");

        var actions = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) };
        AutomationProperties.SetAutomationId(eyedropper, "pointColor.eyedropper");
        AutomationProperties.SetAutomationId(addSwatch, "pointColor.addSwatch");
        AutomationProperties.SetAutomationId(deleteSwatch, "pointColor.deleteSwatch");
        AutomationProperties.SetAutomationId(reset, "pointColor.reset");
        AutomationProperties.SetAutomationId(probeStatus, "pointColor.eyedropper.status");
        AutomationProperties.SetAutomationId(swatchEnabled, "pointColor.swatch.enabled");

        eyedropper.Click += (_, _) => { if (!syncing) EyedropperToggled?.Invoke(eyedropper.IsChecked == true); };
        addSwatch.Click += (_, _) => AddDefaultSwatch();
        deleteSwatch.Click += (_, _) => DeleteSelectedSwatch();
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };

        actions.Children.Add(eyedropper);
        actions.Children.Add(addSwatch);
        actions.Children.Add(deleteSwatch);
        actions.Children.Add(reset);
        Children.Add(actions);
        Children.Add(probeStatus);
        Children.Add(swatchStrip);

        var previewRow = new WrapPanel { Margin = new Thickness(0, 2, 0, 4), VerticalAlignment = VerticalAlignment.Center };
        previewRow.Children.Add(beforeLabel);
        previewRow.Children.Add(beforeSwatch);
        previewRow.Children.Add(afterLabel);
        previewRow.Children.Add(afterSwatch);
        previewRow.Children.Add(swatchReadout);
        editorBody.Children.Add(previewRow);

        swatchEnabled.Click += (_, _) => UpdateSelected(sw => sw with { Enabled = swatchEnabled.IsChecked == true }, false);
        editorBody.Children.Add(swatchEnabled);

        foreach (var row in AllRows())
            editorBody.Children.Add(row);

        hueShift.Changed += (v, d) => UpdateSelected(sw => sw with { HueShift = v }, d);
        saturationShift.Changed += (v, d) => UpdateSelected(sw => sw with { SaturationShift = v }, d);
        luminanceShift.Changed += (v, d) => UpdateSelected(sw => sw with { LuminanceShift = v }, d);
        variance.Changed += (v, d) => UpdateSelected(sw => sw with { Variance = v }, d);
        range.Changed += (v, d) => UpdateSelected(sw => sw with { Range = v }, d);
        hueRange.Changed += (v, d) => UpdateSelected(sw => sw with { HueRange = v }, d);
        satRange.Changed += (v, d) => UpdateSelected(sw => sw with { SatRange = v }, d);
        lumRange.Changed += (v, d) => UpdateSelected(sw => sw with { LumRange = v }, d);

        AutomationProperties.SetAutomationId(hueShift.Number, "pointColor.value.hueShift");
        AutomationProperties.SetAutomationId(saturationShift.Number, "pointColor.value.saturationShift");
        AutomationProperties.SetAutomationId(luminanceShift.Number, "pointColor.value.luminanceShift");
        AutomationProperties.SetAutomationId(variance.Number, "pointColor.value.variance");
        AutomationProperties.SetAutomationId(range.Number, "pointColor.value.range");
        AutomationProperties.SetAutomationId(hueRange.Number, "pointColor.value.hueRange");
        AutomationProperties.SetAutomationId(satRange.Number, "pointColor.value.satRange");
        AutomationProperties.SetAutomationId(lumRange.Number, "pointColor.value.lumRange");

        Children.Add(editorBody);
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }

    private IEnumerable<ParameterRow> AllRows() =>
        [hueShift, saturationShift, luminanceShift, variance, range, hueRange, satRange, lumRange];

    private void AddDefaultSwatch()
    {
        if (syncing || !IsEnabled || settings.Swatches.Count >= AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches) return;
        CancelInputs();
        var list = settings.Swatches.ToList();
        list.Add(new PointColorSwatch(SrcHue: 30, SrcSaturation: 0.45, SrcLuminance: 0.65));
        settings = new PointColorSettings(list);
        selectedIndex = list.Count - 1;
        Refresh(settings, source, eyedropper.IsChecked == true, eyedropper.IsEnabled, probeStatus.Visibility == Visibility.Visible ? probeStatus.Text : null);
        Changed?.Invoke(settings, false);
    }

    private void DeleteSelectedSwatch()
    {
        if (syncing || !IsEnabled || settings.Swatches.Count == 0) return;
        CancelInputs();
        var list = settings.Swatches.ToList();
        var idx = SelectedSwatchIndex;
        list.RemoveAt(idx);
        settings = new PointColorSettings(list);
        selectedIndex = Math.Clamp(idx, 0, Math.Max(0, list.Count - 1));
        Refresh(settings, source, eyedropper.IsChecked == true, eyedropper.IsEnabled, probeStatus.Visibility == Visibility.Visible ? probeStatus.Text : null);
        Changed?.Invoke(settings, false);
    }

    private void UpdateSelected(Func<PointColorSwatch, PointColorSwatch> transform, bool dragging)
    {
        if (syncing || !IsEnabled || settings.Swatches.Count == 0) return;
        var list = settings.Swatches.ToList();
        var idx = SelectedSwatchIndex;
        list[idx] = transform(list[idx]);
        settings = new PointColorSettings(list);
        Refresh(settings, source, eyedropper.IsChecked == true, eyedropper.IsEnabled, probeStatus.Visibility == Visibility.Visible ? probeStatus.Text : null);
        Changed?.Invoke(settings, dragging);
    }

    public void CancelInputs()
    {
        foreach (var row in AllRows()) row.CancelInput();
    }

    public void RefreshLanguage()
    {
        eyedropper.Content = Loc.Text("吸管取样");
        AutomationProperties.SetName(eyedropper, Loc.Text("吸管取样"));
        addSwatch.Content = Loc.Text("添加色板");
        AutomationProperties.SetName(addSwatch, Loc.Text("添加色板"));
        deleteSwatch.Content = Loc.Text("删除");
        AutomationProperties.SetName(deleteSwatch, Loc.Text("删除"));
        reset.Content = Loc.Text("重置");
        AutomationProperties.SetName(reset, Loc.Format("重置{0}", Loc.Text("点颜色")));
        beforeLabel.Text = Loc.Text("调整前");
        afterLabel.Text = Loc.Text("调整后");
        swatchEnabled.Content = Loc.Text("已启用");
        AutomationProperties.SetName(swatchEnabled, Loc.Text("已启用"));
        Refresh(settings, source, eyedropper.IsChecked == true, eyedropper.IsEnabled, probeStatus.Visibility == Visibility.Visible ? probeStatus.Text : null);
    }

    public void Refresh(
        PointColorSettings next,
        object? identity,
        bool eyedropperEnabled = false,
        bool eyedropperAvailable = true,
        string? notice = null)
    {
        syncing = true;
        try
        {
            if (!Equals(source, identity)) { CancelInputs(); selectedIndex = 0; }
            source = identity;
            settings = next;
            selectedIndex = next.Swatches.Count == 0 ? 0 : Math.Clamp(selectedIndex, 0, next.Swatches.Count - 1);

            eyedropper.IsChecked = eyedropperEnabled;
            eyedropper.IsEnabled = eyedropperAvailable && next.Swatches.Count < AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches;
            AutomationProperties.SetItemStatus(eyedropper, Loc.Text(eyedropperEnabled ? "开启" : "关闭"));

            addSwatch.IsEnabled = next.Swatches.Count < AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches;
            deleteSwatch.IsEnabled = next.Swatches.Count > 0;
            reset.IsEnabled = !next.IsDefault;

            probeStatus.Text = notice ?? "";
            probeStatus.Visibility = !string.IsNullOrEmpty(notice) ? Visibility.Visible : Visibility.Collapsed;

            swatchStrip.Children.Clear();
            for (var i = 0; i < next.Swatches.Count; i++)
            {
                var idx = i;
                var swatch = next.Swatches[i];
                var preview = InspectionNative.PointColorPreviewSwatch(swatch);
                var fill = preview is { } p
                    ? Color.FromRgb(p.SrcR, p.SrcG, p.SrcB)
                    : Color.FromRgb(128, 128, 128);
                var chip = new Border
                {
                    Width = 18,
                    Height = 18,
                    CornerRadius = new CornerRadius(9),
                    Background = new SolidColorBrush(fill),
                    BorderBrush = Brushes.White,
                    BorderThickness = new Thickness(1),
                    Opacity = swatch.Enabled ? 1.0 : 0.4,
                };
                var btn = new Button
                {
                    Content = chip,
                    Padding = new Thickness(4),
                    Margin = new Thickness(2),
                    Tag = i == selectedIndex ? "selected" : null,
                };
                if (i == selectedIndex) btn.SetResourceReference(Button.BorderBrushProperty, "Indicator");
                AutomationProperties.SetAutomationId(btn, $"pointColor.swatch.{i}");
                AutomationProperties.SetName(btn, $"{Loc.Text("色板")} {i + 1}");
                btn.Click += (_, _) => SelectSwatch(idx);
                swatchStrip.Children.Add(btn);
            }

            editorBody.Visibility = next.Swatches.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (next.Swatches.Count > 0)
            {
                var current = next.Swatches[selectedIndex];
                var preview = InspectionNative.PointColorPreviewSwatch(current);
                if (preview is { } p)
                {
                    beforeSwatch.Background = new SolidColorBrush(Color.FromRgb(p.SrcR, p.SrcG, p.SrcB));
                    afterSwatch.Background = new SolidColorBrush(Color.FromRgb(p.ShiftedR, p.ShiftedG, p.ShiftedB));
                }
                else
                {
                    beforeSwatch.Background = Brushes.Transparent;
                    afterSwatch.Background = Brushes.Transparent;
                }
                swatchReadout.Text = string.Format(
                    CultureInfo.InvariantCulture,
                    "H {0:F0}°  S {1:F0}%  L {2:F0}%",
                    current.SrcHue,
                    current.SrcSaturation * 100.0,
                    current.SrcLuminance * 100.0);
                swatchEnabled.IsChecked = current.Enabled;

                foreach (var row in AllRows()) row.SourceIdentity = identity;
                var shiftRange = new NumericRange(-100, 100);
                var controlRange = new NumericRange(0, 100);
                object scope = selectedIndex;

                hueShift.Refresh(Loc.Text("色相偏移"), shiftRange, current.HueShift, 0, inputScope: scope);
                saturationShift.Refresh(Loc.Text("饱和度偏移"), shiftRange, current.SaturationShift, 0, inputScope: scope);
                luminanceShift.Refresh(Loc.Text("明亮度偏移"), shiftRange, current.LuminanceShift, 0, inputScope: scope);
                variance.Refresh(Loc.Text("方差"), shiftRange, current.Variance, 0, inputScope: scope);
                range.Refresh(Loc.Text("范围"), controlRange, current.Range, 50, inputScope: scope);
                hueRange.Refresh(Loc.Text("色相范围"), controlRange, current.HueRange, 50, inputScope: scope);
                satRange.Refresh(Loc.Text("饱和度范围"), controlRange, current.SatRange, 50, inputScope: scope);
                lumRange.Refresh(Loc.Text("明亮度范围"), controlRange, current.LumRange, 50, inputScope: scope);
            }
        }
        finally
        {
            syncing = false;
        }
    }
}
