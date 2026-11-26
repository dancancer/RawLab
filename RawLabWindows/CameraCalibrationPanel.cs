using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

public sealed class CameraCalibrationPanel : StackPanel
{
    private CameraCalibrationSettings settings = new();
    private object? source;
    private bool syncing;

    private readonly ParameterRow shadowTint = new();
    private readonly ParameterRow redHue = new(), redSaturation = new();
    private readonly ParameterRow greenHue = new(), greenSaturation = new();
    private readonly ParameterRow blueHue = new(), blueSaturation = new();
    private readonly TextBlock redHeader = new() { Margin = new Thickness(0, 6, 0, 2) };
    private readonly TextBlock greenHeader = new() { Margin = new Thickness(0, 6, 0, 2) };
    private readonly TextBlock blueHeader = new() { Margin = new Thickness(0, 6, 0, 2) };
    private readonly Button reset = new();

    public event Action<CameraCalibrationSettings, bool>? Changed;
    public event Action? ResetRequested;

    public CameraCalibrationPanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);

        redHeader.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        greenHeader.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        blueHeader.SetResourceReference(TextBlock.ForegroundProperty, "Muted");

        Children.Add(shadowTint);
        Children.Add(redHeader);
        Children.Add(redHue);
        Children.Add(redSaturation);
        Children.Add(greenHeader);
        Children.Add(greenHue);
        Children.Add(greenSaturation);
        Children.Add(blueHeader);
        Children.Add(blueHue);
        Children.Add(blueSaturation);

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) };
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };
        actions.Children.Add(reset);
        Children.Add(actions);

        shadowTint.Changed += (value, dragging) => Publish(settings with { ShadowTint = value }, dragging);
        redHue.Changed += (value, dragging) => Publish(settings with { RedHue = value }, dragging);
        redSaturation.Changed += (value, dragging) => Publish(settings with { RedSaturation = value }, dragging);
        greenHue.Changed += (value, dragging) => Publish(settings with { GreenHue = value }, dragging);
        greenSaturation.Changed += (value, dragging) => Publish(settings with { GreenSaturation = value }, dragging);
        blueHue.Changed += (value, dragging) => Publish(settings with { BlueHue = value }, dragging);
        blueSaturation.Changed += (value, dragging) => Publish(settings with { BlueSaturation = value }, dragging);

        AutomationProperties.SetAutomationId(shadowTint.Number, "calibration.value.shadowTint");
        AutomationProperties.SetAutomationId(redHue.Number, "calibration.value.redHue");
        AutomationProperties.SetAutomationId(redSaturation.Number, "calibration.value.redSaturation");
        AutomationProperties.SetAutomationId(greenHue.Number, "calibration.value.greenHue");
        AutomationProperties.SetAutomationId(greenSaturation.Number, "calibration.value.greenSaturation");
        AutomationProperties.SetAutomationId(blueHue.Number, "calibration.value.blueHue");
        AutomationProperties.SetAutomationId(blueSaturation.Number, "calibration.value.blueSaturation");
        AutomationProperties.SetAutomationId(reset, "calibration.reset");

        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }

    private void Publish(CameraCalibrationSettings next, bool dragging)
    {
        if (syncing || !IsEnabled) return;
        settings = next;
        Refresh(settings, source);
        Changed?.Invoke(settings, dragging);
    }

    public void CancelInputs()
    {
        foreach (var row in new[] { shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation })
            row.CancelInput();
    }

    public void RefreshLanguage()
    {
        redHeader.Text = Loc.Text("红原色");
        greenHeader.Text = Loc.Text("绿原色");
        blueHeader.Text = Loc.Text("蓝原色");
        reset.Content = Loc.Text("重置");
        AutomationProperties.SetName(reset, Loc.Format("重置{0}", Loc.Text("相机校准")));
        Refresh(settings, source);
    }

    public void Refresh(CameraCalibrationSettings next, object? identity)
    {
        syncing = true;
        try
        {
            if (!Equals(source, identity)) CancelInputs();
            source = identity;
            settings = next;
            var range = new NumericRange(-100, 100);
            foreach (var row in new[] { shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation })
                row.SourceIdentity = identity;

            shadowTint.Refresh(Loc.Text("阴影色调"), range, next.ShadowTint, 0, inputScope: "calibration");
            redHue.Refresh(Loc.Text("红原色色相"), range, next.RedHue, 0, inputScope: "calibration");
            redSaturation.Refresh(Loc.Text("红原色饱和度"), range, next.RedSaturation, 0, inputScope: "calibration");
            greenHue.Refresh(Loc.Text("绿原色色相"), range, next.GreenHue, 0, inputScope: "calibration");
            greenSaturation.Refresh(Loc.Text("绿原色饱和度"), range, next.GreenSaturation, 0, inputScope: "calibration");
            blueHue.Refresh(Loc.Text("蓝原色色相"), range, next.BlueHue, 0, inputScope: "calibration");
            blueSaturation.Refresh(Loc.Text("蓝原色饱和度"), range, next.BlueSaturation, 0, inputScope: "calibration");
            reset.IsEnabled = !next.IsDefault;
        }
        finally
        {
            syncing = false;
        }
    }
}
