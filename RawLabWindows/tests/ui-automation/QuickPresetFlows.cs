using System.IO;
using System.Text.Json;
using System.Windows.Automation;
using System.Drawing;
using System.Drawing.Imaging;

internal static partial class Program
{
    private sealed partial class DriverContext
    {
        private AutomationElement? quickPanel;
        private AutomationElement QuickPanel => quickPanel ??= Wait(() => FindById(main, "preset.quick.panel"))!;
        private AutomationElement? QuickElement(string id) => FindById(QuickPanel, id);

        private void QuickPresetFlow()
        {
            OpenPhoto(raw); WaitReady();
            if (phase == "restart") {
                Check(Math.Abs(StoredQuickExposure() - 1.25) < .0001, "Quick preset result survives a fresh process");
                Invoke(FindById(main, "editor.group.looks")!); QuickInvoke("preset.quick.open");
                Check(QuickElement("preset.quick.name." + PresetID("Abendlicht mit sanften Farben und unveränderter Geometrie")) != null,
                    "Quick preset library survives a fresh process");
                CaptureQuickWindow("restart"); return;
            }
            SetPresetExposure(1.25); Trace("quick-source-value");
            EditCommand("preset.library.open"); Invoke(FindById(PresetDialog("preset.library"), "preset.create")!);
            var form = PresetDialog("preset.name-dialog");
            SetValue(FindById(form, "preset.name")!, "Abendlicht mit sanften Farben und unveränderter Geometrie");
            var scope = FindById(form, "preset.save.scope")!;
            ((ExpandCollapsePattern)scope.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            var custom = Wait(() => FindByNames(scope, "Custom", "自定义", "Benutzerdefiniert"))!;
            ((SelectionItemPattern)custom.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            Invoke(FindById(form, "preset.save.clear")!);
            ((TogglePattern)FindById(form, "adjustment.field.light.exposure")!.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
            Invoke(FindById(form, "preset.save.confirm")!); Wait(() => FindById(root, "preset.name-dialog") == null);
            ClosePresetLibrary(); var id = PresetID("Abendlicht mit sanften Farben und unveränderter Geometrie");
            SetPresetExposure(.5); Trace("quick-preset-created");
            Invoke(FindById(main, "editor.group.looks")!);
            var previousTool = FindById(main, "Film")!;
            var previousStatus = previousTool.Current.ItemStatus;
            QuickInvoke("preset.quick.open");
            var before = File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"));
            var hold = Path.Combine(profile, "hold-preset.flag"); File.WriteAllText(hold, "hold");
            try {
                QuickInvoke("preset.quick.apply." + id);
                Wait(() => File.Exists(Path.Combine(profile, "prepared-preset.flag")));
                Check(!QuickElement("preset.quick.apply." + id)!.Current.IsEnabled, "Checking disables duplicate quick application");
                QuickInvoke("preset.quick.cancel");
            } finally { File.Delete(hold); }
            Wait(() => File.Exists(Path.Combine(profile, "released-preset.flag")));
            Wait(() => QuickElement("preset.quick.cancel") == null);
            Check(before.SequenceEqual(File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"))),
                "Native Cancel rejects the late prepared result without changing the photo record");
            CaptureQuickWindow("cancelled");
            QuickInvoke("preset.quick.apply." + id);
            Wait(() => QuickElement("preset.quick.undo") != null);
            Check(Math.Abs(StoredQuickExposure() - 1.25) < .0001 && main.Current.IsEnabled,
                "One native Apply click saves the preset without a target-preflight dialog");
            CaptureQuickWindow("saved");
            QuickElement("preset.quick.apply." + id)!.SetFocus(); Keys(0x11, 0x5a);
            Wait(() => Math.Abs(StoredQuickExposure() - .5) < .0001 && QuickElement("preset.quick.status") == null);
            Check(!QuickPanel.Current.IsOffscreen, "Global Undo clears the stale quick result and keeps preset browsing visible");
            QuickInvoke("preset.quick.apply." + id); Wait(() => QuickElement("preset.quick.undo") != null);
            QuickInvoke("preset.quick.undo");
            Wait(() => Math.Abs(StoredQuickExposure() - .5) < .0001);
            Check(true, "Native quick Undo restores the pre-preset value");
            QuickInvoke("preset.quick.apply." + id); Wait(() => QuickElement("preset.quick.undo") != null);
            before = File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"));
            QuickInvoke("preset.quick.apply." + id);
            Wait(() => QuickElement("preset.quick.status")?.Current.Name is { } text &&
                new[] { "Unchanged", "未变化", "Unverändert" }.Any(text.Contains));
            Check(before.SequenceEqual(File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"))),
                "Native unchanged quick application preserves the exact record bytes");
            var apply = QuickElement("preset.quick.apply." + id)!; apply.SetFocus(); Keys(0x09);
            Check(AutomationElement.FocusedElement.Current.AutomationId == "preset.quick.more." + id,
                "Tab moves from Apply to the preset menu");
            Keys(0x1b); Wait(() => QuickPanel.Current.IsOffscreen);
            Check(!previousTool.Current.IsOffscreen && previousTool.Current.ItemStatus == previousStatus,
                "Escape restores the previously selected Film tool");
        }

        private void QuickInvoke(string id)
        {
            Trace("quick-action " + id);
            var element = Wait(() => id == "preset.quick.open" ? FindById(main, id) : QuickElement(id))!;
            if (element.Current.IsOffscreen && element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out var scroll))
                ((ScrollItemPattern)scroll).ScrollIntoView();
            Check(!element.Current.IsOffscreen && element.Current.IsEnabled, "Visible native quick action: " + id);
            Invoke(element);
        }
        private double StoredQuickExposure()
        {
            using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(profile, "edits", "edits.json")));
            var record = json.RootElement.GetProperty("Records").EnumerateObject().Single(entry =>
                string.Equals(entry.Value.GetProperty("Identity").GetProperty("Path").GetString(), raw, StringComparison.OrdinalIgnoreCase)).Value;
            return record.GetProperty("Settings").GetProperty("Values")[1].GetDouble();
        }
        private void CaptureQuickWindow(string name)
        {
            var bounds = main.Current.BoundingRectangle;
            var photo = FindById(main, "ResultCanvas")!.Current.BoundingRectangle;
            var panel = QuickPanel.Current.BoundingRectangle;
            Check(photo.Width > 44 && photo.Height > 44 && bounds.Contains(photo) && bounds.Contains(panel),
                "The native preset panel and photo remain inside the 1024 by 720 window");
            using var bitmap = new Bitmap((int)Math.Ceiling(bounds.Width), (int)Math.Ceiling(bounds.Height));
            using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen((int)bounds.X, (int)bounds.Y, 0, 0, bitmap.Size);
            bitmap.Save(Path.Combine(profile, "quick-" + name + ".png"), ImageFormat.Png);
            File.WriteAllText(Path.Combine(profile, "quick-" + name + ".json"), JsonSerializer.Serialize(new {
                phase, window = new[] { bounds.X, bounds.Y, bounds.Width, bounds.Height },
                photo = new[] { photo.X, photo.Y, photo.Width, photo.Height },
                panel = new[] { panel.X, panel.Y, panel.Width, panel.Height }, exposure = StoredQuickExposure()
            }));
        }
    }
}
