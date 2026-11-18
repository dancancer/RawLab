using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class QuickPresetHDRChecks
{
    internal static void Run(string repo, string fixture, Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetFullPath(repo), ".cache", "tmp", "quick-preset-hdr", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); var source = Path.Combine(root, "source" + Path.GetExtension(fixture)); File.Copy(fixture, source);
        Loc.Initialize("de"); var app = TestWindowState.CreateApplication(); SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = TestWindowState.CreateIsolatedWindow(root, lookLibraryDirectory: Path.Combine(root, "looks"), editDirectory: Path.Combine(root, "edits"));
        var store = window.EditStoreInstance!; var presets = new AdjustmentPresetStore(Path.Combine(root, "presets"));
        window.PresetStoreInstance = presets;
        try {
            window.Show(); window.OpenFile(source); Ready(window);
            var settings = window.Settings;
            if (!settings.IsHDREditing && PhotoInput.IsRaw(source) &&
                PhotoInput.ProbeCameraRaw(source, out var sourceInfo) == HDRProbeState.Supported && sourceInfo?.IsProRAW == true)
            {
                window.HDREditMenu.IsChecked = true;
                window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled &&
                    window.Settings.IsHDREditing &&
                    window.CurrentResult?.HDR != null);
                settings = window.Settings;
            }
            check(settings.IsHDREditing, "Quick HDR fixture uses the real HDR processing path");
            settings.Set(Parameter.Exposure, .7); settings.Set(Parameter.Temperature, 7200); settings.Set(Parameter.Tint, -4);
            window.MarkEditedForTests();
            var preset = presets.Create("HDR +0.70", window.CapturePresetAdjustments(AdjustmentScope.Custom(AdjustmentFields.HDRCommon)));
            settings.Set(Parameter.Exposure, 0); settings.Set(Parameter.Temperature, 6500); settings.Set(Parameter.Tint, 0); window.MarkEditedForTests();
            window.ShowQuickPresets(); window.UpdateLayout();
            check(window.QuickPresetSurface.IsVisible && !window.FilmCategory.IsEnabled && !window.MasterRecipeCategory.IsEnabled,
                "HDR exposes presets while Film and Master Recipe remain disabled");
            Done(window.ApplyPresetToCurrentPhoto(preset)); Ready(window);
            var hdr = store.Find(source)!.Settings.HDR!;
            check(window.QuickPresetPhase == QuickPresetPhase.Saved && hdr.Exposure == .7 && hdr.Temperature == 7200 && hdr.Tint == -4,
                "Quick HDR apply saves exposure and relative white balance");
            window.UndoQuickPreset(); Ready(window);
            check(window.QuickPresetPhase == QuickPresetPhase.Undone && store.Find(source)!.Settings.HDR!.Exposure == 0,
                "Quick HDR Undo restores the preceding HDR state");
            window.HDREditMenu.IsChecked = false; window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready(window);
            var before = store.ReadState(source); window.ShowQuickPresets(); Done(window.ApplyPresetToCurrentPhoto(preset));
            check(window.QuickPresetPhase == QuickPresetPhase.Failed && store.ReadState(source).SameAs(before),
                "Quick relative HDR white balance cannot overwrite SDR editing mode");
            Console.WriteLine("Quick HDR artifacts: " + root);
        } finally { window.Close(); app.Shutdown(); }
    }
    private static void Done(Task work) { InteractionChecks.PumpUntil(() => work.IsCompleted); work.GetAwaiter().GetResult(); }
    private static void Ready(MainWindow window) => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
}
