using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace RawLab.Windows;

public sealed class WhiteBalancePanel : StackPanel
{
    private readonly TextBlock relativeNote = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 4), TextWrapping = TextWrapping.Wrap };
    private readonly ToggleButton eyedropper = new() { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 4) };
    private readonly TextBlock probeStatus = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 6), TextWrapping = TextWrapping.Wrap };
    private readonly ParameterRow temperature = new();
    private readonly ParameterRow tint = new();
    internal ParameterRow TemperatureRow => temperature;
    internal ParameterRow TintRow => tint;
    internal ToggleButton EyedropperButton => eyedropper;
    internal TextBlock ProbeStatusBlock => probeStatus;
    // 分组重置写成文字按钮，与普通参数的“重置分组”、HSL 的“重置 HSL”一致；
    // 无字的图标会和两行各自的重置图标叠成一列，看起来像多出来的第三个
    private readonly Button reset = new();
    private bool syncing;

    public event Action<Parameter, double, bool>? Changed;
    public event Action? ResetRequested;
    public event Action<bool>? EyedropperToggled;

    public WhiteBalancePanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);
        relativeNote.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        probeStatus.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        AutomationProperties.SetAutomationId(eyedropper, "wb.eyedropper");
        AutomationProperties.SetAutomationId(probeStatus, "wb.eyedropper.status");
        eyedropper.Click += (_, _) => { if (!syncing) EyedropperToggled?.Invoke(eyedropper.IsChecked == true); };
        Children.Add(relativeNote);
        Children.Add(eyedropper);
        Children.Add(probeStatus);
        Children.Add(temperature);
        Children.Add(tint);

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };
        actions.Children.Add(reset);
        Children.Add(actions);

        temperature.Changed += (value, dragging) => Publish(Parameter.Temperature, value, dragging);
        tint.Changed += (value, dragging) => Publish(Parameter.Tint, value, dragging);
    }

    public void Refresh(Adjustments settings, bool enabled, bool isRaster = false,
        bool wbProbeAvailable = false, bool wbProbeEnabled = false, string? wbProbeNotice = null)
    {
        syncing = true;
        relativeNote.Text = Loc.Text("相对白平衡");
        relativeNote.Visibility = (isRaster || settings.IsHDREditing) ? Visibility.Visible : Visibility.Collapsed;
        eyedropper.Content = Loc.Text("白平衡吸管");
        AutomationProperties.SetName(eyedropper, Loc.Text("白平衡吸管"));
        AutomationProperties.SetItemStatus(eyedropper, Loc.Text(wbProbeEnabled ? "开启" : "关闭"));
        eyedropper.IsChecked = wbProbeEnabled;
        eyedropper.Visibility = settings.IsHDREditing ? Visibility.Collapsed : Visibility.Visible;
        eyedropper.IsEnabled = wbProbeAvailable;
        probeStatus.Text = wbProbeNotice ?? "";
        probeStatus.Visibility = !settings.IsHDREditing && !string.IsNullOrEmpty(wbProbeNotice) ? Visibility.Visible : Visibility.Collapsed;
        var temperatureSpec = ParameterSpec.All[(int)Parameter.Temperature];
        var tintSpec = ParameterSpec.All[(int)Parameter.Tint];
        temperature.Refresh(Loc.Text(temperatureSpec.Title), NumericRange.For(temperatureSpec),
            settings[Parameter.Temperature], settings.Default(Parameter.Temperature), temperatureSpec.Unit, enabled);
        tint.Refresh(Loc.Text(tintSpec.Title), NumericRange.For(tintSpec),
            settings[Parameter.Tint], settings.Default(Parameter.Tint), tintSpec.Unit, enabled);
        AutomationProperties.SetName(reset, Loc.Text("重置白平衡"));
        reset.Content = Loc.Text("重置白平衡");
        reset.IsEnabled = enabled;
        syncing = false;
    }

    private void Publish(Parameter parameter, double value, bool dragging)
    {
        if (syncing || !IsEnabled) return;
        Changed?.Invoke(parameter, value, dragging);
    }
}
