using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private AdjustmentPresetStore presetStore = new(AdjustmentPresetStore.DefaultDirectory);

    internal AdjustmentPayload CapturePresetAdjustments(AdjustmentScope scope)
    {
        if (file == null || editDirty || transform.Active || editGesture != null || exporting || closing || aiJob.State.IsRunning || adjustmentReloadRequired)
            throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        if (currentEditRecord == null || !editStore!.VersionedState(file).SameAs(currentEditRecord)) {
            adjustmentReloadRequired = true;
            SetSaveNotice("调整未保存 · 重试", AdjustmentTransferPresentation.Error(new EditPersistenceConflict()), true); RefreshControls();
            throw new EditPersistenceConflict();
        }
        return AdjustmentTransfer.Capture(scope, CaptureCurrentEdit(), CurrentTransferContext());
    }

    private async void ShowPresetsClicked(object sender, RoutedEventArgs e)
    {
        if (closing || exporting || transferPreparing) return;
        while (!closing) {
            var library = new AdjustmentPresetLibraryDialog(this, presetStore, file != null && !aiJob.State.IsRunning && !adjustmentReloadRequired);
            library.ShowDialog();
            if (library.SaveRequested) {
                if (!PrepareAdjustmentCommand()) return;
                AdjustmentPresetNameDialog? editor = null;
                editor = new(this, "保存预设", Loc.Text("新预设"), true, (name, scope) => {
                    var payload = CapturePresetAdjustments(scope);
                    try { presetStore.Create(name, payload); return null; }
                    catch (AdjustmentPresetException duplicate) when (duplicate.Reason == PresetFailure.DuplicateName && duplicate.Existing != null) {
                        var confirmation = new AdjustmentPresetConfirmationDialog(editor!, duplicate.Existing, true);
                        confirmation.ShowDialog();
                        if (confirmation.Choice == PresetConfirmationChoice.Confirm) { presetStore.Overwrite(duplicate.Existing, payload); return null; }
                        return confirmation.Choice == PresetConfirmationChoice.SaveAs ? Loc.Text("请输入不同的预设名称。") : Loc.Text("同名预设已存在，请使用其他名称。");
                    }
                });
                editor.ShowDialog();
            } else if (library.ApplyRequested is { } preset) {
                if (!PrepareAdjustmentCommand()) return;
                await ShowAdjustmentPreflight(preset.Payload, [file!], AdjustmentHistoryAction.Preset, preset.Name);
            } else return;
        }
    }
}
