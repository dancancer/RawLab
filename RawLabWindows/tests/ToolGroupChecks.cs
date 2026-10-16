using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using RawLab.Windows;

internal static class ToolGroupChecks
{
    internal static void Run(string repo, string fixture)
    {
        repo = Path.GetFullPath(repo);
        fixture = Path.GetFullPath(fixture);
        var output = Path.Combine(repo, "build", "tool-groups-verification", DateTime.Now.ToString("yyyyMMdd-HHmmss"));
        Directory.CreateDirectory(output);
        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow { Width = 1200, Height = 800 };
        TestWindowState.Isolate(window, output);
        window.GpuMode.SelectedIndex = 1;
        var checks = 0;
        void Check(bool success, string name)
        {
            if (!success) throw new Exception(name);
            Console.WriteLine("PASS " + name); checks++;
        }

        window.Show();
        try
        {
            window.OpenFile(fixture);
            InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
            RunAssertions(window, output, Check);
            Console.WriteLine($"PASS {checks} tool-group checks; artifacts: {output}");
        }
        finally { window.Close(); app.Shutdown(); }
    }

    // The full photo suite calls this same assertion block before its native confirmation path.
    internal static void RunAssertions(MainWindow window, string output, Action<bool, string> check)
    {
        window.ValueSlider.Value = .625;
        InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
        var whiteBalanceTools = window.Tools.Children.OfType<Button>().ToArray();
        var whiteBalanceTool = whiteBalanceTools.Single(button =>
            AutomationProperties.GetAutomationId(button) == "WhiteBalance");
        check(whiteBalanceTools.Count(button =>
            AutomationProperties.GetAutomationId(button) is "Temperature" or "Tint") == 0,
            "White balance uses one toolbar entry instead of separate temperature and tint entries");
        check(AutomationProperties.GetName(whiteBalanceTool) == Loc.Text("白平衡"),
            "White balance toolbar entry has the group accessibility name");
        PhotoFeatureChecks.Click(whiteBalanceTool); window.UpdateLayout();
        check(window.WhiteBalanceSurface.Visibility == Visibility.Visible &&
              window.WhiteBalanceEditor.Visibility == Visibility.Visible,
            "White balance toolbar entry selects its dedicated panel");
        check((string?)whiteBalanceTool.Tag == "selected" && window.WhiteBalanceCategoryRing.Selected,
            "White balance toolbar entry exposes selected state to keyboard and visual affordances");
        var whiteBalanceSliders = PhotoFeatureChecks.Descendants<Slider>(window.WhiteBalanceEditor).ToArray();
        check(whiteBalanceSliders.Count(slider => AutomationProperties.GetName(slider) == Loc.Text("色温")) == 1 &&
              whiteBalanceSliders.Count(slider => AutomationProperties.GetName(slider) == Loc.Text("色调")) == 1,
            "White balance panel keeps independently adjustable temperature and tint controls");
        var whiteBalanceReset = PhotoFeatureChecks.Descendants<Button>(window.WhiteBalanceEditor).Single(button =>
            AutomationProperties.GetName(button) == Loc.Text("重置白平衡"));
        check(whiteBalanceReset.IsEnabled, "White balance group reset is exposed as an enabled accessible action");
        var asShotWhiteBalance = ((Adjustments)PhotoFeatureChecks.Field(window, "settings")!).AsShot!.Value;
        var temperatureSlider = whiteBalanceSliders.Single(slider => AutomationProperties.GetName(slider) == Loc.Text("色温"));
        var tintSlider = whiteBalanceSliders.Single(slider => AutomationProperties.GetName(slider) == Loc.Text("色调"));
        temperatureSlider.Value = NumericRange.For(ParameterSpec.All[(int)Parameter.Temperature]).Position(6400);
        tintSlider.Value = NumericRange.For(ParameterSpec.All[(int)Parameter.Tint]).Position(12.3);
        var editedWhiteBalance = (Adjustments)PhotoFeatureChecks.Field(window, "settings")!;
        check(editedWhiteBalance[Parameter.Temperature] == 6400 && editedWhiteBalance[Parameter.Tint] == 12.3,
            "White balance panel changes preserve both underlying adjustment parameters");
        check(Math.Abs(window.WhiteBalanceCategoryRing.Progress) > 0,
            "White balance toolbar ring reflects a combined temperature or tint edit");
        PhotoFeatureChecks.Click(whiteBalanceReset);
        var resetWhiteBalance = (Adjustments)PhotoFeatureChecks.Field(window, "settings")!;
        check(resetWhiteBalance.CameraWhiteBalance && resetWhiteBalance[Parameter.Temperature] == asShotWhiteBalance.Temperature &&
              resetWhiteBalance[Parameter.Tint] == asShotWhiteBalance.Tint,
            "White balance group reset restores the current photo as-shot pair");
        check(window.WhiteBalanceCategoryRing.Progress == 0,
            "White balance group reset clears the combined toolbar progress");

        var recipe = MasterRecipe.All.First(recipe => recipe.TintDelta != 0);
        PhotoFeatureChecks.Click(window.MasterRecipeCategory); window.UpdateLayout();
        var recipeButton = PhotoFeatureChecks.Descendants<Button>(window.MasterRecipePanel).Single(button =>
            AutomationProperties.GetName(button) == recipe.Name);
        PhotoFeatureChecks.Click(recipeButton);
        var recipeSettings = (Adjustments)PhotoFeatureChecks.Field(window, "settings")!;
        check(recipeSettings.MasterRecipeID == recipe.Id,
            "White balance recipe regression starts with an active master recipe");
        PhotoFeatureChecks.Click(whiteBalanceTool);
        PhotoFeatureChecks.Click(whiteBalanceReset);
        recipeSettings = (Adjustments)PhotoFeatureChecks.Field(window, "settings")!;
        check(recipeSettings.MasterRecipeID == recipe.Id &&
              (string?)PhotoFeatureChecks.Field(window, "lut") == recipe.LutPath,
            "White balance group reset preserves the active master recipe");
        PhotoFeatureChecks.Click(window.MasterRecipeCategory); window.UpdateLayout();
        var neutralRecipe = PhotoFeatureChecks.Descendants<Button>(window.MasterRecipePanel).Single(button =>
            AutomationProperties.GetName(button) == Loc.Text("无配方"));
        PhotoFeatureChecks.Click(neutralRecipe);

        PhotoFeatureChecks.Click(whiteBalanceTool);
        check((bool)PhotoFeatureChecks.Field(window, "choosingWhiteBalance")!,
            "Selecting white balance marks its editor as active before a transform");
        PhotoFeatureChecks.Click(window.GeometryCategory);
        var transform = (TransformDraft)PhotoFeatureChecks.Field(window, "transform")!;
        check(transform.Active && !(bool)PhotoFeatureChecks.Field(window, "choosingWhiteBalance")!,
            "Entering a transform clears stale white-balance selection state");
        var cancel = PhotoFeatureChecks.Descendants<Button>(window.DraftActions).Single(button =>
            string.Equals(button.Content?.ToString(), Loc.Text("取消"), StringComparison.Ordinal));
        PhotoFeatureChecks.Click(cancel);
        check(!transform.Active && !(bool)PhotoFeatureChecks.Field(window, "choosingWhiteBalance")!,
            "Leaving a transform does not restore stale white-balance selection state");

        var grainTool = window.Tools.Children.OfType<Button>().Single(button =>
            AutomationProperties.GetAutomationId(button) == "Grain");
        PhotoFeatureChecks.Click(grainTool);
        window.UpdateLayout();
        check(PhotoFeatureChecks.Descendants<Button>(window.PhotoEffectsEditor).Single(button =>
            AutomationProperties.GetName(button) == Loc.Text("重置当前效果")).Visibility == Visibility.Visible &&
              PhotoFeatureChecks.Descendants<Button>(window.PhotoEffectsEditor).Count(button =>
                  AutomationProperties.GetName(button).StartsWith(Loc.Text("重置颗粒"), StringComparison.Ordinal)) == 3,
            "Grain keeps its existing group and per-parameter reset actions");
        var grainAmount = PhotoFeatureChecks.Descendants<TextBox>(window).Single(field =>
            AutomationProperties.GetName(field) == "颗粒强度数值");
        var grainAmountSlider = PhotoFeatureChecks.Descendants<Slider>(window).Single(slider =>
            AutomationProperties.GetName(slider) == "颗粒强度");
        grainAmountSlider.Value = 100;
        grainAmount.Text = "1000";
        grainAmount.RaiseEvent(new System.Windows.Input.KeyboardFocusChangedEventArgs(
            System.Windows.Input.Keyboard.PrimaryDevice, Environment.TickCount, grainAmount, grainAmount)
            { RoutedEvent = UIElement.LostKeyboardFocusEvent });
        check(grainAmount.Text == "100", "Clamped photo effect input normalizes its numeric field");
        PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "grain.png"));
        grainAmountSlider.Value = 0;
        InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
        var vignetteTool = window.Tools.Children.OfType<Button>().Single(button =>
            AutomationProperties.GetAutomationId(button) == "Vignette");
        PhotoFeatureChecks.Click(vignetteTool); window.UpdateLayout();
        var vignetteDetails = (Expander)window.PhotoEffectsEditor.FindName("VignetteDetails");
        var vignetteGroupReset = PhotoFeatureChecks.Descendants<Button>(window.PhotoEffectsEditor).Single(button =>
            AutomationProperties.GetName(button) == Loc.Text("重置当前效果"));
        var collapsedVignetteAmountReset = PhotoFeatureChecks.Descendants<Button>(window.PhotoEffectsEditor).Single(button =>
            AutomationProperties.GetName(button) == Loc.Text("重置暗角强度"));
        check(!vignetteDetails.IsExpanded && vignetteGroupReset.Visibility != Visibility.Visible &&
              collapsedVignetteAmountReset.Visibility != Visibility.Visible,
            "Collapsed vignette keeps only intensity, value and the fine-adjustment entry");
        vignetteDetails.IsExpanded = true; window.UpdateLayout();
        check(vignetteGroupReset.Visibility == Visibility.Visible &&
              collapsedVignetteAmountReset.Visibility == Visibility.Visible,
            "Expanded vignette restores group and per-parameter reset actions");
        var vignetteAmount = PhotoFeatureChecks.Descendants<Slider>(window).Single(slider =>
            AutomationProperties.GetName(slider) == "暗角强度");
        var vignetteHighlights = PhotoFeatureChecks.Descendants<Slider>(window).Single(slider =>
            AutomationProperties.GetName(slider) == "暗角高光保护");
        check(!vignetteHighlights.IsEnabled, "Zero vignette disables highlights protection");
        vignetteAmount.Value = .3;
        check(vignetteHighlights.IsEnabled, "Negative vignette enables highlights protection");
        PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "vignette.png"));
        var labels = PhotoFeatureChecks.Descendants<TextBlock>(window.PhotoEffectsEditor).Where(label => label.IsVisible &&
            new[] { "强度", "中点", "圆度", "羽化", "高光保护" }.Contains(label.Text)).ToArray();
        check(labels.Length == 5, "All vignette parameter labels are visible in the narrow editor");
        foreach (var label in labels)
        {
            var text = new FormattedText(label.Text, System.Globalization.CultureInfo.CurrentCulture,
                label.FlowDirection, new Typeface(label.FontFamily, label.FontStyle, label.FontWeight, label.FontStretch),
                label.FontSize, label.Foreground, VisualTreeHelper.GetDpi(label).PixelsPerDip);
            var available = Math.Min(label.ActualWidth, LayoutInformation.GetLayoutSlot(label).Width);
            check(available + 1 >= text.Width, "Vignette label fits without clipping: " + label.Text);
        }
        window.PhotoEffectsSurface.ScrollToBottom(); window.UpdateLayout();
        var highlightsPosition = vignetteHighlights.TransformToAncestor(window.PhotoEffectsSurface)
            .Transform(new Point(0, vignetteHighlights.ActualHeight / 2));
        check(highlightsPosition.Y >= 0 && highlightsPosition.Y < window.PhotoEffectsSurface.ActualHeight,
            "Wrapped vignette controls remain reachable in the adjustment dock");
        PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "vignette-scrolled.png"));
    }
}
