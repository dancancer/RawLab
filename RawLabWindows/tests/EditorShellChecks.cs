using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;
using RawLab.Windows.Tests;

internal static class EditorShellChecks
{
    internal static void Run(string output, Action<bool, string> check)
    {
        if (File.Exists(Path.Combine(BatchJournal.DefaultDirectory, "job.json")))
            throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        Directory.CreateDirectory(output);
        var app = TestWindowState.CreateApplication();
        var previous = Loc.Preference;
        MainWindow? window = null;
        try
        {
            Loc.Initialize("en");
            foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
            window = TestWindowState.CreateIsolatedWindow(output);
            window.Show();
            WpfTestHost.ArrangeLayout(window, new Size(1024, 720));
            var menu = window.FindName("MainMenu") as Menu;
            check(menu?.Items.Count == 5, "Five discoverable native menus: en");
            check(window.WindowStyle == WindowStyle.SingleBorderWindow && window.ResizeMode == ResizeMode.CanResize,
                "Standard caption and resizable Windows shell");
            check(window.FontSize == (double)app.Resources["EditorBodySize"], "Editor uses the shared Windows text scale");
            check(window.ResultCanvas.ActualHeight >= WorkspaceLayout.MinimumCanvasHeight, "Canvas retains minimum DIP height");
            check(!window.ExportButton.IsEnabled, "Empty editor cannot export");
            check(window.AdjustmentPanel.Visibility == Visibility.Collapsed && !window.Groups.IsVisible,
                "No photo hides all adjustment groups and parameters");
            check(window.NeutralCanvas.Visibility == Visibility.Collapsed && window.NeutralColumn.ActualWidth == 0,
                "Empty editor has a single unbroken canvas");
            check(window.ResultCanvas.ToolTip == null, "Empty canvas has no zoom instructions");
            check(Descendants(window.Welcome).OfType<TextBlock>().Any(t => t.Text == Loc.Text("打开照片")),
                "Exact approved empty-state heading");
            window.Close();
            window = null;

            var row = new ParameterRow();
            var host = new Window { Content = row, Width = 720, SizeToContent = SizeToContent.Height };
            host.Show();
            row.Refresh("Exposure", new(-4, 4, .01, .1, .01, false, 2), 0, 0, "EV");
            host.UpdateLayout();
            MouseWheelEventArgs Wheel(int delta)
            {
                var args = new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta) { RoutedEvent = UIElement.PreviewMouseWheelEvent };
                row.Number.RaiseEvent(args);
                return args;
            }
            check(Wheel(120).Handled && row.Number.Text == "0.10", "WPF vertical wheel takes one ordinary exposure step");
            row.Number.Text = "invalid";
            check(!Wheel(120).Handled, "Invalid numeric draft does not intercept panel scrolling");
            row.RestoreText();
            var provider = (IRangeValueProvider)UIElementAutomationPeer.CreatePeerForElement(row.Slider)!.GetPattern(PatternInterface.RangeValue)!;
            check(provider.Minimum == -4 && provider.Maximum == 4 && provider.SmallChange == .01 && Math.Abs(provider.Value - .1) < 1e-10,
                "Slider automation reports actual numeric units, not normalized position");
            host.Close();
        }
        finally
        {
            window?.Close();
            Loc.Initialize(previous);
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
