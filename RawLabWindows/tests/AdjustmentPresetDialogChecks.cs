using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AdjustmentPresetDialogChecks
{
    private sealed record Step(string ID, Action<Window> Run);
    internal static void Run(MainWindow owner, AdjustmentPresetStore store, string output, Action<bool, string> check)
    {
        var modeless = new Window { Owner = owner, Width = 120, Height = 100, ShowInTaskbar = false };
        var unrelated = new Window { Width = 120, Height = 100, ShowInTaskbar = false };
        try {
            modeless.Show(); owner.Activate(); InteractionChecks.PumpUntil(() => owner.IsActive);
            owner.OrdinaryParameter.Number.Focus(); owner.OrdinaryParameter.Number.Text = "-";
            unrelated.Show(); InteractionChecks.PumpUntil(() => unrelated.IsActive);
            check(!owner.OrdinaryParameter.HasInvalidInput,
                "Unrelated window activation still cancels precise input when a modeless owned window remains open");
        } finally { unrelated.Close(); modeless.Close(); owner.Activate(); }
        owner.OrdinaryParameter.Number.Text = "-";
        Drive(owner, [new("preset.library", w => Click(w, "preset.close"))]);
        check(owner.OrdinaryParameter.HasInvalidInput && owner.OrdinaryParameter.Number.Text == "-",
            "Opening and closing preset management preserves an unfinished numeric input");
        Drive(owner, [new("preset.library", w => Click(w, "preset.create"))]);
        check(owner.OrdinaryParameter.HasInvalidInput && store.List().Count == 1,
            "Preset capture waits for invalid numeric input to be corrected or cancelled");
        owner.OrdinaryParameter.Number.Text = "1.35";
        Drive(owner, [new("preset.library", w => Click(w, "preset.create")),
            new("preset.name-dialog", w => Click(w, "preset.cancel")),
            new("preset.library", w => Click(w, "preset.close"))]);
        check(AdjustmentPayload.Number(owner.CapturePresetAdjustments(AdjustmentScope.Custom([AdjustmentField.Exposure]))[AdjustmentField.Exposure]) == 1.35,
            "Preset source preflight commits a legal precise input before opening the save form");
        var before = store.List().Single();
        Drive(owner, [
            new("preset.library", w => Click(w, "preset.create")),
            new("preset.name-dialog", w => {
                Find<TextBox>(w, "preset.name").Text = "Evening";
                Find<ComboBox>(w, "preset.save.scope").SelectedIndex = 3; Click(w, "preset.save.clear");
                check(!Find<Button>(w, "preset.save.confirm").IsEnabled, "Native save refuses an empty custom scope");
                Find<CheckBox>(w, "adjustment.field.light.exposure").IsChecked = true; Click(w, "preset.save.confirm");
            }),
            new("preset.library", w => Click(w, "preset.create")),
            new("preset.name-dialog", w => { Find<TextBox>(w, "preset.name").Text = "Evening"; Click(w, "preset.save.confirm"); }),
            new("preset.confirmation", w => Click(w, "preset.confirm.cancel")),
            new("preset.name-dialog", w => {
                check(store.List().Count == 2 && Find<TextBlock>(w, "preset.error").Text.Length > 0, "Duplicate cancel preserves the preset and save form");
                Click(w, "preset.save.confirm");
            }),
            new("preset.confirmation", w => Click(w, "preset.confirm.save-as")),
            new("preset.name-dialog", w => { Find<TextBox>(w, "preset.name").Text = "Night"; Click(w, "preset.save.confirm"); }),
            new("preset.library", w => Click(w, "preset.close"))
        ]);
        var evening = store.List().Single(p => p.Name == "Evening"); var night = store.List().Single(p => p.Name == "Night");
        check(evening.Payload.Fields.SetEquals([AdjustmentField.Exposure]) && store.List().Count == 3, "Native create and Save As persist distinct names and the selected scope");
        Drive(owner, [
            new("preset.library", w => Click(w, "preset.create")),
            new("preset.name-dialog", w => { Find<TextBox>(w, "preset.name").Text = "Evening"; Click(w, "preset.save.confirm"); }),
            new("preset.confirmation", w => Click(w, "preset.confirm.commit")),
            new("preset.library", w => Click(w, "preset.rename." + night.ID)),
            new("preset.name-dialog", w => { Find<TextBox>(w, "preset.name").Text = "Night edited"; Click(w, "preset.save.confirm"); }),
            new("preset.library", w => Click(w, "preset.delete." + night.ID)),
            new("preset.confirmation", w => Click(w, "preset.confirm.cancel")),
            new("preset.library", w => {
                check(store.List().Any(p => p.ID == night.ID && p.Name == "Night edited"), "Rename preserves identity and cancelled delete preserves the entry");
                Click(w, "preset.delete." + night.ID);
            }),
            new("preset.confirmation", w => Click(w, "preset.confirm.commit")),
            new("preset.library", w => Click(w, "preset.close"))
        ]);
        var overwritten = store.List().Single(p => p.ID == evening.ID);
        check(overwritten.CreatedAt == evening.CreatedAt && overwritten.Payload.Fields.SetEquals(AdjustmentFields.Common) &&
            store.List().All(p => p.ID != night.ID) && store.List().Single(p => p.ID == before.ID).SameAs(before),
            "Overwrite preserves stable identity, delete removes only its target and other content remains unchanged");
        Drive(owner, [
            new("preset.library", w => Click(w, "preset.delete." + evening.ID)),
            new("preset.confirmation", w => { store.Rename(overwritten, "Changed elsewhere"); Click(w, "preset.confirm.commit"); }),
            new("preset.library", w => {
                check(Find<TextBlock>(w, "preset.error").Text == Loc.Text("预设已变化，请重新载入列表后重试。") && store.List().Any(p => p.Name == "Changed elsewhere"),
                    "Stale native delete confirmation rejects a concurrent rename"); Click(w, "preset.reload"); Click(w, "preset.close");
            })
        ]);
        var registry = Path.Combine(output, "presets", "presets.json"); FileStream? held = null;
        try {
            Drive(owner, [
                new("preset.library", w => Click(w, "preset.rename." + evening.ID)),
                new("preset.name-dialog", w => {
                    held = new FileStream(registry, FileMode.Open, FileAccess.Read, FileShare.Read);
                    Find<TextBox>(w, "preset.name").Text = "Recovered"; Click(w, "preset.save.confirm");
                }),
                new("preset.name-dialog", w => {
                    check(Find<TextBlock>(w, "preset.error").Text.Length > 0 && store.List().Any(p => p.Name == "Changed elsewhere"),
                        "Real registry replacement failure retains the saved entry and rename draft");
                    held!.Dispose(); held = null; Click(w, "preset.save.confirm");
                }),
                new("preset.library", w => { check(store.List().Any(p => p.ID == evening.ID && p.Name == "Recovered"), "Native rename retries successfully after the file lock is released"); Click(w, "preset.close"); })
            ]);
        } finally { held?.Dispose(); }
        var bytes = File.ReadAllBytes(registry);
        try {
            File.WriteAllText(registry, "{\"registry_version\":99,\"presets\":[]}"); var future = File.ReadAllBytes(registry);
            Drive(owner, [new("preset.library", w => {
                check(!Find<Button>(w, "preset.create").IsEnabled && Find<TextBlock>(w, "preset.error").Text == Loc.Text("此预设库来自更新版本，请更新应用后重试。") && File.ReadAllBytes(registry).SequenceEqual(future),
                    "Future registry reports the native error without replacing or clearing the file"); Click(w, "preset.close");
            })]);
        } finally { File.WriteAllBytes(registry, bytes); }
        var missing = store.Create("Missing look", new AdjustmentPayload(before.Payload.Source,
            new Dictionary<AdjustmentField, JsonElement> {
                [AdjustmentField.Look] = AdjustmentPayload.Value(new { kind = "managed", id = "missing-native-preset-look" })
            }));
        var editsPath = Path.Combine(output, "edits", "edits.json"); var savedEdits = File.ReadAllBytes(editsPath);
        try {
            Drive(owner, [
                new("preset.library", w => Click(w, "preset.apply." + missing.ID)),
                new("adjustment.results", w => {
                    check(!Find<Button>(w, "adjustment.results.apply").IsEnabled &&
                        UiDetailChecks.Descendants(w).OfType<TextBlock>().Any(t => t.Text == Loc.Text("目标缺少所选外观，请先导入外观。")),
                        "Native preset preflight shows the missing look and blocks application");
                    Screenshot(w, Path.Combine(output, "missing-look.png")); Click(w, "adjustment.results.close");
                }),
                new("preset.library", w => Click(w, "preset.close"))
            ]);
            check(File.ReadAllBytes(editsPath).SequenceEqual(savedEdits), "Blocked native preset leaves the photo registry unchanged");
        } finally { store.Delete(missing); }
        Locales(owner, store, output, check);
    }
    private static void Locales(MainWindow owner, AdjustmentPresetStore store, string output, Action<bool, string> check)
    {
        var initial = store.List().First(); store.Rename(initial, "A long personal preset name for evening mountains, warm highlights and gentle shadows — 山の夕景");
        try {
            foreach (var language in new[] { "en", "zh-Hans", "de", "fr", "ja", "es" }) foreach (var font in new[] { 13d, 26d }) {
                Loc.Initialize(language); foreach (var pair in Loc.Strings) Application.Current.Resources[pair.Key] = pair.Value;
                var library = new AdjustmentPresetLibraryDialog(owner, store, true) { Width = 520, FontSize = font };
                library.Show(); library.UpdateLayout();
                var count = initial.Payload.Fields.Count;
                var expectedCount = language switch {
                    "en" => $"{count} selected", "zh-Hans" => $"已选 {count} 项", "de" => $"{count} ausgewählt",
                    "fr" => $"{count} sélectionnés", "ja" => $"{count} 項目を選択中", _ => $"{count} seleccionados"
                };
                check(UiDetailChecks.Descendants(library).OfType<TextBlock>().Any(t => t.Text == expectedCount),
                    "Preset field count uses the selected native language: " + language + "/" + font);
                check(Fits(library, "preset.close") && Fits(library, "preset.create") && Fits(library, "preset.apply." + initial.ID), "Preset library actions fit narrow native layout: " + language + "/" + font);
                Screenshot(library, Path.Combine(output, $"library-{language}-{font}.png")); library.Close();
                var save = new AdjustmentPresetNameDialog(owner, "保存预设", "My long preset", true, (_, _) => null,
                    preview: owner.PreviewAdjustmentPayload, lookName: owner.AdjustmentSummaryLookName) { Width = 520, FontSize = font };
                save.Show(); Find<ComboBox>(save, "preset.save.scope").SelectedIndex = 3; save.UpdateLayout();
                check(Fits(save, "preset.save.confirm") && Fits(save, "preset.cancel") && Fits(save, "preset.name"), "Preset save controls fit narrow native layout: " + language + "/" + font);
                Screenshot(save, Path.Combine(output, $"save-{language}-{font}.png")); save.Close();
            }
        } finally {
            Loc.Initialize("en"); foreach (var pair in Loc.Strings) Application.Current.Resources[pair.Key] = pair.Value;
            store.Rename(store.List().Single(p => p.ID == initial.ID), initial.Name);
        }
    }
    private static void Drive(MainWindow owner, Step[] sequence)
    {
        var pending = new Queue<Step>(sequence); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        var watch = Stopwatch.StartNew(); var progress = Stopwatch.StartNew(); Exception? failure = null; var dispatched = false;
        timer.Tick += (_, _) => {
            var windows = Application.Current.Windows.OfType<Window>().Where(w => w != owner && w.IsVisible).ToArray();
            if (progress.Elapsed > TimeSpan.FromSeconds(30)) failure ??= new TimeoutException("Preset dialog sequence stalled at " + pending.FirstOrDefault()?.ID +
                "; windows=" + string.Join(" | ", windows.Select(w => AutomationProperties.GetAutomationId(w) + ":enabled=" + w.IsEnabled + ":" +
                    string.Join(";", UiDetailChecks.Descendants(w).OfType<TextBlock>().Select(t => t.Text).Where(t => t.Length > 0).TakeLast(12)))));
            if (failure != null) { foreach (var w in windows.Reverse()) w.Close(); if (windows.Length == 0) timer.Stop(); return; }
            if (pending.Count == 0) { if (windows.Length == 0) timer.Stop(); return; }
            if (dispatched) return;
            var expected = pending.Peek(); var dialog = windows.LastOrDefault(w => AutomationProperties.GetAutomationId(w) == expected.ID && w.IsEnabled);
            if (dialog == null) return;
            pending.Dequeue(); dispatched = true; progress.Restart();
            Console.WriteLine("PRESET_UI step=" + expected.ID + " remaining=" + pending.Count + " elapsed=" + watch.Elapsed.TotalSeconds);
            // 模态按钮通过独立 dispatcher 回调进入，避免占住 timer tick 后无法驱动下一层窗口。
            owner.Dispatcher.BeginInvoke(() => { dispatched = false; try { expected.Run(dialog); } catch (Exception error) { failure = error; } });
        };
        timer.Start();
        try { owner.PresetsAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); InteractionChecks.PumpUntil(() => !timer.IsEnabled); }
        finally { timer.Stop(); }
        if (failure != null) throw failure;
        if (pending.Count != 0) throw new InvalidOperationException("Preset dialog sequence did not complete");
    }
    private static bool Fits(Window window, string id)
    {
        var control = Find<FrameworkElement>(window, id); var root = (Grid)window.Content;
        var bounds = control.TransformToAncestor(root).TransformBounds(new Rect(control.RenderSize));
        return control.IsVisible && bounds.Left >= -.5 && bounds.Right <= root.ActualWidth + .5 && bounds.Top >= -.5 && bounds.Bottom <= root.ActualHeight + .5;
    }
    private static void Screenshot(Window window, string path)
    {
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(window);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var output = File.Create(path); encoder.Save(output);
    }
    private static void Click(Window window, string id) => Find<Button>(window, id).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static T Find<T>(DependencyObject parent, string id) where T : DependencyObject
    {
        if (parent is T value && AutomationProperties.GetAutomationId(value) == id) return value;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) try { return Find<T>(VisualTreeHelper.GetChild(parent, i), id); } catch (InvalidOperationException) { }
        throw new InvalidOperationException("Missing native preset control " + id);
    }
}
