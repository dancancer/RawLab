using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public enum PhotoEffectTool { Vignette, Grain }

public partial class PhotoEffectsPanel : UserControl
{
    private PhotoEffectsSettings value = new();
    private PhotoEffectTool tool;
    private bool syncing, dragging;
    public event Action<PhotoEffectsSettings, bool>? Changed;

    public PhotoEffectsPanel()
    {
        InitializeComponent();
        SizeChanged += (_, _) => ReflowColumns();
        foreach (var slider in new[] {
            VignetteAmountSlider, VignetteMidpointSlider, VignetteRoundnessSlider, VignetteFeatherSlider,
            VignetteHighlightsSlider, GrainAmountSlider, GrainSizeSlider, GrainRoughnessSlider
        })
        {
            slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
            slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => { dragging = false; Changed?.Invoke(value, false); }));
        }
        Refresh(value, PhotoEffectTool.Vignette);
    }

    private void ReflowColumns()
    {
        var columns = Math.Clamp((int)((ActualWidth - 8) / 148), 1, 5);
        VignetteParameters.Columns = columns == 4 ? 3 : columns;
        GrainParameters.Columns = Math.Min(columns, 3);
    }

    public void Refresh(PhotoEffectsSettings settings, PhotoEffectTool selected)
    {
        syncing = true;
        value = settings;
        tool = selected;
        Title.Text = selected == PhotoEffectTool.Vignette ? "暗角" : "颗粒";
        VignetteParameters.Visibility = selected == PhotoEffectTool.Vignette ? Visibility.Visible : Visibility.Collapsed;
        GrainParameters.Visibility = selected == PhotoEffectTool.Grain ? Visibility.Visible : Visibility.Collapsed;
        Set(VignetteAmountSlider, VignetteAmountText, PhotoEffectParameter.VignetteAmount);
        Set(VignetteMidpointSlider, VignetteMidpointText, PhotoEffectParameter.VignetteMidpoint);
        Set(VignetteRoundnessSlider, VignetteRoundnessText, PhotoEffectParameter.VignetteRoundness);
        Set(VignetteFeatherSlider, VignetteFeatherText, PhotoEffectParameter.VignetteFeather);
        Set(VignetteHighlightsSlider, VignetteHighlightsText, PhotoEffectParameter.VignetteHighlights);
        Set(GrainAmountSlider, GrainAmountText, PhotoEffectParameter.GrainAmount);
        Set(GrainSizeSlider, GrainSizeText, PhotoEffectParameter.GrainSize);
        Set(GrainRoughnessSlider, GrainRoughnessText, PhotoEffectParameter.GrainRoughness);
        VignetteMidpointParameters.IsEnabled = VignetteRoundnessParameters.IsEnabled =
            VignetteFeatherParameters.IsEnabled = value.VignetteAmount != 0;
        // Highlights protection only applies while a negative vignette darkens pixels.
        VignetteHighlightsParameters.IsEnabled = value.VignetteAmount < 0;
        GrainSizeParameters.IsEnabled = GrainRoughnessParameters.IsEnabled = value.GrainAmount != 0;
        ResetGroupButton.IsEnabled = PhotoEffectSpec.All.Where(spec => spec.IsVignette == (selected == PhotoEffectTool.Vignette))
            .Any(spec => value[spec.Id] != spec.DefaultValue);
        syncing = false;
    }

    private void Set(Slider slider, TextBox text, PhotoEffectParameter parameter)
    {
        var number = value[parameter];
        slider.Value = number;
        text.Text = number.ToString("F0", CultureInfo.CurrentCulture);
    }

    private void Publish(PhotoEffectsSettings next, bool interactive = false)
    {
        if (syncing || !IsEnabled) return;
        Refresh(next, tool);
        Changed?.Invoke(value, interactive);
    }

    private void SliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!syncing && sender is Slider slider && slider.Tag is string name && Enum.TryParse<PhotoEffectParameter>(name, out var parameter))
            SetValue(parameter, e.NewValue, dragging);
    }

    private void SetValue(PhotoEffectParameter parameter, double number, bool interactive = false)
    {
        var spec = PhotoEffectSpec.For(parameter);
        number = Math.Clamp(Math.Round(number, MidpointRounding.AwayFromZero), spec.Min, spec.Max);
        var next = parameter switch {
            PhotoEffectParameter.VignetteAmount => value with { VignetteAmount = number },
            PhotoEffectParameter.VignetteMidpoint => value with { VignetteMidpoint = number },
            PhotoEffectParameter.VignetteRoundness => value with { VignetteRoundness = number },
            PhotoEffectParameter.VignetteFeather => value with { VignetteFeather = number },
            PhotoEffectParameter.VignetteHighlights => value with { VignetteHighlights = number },
            PhotoEffectParameter.GrainAmount => value with { GrainAmount = number },
            PhotoEffectParameter.GrainSize => value with { GrainSize = number },
            PhotoEffectParameter.GrainRoughness => value with { GrainRoughness = number },
            _ => value
        };
        if (next != value) Publish(next, interactive);
        else Refresh(value, tool);
    }

    private void Commit(TextBox box)
    {
        if (box.Tag is string name && Enum.TryParse<PhotoEffectParameter>(name, out var parameter) &&
            double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var number) && double.IsFinite(number))
            SetValue(parameter, number);
        else Refresh(value, tool);
    }

    private void ValueCommitted(object sender, KeyboardFocusChangedEventArgs e) { if (!syncing) Commit((TextBox)sender); }
    private void ValueKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Commit((TextBox)sender); e.Handled = true; }
        if (e.Key == Key.Escape) { Refresh(value, tool); e.Handled = true; }
    }

    private void ResetValue(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string name } && Enum.TryParse<PhotoEffectParameter>(name, out var parameter))
            SetValue(parameter, PhotoEffectSpec.For(parameter).DefaultValue);
    }

    private void ResetGroupClicked(object sender, RoutedEventArgs e)
    {
        var vignette = tool == PhotoEffectTool.Vignette;
        var next = value;
        foreach (var spec in PhotoEffectSpec.All.Where(spec => spec.IsVignette == vignette))
            next = spec.Id switch {
                PhotoEffectParameter.VignetteAmount => next with { VignetteAmount = spec.DefaultValue },
                PhotoEffectParameter.VignetteMidpoint => next with { VignetteMidpoint = spec.DefaultValue },
                PhotoEffectParameter.VignetteRoundness => next with { VignetteRoundness = spec.DefaultValue },
                PhotoEffectParameter.VignetteFeather => next with { VignetteFeather = spec.DefaultValue },
                PhotoEffectParameter.VignetteHighlights => next with { VignetteHighlights = spec.DefaultValue },
                PhotoEffectParameter.GrainAmount => next with { GrainAmount = spec.DefaultValue },
                PhotoEffectParameter.GrainSize => next with { GrainSize = spec.DefaultValue },
                PhotoEffectParameter.GrainRoughness => next with { GrainRoughness = spec.DefaultValue },
                _ => next
            };
        Publish(next);
    }
}
