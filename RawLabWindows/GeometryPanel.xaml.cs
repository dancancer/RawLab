using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class GeometryPanel : UserControl
{
    private GeometrySettings value = new();
    private bool syncing = true, dragging, swapped, canvasReady;
    private double canvasWidth, canvasHeight;
    public CropAspectPreset Preset => (CropAspectPreset)Math.Max(0, AspectPreset.SelectedIndex);
    public double? AspectRatio => CropInteraction.Ratio(Preset, canvasWidth, canvasHeight, swapped);
    public bool ShowCorrectionGrid => GeometryTabs.SelectedIndex == 1;
    public event Action? ApplyRequested, CancelRequested, GridChanged;
    public event Action<GeometrySettings, bool>? Changed;
    public GeometryPanel()
    {
        InitializeComponent();
        foreach (var slider in new[] { PerspectiveHorizontalSlider, PerspectiveVerticalSlider, StraightenSlider }) {
            slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
            slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => {
                dragging = false; Changed?.Invoke(value, false);
            }));
        }
        Refresh(value);
    }
    public void Refresh(GeometrySettings settings)
    {
        syncing = true; value = settings;
        CropX.Text = Number(value.CropX * 100); CropY.Text = Number(value.CropY * 100);
        CropWidth.Text = Number(value.CropWidth * 100); CropHeight.Text = Number(value.CropHeight * 100);
        HorizontalFlip.Tag = value.FlipHorizontal ? "selected" : null; VerticalFlip.Tag = value.FlipVertical ? "selected" : null;
        SwapAspect.IsEnabled = Preset is not (CropAspectPreset.Free or CropAspectPreset.Square) && canvasReady;
        PerspectiveHorizontalSlider.Value = value.PerspectiveHorizontal * 100;
        PerspectiveHorizontalText.Text = Number(value.PerspectiveHorizontal * 100);
        PerspectiveVerticalSlider.Value = value.PerspectiveVertical * 100;
        PerspectiveVerticalText.Text = Number(value.PerspectiveVertical * 100);
        StraightenSlider.Value = value.StraightenDegrees; StraightenText.Text = Number(value.StraightenDegrees);
        ResetGeometry.IsEnabled = !value.IsIdentity;
        syncing = false;
    }
    public void Begin(GeometrySettings settings)
    {
        syncing = true; swapped = false; AspectPreset.SelectedIndex = 0; GeometryTabs.SelectedIndex = 0;
        canvasWidth = canvasHeight = 0; canvasReady = false; Refresh(settings);
    }
    public void SetCanvasSize(int width, int height)
    {
        canvasReady = width > 0 && height > 0;
        ApplyGeometry.IsEnabled = AspectPreset.IsEnabled = canvasReady;
        if (!canvasReady) { Refresh(value); return; }
        var changed = canvasWidth > 0 && (canvasWidth != width || canvasHeight != height);
        canvasWidth = width; canvasHeight = height;
        Refresh(value);
        if (changed && Preset != CropAspectPreset.Free)
            Publish(CropInteraction.Applying(CropInteraction.MaintainingRatio(AspectRatio, canvasWidth, canvasHeight,
                CropInteraction.FromGeometry(value)), value));
    }
    public void CommitFocusedValue()
    {
        if (Keyboard.FocusedElement is TextBox box && IsAncestorOf(box)) Commit(box);
    }
    private void FitAspect() => Publish(CropInteraction.Applying(
        CropInteraction.Fitting(AspectRatio, canvasWidth, canvasHeight, CropInteraction.FromGeometry(value)), value));
    private void AspectChanged(object sender, SelectionChangedEventArgs e) { if (!syncing && IsLoaded) FitAspect(); }
    private void SwapClicked(object sender, RoutedEventArgs e) { swapped = !swapped; FitAspect(); }
    private void TabChanged(object sender, SelectionChangedEventArgs e) { if (!syncing && e.Source == GeometryTabs) GridChanged?.Invoke(); }
    private void ApplyClicked(object sender, RoutedEventArgs e) { CommitFocusedValue(); ApplyRequested?.Invoke(); }
    private void CancelClicked(object sender, RoutedEventArgs e) => CancelRequested?.Invoke();
    private static string Number(double number) => number.ToString("0.##", CultureInfo.CurrentCulture);
    private void Publish(GeometrySettings next, bool interactive = false)
    {
        if (syncing || !IsEnabled) return;
        _ = next.NativeConfig();
        Refresh(next); Changed?.Invoke(next, interactive);
    }
    private void RotateLeftClicked(object sender, RoutedEventArgs e) => Publish(value.Rotate(-1));
    private void RotateRightClicked(object sender, RoutedEventArgs e) => Publish(value.Rotate(1));
    private void HorizontalFlipClicked(object sender, RoutedEventArgs e) => Publish(value with { FlipHorizontal = !value.FlipHorizontal });
    private void VerticalFlipClicked(object sender, RoutedEventArgs e) => Publish(value with { FlipVertical = !value.FlipVertical });
    private void ResetClicked(object sender, RoutedEventArgs e) { syncing = true; swapped = false; AspectPreset.SelectedIndex = 0; syncing = false; Publish(new()); }
    private void StraightenChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!syncing) Publish(value with { StraightenDegrees = Math.Round(e.NewValue, 2) }, dragging);
    }
    private void PerspectiveChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (syncing) return;
        var amount = Math.Round(e.NewValue, 2) / 100;
        Publish(sender == PerspectiveHorizontalSlider
            ? value with { PerspectiveHorizontal = amount }
            : value with { PerspectiveVertical = amount }, dragging);
    }
    private void Commit(TextBox box)
    {
        if (syncing || !IsEnabled) return;
        if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var number) || !double.IsFinite(number))
        { Refresh(value); return; }
        if (box.Tag is string component && Enum.TryParse<CropComponent>(component, out var field))
        {
            syncing = true; AspectPreset.SelectedIndex = 0; swapped = false; syncing = false;
            Publish(value.WithCropPercent(field, number));
        }
        else if (box.Tag is "PerspectiveHorizontal") Publish(value with { PerspectiveHorizontal = Math.Clamp(number, -100, 100) / 100 });
        else if (box.Tag is "PerspectiveVertical") Publish(value with { PerspectiveVertical = Math.Clamp(number, -100, 100) / 100 });
        else Publish(value with { StraightenDegrees = Math.Clamp(number, -45, 45) });
    }
    private void ValueCommitted(object sender, KeyboardFocusChangedEventArgs e) => Commit((TextBox)sender);
    private void ValueKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Commit((TextBox)sender); ApplyRequested?.Invoke(); e.Handled = true; }
        if (e.Key == Key.Escape) { CancelRequested?.Invoke(); e.Handled = true; }
    }
}
