using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace RawLab.Windows;

public partial class MainWindow
{
    private bool quickPresetsVisible;
    private QuickPresetState quickPreset = new();
    private long quickPresetGeneration;
    private IReadOnlyList<AdjustmentPreset> quickPresetLibrary = [];
    private string? quickPresetLibraryError;
    internal QuickPresetPhase QuickPresetPhase => quickPreset.Phase;
    internal Func<Task>? QuickPresetPrepared;

    private void PreserveQuickPresetInputs()
    {
        foreach (var row in ParameterRows(AdjustmentPanel).Where(row => row.IsVisible)) row.PreserveInputForUpdateNavigation();
    }

    internal void ShowQuickPresets()
    {
        if (file == null || closing || exporting) return;
        PreserveQuickPresetInputs(); CancelHslTarget();
        quickPresetsVisible = true; expandedGroup = EditorAdjustmentGroup.Looks;
        AdjustmentPanel.Visibility = AdjustmentSplitter.Visibility = Visibility.Visible;
        DockRow.Height = new(dockHeight); DockRow.MinHeight = 216; SplitterRow.Height = new(6);
        RefreshQuickPresets(reload: true); RefreshControls(); UpdateDockMinimum();
    }

    internal void CloseQuickPresets()
    {
        if (!quickPresetsVisible) return;
        CancelQuickPreset(); quickPresetsVisible = false;
        expandedGroup = EditorAdjustmentRules.GroupFor(CurrentTool); RefreshControls();
    }

    internal void CancelQuickPreset()
    {
        ++quickPresetGeneration;
        if (quickPreset.Phase == QuickPresetPhase.Preparing) { ++transferGeneration; transferPreparing = false; }
        quickPreset = new(); RefreshQuickPresets(); RefreshControls();
    }

    private bool PrepareQuickPresetCommand()
    {
        foreach (var row in ParameterRows(AdjustmentPanel).Where(row => row.HasPendingInput)) {
            if (row.Commit()) continue;
            CloseQuickPresets(); row.Number.Focus(); return false;
        }
        return PrepareAdjustmentCommand();
    }

    internal async Task ApplyPresetToCurrentPhoto(AdjustmentPreset preset)
    {
        if (!quickPresetsVisible || transferPreparing || quickPreset.Phase == QuickPresetPhase.Preparing || file == null) return;
        var source = file; var opened = openRevision;
        if (!PrepareQuickPresetCommand() || !quickPresetsVisible || file != source || openRevision != opened) return;
        var generation = ++quickPresetGeneration; var revision = editRevision;
        try {
            _ = CaptureVerifiedAdjustmentSource();
            var expected = currentEditRecord!; var session = TransferSession;
            quickPreset = new(QuickPresetPhase.Preparing, preset); RefreshQuickPresets(); RefreshControls();
            var operation = await PrepareAdjustmentTargets(preset.Payload, [source], AdjustmentHistoryAction.Preset);
            if (QuickPresetPrepared is { } prepared) await prepared();
            if (generation != quickPresetGeneration || !quickPresetsVisible) return;
            if (file != source || opened != openRevision || revision != editRevision || operation == null) { CancelQuickPreset(); return; }
            if (operation.Targets.FirstOrDefault()?.Error is { } targetError) throw targetError;
            if (operation.Targets.Count != 1 || operation.Targets[0].Original?.SameAs(expected) != true || currentEditRecord?.SameAs(expected) != true)
                throw new EditPersistenceConflict();
            var outcome = AdoptAdjustmentOutcomes(session.Apply(operation), []).Single();
            if (outcome.Status == AdjustmentStatus.Applied && (outcome.Error != null || outcome.Saved?.SameAs(currentEditRecord) != true)) {
                quickPreset = new(QuickPresetPhase.Failed, preset, Message: Loc.Text("调整已保存，当前照片需要重新载入。"));
            } else if (outcome.Error == null && outcome.Saved?.SameAs(currentEditRecord) == true && outcome.Status is AdjustmentStatus.Applied or AdjustmentStatus.Unchanged) {
                quickPreset = new(outcome.Status == AdjustmentStatus.Applied ? QuickPresetPhase.Saved : QuickPresetPhase.Unchanged, preset, operation.ID);
            } else throw outcome.Error ?? new EditPersistenceConflict();
        } catch (Exception error) {
            if (generation == quickPresetGeneration) quickPreset = new(QuickPresetPhase.Failed, preset, Message: QuickPresetError(error));
        } finally {
            if (generation == quickPresetGeneration) { RefreshQuickPresets(); RefreshControls(); }
        }
    }

    internal void UndoQuickPreset()
    {
        if (!quickPresetsVisible || quickPreset.Phase is not (QuickPresetPhase.Saved or QuickPresetPhase.UndoFailed) || quickPreset.Transaction is not { } transaction ||
            quickPreset.Preset is not { } preset || !PrepareQuickPresetCommand() || file == null) return;
        var outcomes = AdoptAdjustmentOutcomes(TransferSession.UndoPhoto(file, transaction, HistoryTargetIsCurrent), []);
        var outcome = outcomes.SingleOrDefault();
        quickPreset = outcome?.Status == AdjustmentStatus.Applied && outcome.Error == null && outcome.Saved?.SameAs(currentEditRecord) == true
            ? new(QuickPresetPhase.Undone, preset) : new(QuickPresetPhase.UndoFailed, preset, transaction, AdjustmentTransferPresentation.Error(outcome?.Error));
        RefreshQuickPresets(); RefreshControls();
    }

    private static string QuickPresetError(Exception error) => error switch {
        AdjustmentTransferException { Failure: AdjustmentFailure.Incompatible, Detail: "hdr.relative_white_balance" } => Loc.Text("此预设包含 HDR 相对白平衡，当前编辑模式不支持。"),
        AdjustmentTransferException { Failure: AdjustmentFailure.Incompatible } => Loc.Text("此预设与当前照片不兼容，请选择其他预设。"),
        AdjustmentTransferException { Failure: AdjustmentFailure.Unrepresentable } => Loc.Text("此预设无法保留照片的其他调整，请选择其他预设。"),
        _ => AdjustmentTransferPresentation.Error(error)
    };

    private void RefreshQuickPresets(bool reload = false)
    {
        if (!quickPresetsVisible) return;
        if (reload) {
            try { quickPresetLibrary = presetStore.List(); quickPresetLibraryError = null; }
            catch (Exception error) { quickPresetLibrary = []; quickPresetLibraryError = AdjustmentPresetPresentation.Error(error); }
        }
        QuickPresetSurface.Content = QuickPresetView.Build(quickPresetLibrary, quickPresetLibraryError, quickPreset, AdjustmentSummaryLookName,
            () => ShowPresetsClicked(this, new()), () => { if (PrepareQuickPresetCommand()) ShowPresetSaveEditor(); RefreshQuickPresets(true); },
            () => RefreshQuickPresets(true), async preset => await ApplyPresetToCurrentPhoto(preset), async preset => await ApplyPresetToPhotos(preset),
            UndoQuickPreset, CancelQuickPreset, adjustmentReloadRequired, () => ReloadEditsClicked(this, new()));
    }

    private async Task ApplyPresetToPhotos(AdjustmentPreset preset)
    {
        if (!PrepareQuickPresetCommand()) return;
        CancelQuickPreset();
        var picker = new OpenFileDialog { Title = Loc.Text("选择目标照片"), Filter = Loc.Text("照片|") + LibraryEntry.ImageFilter, Multiselect = true };
        if (picker.ShowDialog(this) == true) await ShowAdjustmentPreflight(preset.Payload, picker.FileNames, AdjustmentHistoryAction.Preset, preset.Name);
    }
}
