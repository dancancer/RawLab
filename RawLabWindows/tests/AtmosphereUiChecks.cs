using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AtmosphereUiChecks
{
    private static void Ready(MainWindow window) => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
    internal static void Run(string repo, string input, Action<bool, string> check)
    {
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var output = Path.Combine(repo, "build", "windows-atmosphere-ui", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(output);
        var photo = Path.Combine(output, "source" + Path.GetExtension(input)); File.Copy(input, photo);
        Loc.Initialize("en");
        var app = TestWindowState.CreateApplication(); SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = TestWindowState.CreateIsolatedWindow(output, editDirectory: Path.Combine(output, "edits"), width: 1200, height: 900);
        var store = window.EditStoreInstance!;
        try {
            window.GpuMode.SelectedIndex = 1; window.Show(); window.OpenFile(photo); Ready(window);
            window.Settings.Atmosphere = new(37.251234, 0); window.MarkEditedForTests(); Ready(window);
            void Select(AtmosphereParameter id) {
                var buttons = window.AtmosphereToolButtons;
                var button = buttons[id].Button;
                check(button.IsVisible && button.IsEnabled, "Atmosphere tool is visible and enabled: " + id);
                ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                InteractionChecks.PumpUntil(() => button.Tag as string == "selected"); Ready(window);
                check(window.OrdinaryParameter.IsVisible && window.OrdinaryParameter.IsEnabled, "Atmosphere has an enabled native parameter row: " + id);
            }
            void Enter(string text) {
                var number = window.OrdinaryParameter.Number; number.BringIntoView(); number.Focus(); number.Text = text;
                number.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(number), Environment.TickCount, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                Ready(window);
            }
            var groups = window.GroupButtons;
            ((IInvokeProvider)new ButtonAutomationPeer(groups[EditorAdjustmentGroup.Effects]).GetPattern(PatternInterface.Invoke)).Invoke();
            InteractionChecks.PumpUntil(() => window.AtmosphereToolButtons[AtmosphereParameter.Clarity].Button.IsVisible); Ready(window);
            Select(AtmosphereParameter.Clarity);
            var session = window.TransferSessionForTests;
            var count = session.Transactions.Count;
            check(window.OrdinaryParameter.Number.Text == "37.25", "Atmosphere UI displays at most two decimals");
            Enter("37.25");
            check(window.Settings.Atmosphere.Clarity == 37.251234 && session.Transactions.Count == count,
                "Unchanged rounded clarity keeps full precision without a history entry");
            Select(AtmosphereParameter.Dehaze); Enter("-42.5");
            var expected = new AtmosphereSettings(37.251234, -42.5);
            check(window.Settings.Atmosphere == expected && session.Transactions.Count == count + 1,
                "Dehaze commits once and preserves independent clarity");
            check(store.ReadState(photo).Edit!.Settings.Restore().Atmosphere == expected, "Atmosphere UI commits persist full values");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready(window);
            check(window.Settings.Atmosphere == new AtmosphereSettings(37.251234, 0), "Undo restores only the last atmosphere edit");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready(window);
            check(window.Settings.Atmosphere == expected, "Redo restores the complete atmosphere snapshot");
            foreach (var language in new[] { "zh-Hans", "en", "de", "fr", "ja", "es" }) {
                Loc.SetPreference(language, Path.Combine(output, "language.txt"));
                foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
                window.FontSize = 26; System.Windows.Documents.TextElement.SetFontSize(window.OrdinaryParameter, 26); app.Resources["EditorCaptionSize"] = 26.0;
                foreach (var id in Enum.GetValues<AtmosphereParameter>()) {
                    Select(id); window.UpdateLayout();
                    var buttons = window.AtmosphereToolButtons;
                    var button = buttons[id].Button;
                    check(AutomationProperties.GetName(button) == Loc.Text(AtmosphereSpec.For(id).Title), "Translated atmosphere tool has an accessible name: " + language + " " + id);
                    check(window.OrdinaryParameter.Number.ActualHeight >= 26 && window.OrdinaryParameter.ActualWidth <= window.ActualWidth,
                        "Atmosphere row fits with enlarged text: " + language + " " + id);
                    PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "atmosphere-" + language + "-" + id + ".png"));
                }
            }
        } finally { window.Close(); }
    }
}
