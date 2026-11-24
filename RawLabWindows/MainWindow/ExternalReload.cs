using System;
using System.IO;
using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private ExternalStoreWatcher? externalStoreWatcher;
    private ExternalReloadBannerState externalReloadBanner = ExternalReloadBannerState.Empty;
    private bool deferredExternalEditsCheck;
    private bool deferredExternalReloadAccept;

    private bool HasUnsavedManualDraft =>
        editDirty || transform.Active || editGesture != null || interacting || editSaveTimer.IsEnabled ||
        HasPendingEditSaves || ParameterRows(AdjustmentPanel).Any(row => row.HasPendingInput);

    private bool HasPendingEditSaves =>
        pendingEditSaves.HasPending || editSaveQueue.HasPendingWork;

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
        if (HasPendingEditSaves)
            return;
        if (deferredExternalReloadAccept)
        {
            deferredExternalReloadAccept = false;
            deferredExternalEditsCheck = false;
            ReloadExternalUpdate();
            return;
        }
        if (!deferredExternalEditsCheck)
            return;
        deferredExternalEditsCheck = false;
        HandleExternalEditsFileChange();
    }

    private void HandleExternalEditsFileChange()
    {
        if (closing) return;
        EditStore store;
        try
        {
            store = editStore ?? new EditStore(appPaths.EditsDirectory);
            editStore = store;
        }
        catch
        {
            return;
        }
        var editsPath = Path.GetFullPath(store.RegistryPath);
        var currentStamp = PathStatStamp.Capture(editsPath);
        if (store.LastWriteStamp is { } lastWrite && lastWrite == currentStamp)
            return;

        PhotoPreviewReady("");
        if (file == null) return;

        if (HasPendingEditSaves)
        {
            deferredExternalEditsCheck = true;
            return;
        }

        PhotoEditState diskRecord;
        try { diskRecord = store.ReadState(file); }
        catch { return; }

        EvaluateExternalEditsRecord(diskRecord, currentStamp);
    }

    internal void EvaluateExternalEditsRecord(PhotoEditState diskRecord, PathStatStamp? stamp = null)
    {
        if (file == null || currentEditRecord == null) return;
        if (HasPendingEditSaves)
        {
            deferredExternalEditsCheck = true;
            return;
        }
        var currentUi = new SavedEdit(currentEditRecord.Identity, settings.Capture(), CurrentLookIdentity());
        var evaluation = externalReloadBanner.Evaluate(
            currentEditRecord,
            currentUi,
            diskRecord,
            stamp,
            HasUnsavedManualDraft,
            HasPendingEditSaves,
            settings.AsShot);

        externalReloadBanner = evaluation.NextState;
        RefreshExternalReloadBanner();

        if (evaluation.Decision == ExternalReloadDecision.AutoReload)
            ApplyExternalReloadRecord(diskRecord);
    }

    internal void ReloadExternalUpdate()
    {
        if (HasPendingEditSaves)
        {
            deferredExternalEditsCheck = true;
            deferredExternalReloadAccept = true;
            return;
        }
        deferredExternalReloadAccept = false;
        if (!externalReloadBanner.TryAcceptReload(HasPendingEditSaves, out var diskRecord) || diskRecord == null)
            return;
        externalReloadBanner = externalReloadBanner.AcceptReload();
        RefreshExternalReloadBanner();

        if (transform.Active)
        {
            transform.Cancel();
            EndTransform();
        }
        CancelParameterInputs();
        editSaveTimer.Stop();
        editGesture = null;
        interacting = false;
        editDirty = false;
        pendingMigrationReceiptClear = false;
        ++editRevision;
        ApplyExternalReloadRecord(diskRecord);
    }

    internal void KeepManualDraftOnExternalUpdate()
    {
        deferredExternalReloadAccept = false;
        externalReloadBanner = externalReloadBanner.KeepManualDraft();
        RefreshExternalReloadBanner();
    }

    private void ClearExternalReloadOnSourceChange()
    {
        deferredExternalEditsCheck = false;
        deferredExternalReloadAccept = false;
        externalReloadBanner = externalReloadBanner.ClearOnSourceChange();
        RefreshExternalReloadBanner();
    }

    private void RefreshExternalReloadBanner()
    {
        ExternalReloadBanner.Visibility = externalReloadBanner.Visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ReloadExternalUpdateClicked(object sender, RoutedEventArgs e) => ReloadExternalUpdate();

    private void KeepManualDraftClicked(object sender, RoutedEventArgs e) => KeepManualDraftOnExternalUpdate();

    private void ApplyExternalReloadRecord(PhotoEditState diskRecord)
    {
        if (file == null || currentEditRecord == null) return;
        var outcome = TransferSession.AdoptExternalReload(currentEditRecord, diskRecord);
        if (outcome.Status != AdjustmentStatus.Applied)
            return;

        CancelHslTarget();
        CancelCurveTarget();
        CancelWbProbe();
        CancelProcessingMigration();
        var saved = outcome.Saved ?? diskRecord;
        AdoptSavedEdit(saved);
        processingMigrationReceipt = editStore?.ReadProcessingMigration(file);
        RefreshProcessingMigrationControls();
    }
}
