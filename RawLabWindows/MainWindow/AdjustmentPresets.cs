using System.Windows;
using System.IO;

namespace RawLab.Windows;

public partial class MainWindow
{
    private AdjustmentPresetStore presetStore = new(AdjustmentPresetStore.DefaultDirectory);

    internal AdjustmentPayload PreviewAdjustmentPayload(AdjustmentScope scope)
    {
        if (file == null || currentEditRecord == null || !StringComparer.OrdinalIgnoreCase.Equals(currentEditRecord.Identity.Path, Path.GetFullPath(file)) ||
            editDirty || transform.Active || editGesture != null || exporting || closing || aiJob.State.IsRunning || adjustmentReloadRequired)
            throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        var defaults = new Adjustments { ExposureMode = PhotoInput.IsRaw(file) ? 1 : 2, HDR = hdrSource == null ? null : new HDRSettings() };
        var committed = currentEditRecord.Edit ?? new SavedEdit(currentEditRecord.Identity, defaults.Capture(), null);
        var snapshot = new SavedEdit(currentEditRecord.Identity, settings.Capture(), CurrentLookIdentity());
        return AdjustmentTransfer.PreviewCapture(scope, snapshot, committed, CurrentTransferContext());
    }

    internal string? AdjustmentSummaryLookName(string kind, string id)
    {
        if (kind is "recipe" or "recipe_lut") {
            var recipe = MasterRecipe.Find(id);
            return recipe != null && File.Exists(recipe.LutPath) ? Loc.Text(recipe.Name) : null;
        }
        var path = kind == "builtin" ? Path.Combine(AppContext.BaseDirectory, "LUTs", id) : lookLibrary?.ResolveIdentity(id);
        if (path == null || !File.Exists(path)) return null;
        return films.FirstOrDefault(film => StringComparer.OrdinalIgnoreCase.Equals(film.Path, path))?.Name
            ?? lookLibrary?.DisplayName(path, Path.GetFileNameWithoutExtension(path));
    }

    internal AdjustmentPayload CapturePresetAdjustments(AdjustmentScope scope)
        => AdjustmentTransfer.Capture(scope, CaptureVerifiedAdjustmentSource(), CurrentTransferContext());

    private SavedEdit CaptureVerifiedAdjustmentSource()
    {
        if (file == null || editDirty || transform.Active || editGesture != null || exporting || closing || aiJob.State.IsRunning || adjustmentReloadRequired)
            throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        if (currentEditRecord == null || !editStore!.VersionedState(file).SameAs(currentEditRecord)) {
            adjustmentReloadRequired = true;
            SetSaveNotice("调整未保存 · 重试", AdjustmentTransferPresentation.Error(new EditPersistenceConflict()), true); RefreshControls();
            throw new EditPersistenceConflict();
        }
        return CaptureCurrentEdit();
    }

    private async void ShowPresetsClicked(object sender, RoutedEventArgs e)
    {
        if (closing || exporting || transferPreparing) return;
        while (!closing) {
            var library = new AdjustmentPresetLibraryDialog(this, presetStore, file != null && !aiJob.State.IsRunning && !adjustmentReloadRequired, AdjustmentSummaryLookName);
            library.ShowDialog();
            if (library.SaveRequested) {
                if (!PrepareQuickPresetCommand()) return;
                ShowPresetSaveEditor();
                RefreshQuickPresets(true);
            } else if (library.ApplyRequested is { } preset) {
                if (!PrepareQuickPresetCommand()) return;
                ShowQuickPresets(); await ApplyPresetToCurrentPhoto(preset); return;
            } else if (library.ApplyMultipleRequested is { } multiple) { await ApplyPresetToPhotos(multiple); return; }
            else { RefreshQuickPresets(true); return; }
        }
    }

    private void ShowPresetSaveEditor()
    {
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
        },settings.IsHDREditing, PreviewAdjustmentPayload, AdjustmentSummaryLookName);
        editor.ShowDialog();
    }
}
