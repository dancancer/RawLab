using System;
using System.IO;
using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private ExternalStoreWatcher? externalStoreWatcher;

    private bool HasUnsavedManualDraft =>
        editDirty || transform.Active || editGesture != null || interacting || editSaveTimer.IsEnabled ||
        HasPendingEditSaves || ParameterRows(AdjustmentPanel).Any(row => row.HasPendingInput);

    private bool HasPendingEditSaves => persistence.HasPendingSaves;

    private (SavedEdit? CurrentUi, bool HasUnsavedManualDraft, (double Temperature, double Tint)? AsShot) CaptureExternalUiState() =>
        (currentEditRecord != null ? new SavedEdit(currentEditRecord.Identity, settings.Capture(), CurrentLookIdentity()) : null,
            HasUnsavedManualDraft,
            settings.AsShot);

    private void StartExternalStoreWatcher()
    {
        externalStoreWatcher?.Dispose();
        var editsPath = Path.GetFullPath(editStore?.RegistryPath ?? Path.Combine(appPaths.EditsDirectory, "edits.json"));
        var presetsPath = Path.GetFullPath(presetStore.RegistryPath);

        externalStoreWatcher = new ExternalStoreWatcher([editsPath, presetsPath], changedPath =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (closing) return;
                if (StringComparer.OrdinalIgnoreCase.Equals(changedPath, presetsPath))
                    HandleExternalPresetsFileChange();
                else if (StringComparer.OrdinalIgnoreCase.Equals(changedPath, editsPath))
                    HandleExternalEditsFileChange();
            });
        });
    }

    private void HandleExternalPresetsFileChange()
    {
        var currentStamp = PathStatStamp.Capture(Path.GetFullPath(presetStore.RegistryPath));
        if (presetStore.LastWriteStamp is { } lastWrite && lastWrite == currentStamp)
            return;

        if (quickPresetsVisible)
            RefreshQuickPresets(true);

        foreach (var dialog in OwnedWindows.OfType<AdjustmentPresetLibraryDialog>().Where(window => window.IsVisible))
            dialog.ReloadFromExternalChange();
    }

    private void FlushDeferredExternalEditsCheckIfNeeded()
    {
        if (closing) return;
        var reloadResult = persistence.FlushDeferredExternalReload(CaptureExternalUiState, () => PhotoPreviewReady(""));
        ApplyExternalReloadResult(reloadResult);
    }

    private void HandleExternalEditsFileChange()
    {
        if (closing) return;
        var reloadResult = persistence.HandleExternalEditsChange(CaptureExternalUiState, () => PhotoPreviewReady(""));
        ApplyExternalReloadResult(reloadResult);
    }

    internal void EvaluateExternalEditsRecord(PhotoEditState diskRecord, PathStatStamp? stamp = null)
    {
        var (currentUi, hasManualDraft, asShot) = CaptureExternalUiState();
        var reloadResult = persistence.EvaluateExternalEditsRecord(diskRecord, stamp, currentUi, hasManualDraft, asShot);
        ApplyExternalReloadResult(reloadResult);
    }

    internal void ReloadExternalUpdate()
    {
        var reloadResult = persistence.RequestExternalReloadAccept();
        ApplyExternalReloadResult(reloadResult, fromManualAccept: true);
    }

    internal void KeepManualDraftOnExternalUpdate()
    {
        persistence.KeepManualDraft();
        RefreshExternalReloadBanner();
    }

    private void ClearExternalReloadOnSourceChange()
    {
        persistence.ClearExternalReloadOnSourceChange();
        RefreshExternalReloadBanner();
    }

    private void RefreshExternalReloadBanner()
    {
        ExternalReloadBanner.Visibility = persistence.ExternalReloadBanner.Visible ? Visibility.Visible : Visibility.Collapsed;
        RefreshHDRPresentation();
    }

    private void ReloadExternalUpdateClicked(object sender, RoutedEventArgs e) => ReloadExternalUpdate();

    private void KeepManualDraftClicked(object sender, RoutedEventArgs e) => KeepManualDraftOnExternalUpdate();

    private void ApplyExternalReloadResult(ExternalReloadResult reloadResult, bool fromManualAccept = false)
    {
        RefreshExternalReloadBanner();
        if (reloadResult.Action != ExternalReloadAction.AutoReload || reloadResult.AdoptedRecord == null)
            return;

        if (fromManualAccept || reloadResult.FromManualAccept)
        {
            if (transform.Active)
            {
                transform.Cancel();
                EndTransform();
            }
            CancelParameterInputs();
            editSaveTimer.Stop();
            editGesture = null;
            interacting = false;
        }

        CancelHslTarget();
        CancelCurveTarget();
        CancelWbProbe();
        CancelPointColorProbe();
        CancelProcessingMigration();
        ApplyAdoptedEditToUi(reloadResult.AdoptedRecord, reloadResult.PreviousRecord);
        processingMigrationReceipt = file != null ? editStore?.ReadProcessingMigration(file) : null;
        RefreshProcessingMigrationControls();
    }
}
