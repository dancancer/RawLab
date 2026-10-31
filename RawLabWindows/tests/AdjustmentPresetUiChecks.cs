using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AdjustmentPresetUiChecks
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    internal static void Run(string repo, string raw, Action<bool, string> check)
    {
        repo = Path.GetFullPath(repo); raw = Path.GetFullPath(raw);
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var output = Path.Combine(repo, "build", "windows-presets", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(output);
        var source = Path.Combine(output, "source" + Path.GetExtension(raw)); var target = Path.Combine(output, "target" + Path.GetExtension(raw));
        File.Copy(raw, source); File.Copy(raw, target);
        var app = TestWindowState.CreateApplication(); SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("en"); foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
        var window = new MainWindow(); TestWindowState.Isolate(window, output);
        var edits = new EditStore(Path.Combine(output, "edits")); var library = new AdjustmentPresetStore(Path.Combine(output, "presets"));
        Set(window, "editStore", edits); Set(window, "presetStore", library);
        try {
            window.GpuMode.SelectedIndex = 1; window.Show(); window.OpenFile(source); Ready(window);
            var settings = Get<Adjustments>(window, "settings"); settings.Set(Parameter.Exposure, 1.25); Invoke(window, "MarkEdited"); Invoke(window, "SaveEdits");
            var session = (AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession", Private)!.GetValue(window)!;
            session.Copy(AdjustmentScope.Custom([AdjustmentField.Contrast]), new(OriginalIdentity.Read(source), settings.Capture(), null), new(source, true));
            var clipboard = session.Clipboard; var revision = edits.VersionedState(source); var history = session.Transactions.Count;
            var summaryDialog = new AdjustmentPresetNameDialog(window, "保存预设", "Summary", true, (_, _) => null,
                preview: window.PreviewAdjustmentPayload, lookName: window.AdjustmentSummaryLookName);
            summaryDialog.Show(); summaryDialog.UpdateLayout();
            var summaryScope = Find<ComboBox>(summaryDialog, "preset.save.scope");
            summaryScope.SelectedIndex = 2; summaryDialog.UpdateLayout();
            Find<Expander>(summaryDialog, "preset.save.summary.group.light").IsExpanded = true; summaryDialog.UpdateLayout();
            check(Find<TextBlock>(summaryDialog, "preset.save.summary.value.light.exposure").Text == "+1.25 EV" &&
                window.PreviewAdjustmentPayload(AdjustmentScope.Modified).Fields.SetEquals([AdjustmentField.Exposure]),
                "Native modified summary shows the actual capture field and value");
            summaryScope.SelectedIndex = 1; summaryDialog.UpdateLayout();
            check(Find<TextBlock>(summaryDialog, "preset.save.summary.count").Text.Contains(AdjustmentFields.All.Count.ToString()),
                "Native all summary follows the full payload count");
            summaryScope.SelectedIndex = 3;
            Find<Button>(summaryDialog, "preset.save.clear").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); summaryDialog.UpdateLayout();
            check(!Find<Button>(summaryDialog, "preset.save.confirm").IsEnabled &&
                Find<TextBlock>(summaryDialog, "preset.save.summary.empty").Text == Loc.Text("未选择任何调整。"),
                "Native summary distinguishes empty custom scope and disables Save");
            summaryDialog.Close();
            check(edits.VersionedState(source).SameAs(revision) && session.Clipboard == clipboard && session.Transactions.Count == history,
                "Switching summary scopes and cancelling preserves the receipt, clipboard and history");
            var payload = window.CapturePresetAdjustments(AdjustmentScope.Custom([AdjustmentField.Exposure]));
            var preset = library.Create("Morning", payload);
            check(payload.Fields.SetEquals([AdjustmentField.Exposure]) && edits.VersionedState(source).SameAs(revision) &&
                session.Clipboard == clipboard && session.Transactions.Count == history, "Native preset capture preserves photo receipt, clipboard and history");
            var external = settings.Clone(); external.Set(Parameter.Exposure, 1.8); edits.Save(source, external.Capture(), null);
            var rejected = false;
            try { window.CapturePresetAdjustments(AdjustmentScope.Standard); } catch (EditPersistenceConflict) { rejected = true; }
            check(rejected && edits.Find(source)!.Settings.Values[1] == 1.8, "Native preset capture rejects an external photo revision");
            Set(window, "adjustmentReloadRequired", false);
            rejected = false;
            try { window.CopyCurrentAdjustments(AdjustmentScope.Standard); } catch (EditPersistenceConflict) { rejected = true; }
            check(rejected && session.Clipboard == clipboard, "Copy confirmation revalidates the source and preserves the clipboard on conflict");
            window.ReloadCurrentAdjustments(); Ready(window);
            window.OpenFile(target); Ready(window); File.Delete(source);
            var preparation = window.PrepareAdjustmentTargets(preset.Payload, [target], AdjustmentHistoryAction.Preset);
            InteractionChecks.PumpUntil(() => preparation.IsCompleted); var operation = preparation.GetAwaiter().GetResult()!;
            var applied = session.Apply(operation).Single(); Invoke(window, "AdoptSavedEdit", applied.Saved!); Ready(window);
            check(applied.Status == AdjustmentStatus.Applied && Get<Adjustments>(window, "settings")[Parameter.Exposure] == 1.25 &&
                session.Transactions.Last().Action == AdjustmentHistoryAction.Preset, "Native preset applies after source removal through the shared history");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready(window);
            check(edits.Find(target) == null, "Native preset Undo restores original absence");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready(window);
            check(edits.Find(target)!.Settings.Values[1] == 1.25, "Native preset Redo restores saved appearance");
            var dialog = new AdjustmentPresetNameDialog(window, "保存预设", "", true, (name, scope) => null);
            dialog.Show(); InteractionChecks.PumpUntil(() => dialog.IsVisible); dialog.UpdateLayout();
            check(Find<Button>(dialog, "preset.save.confirm").IsEnabled == false, "Native preset dialog rejects an empty name");
            Find<TextBox>(dialog, "preset.name").Text = "Named preset";
            check(Find<Button>(dialog, "preset.save.confirm").IsEnabled, "Native preset dialog enables a named nonempty scope");
            dialog.Close();
            AdjustmentPresetDialogChecks.Run(window, library, output, check);
            Console.WriteLine("Native preset artifacts: " + output);
        } finally { window.Close(); app.Shutdown(); }
    }
    private static void Ready(MainWindow window) => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
    private static T Get<T>(object owner, string name) => (T)owner.GetType().GetField(name, Private)!.GetValue(owner)!;
    private static void Set(object owner, string name, object value) => owner.GetType().GetField(name, Private)!.SetValue(owner, value);
    private static object? Invoke(object owner, string name, params object[] arguments) => owner.GetType().GetMethod(name, Private)!.Invoke(owner, arguments);
    private static IEnumerable<DependencyObject> Children(DependencyObject parent)
    {
        yield return parent;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            foreach (var child in Children(VisualTreeHelper.GetChild(parent, index))) yield return child;
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject => Children(root).OfType<T>()
        .Single(value => AutomationProperties.GetAutomationId(value) == id);
}
