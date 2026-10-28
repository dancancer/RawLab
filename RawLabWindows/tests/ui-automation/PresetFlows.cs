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
