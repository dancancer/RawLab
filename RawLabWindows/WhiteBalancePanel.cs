using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

public sealed class WhiteBalancePanel : StackPanel
{
    private readonly ParameterRow temperature = new();
    private readonly ParameterRow tint = new();
    private readonly Button reset = new() {
        Width = 28, Height = 28, MinHeight = 28, Padding = new Thickness(3),
        Content = new EditorIcon { Kind = "Reset", Width = 16, Height = 16 }
    };
    private bool syncing;

    public event Action<Parameter, double, bool>? Changed;
    public event Action? ResetRequested;

    public WhiteBalancePanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);
        Children.Add(temperature);
        Children.Add(tint);

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetName(reset, Loc.Text("重置白平衡"));
        reset.ToolTip = Loc.Text("重置白平衡");
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };
        actions.Children.Add(reset);
        Children.Add(actions);

        temperature.Changed += (value, dragging) => Publish(Parameter.Temperature, value, dragging);
        tint.Changed += (value, dragging) => Publish(Parameter.Tint, value, dragging);
    }

    public void Refresh(Adjustments settings, bool enabled)
    {
        syncing = true;
        var temperatureSpec = ParameterSpec.All[(int)Parameter.Temperature];
        var tintSpec = ParameterSpec.All[(int)Parameter.Tint];
        temperature.Refresh(Loc.Text(temperatureSpec.Title), NumericRange.For(temperatureSpec),
            settings[Parameter.Temperature], settings.Default(Parameter.Temperature), temperatureSpec.Unit, enabled);
        tint.Refresh(Loc.Text(tintSpec.Title), NumericRange.For(tintSpec),
            settings[Parameter.Tint], settings.Default(Parameter.Tint), tintSpec.Unit, enabled);
        AutomationProperties.SetName(reset, Loc.Text("重置白平衡"));
        reset.ToolTip = Loc.Text("重置白平衡");
        reset.IsEnabled = enabled;
        syncing = false;
    }

    private void Publish(Parameter parameter, double value, bool dragging)
    {
        if (syncing || !IsEnabled) return;
        Changed?.Invoke(parameter, value, dragging);
    }
}
