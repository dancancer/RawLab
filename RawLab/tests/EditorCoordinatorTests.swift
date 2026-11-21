import Foundation
import PhotosUI
import RawLabKit
import SwiftUI

// Minimal RawEditorViewModel/Sony2FujiProcessor host declarations so the real
// EditorResetTransaction.swift compiles in the macOS model runner alongside EditorCoordinator.
enum Sony2FujiProcessor {
    struct RawWhiteBalance: Equatable {
        let temperature: Double
        let tint: Double
        let isCalibrated: Bool
    }
}

final class RawEditorViewModel {
    enum SourceKind: Equatable { case raw, raster }
    enum EditSaveState: Equatable { case idle, failed(String) }

    var sourceFile: PhotoSourceFile?
    var sourceIdentity: PhotoIdentity?
    var sourceKind: SourceKind? = .raw
    var activeImportRevision: UUID?
    var sourceRevision = UUID()
    var editRecordMetadata: EditorRecordMetadata?
    var isBusy = false
    var hasImage = true
    var rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance? = .init(temperature: 5500, tint: 0, isCalibrated: true)
    var pendingResetMigrationClear: (EditorEditSource, PhotoEditState, Bool)?
    var failedDraftSource: EditorEditSource?
    var persistedEditorSettings: PersistedEditorSettings?
    var editSaveState: EditSaveState = .idle
    var pendingSettings: RawSettings?

    func cancelQueuedSettingsSave() { pendingSettings = nil }
    func persistEditCandidate(_ candidate: PhotoEditState, source: EditorEditSource) -> Bool { true }
    func queueSettingsSave(_ settings: RawSettings) { pendingSettings = settings }
}

@MainActor
private final class MockCoordinatorBackend: EditorCoordinatorBackend {
    var hasImage = true
    var isBusy = false
    var isLoadingLUTs = false
    var isImportingLooks = false
    var previewRendering = false
    var previewResizePending = false
    var previewFailed = false
    var quickPresetsVisible = false
    var quickPresetStateIsPreparing = false
    var hasAdjustmentDraft = false
    var hasFailedDraftSave = false
    var adjustmentInteractionRejected = false
    var hasActiveAdjustmentInteraction = false
    var sourceRevision = UUID()
    var isRawSource = true
    var sourceIdentity: PhotoIdentity? = PhotoIdentity(resourceIdentifier: "coord-test-photo", contentIdentifier: "coord-bytes")
    var statusMessage: String?
    var cameraWhiteBalance: (temperature: Double, tint: Double, isCalibrated: Bool)? = (5500, 0, true)
    var committedPreviewSettings: RawSettings?
    var pendingSettings: RawSettings?
    var clearedHistoryRequestCount = 0

    var savedSettingsHistory: [RawSettings] = []
    var queuedSettingsHistory: [RawSettings] = []
    var previewUpdates: [(settings: RawSettings, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality)] = []
    var scheduledPreviewUpdates: [(settings: RawSettings, delay: TimeInterval, quality: EditorCoordinatorPreviewQuality)] = []
    var saveShouldSucceed = true
    var draftSaveShouldSucceed = true
    var resetShouldRequireConfirmation = true
    var commitResetShouldSucceed = true
    var committedOnDisk = RawSettings.default
    var appliedPresets: [AdjustmentPreset] = []
    var historyActionOutcomes: [IOSAdjustmentTransferOutcome] = []
    var historyUndoCalls: [Bool] = []
    var renamedLooks: [(id: String, name: String)] = []
    var appendedBatchSelectionCount = 0
    var returnedToCollectionCount = 0
    var cancelImageImportCount = 0
    var cancelCollectionPrepCount = 0
    var cancelQuickPresetCount = 0
    var cancelHDRExportCount = 0
    var closeQuickPresetsCount = 0
    var consumedRestored = false
    var consumedPersisted = false
    var activeInteractionOriginal: RawSettings?
    var retrySaveCalls: [RawSettings] = []

    func saveCurrentSettings(_ settings: RawSettings) -> Bool {
        guard saveShouldSucceed else { return false }
        savedSettingsHistory.append(settings)
        committedOnDisk = settings
        return true
    }

    func queueSettingsSave(_ settings: RawSettings) {
        pendingSettings = settings
        queuedSettingsHistory.append(settings)
    }

    func retrySave(settings: RawSettings) {
        retrySaveCalls.append(settings)
    }

    func updateCoordinatorPreview(settings: RawSettings, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality) {
        previewUpdates.append((settings, includeHistogram, quality))
    }

    func scheduleCoordinatorPreviewUpdate(settings: RawSettings, delay: TimeInterval, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality) {
        scheduledPreviewUpdates.append((settings, delay, quality))
    }

    func beginAdjustmentInteraction(settings: RawSettings) -> Bool {
        guard !adjustmentInteractionRejected else { return false }
        hasActiveAdjustmentInteraction = true
        activeInteractionOriginal = settings
        return true
    }

    func endAdjustmentInteraction(settings: RawSettings) -> Bool {
        hasActiveAdjustmentInteraction = false
        return saveShouldSucceed
    }

    func cancelAdjustmentInteraction() -> RawSettings? {
        guard hasActiveAdjustmentInteraction else { return nil }
        hasActiveAdjustmentInteraction = false
        let original = activeInteractionOriginal
        activeInteractionOriginal = nil
        return original
    }

    func prepareDraft(settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> PreparedEditorDraft? {
        guard draft.isActive, draft.isChanged(from: settings), let sourceIdentity else { return nil }
        let projected = draft.projecting(on: settings)
        let source = EditorEditSource(file: .externallyManaged(URL(fileURLWithPath: "/tmp/coord.arw")), identity: sourceIdentity, revision: sourceRevision)
        let committed = PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 0))
        let context = EditorAdjustmentContext(isRaw: isRawSource, defaultExposureMode: RawSettings.default.exposureMode,
                                              cameraTemperature: cameraWhiteBalance?.temperature, cameraTint: cameraWhiteBalance?.tint)
        let snap = EditorEditSnapshot(source: source, editRevision: revision, committed: committed, draft: draft,
                                      context: context, whiteBalance: nil)
        return PreparedEditorDraft(original: snap, candidate: committed.replacing(settings: projected, preservingFilmID: committed.filmID))
    }

    func saveDraft(_ prepared: PreparedEditorDraft, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> Bool {
        if !draftSaveShouldSucceed {
            hasFailedDraftSave = true
            return false
        }
        hasFailedDraftSave = false
        committedOnDisk = prepared.candidate.settings
        savedSettingsHistory.append(prepared.candidate.settings)
        return true
    }

    func discardDraftSaveFailure(settings: RawSettings) {
        hasFailedDraftSave = false
    }

    func prepareReset(_ scope: EditorAdjustmentScope, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> EditorResetPreparation {
        guard hasImage, let sourceIdentity else { return .blocked(.sourceNotReady) }
        if draft.isActive {
            switch scope {
            case .tool(let tool) where tool == draft.tool: break
            case .hslChannel where draft.tool == .adjustment(.hsl),
                 .allHSL where draft.tool == .adjustment(.hsl): break
            case .gradingZone where draft.tool == .adjustment(.colorGrading),
                 .allGrading where draft.tool == .adjustment(.colorGrading): break
            case .group(.geometry) where draft.tool == .geometry || draft.tool == .lens: break
            default: return .blocked(.draftConflict)
            }
        }
        let snapshot = PhotoEditState(settings: draft.isActive ? draft.projecting(on: settings) : settings, updatedAt: Date(timeIntervalSince1970: 0))
        let context = EditorAdjustmentContext(isRaw: isRawSource, defaultExposureMode: RawSettings.default.exposureMode,
                                              cameraTemperature: cameraWhiteBalance?.temperature, cameraTint: cameraWhiteBalance?.tint)
        switch EditorAdjustmentRules.prepareReset(scope, snapshot: snapshot, context: context) {
        case .unchanged: return .unchanged
        case .blocked(let reason): return .blocked(.adjustment(reason))
        case .candidate(let candidate, let requiresConfirmation):
            let source = EditorEditSource(file: .externallyManaged(URL(fileURLWithPath: "/tmp/coord.arw")), identity: sourceIdentity, revision: sourceRevision)
            let original = EditorEditSnapshot(source: source, editRevision: revision, committed: snapshot, draft: draft,
                                              context: context, whiteBalance: nil)
            return .prepared(PreparedEditorReset(scope: scope, original: original, candidate: candidate,
                                                 updatesDraft: draft.isActive,
                                                 requiresConfirmation: resetShouldRequireConfirmation && requiresConfirmation))
        }
    }

    func commitReset(_ prepared: PreparedEditorReset, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> PhotoEditState? {
        guard commitResetShouldSucceed else { return nil }
        return prepared.candidate
    }

    func currentEditState(settings: RawSettings) -> PhotoEditState {
        PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 0))
    }

    func closeQuickPresets() {
        quickPresetsVisible = false
        closeQuickPresetsCount += 1
    }

    func applyPresetToCurrentPhoto(_ preset: AdjustmentPreset, settings: RawSettings) {
        appliedPresets.append(preset)
    }

    func clearAdjustmentHistoryRequest() {
        clearedHistoryRequestCount += 1
    }

    func performAdjustmentHistoryStep(undo: Bool) -> [IOSAdjustmentTransferOutcome] {
        historyUndoCalls.append(undo)
        return historyActionOutcomes
    }

    func restoreCommittedSettings() throws -> RawSettings {
        committedOnDisk
    }

    func cancelActiveImageImport() { cancelImageImportCount += 1 }
    func cancelCollectionExportPreparation() { cancelCollectionPrepCount += 1 }
    func cancelQuickPreset() { cancelQuickPresetCount += 1 }
    func cancelHDRExport() { cancelHDRExportCount += 1 }

    func consumeRestoredSettings(_ settings: RawSettings) -> Bool {
        defer { consumedRestored = false }
        return consumedRestored
    }

    func consumePersistedEditorSettings(_ settings: RawSettings) -> Bool {
        defer { consumedPersisted = false }
        return consumedPersisted
    }

    func returnBatchSelectionToCollection() { returnedToCollectionCount += 1 }
    func appendCurrentBatchSelectionPhoto() { appendedBatchSelectionCount += 1 }
    func renameLook(id: String, name: String) { renamedLooks.append((id, name)) }
}

@MainActor
private final class MockBatchHandle: EditorBatchExportHandle {
    var isRunning: Bool
    var backgroundCancelCount = 0
    init(isRunning: Bool = false) { self.isRunning = isRunning }
    func cancel(forBackground: Bool) {
        if forBackground { backgroundCancelCount += 1 }
        isRunning = false
    }
}

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@MainActor
@main
struct EditorCoordinatorTests {
    static func main() {
        testNavigationAndDraftTransitions()
        testExpansionAndOverviewNavigation()
        testResetConfirmationAndFailureRollback()
        testModalsSheetsAndPresets()
        testImportExportAndSceneLifecycle()
        testDraftPersistenceRoundTrip()
        print("PASS: all EditorCoordinator unit tests passed")
    }

    static func testNavigationAndDraftTransitions() {
        let backend = MockCoordinatorBackend()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-nav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(backend: backend, draftStoreProvider: { EditorToolDraftStore(directory: tempDir) })

        // 1. Group navigation in overview vs active draft
        coordinator.selectEditorGroup(.color)
        check(coordinator.selectedGroup == .color && coordinator.adjustmentsExpanded && !coordinator.isEditorDraftActive,
              "selectEditorGroup switches group and expands overview")

        // 2. Selecting geometry initializes draft and clears aspect state
        coordinator.geometryAspectPreset = .square
        coordinator.geometryLockedRatio = 1.0
        coordinator.geometryAspectSwapped = true
        coordinator.selectEditorTool(.geometry)
        check(coordinator.toolWorkspaceOpen && coordinator.isEditorDraftActive && coordinator.geometrySelected &&
              coordinator.selectedGroup == .geometry && coordinator.geometryAspectPreset == .free &&
              coordinator.geometryLockedRatio == nil && !coordinator.geometryAspectSwapped &&
              coordinator.geometryDraft == coordinator.settings.geometrySettings && !coordinator.isEditorDraftChanged,
              "selectEditorTool(.geometry) initializes geometry workspace cleanly")

        // Group selection blocked while active draft workspace is open
        coordinator.selectEditorGroup(.light)
        check(coordinator.selectedGroup == .geometry, "selectEditorGroup is blocked while tool workspace is active")

        // 3. Unchanged draft switches directly without draftExitPresented
        coordinator.selectEditorTool(.adjustment(.exposure))
        check(!coordinator.draftExitPresented && coordinator.currentEditorTool == .adjustment(.exposure) &&
              !coordinator.geometrySelected && coordinator.toolWorkspaceOpen,
              "Unchanged draft switches tools directly without exit confirmation")

        // 4. Modified draft prompts confirmation, cancelDraftNavigation preserves draft & clears destination
        coordinator.workingSettings.exposure = 1.25
        check(coordinator.isEditorDraftChanged, "Editing workingSettings marks draft changed")
        coordinator.selectEditorTool(.adjustment(.contrast))
        check(coordinator.draftExitPresented && coordinator.pendingToolSelection == .adjustment(.contrast),
              "Modified draft prompts draftExitPresented with pendingToolSelection")

        coordinator.cancelDraftNavigation()
        coordinator.draftExitPresented = false
        check(coordinator.pendingToolSelection == nil && coordinator.isEditorDraftChanged &&
              coordinator.workingSettings.exposure == 1.25 && coordinator.currentEditorTool == .adjustment(.exposure),
              "cancelDraftNavigation clears destination while preserving modified draft")

        // 5. Discarding dirty draft switches to destination and leaves committed settings unchanged
        coordinator.selectEditorTool(.adjustment(.contrast))
        coordinator.finishDraftNavigation(apply: false)
        check(!coordinator.draftExitPresented && coordinator.currentEditorTool == .adjustment(.contrast) &&
              coordinator.settings.exposure == 0 && !coordinator.isEditorDraftChanged,
              "finishDraftNavigation(apply: false) discards dirty draft and opens destination")

        // 6. Applying dirty draft commits via backend and clears failure state
        coordinator.workingSettings.contrast = 1.35
        coordinator.selectEditorTool(.lens)
        coordinator.finishDraftNavigation(apply: true)
        check(abs(coordinator.settings.contrast - 1.35) < 0.0001 && coordinator.lensSelected &&
              coordinator.currentEditorTool == .lens && !coordinator.isEditorDraftChanged &&
              backend.savedSettingsHistory.last?.contrast == coordinator.settings.contrast,
              "finishDraftNavigation(apply: true) commits draft and transitions to .lens")

        // 7. Failed draft save preserves draft, destination, and committed settings
        coordinator.lensDraft?.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false)
        backend.draftSaveShouldSucceed = false
        coordinator.selectEditorTool(.film)
        coordinator.finishDraftNavigation(apply: true)
        check(coordinator.pendingToolSelection == .film && coordinator.lensSelected &&
              coordinator.isEditorDraftChanged && coordinator.settings.lensCorrection == nil,
              "Failed saveDraft keeps pendingToolSelection, draft, and committed settings")

        // Retry succeeds once disk recovers
        backend.draftSaveShouldSucceed = true
        coordinator.retryEditorSave()
        check(coordinator.pendingToolSelection == nil && coordinator.currentEditorTool == .film &&
              coordinator.settings.lensCorrection?.distortion == true,
              "retryEditorSave commits failed draft and completes pending navigation")

        // 8. Undo/redo within workspace draft
        coordinator.selectEditorTool(.adjustment(.exposure))
        coordinator.workingSettings.exposure = 0.5
        coordinator.workingSettings.exposure = 1.0
        coordinator.undoEditorDraft()
        check(abs(coordinator.workingSettings.exposure - 0.5) < 0.0001, "undoEditorDraft steps back local draft edit")
        coordinator.redoEditorDraft()
        check(abs(coordinator.workingSettings.exposure - 1.0) < 0.0001, "redoEditorDraft restores local draft edit")
    }

    static func testExpansionAndOverviewNavigation() {
        let backend = MockCoordinatorBackend()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-exp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(backend: backend, draftStoreProvider: { EditorToolDraftStore(directory: tempDir) })

        // Collapsing in overview must NOT record collapsedEditorTool
        coordinator.requestAdjustmentExpansion(false)
        check(!coordinator.adjustmentsExpanded && coordinator.collapsedEditorTool == nil && !coordinator.toolWorkspaceOpen,
              "Overview collapse leaves collapsedEditorTool nil")
        coordinator.selectEditorGroup(.color)
        coordinator.requestAdjustmentExpansion(true)
        check(coordinator.selectedGroup == .color && coordinator.adjustmentsExpanded && !coordinator.toolWorkspaceOpen,
              "Overview re-expand stays in overview without hijacking into a tool workspace")

        // Collapsing dirty tool workspace prompts and remembers collapsedEditorTool on discard
        coordinator.selectEditorTool(.adjustment(.exposure))
        coordinator.workingSettings.exposure = 2.0
        coordinator.requestAdjustmentExpansion(false)
        check(coordinator.draftExitPresented && coordinator.pendingAdjustmentExpansion == false && coordinator.adjustmentsExpanded,
              "Collapsing dirty tool prompts draftExitPresented")
        coordinator.finishDraftNavigation(apply: false)
        check(!coordinator.adjustmentsExpanded && coordinator.collapsedEditorTool == .adjustment(.exposure) &&
              !coordinator.toolWorkspaceOpen && coordinator.settings.exposure == 0,
              "Discarding collapse closes workspace and remembers collapsedEditorTool")
        coordinator.requestAdjustmentExpansion(true)
        check(coordinator.adjustmentsExpanded && coordinator.toolWorkspaceOpen &&
              coordinator.selectedAdjustment == .exposure && coordinator.collapsedEditorTool == nil,
              "Re-expanding restores the remembered collapsedEditorTool")

        // New source clears collapsed tool, recipe picker, sheets, and viewport
        coordinator.selectEditorTool(.recipe)
        coordinator.draftExitPresented = true
        coordinator.resetForNewSource()
        check(!coordinator.choosingMasterRecipe && !coordinator.toolWorkspaceOpen && !coordinator.draftExitPresented &&
              coordinator.collapsedEditorTool == nil && coordinator.pendingToolSelection == nil,
              "resetForNewSource clears active workspace, recipe picker, and pending modal state")
    }

    static func testResetConfirmationAndFailureRollback() {
        let backend = MockCoordinatorBackend()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(backend: backend, draftStoreProvider: { EditorToolDraftStore(directory: tempDir) })

        coordinator.settings.exposure = 1.0
        coordinator.selectEditorTool(.geometry)
        coordinator.geometryDraft?.quarterTurns = 1

        // Resetting .all while a draft is open is blocked with draftConflict
        coordinator.requestEditorReset(.all)
        check(!coordinator.resetConfirmationPresented && coordinator.preparedReset == nil &&
              backend.statusMessage == EditorResetBlock.draftConflict.message,
              "requestEditorReset(.all) during active draft is blocked with draftConflict")

        // Resetting committed state shows confirmation and applies only upon confirmEditorReset
        coordinator.cancelEditorDraft()
        coordinator.requestEditorReset(.all)
        check(coordinator.resetConfirmationPresented && coordinator.preparedReset != nil &&
              coordinator.preparedResetScope == .all && coordinator.settings.exposure == 1.0,
              "requestEditorReset(.all) presents confirmation before mutating settings")

        coordinator.cancelEditorReset()
        coordinator.resetConfirmationPresented = false
        check(coordinator.preparedReset == nil && coordinator.settings.exposure == 1.0,
              "cancelEditorReset keeps settings untouched")

        coordinator.requestEditorReset(.all)
        coordinator.confirmEditorReset()
        coordinator.resetConfirmationPresented = false
        check(coordinator.settings.exposure == 0 && coordinator.preparedReset == nil,
              "confirmEditorReset resets settings to default")

        // Stale reset rejection reports error message
        coordinator.settings.exposure = 0.75
        coordinator.requestEditorReset(.all)
        backend.commitResetShouldSucceed = false
        coordinator.confirmEditorReset()
        check(coordinator.settings.exposure == 0.75 && backend.statusMessage != nil,
              "Stale commitReset failure preserves settings and surfaces statusMessage")
    }

    static func testModalsSheetsAndPresets() {
        let backend = MockCoordinatorBackend()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-modal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(backend: backend, draftStoreProvider: { EditorToolDraftStore(directory: tempDir) })

        // 1. Clean subtool draft auto-closes when opening copy/paste/history
        coordinator.selectEditorTool(.adjustment(.contrast))
        coordinator.requestAdjustmentAction(.copy)
        check(!coordinator.toolWorkspaceOpen && !coordinator.isEditorDraftActive &&
              coordinator.adjustmentSheet == .copy && !backend.hasAdjustmentDraft,
              "Clean subtool draft closes cleanly and opens .copy sheet")

        // 2. Modified subtool draft prompts before opening paste sheet
        coordinator.adjustmentSheet = nil
        coordinator.selectEditorTool(.adjustment(.contrast))
        coordinator.workingSettings.contrast = 1.4
        coordinator.requestAdjustmentAction(.paste)
        check(coordinator.draftExitPresented && coordinator.adjustmentSheet == nil &&
              coordinator.pendingAdjustmentAction == .paste,
              "Dirty subtool draft prompts before opening .paste sheet")
        coordinator.finishDraftNavigation(apply: false)
        check(!coordinator.toolWorkspaceOpen && coordinator.adjustmentSheet == .paste &&
              coordinator.pendingAdjustmentAction == nil,
              "Discarding dirty draft opens pending .paste sheet")

        // 3. Preset library queued action and returnToPresetLibrary round-trip
        let payload = try! AdjustmentTransferPayload(
            source: AdjustmentTransferSource(identifier: "coord-test-photo", isRaw: true, processingVersion: 1, recipe: nil),
            values: ["light.exposure": .number(0.5)]
        )
        let preset = AdjustmentPreset(id: "preset-test-1", name: "Test", createdAt: 1, updatedAt: 1, payload: payload)
        coordinator.adjustmentSheet = .presets
        coordinator.queuePresetAction(.presetApplyMultiple(preset))
        check(coordinator.adjustmentSheet == nil && coordinator.queuedPresetAction == .presetApplyMultiple(preset),
              "queuePresetAction dismisses presets sheet before executing")
        coordinator.finishAdjustmentSheet()
        check(coordinator.adjustmentSheet == .presetApply && coordinator.returnToPresetLibrary &&
              coordinator.applyingPreset == preset,
              "finishAdjustmentSheet executes queued presetApplyMultiple and sets returnToPresetLibrary")
        coordinator.adjustmentSheet = nil
        coordinator.finishAdjustmentSheet()
        check(coordinator.adjustmentSheet == .presets && !coordinator.returnToPresetLibrary &&
              coordinator.applyingPreset == nil,
              "Dismissing presetApply returns to .presets library")

        // 4. Quick presets open/close & single preset apply
        coordinator.adjustmentSheet = nil
        coordinator.selectEditorTool(.adjustment(.contrast))
        coordinator.workingSettings.contrast = 1.25
        coordinator.requestAdjustmentAction(.presetApply(preset))
        coordinator.finishDraftNavigation(apply: true)
        check(backend.quickPresetsVisible && coordinator.selectedGroup == .looks &&
              backend.appliedPresets == [preset] && abs(coordinator.settings.contrast - 1.25) < 0.0001,
              "presetApply commits draft, shows quick presets, and applies preset")
        coordinator.closeQuickPresets()
        check(!backend.quickPresetsVisible, "closeQuickPresets delegates to backend")

        // 5. Look rename modal transitions
        coordinator.beginLookRename(id: "custom-look", name: "Old Name")
        check(coordinator.showingLookRename && coordinator.renamingLook?.id == "custom-look",
              "beginLookRename presents look rename alert")
        coordinator.renamedLUTName = "New Name"
        coordinator.completeLookRename()
        check(!coordinator.showingLookRename && coordinator.renamingLook == nil &&
              backend.renamedLooks.count == 1 && backend.renamedLooks[0].name == "New Name",
              "completeLookRename delegates renameLook and dismisses alert")

        // 6. Recent photos, camera, processing context, privacy modals
        coordinator.showRecentPhotos()
        check(coordinator.showingRecentPhotos, "showRecentPhotos opens recent photos sheet")
        coordinator.showingRecentPhotos = false
        coordinator.recentImportRequested = true
        coordinator.finishRecentPhotos { _ in
            check(false, "Should import instead of opening recent photo when recentImportRequested is true")
        }
        check(!coordinator.recentImportRequested && coordinator.showingPhotoImporter,
              "finishRecentPhotos triggers photo importer when recentImportRequested is set")
        coordinator.showingPhotoImporter = false
        coordinator.presentProcessingContext()
        check(coordinator.showingProcessingContext, "presentProcessingContext shows sheet")
        coordinator.dismissProcessingContext()
        check(!coordinator.showingProcessingContext, "dismissProcessingContext hides sheet")
        coordinator.presentPrivacy()
        check(coordinator.showingPrivacy, "presentPrivacy shows privacy sheet")
        coordinator.presentCameraWorkspace()
        check(coordinator.showingCameraWorkspace, "presentCameraWorkspace shows camera workspace")
    }

    static func testImportExportAndSceneLifecycle() {
        let backend = MockCoordinatorBackend()
        var releasedURLs: [URL] = []
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-life-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(
            backend: backend,
            draftStoreProvider: { EditorToolDraftStore(directory: tempDir) },
            releaseImportedFile: { releasedURLs.append($0) }
        )

        // File & look import routing
        coordinator.requestEditorImport(file: true)
        check(coordinator.documentImportKind == .photo && coordinator.showingDocumentImporter && !coordinator.showingPhotoImporter,
              "requestEditorImport(file: true) opens document importer for photo")
        coordinator.showingDocumentImporter = false

        // Look import allowed in overview or .film, blocked in other tools
        coordinator.selectEditorTool(.adjustment(.exposure))
        coordinator.requestLookImport()
        check(!coordinator.showingDocumentImporter, "requestLookImport is blocked during non-film active tool draft")
        coordinator.selectEditorTool(.film)
        coordinator.requestLookImport()
        check(coordinator.documentImportKind == .looks && coordinator.showingDocumentImporter,
              "requestLookImport opens document importer for looks inside .film tool")
        coordinator.showingDocumentImporter = false
        coordinator.finishEditorTool()

        // Single export & batch selection close clean draft
        coordinator.selectEditorTool(.adjustment(.contrast))
        coordinator.workingSettings.contrast = 1.2
        coordinator.requestSingleExport(.renderedDNG)
        check(!coordinator.toolWorkspaceOpen && coordinator.showingExportSize &&
              coordinator.singleExportFormat == .renderedDNG && abs(coordinator.settings.contrast - 1.2) < 0.0001,
              "requestSingleExport commits active draft and opens export size sheet")

        coordinator.showingExportSize = false
        coordinator.openBatchSelection()
        check(coordinator.showingBatchSelection && backend.appendedBatchSelectionCount == 1,
              "openBatchSelection appends current photo and opens collection sheet")
        coordinator.showingBatchSelection = false

        // Collection navigation prompt on dirty draft
        coordinator.selectEditorTool(.adjustment(.exposure))
        coordinator.workingSettings.exposure = 0.8
        coordinator.requestCollectionNavigation(.returnToCollection)
        check(coordinator.draftExitPresented && coordinator.pendingCollectionNavigation == .returnToCollection,
              "requestCollectionNavigation prompts on dirty draft")
        coordinator.finishDraftNavigation(apply: false)
        check(coordinator.showingBatchSelection && backend.returnedToCollectionCount == 1 &&
              coordinator.settings.exposure == 0,
              "finishDraftNavigation(apply: false) returns to collection without committing dirty draft")

        // System photo drop/open cancel releases URLs
        let dropped = URL(fileURLWithPath: "/tmp/dropped-\(UUID().uuidString).arw")
        coordinator.pendingSystemPhotoURLs = [[dropped]]
        var skippedCallbackCalled = false
        coordinator.cancelDraftNavigation(onSystemPhotoSkipped: { skippedCallbackCalled = true })
        check(coordinator.pendingSystemPhotoURLs.isEmpty && releasedURLs == [dropped] && !skippedCallbackCalled,
              "cancelDraftNavigation releases skipped system photo URLs immediately")

        // Scene phase background cancels running batch, HDR export, quick presets, and temporary viewing
        let batch = MockBatchHandle(isRunning: true)
        coordinator.batchExportHandle = batch
        coordinator.photoViewing.beginHolding(isDraft: false)
        coordinator.handleScenePhaseChange(.background)
        check(batch.backgroundCancelCount == 1 && !batch.isRunning &&
              backend.cancelHDRExportCount == 1 && backend.cancelCollectionPrepCount == 1 &&
              backend.cancelQuickPresetCount == 1 && !coordinator.photoViewing.holdingBefore,
              "handleScenePhaseChange(.background) cancels running batch, HDR export, presets, and temporary viewing")
    }

    static func testDraftPersistenceRoundTrip() {
        let backend = MockCoordinatorBackend()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coord-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let coordinator = EditorCoordinator(backend: backend, draftStoreProvider: { EditorToolDraftStore(directory: tempDir) })

        coordinator.selectEditorTool(.geometry)
        coordinator.geometryDraft?.cropX = 0.25
        coordinator.geometryDraft?.cropWidth = 0.5
        coordinator.syncGeometryDraft()
        coordinator.preserveEditorDraft()

        // Reset in-memory coordinator state and restore from temp draft store
        coordinator.resetForNewSource()
        check(!coordinator.toolWorkspaceOpen && coordinator.geometryDraft == nil, "resetForNewSource clears in-memory draft")

        coordinator.restoreEditorDraft()
        check(coordinator.toolWorkspaceOpen && coordinator.geometrySelected &&
              coordinator.geometryDraft?.cropX == 0.25 && coordinator.geometryDraft?.cropWidth == 0.5,
              "restoreEditorDraft recovers saved geometry draft from EditorToolDraftStore")
    }
}
