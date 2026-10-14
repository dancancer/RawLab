using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class GeometryPanel : UserControl
{
    private GeometrySettings value = new();
    private bool syncing = true, dragging;
    public event Action<GeometrySettings, bool>? Changed;
    public GeometryPanel()
    {
        InitializeComponent();
        StraightenSlider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
        StraightenSlider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => {
            dragging = false; Changed?.Invoke(value, false);
        }));
        Refresh(value);
    }
    public void Refresh(GeometrySettings settings)
    {
        syncing = true; value = settings;
        CropX.Text = Number(value.CropX * 100); CropY.Text = Number(value.CropY * 100);
        CropWidth.Text = Number(value.CropWidth * 100); CropHeight.Text = Number(value.CropHeight * 100);
        HorizontalFlip.IsChecked = value.FlipHorizontal; VerticalFlip.IsChecked = value.FlipVertical;
        StraightenSlider.Value = value.StraightenDegrees; StraightenText.Text = Number(value.StraightenDegrees);
        ResetGeometry.IsEnabled = !value.IsIdentity;
        syncing = false;
    }
    private static string Number(double number) => number.ToString("0.##", CultureInfo.CurrentCulture);
    private void Publish(GeometrySettings next, bool interactive = false)
    {
        if (syncing || !IsEnabled) return;
        _ = next.NativeConfig();
        Refresh(next); Changed?.Invoke(next, interactive);
    }
    private void RotateLeftClicked(object sender, RoutedEventArgs e) => Publish(value.Rotate(-1));
    private void RotateRightClicked(object sender, RoutedEventArgs e) => Publish(value.Rotate(1));
    private void FlipChanged(object sender, RoutedEventArgs e) => Publish(value with {
        FlipHorizontal = HorizontalFlip.IsChecked == true, FlipVertical = VerticalFlip.IsChecked == true
    });
    private void ResetClicked(object sender, RoutedEventArgs e) => Publish(new());
    private void StraightenChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!syncing) Publish(value with { StraightenDegrees = Math.Round(e.NewValue, 2) }, dragging);
    }
    private void Commit(TextBox box)
    {
        if (syncing || !IsEnabled) return;
        if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var number) || !double.IsFinite(number))
        { Refresh(value); return; }
        if (box.Tag is string component && Enum.TryParse<CropComponent>(component, out var field))
            Publish(value.WithCropPercent(field, number));
        else Publish(value with { StraightenDegrees = Math.Clamp(number, -45, 45) });
    }
    private void ValueCommitted(object sender, KeyboardFocusChangedEventArgs e) => Commit((TextBox)sender);
    private void ValueKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Commit((TextBox)sender); e.Handled = true; }
        if (e.Key == Key.Escape) { Refresh(value); e.Handled = true; }
    }
}
