using System.IO;
using System.Text.Json;
using System.Windows.Automation;

internal static partial class Program
{
    private sealed partial class DriverContext
    {
        private void PresetFlows()
        {
            var source = Path.Combine(profile, "preset-source" + Path.GetExtension(raw)); File.Copy(raw, source);
            OpenPhoto(source); WaitBusyThenReady(() => SetRangeValue("ParameterValueSlider", 1.5));
            var number = FindById(main, "ParameterValueText")!; number.SetFocus(); SetValue(number, "-");
            EditCommand("preset.library.open"); ClosePresetLibrary();
            Check(((ValuePattern)number.GetCurrentPattern(ValuePattern.Pattern)).Current.Value == "-", "External UIA preset management preserves unfinished precise input");
            EditCommand("preset.library.open"); Invoke(FindById(PresetDialog("preset.library"), "preset.create")!);
            Wait(() => main.Current.IsEnabled);
            Check(FindById(root, "preset.name-dialog") == null && ((ValuePattern)number.GetCurrentPattern(ValuePattern.Pattern)).Current.Value == "-",
                "External UIA blocks preset saving until invalid precise input is resolved");
            number.SetFocus(); Keys(0x1b);
            EditCommand("preset.library.open");
            var library = PresetDialog("preset.library"); Invoke(FindById(library, "preset.create")!);
            var form = PresetDialog("preset.name-dialog"); SetValue(FindById(form, "preset.name")!, "UIA Saved");
            var scope = FindById(form, "preset.save.scope")!;
            ((ExpandCollapsePattern)scope.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            var custom = Wait(() => FindByNames(scope, "自定义", "Custom"))!;
            ((SelectionItemPattern)custom.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            Invoke(Wait(() => FindById(form, "preset.save.clear"))!);
            ((TogglePattern)FindById(form, "adjustment.field.light.exposure")!.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
            Invoke(FindById(form, "preset.save.confirm")!); Wait(() => FindById(root, "preset.name-dialog") == null);
            library = PresetDialog("preset.library"); var id = PresetID("UIA Saved");
            Invoke(FindById(library, "preset.rename." + id)!); form = PresetDialog("preset.name-dialog");
            SetValue(FindById(form, "preset.name")!, "UIA Restart"); Invoke(FindById(form, "preset.save.confirm")!);
            Wait(() => FindById(root, "preset.name-dialog") == null); ClosePresetLibrary();
            Check(PresetID("UIA Restart") == id, "External UIA creates an exposure preset and renames it without changing identity");
            OpenPhoto(raw); File.Delete(source);
            ApplyPreset(id); Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.5) < .0001);
            EditCommand("adjustment.undo"); WaitReady(); Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.25) < .0001);
            EditCommand("adjustment.redo"); WaitReady(); Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.5) < .0001);
            EditCommand("adjustment.undo"); WaitReady(); Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.25) < .0001);
            Check(!File.Exists(source), "External UIA applies the source-independent preset and traverses Undo/Redo");
        }
        private void PresetSummaryFlow()
        {
            EditCommand("preset.library.open");
            Invoke(FindById(PresetDialog("preset.library"), "preset.create")!);
            var form = PresetDialog("preset.name-dialog");
            SetValue(FindById(form, "preset.name")!, "UIA Summary");
            var before = File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"));
            var scope = FindById(form, "preset.save.scope")!;
            ((ExpandCollapsePattern)scope.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            var modified = Wait(() => FindByNames(scope, "仅已修改", "Modified only"))!;
            ((SelectionItemPattern)modified.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var light = Wait(() => FindById(form, "preset.save.summary.group.light"))!;
            ((ExpandCollapsePattern)light.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            Check(Wait(() => FindById(form, "preset.save.summary.value.light.exposure"))!.Current.Name == "+1.25 EV",
                "External UIA exposes the actual modified exposure value");
            ((ExpandCollapsePattern)scope.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            var custom = Wait(() => FindByNames(scope, "自定义", "Custom"))!;
            ((SelectionItemPattern)custom.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            Invoke(Wait(() => FindById(form, "preset.save.clear"))!);
            Check(!FindById(form, "preset.save.confirm")!.Current.IsEnabled &&
                FindById(form, "preset.save.summary.empty") != null,
                "External UIA exposes empty custom scope and disables Save");
            Invoke(FindById(form, "preset.cancel")!);
            Wait(() => FindById(root, "preset.name-dialog") == null);
            ClosePresetLibrary();
            Check(before.SequenceEqual(File.ReadAllBytes(Path.Combine(profile, "edits", "edits.json"))),
                "External UIA scope changes and cancellation preserve the photo record");
        }
        private void SetPresetExposure(double value)
        {
            var number = FindById(main, "ParameterValueText")!;
            number.SetFocus(); SetValue(number, value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            Keys(0x0d);
            WaitReady();
            Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - value) < .0001);
        }
        private void PresetRestartFlow()
        {
            var id = PresetID("UIA Restart"); ApplyPreset(id);
            Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.5) < .0001);
            Check(!File.Exists(Path.Combine(profile, "preset-source" + Path.GetExtension(raw))), "Restarted native process loads and applies the preset after its source is deleted");
            EditCommand("adjustment.undo"); WaitReady(); Wait(() => Math.Abs(GetRangeValue("ParameterValueSlider") - 1.25) < .0001);
            EditCommand("preset.library.open"); var library = PresetDialog("preset.library");
            Invoke(FindById(library, "preset.delete." + id)!);
            Invoke(FindById(PresetDialog("preset.confirmation"), "preset.confirm.cancel")!);
            Wait(() => FindById(root, "preset.confirmation") == null);
            Check(PresetID("UIA Restart") == id, "External UIA delete cancellation preserves the persisted preset");
            Invoke(FindById(PresetDialog("preset.library"), "preset.delete." + id)!);
            Invoke(FindById(PresetDialog("preset.confirmation"), "preset.confirm.commit")!);
            Wait(() => FindById(root, "preset.confirmation") == null);
            Wait(() => FindById(PresetDialog("preset.library"), "preset.delete." + id) == null);
            ClosePresetLibrary();
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(profile, "presets", "presets.json")));
            Check(document.RootElement.GetProperty("presets").GetArrayLength() == 0, "External UIA confirmed deletion persists without changing the photo");
        }
        private void ApplyPreset(string id)
        {
            EditCommand("preset.library.open"); Invoke(FindById(PresetDialog("preset.library"), "preset.apply." + id)!);
            var results = Wait(() => FindById(root, "adjustment.results"))!;
            var apply = FindById(results, "adjustment.results.apply")!; Wait(() => apply.Current.IsEnabled); Invoke(apply);
            Wait(() => !apply.Current.IsEnabled); Invoke(FindById(results, "adjustment.results.close")!);
            Wait(() => FindById(root, "adjustment.results") == null); ClosePresetLibrary(); WaitReady();
        }
        private AutomationElement PresetDialog(string id) => Wait(() => {
            var dialog = FindById(root, id); return dialog != null && dialog.Current.IsEnabled ? dialog : null;
        }, TimeSpan.FromSeconds(20)) ?? throw new InvalidOperationException("Missing preset dialog " + id);
        private void ClosePresetLibrary()
        {
            Invoke(FindById(PresetDialog("preset.library"), "preset.close")!);
            Wait(() => FindById(root, "preset.library") == null);
        }
        private string PresetID(string name)
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(profile, "presets", "presets.json")));
            return document.RootElement.GetProperty("presets").EnumerateArray().Single(p => p.GetProperty("name").GetString() == name).GetProperty("id").GetString()!;
        }
    }
}
