using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    internal AppPaths Paths => appPaths;
    internal EditStore? EditStoreInstance { get => persistence.Store; set => persistence.RebindStore(value); }
    internal BatchJournal BatchJournalInstance { get => batchJournal; set => batchJournal = value; }
    internal AdjustmentPresetStore PresetStoreInstance { get => presetStore; set => presetStore = value; }
    internal Library LibraryInstance => library;
    internal LookLibrary? LookLibraryInstance { get => lookLibrary; set => lookLibrary = value; }
    internal UsageAnalytics UsageAnalyticsInstance { get => usageAnalytics; set => usageAnalytics = value; }
    internal DesktopUpdateController DesktopUpdates => desktopUpdates;
    internal AIGpuPreferenceStore AiPreferenceStoreInstance { get => aiPreferenceStore; set => aiPreferenceStore = value; }
    internal AIGpuPreference AiPreferenceValue { get => aiPreference; set => aiPreference = value; }
    internal AIDiagnosticStore AiDiagnosticsInstance { get => aiDiagnostics; set => aiDiagnostics = value; }
    internal RenderEngine? EngineInstance { get => engine; set => engine = value; }
    internal Adjustments Settings { get => settings; set => settings = value; }
    internal string? CurrentFile { get => file; set => file = value; }
    internal string? CurrentLut { get => lut; set => lut = value; }
    internal RenderedImage? CurrentResult => result;
    internal RenderedImage? NeutralResult => neutralResult;
    internal NeutralReferenceKey? AcceptedReference => acceptedReference;
    internal bool RenderFailed => renderFailed;
    internal bool ExactReady => exactReady;
    internal bool EditDirty => editDirty;
    internal long EditRevision => editRevision;
    internal long OpenRevision => persistence.OpenRevision;
    internal int? ExportLongEdge { get => exportLongEdge; set => exportLongEdge = value; }
    internal OutputSharpening ExportOutputSharpening { get => exportOutputSharpening; set { exportOutputSharpening = value; RefreshExportSharpeningMenu(); } }
    internal string? LastExportedPath => lastExportedPath;
    internal int PreviewLongEdge { get => previewLongEdge; set => previewLongEdge = value; }
    internal int RequestedPreviewLongEdge { get => requestedPreviewLongEdge; set => requestedPreviewLongEdge = value; }
    internal bool PreviewDeferred => previewDeferred;
    internal bool Interacting { get => interacting; set => interacting = value; }
    internal bool ForegroundBusy { get => foregroundBusy; set => foregroundBusy = value; }
    internal bool ClosingFlag { get => Volatile.Read(ref closing); set => Volatile.Write(ref closing, value); }
    internal bool CloseFinished => closeFinished;
    internal bool UpdateQuitApproved { get => updateQuitApproved; set => updateQuitApproved = value; }
    internal bool AutoExposing { get => autoExposing; set => autoExposing = value; }
    internal bool TransferPreparing { get => transferPreparing; set => transferPreparing = value; }
    internal bool AnalyticsDisposed => analyticsDisposed;
    internal bool ReadingFolder => readingFolder;
    internal LibraryEntry? BrowsedFolder { get => browsedFolder; set => browsedFolder = value; }
    internal BitmapSource? OpeningPreview => openingPreview;
    internal PhotoInfoMode PhotoInfoModeValue => photoInfoMode;
    internal EditorViewState ViewState => view;
    internal WorkspaceLayout WorkspaceLayoutInstance => workspaceLayout;
    internal RecentLooks RecentLooksInstance { get => recentLooks; set => recentLooks = value; }
    internal string RecentLooksPath { get => recentLooksPath; set => recentLooksPath = value; }
    internal string WorkspaceWidthsPath { get => workspaceWidthsPath; set => workspaceWidthsPath = value; }
    internal string ExportStagingDirectory { get => exportStagingDirectory; set => exportStagingDirectory = value; }
    internal string? PhotoPreviewCacheDirectory { get => photoPreviewCacheDirectory; set => photoPreviewCacheDirectory = value; }
    internal TransformDraft TransformDraft => transform;
    internal bool TransformPreviewReady => transformPreviewReady;
    internal bool HasHslAcceptedWork => hslAcceptedWork != null;
    internal object? HslAcceptedWorkToken => hslAcceptedWork;
    internal HslTargetInteraction HslTarget => hslTarget;
    internal bool HslHistoryActive => hslHistoryActive;
    internal bool HslTargetEnabled => hslTargetEnabled;
    internal HslTargetAvailability? HslTargetNotice => hslTargetNotice;
    internal object? EditGestureInstance => editGesture;
    internal EditorToolMode ToolMode => toolMode;
    internal Parameter SelectedParameter => selectedParameter;
    internal ToneControlParameter? SelectedToneParameter => selectedToneParameter;
    internal EditorAdjustmentGroup? ExpandedGroup { get => expandedGroup; set => expandedGroup = value; }
    internal EditorAdjustmentTool CurrentToolForTests => CurrentTool;
    internal int RequestedAIBackendForTests => RequestedAIBackend;
    internal bool ReferenceCurrentForTests => ReferenceCurrent;
    internal bool ViewInputBlockedForTests => ViewInputBlocked;
    internal AdjustmentTransferSession TransferSessionForTests => TransferSession;
    internal AdjustmentTransferSession? AdjustmentSessionInstance => adjustmentSession;
    internal Dictionary<EditorAdjustmentGroup, Button> GroupButtons => groupButtons;
    internal Dictionary<EditorAdjustmentTool, (Button Button, AdjustmentRing Ring)> WorkspaceTools => workspaceTools;
    internal Dictionary<AtmosphereParameter, (Button Button, AdjustmentRing Ring)> AtmosphereToolButtons => atmosphereToolButtons;
    internal Dictionary<string, Button> FilmButtons => filmButtons;
    internal Dictionary<string, Button> RecipeButtons => recipeButtons;
    internal PhotoEditState? CurrentEditRecord => currentEditRecord;
    internal ProcessingMigrationReceipt? ProcessingMigrationReceiptValue => processingMigrationReceipt;
    internal Dictionary<HDRFloatImage, BitmapSource> HdrFalseColorCache => hdrFalseColorCache;
    internal DispatcherTimer PreviewResizeTimer => previewResize;
    internal DispatcherTimer EditSaveTimer => editSaveTimer;
    internal DispatcherTimer EditNoticeTimer => editNoticeTimer;
    internal DispatcherTimer ThumbnailRefreshTimer => thumbnailRefresh;
    internal DispatcherTimer PhotoFolderRefreshTimer => photoFolderRefresh;
    internal AboutWindow? AboutWindowInstance => aboutWindow;
    internal BatchExportWindow? BatchWindowInstance => batchWindow;
    internal BatchSelectionWindow? CollectionWindowInstance => collectionWindow;
    internal SoftwareUpdateWindow? SoftwareUpdateWindowInstance => softwareUpdateWindow;
    internal bool SchedulerBusy => scheduler.Busy;
    internal bool SchedulerHasActive => scheduler.Active != null;
    internal object? SchedulerPending => scheduler.Pending;
    internal long SchedulerRevision => scheduler.Revision;
    internal bool EmbeddedSchedulerBusy => embeddedScheduler.Busy;
    internal HashSet<LibraryEntry> VisibleThumbnails => visibleThumbnails;
    internal bool HasPendingAllReset => pendingAllReset != null;
    internal InspectionSessionState InspectionState => inspection;
    internal void SetInspectionOverlayForTests(InspectionOverlayMode mode) { inspection.SelectOverlay(mode); RefreshViewingFrames(); }
    internal void PinInspectionAnchorForTests(double outX, double outY) => PinInspectionAnchor(outX, outY);

    internal void SetPendingAllResetForTests(string? targetFile, long targetOpenRevision, EditorAdjustmentTool tool, EditorAdjustmentGroup? group) =>
        pendingAllReset = targetFile == null ? null : new PendingAllReset(targetFile, targetOpenRevision, tool, group);

    internal void ClearPendingAllResetForTests() => pendingAllReset = null;

    internal void SelectToolForTests(EditorAdjustmentTool tool) => SelectTool(tool);
    internal void SelectGroupForTests(EditorAdjustmentGroup group) => SelectGroup(group);
    internal void MarkEditedForTests() => MarkEdited();
    internal bool SaveEditsForTests() => SaveEdits();
    internal Task<bool> FlushSaveEditsForTestsAsync() => FlushSaveEditsAsync();
    internal bool HasPendingBackgroundSave => persistence.HasPendingBackgroundSave;
    internal void ScheduleForTests(bool initialPreview = false, bool viewportOnly = false) => Schedule(initialPreview, viewportOnly);
    internal void RefreshControlsForTests() => RefreshControls();
    internal void RefreshWorkspaceForTests() => RefreshWorkspace();
    internal void RefreshCopyLabelsForTests() => RefreshCopyLabels();
    internal void BuildResetMenuForTests() => BuildResetMenu();
    internal void BuildToolsForTests() => BuildTools();
    internal void LoadRecentLooksForTests() => LoadRecentLooks();
    internal Task BrowseFolderForTests(LibraryEntry? folder, bool reload = false) => BrowseFolder(folder, reload);
    internal bool DismissWorkspaceTransientForTests() => DismissWorkspaceTransient();
    internal LibraryEntry? ResolveContextEntryForTests(object sender) => ResolveContextEntry(sender);
    internal void AboutClickedForTests(object sender, RoutedEventArgs e) => AboutClicked(sender, e);
    internal void SetStatusForTests(string text, bool error = false) => SetStatus(text, error);
    internal void SetSaveNoticeForTests(string key, string detail, bool failed) => SetSaveNotice(key, detail, failed);
    internal void ActualClickedForTests(object sender, RoutedEventArgs e) => ActualClicked(sender, e);
    internal void FitClickedForTests(object sender, RoutedEventArgs e) => FitClicked(sender, e);
    internal void ShowBatchForTests(BatchJob job, bool autoStart = false) => ShowBatch(job, autoStart);
    internal void FinishCloseForTests() => FinishClose();
    internal void CancelParameterInputsForTests() => CancelParameterInputs();
    internal int RenderEdgeForTests(bool proxy) => RenderEdge(proxy);
    internal void BeginTransformForTests(TransformTool tool) => BeginTransform(tool);
    internal void UpdateLensDraftForTests(LensSettings value) => UpdateLensDraft(value);
    internal void UpdateGeometryDraftForTests(GeometrySettings value, bool dragging) => UpdateGeometryDraft(value, dragging);
    internal bool ApplyTransformDraftForTests() => ApplyTransformDraft();
    internal void CancelTransformDraftForTests() => CancelTransformDraft();
    internal bool ResolveTransformDraftForTests() => ResolveTransformDraft();
    internal void BeginHoldingBeforeCoreForTests(bool semanticAction) => BeginHoldingBeforeCore(semanticAction);
    internal void EndHoldingBeforeForTests() => EndHoldingBefore();
    internal void RequestResetForTests(EditorResetScope scope) => RequestReset(scope);
    internal void ExecuteResetForTests(EditorResetScope scope) => ExecuteReset(scope);
    internal void ResetAITaskForTests() => ResetAITask();
    internal void ResetMenuClickedForTests(object sender, RoutedEventArgs e) => ResetMenuClicked(sender, e);
    internal void ShowSoftwareUpdatesForTests(bool fromSettings) => ShowSoftwareUpdates(fromSettings);
    internal UpdateSessionStatus UpdateStatusForTests() => UpdateStatus();
    internal void ShowCollectionForTests() => ShowCollection();
    internal void RunPhotoHistoryForTests(bool undo) => RunPhotoHistory(undo);
    internal void AdoptSavedEditForTests(PhotoEditState saved) => AdoptSavedEdit(saved);
    internal IReadOnlyList<AdjustmentOutcome> AdoptAdjustmentOutcomesForTests(IReadOnlyList<AdjustmentOutcome> outcomes, Dictionary<string, Exception?> adopted) =>
        AdoptAdjustmentOutcomes(outcomes, adopted);
    internal Task ShowAdjustmentPreflightForTests(AdjustmentPayload payload, IEnumerable<string> paths,
        AdjustmentHistoryAction action = AdjustmentHistoryAction.Paste, string? sourceName = null) =>
        ShowAdjustmentPreflight(payload, paths, action, sourceName);
    internal void RetrySaveClickedForTests(object sender, RoutedEventArgs e) => RetrySaveClicked(sender, e);
    internal void BeginHslTargetForTests(Point point, double? keyDelta = null) => BeginHslTarget(point, keyDelta);
    internal void MoveHslTargetForTests(double delta) => MoveHslTarget(delta);
    internal void EndHslTargetForTests() => EndHslTarget();
    internal void CancelHslTargetForTests() => CancelHslTarget();
    internal void SetHslTargetModeForTests(bool enabled, int axis) => SetHslTargetMode(enabled, axis);
    internal void ExitHslTargetClickedForTests(object sender, RoutedEventArgs e) => ExitHslTargetClicked(sender, e);
    internal void BeginEditGestureForTests() => BeginEditGesture();
    internal void CancelEditGestureForTests() => CancelEditGesture();

    internal void IsolateForTests(AppPaths isolatedPaths, UsageAnalytics isolatedAnalytics, string? editDirectory = null)
    {
        appPaths = isolatedPaths;
        desktopUpdates.IsolateForTests(
            new UpdateStore(isolatedPaths.UpdatesDirectory),
            new UpdateDataBackup(isolatedPaths.Root, isolatedPaths.UpdatesDirectory),
            new UpdatePreferences { AutomaticCheck = false });
        usageAnalytics = isolatedAnalytics;
        UpdateNotice.Visibility = Visibility.Collapsed;
        persistence.RebindStore(new EditStore(editDirectory ?? isolatedPaths.EditsDirectory));
        photoPreviewCacheDirectory = isolatedPaths.EditedPhotoPreviewCacheDirectory;
        recentLooksPath = isolatedPaths.RecentLooksPath;
        workspaceWidthsPath = isolatedPaths.WorkspaceWidthsPath;
        recentLooks = new RecentLooks();
        presetStore = new AdjustmentPresetStore(isolatedPaths.PresetsDirectory);
        batchJournal = new BatchJournal(isolatedPaths.BatchDirectory);
        exportStagingDirectory = isolatedPaths.ExportStagingDirectory;
        aiPreferenceStore = new AIGpuPreferenceStore(isolatedPaths.AiGpuPreferencesPath);
        aiDiagnostics = new AIDiagnosticStore(isolatedPaths.AiDiagnosticsDirectory);
        diagnosticSession = new DiagnosticSessionStore(isolatedPaths.DiagnosticsDirectory);
        aiPreference = new AIGpuPreference();
        library.SettingsPath = isolatedPaths.FoldersPath;
        library.Roots.Clear();
        if (photoPreviews != null && !ReferenceEquals(photoPreviews.Store, editStore))
        {
            photoPreviews.Store.Changed -= PhotoEditChanged;
            photoPreviews.Ready -= PhotoPreviewReady;
            _ = photoPreviews.DisposeAsync();
            photoPreviews = null;
        }
        StartExternalStoreWatcher();
    }

    internal bool HasActiveExternalReloadBannerForTests => ExternalReloadBanner.Visibility == Visibility.Visible;
    internal bool HasUnsavedManualDraftForTests => HasUnsavedManualDraft;
    internal void ReloadExternalUpdateForTests() => ReloadExternalUpdate();
    internal void KeepManualDraftOnExternalUpdateForTests() => KeepManualDraftOnExternalUpdate();
    internal void HandleExternalPresetsFileChangeForTests() => HandleExternalPresetsFileChange();
    internal void HandleExternalEditsFileChangeForTests() => HandleExternalEditsFileChange();
    internal EditedPhotoPreviews? PhotoPreviewsForTests() => PhotoPreviews();
}
