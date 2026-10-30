using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class QuickPresetHDRChecks
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    internal static void Run(string repo, string fixture, Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetFullPath(repo), ".cache", "tmp", "quick-preset-hdr", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root); var source = Path.Combine(root, "source.jpg"); File.Copy(fixture, source);
        Loc.Initialize("de"); var app = TestWindowState.CreateApplication(); SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow(Path.Combine(root, "looks")); TestWindowState.Isolate(window, root);
        var store = new EditStore(Path.Combine(root, "edits")); var presets = new AdjustmentPresetStore(Path.Combine(root, "presets"));
        Set(window, "editStore", store); Set(window, "presetStore", presets);
        try {
            window.Show(); window.OpenFile(source); Ready(window);
            var settings = Get<Adjustments>(window, "settings");
            check(settings.IsHDREditing, "Quick HDR fixture uses the real HDR processing path");
            settings.Set(Parameter.Exposure, .7); settings.Set(Parameter.Temperature, 7200); settings.Set(Parameter.Tint, -4);
            Invoke(window, "MarkEdited");
            var preset = presets.Create("HDR +0.70", window.CapturePresetAdjustments(AdjustmentScope.Custom(AdjustmentFields.HDRCommon)));
            settings.Set(Parameter.Exposure, 0); settings.Set(Parameter.Temperature, 6500); settings.Set(Parameter.Tint, 0); Invoke(window, "MarkEdited");
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
            var before = store.VersionedState(source); window.ShowQuickPresets(); Done(window.ApplyPresetToCurrentPhoto(preset));
            check(window.QuickPresetPhase == QuickPresetPhase.Failed && store.VersionedState(source).SameAs(before),
                "Quick relative HDR white balance cannot overwrite SDR editing mode");
            Console.WriteLine("Quick HDR artifacts: " + root);
        } finally { window.Close(); app.Shutdown(); }
    }
    private static void Done(Task work) { InteractionChecks.PumpUntil(() => work.IsCompleted); work.GetAwaiter().GetResult(); }
    private static void Ready(MainWindow window) => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
    private static T Get<T>(object owner, string name) => (T)owner.GetType().GetField(name, Private)!.GetValue(owner)!;
    private static void Set(object owner, string name, object value) => owner.GetType().GetField(name, Private)!.SetValue(owner, value);
    private static void Invoke(object owner, string name) => owner.GetType().GetMethod(name, Private)!.Invoke(owner, null);
}
