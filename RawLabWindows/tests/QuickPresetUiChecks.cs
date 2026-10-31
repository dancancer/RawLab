using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using RawLab.Windows;

internal static class QuickPresetUiChecks
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    internal static void Run(string repo, string raw, Action<bool, string> check)
    {
        var output = Path.Combine(Path.GetFullPath(repo), ".cache", "tmp", "quick-preset-ui", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        var source = Path.Combine(output, "source" + Path.GetExtension(raw)); File.Copy(raw, source);
        var target = Path.Combine(output, "target" + Path.GetExtension(raw)); File.Copy(raw, target);
        var app = TestWindowState.CreateApplication(); SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("en"); foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
        var window = new MainWindow(); TestWindowState.Isolate(window, output);
        var edits = new EditStore(Path.Combine(output, "edits")); var library = new AdjustmentPresetStore(Path.Combine(output, "presets"));
        Set(window, "editStore", edits); Set(window, "presetStore", library);
        try {
            window.GpuMode.SelectedIndex = 1; window.Show(); window.OpenFile(source); Ready(window);
            void Change(double exposure, double? contrast = null) {
                var settings = Get<Adjustments>(window, "settings"); settings.Set(Parameter.Exposure, exposure);
                if (contrast.HasValue) settings.Set(Parameter.Contrast, contrast.Value);
                Invoke(window, "MarkEdited"); Invoke(window, "RefreshControls");
            }
            Change(.7);
            var preset = library.Create("Quick exposure", window.CapturePresetAdjustments(AdjustmentScope.Custom([AdjustmentField.Exposure])));
            Change(.2);
            var session = (AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession", Private)!.GetValue(window)!;
            var count = session.Transactions.Count;
            window.ShowQuickPresets();
            var applying = window.ApplyPresetToCurrentPhoto(preset);
            var duplicate = window.ApplyPresetToCurrentPhoto(preset);
            Done(applying); Done(duplicate); Ready(window);
            check(window.QuickPresetPhase == QuickPresetPhase.Saved && edits.Find(source)!.Settings.Values[1] == .7 &&
                session.Transactions.Count == count + 1 && session.Transactions.Last().Action == AdjustmentHistoryAction.Preset,
                "Quick one-click apply saves one preset transaction and rejects duplicate submit");
            Invoke(window, "RunPhotoHistory", true); Ready(window);
            check(window.QuickPresetPhase == QuickPresetPhase.Idle && window.QuickPresetSurface.IsVisible && edits.Find(source)!.Settings.Values[1] == .2,
                "Global Undo dismisses the previous quick preset result and preserves browsing");
            Invoke(window, "RunPhotoHistory", false); Ready(window);
            var saved = edits.VersionedState(source);
            Done(window.ApplyPresetToCurrentPhoto(preset));
            check(window.QuickPresetPhase == QuickPresetPhase.Unchanged && edits.VersionedState(source).SameAs(saved) && session.Transactions.Count == count + 1,
                "Quick unchanged apply preserves the receipt and history");
            Change(.2); Done(window.ApplyPresetToCurrentPhoto(preset)); window.UndoQuickPreset(); Ready(window);
            check(window.QuickPresetPhase == QuickPresetPhase.Undone && edits.Find(source)!.Settings.Values[1] == .2,
                "Quick Undo targets the saved preset transaction");

            void Late(Action invalidate, string reason) {
                var reached = false; var release = new TaskCompletionSource();
                window.QuickPresetPrepared = () => { reached = true; return release.Task; };
                var expected = edits.VersionedState(source); var history = session.Transactions.Count;
                window.ShowQuickPresets(); var pending = window.ApplyPresetToCurrentPhoto(preset);
                InteractionChecks.PumpUntil(() => reached);
                try { invalidate(); expected = edits.VersionedState(source); history = session.Transactions.Count; }
                finally { release.TrySetResult(); window.QuickPresetPrepared = null; }
                Done(pending);
                check(edits.VersionedState(source).SameAs(expected) && session.Transactions.Count == history,
                    "Quick " + reason + " rejects a late prepared candidate");
            }
            Late(window.CancelQuickPreset, "Cancel");
            Late(window.CloseQuickPresets, "panel close");
            Late(() => Change(.4), "later ordinary edit");
            check(edits.Find(source)!.Settings.Values[1] == .4, "A later ordinary edit is never replaced by the prepared preset");
            Late(() => window.OpenFile(target), "source switch"); Ready(window);
            check(Get<string>(window, "file") == target && Get<Adjustments>(window, "settings")[Parameter.Exposure] == 0,
                "A late prepared preset cannot leak into the newly opened photo");
            window.OpenFile(source); Ready(window);
            window.ShowQuickPresets();
            var reachedConflict = false; var conflictRelease = new TaskCompletionSource();
            window.QuickPresetPrepared = () => { reachedConflict = true; return conflictRelease.Task; };
            var conflict = window.ApplyPresetToCurrentPhoto(preset);
            InteractionChecks.PumpUntil(() => reachedConflict);
            var external = Get<Adjustments>(window, "settings").Clone(); external.Set(Parameter.Exposure, 1.2);
            edits.Save(source, external.Capture(), null); conflictRelease.SetResult(); Done(conflict); window.QuickPresetPrepared = null;
            check(window.QuickPresetPhase == QuickPresetPhase.Failed && edits.Find(source)!.Settings.Values[1] == 1.2,
                "Quick CAS conflict preserves external edits");
            window.ReloadCurrentAdjustments(); Ready(window); window.ShowQuickPresets();
            using (var held = new FileStream(Path.Combine(output, "edits", "edits.json"), FileMode.Open, FileAccess.Read, FileShare.Read)) {
                Done(window.ApplyPresetToCurrentPhoto(preset));
                check(window.QuickPresetPhase == QuickPresetPhase.Failed && edits.Find(source)!.Settings.Values[1] == 1.2,
                    "Quick save failure cannot report Saved or replace the original");
            }
            Done(window.ApplyPresetToCurrentPhoto(preset)); Ready(window);
            check(window.QuickPresetPhase == QuickPresetPhase.Saved, "Quick retry performs a fresh prepare and saves");
            Change(.7, 1.3); var ordinary = edits.VersionedState(source); window.UndoQuickPreset();
            check(window.QuickPresetPhase == QuickPresetPhase.UndoFailed && edits.VersionedState(source).SameAs(ordinary),
                "Quick Undo cannot undo a later ordinary edit");
            Console.WriteLine("Quick preset artifacts: " + output);
        } finally { window.Close(); app.Shutdown(); }
    }
    private static void Done(Task work) { InteractionChecks.PumpUntil(() => work.IsCompleted); work.GetAwaiter().GetResult(); }
    private static void Ready(MainWindow window) => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
    private static T Get<T>(object owner, string name) => (T)owner.GetType().GetField(name, Private)!.GetValue(owner)!;
    private static void Set(object owner, string name, object value) => owner.GetType().GetField(name, Private)!.SetValue(owner, value);
    private static object? Invoke(object owner, string name, params object[] arguments) => owner.GetType().GetMethod(name, Private)!.Invoke(owner, arguments);
}
