import Combine
import Foundation
import PhotosUI
import RawLabKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorOpaquePresentation: Identifiable {
    let id = UUID()
    let value: Any
}

enum EditorDocumentImportKind {
    case photo
    case looks

    var contentTypes: [UTType] {
        switch self {
        case .photo: PhotoImportFile.photoPickerContentTypes
        case .looks: PhotoImportFile.supportedLookContentTypes
        }
    }

    var allowsMultipleSelection: Bool { self == .looks }
}

enum RulerFocusPhase: Equatable {
    case idle, dragging, holding, restoring
}

enum IOSCollectionNavigation: Equatable {
    case edit(String)
    case returnToCollection
}

enum IOSAdjustmentSheet: String, Identifiable {
    case copy, paste, history, presets, presetSave, presetApply
    var id: String { rawValue }
}

enum IOSAdjustmentAction: Equatable {
    case copy, paste, history, undo, redo
    case presetSave
    case presetApply(AdjustmentPreset)
    case presetApplyMultiple(AdjustmentPreset)
}

enum PhotoEditFilter: String, CaseIterable, Identifiable {
    case all, edited, unedited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .edited: "已编辑"
        case .unedited: "未编辑"
        }
    }
    func includes(_ edited: Bool?) -> Bool {
        switch self {
        case .all: true
        case .edited: edited == true
        case .unedited: edited == false
        }
    }
}

struct FileExportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let removeAfterExport: Bool
    let successMessage: String?
    let cancelMessage: String?
    var recordsPhotoExport = true
    // Q6（B1）：另存成功后要登记的导出证据（源照片内容标识，如相机原件 digest）；
    // 空数组表示该导出与相机原件账本无关（如错误日志）。
    var evidenceIdentifiers: [String] = []
}

struct EditorRenamingLook: Equatable {
    let id: String
    let name: String
}

enum EditorCoordinatorPreviewQuality: Equatable {
    case interactive
    case final
}

@MainActor
protocol EditorBatchExportHandle: AnyObject {
    var isRunning: Bool { get }
    func cancel(forBackground: Bool)
}

struct EditorCollectionBatchHandoff {
    private var pending: (handle: any EditorBatchExportHandle, automaticallyStart: Bool)?
    var hasPending: Bool { pending != nil }

    mutating func enqueue(_ handle: any EditorBatchExportHandle, automaticallyStart: Bool) {
        pending = (handle, automaticallyStart)
    }

    mutating func cancelAutomaticStart() {
        pending?.automaticallyStart = false
    }

    mutating func promote<Model: EditorBatchExportHandle>(
        as type: Model.Type = Model.self,
        sceneIsActive: Bool,
        configure: (Model) -> Void,
        start: (Model) -> Bool
    ) -> Model? {
        guard let entry = pending, let model = entry.handle as? Model else { return nil }
        pending = nil
        configure(model)
        if entry.automaticallyStart && sceneIsActive {
            _ = start(model)
        }
        return model
    }
}

protocol EditorToolDraftStoring {
    func save(identity: PhotoIdentity, draft: EditorToolDraft) throws
    func load(identity: PhotoIdentity, committed: RawSettings) throws -> EditorToolDraft?
    func clear(identity: PhotoIdentity) throws
}

extension EditorToolDraftStore: EditorToolDraftStoring {}

@MainActor
protocol EditorCoordinatorBackend: AnyObject {
    var hasImage: Bool { get }
    var isBusy: Bool { get }
    var isLoadingLUTs: Bool { get }
    var isImportingLooks: Bool { get }
    var previewRendering: Bool { get }
    var previewResizePending: Bool { get }
    var previewFailed: Bool { get }
    var quickPresetsVisible: Bool { get set }
    var quickPresetStateIsPreparing: Bool { get }
    var hasAdjustmentDraft: Bool { get set }
    var hasFailedDraftSave: Bool { get }
    var adjustmentInteractionRejected: Bool { get }
    var hasActiveAdjustmentInteraction: Bool { get }
    var sourceRevision: UUID { get }
    var isRawSource: Bool { get }
    var sourceIdentity: PhotoIdentity? { get }
    var statusMessage: String? { get set }
    var cameraWhiteBalance: (temperature: Double, tint: Double, isCalibrated: Bool)? { get }
    var committedPreviewSettings: RawSettings? { get set }
    var pendingSettings: RawSettings? { get }

    func saveCurrentSettings(_ settings: RawSettings) -> Bool
    func queueSettingsSave(_ settings: RawSettings)
    func retrySave(settings: RawSettings)
    func updateCoordinatorPreview(settings: RawSettings, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality)
    func scheduleCoordinatorPreviewUpdate(settings: RawSettings, delay: TimeInterval, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality)
    func beginAdjustmentInteraction(settings: RawSettings) -> Bool
    func endAdjustmentInteraction(settings: RawSettings) -> Bool
    func cancelAdjustmentInteraction() -> RawSettings?
    func prepareDraft(settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> PreparedEditorDraft?
    func saveDraft(_ prepared: PreparedEditorDraft, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> Bool
    func discardDraftSaveFailure(settings: RawSettings)
    func prepareReset(_ scope: EditorAdjustmentScope, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> EditorResetPreparation
    func commitReset(_ prepared: PreparedEditorReset, settings: RawSettings, revision: UUID, draft: EditorDraftSnapshot) -> PhotoEditState?
    func currentEditState(settings: RawSettings) -> PhotoEditState
    func closeQuickPresets()
    func applyPresetToCurrentPhoto(_ preset: AdjustmentPreset, settings: RawSettings)
    func clearAdjustmentHistoryRequest()
    func performAdjustmentHistoryStep(undo: Bool) -> [IOSAdjustmentTransferOutcome]
    func restoreCommittedSettings() throws -> RawSettings
    func cancelActiveImageImport()
    func cancelCollectionExportPreparation()
    func cancelQuickPreset()
    func cancelHDRExport()
    func consumeRestoredSettings(_ settings: RawSettings) -> Bool
    func consumePersistedEditorSettings(_ settings: RawSettings) -> Bool
    func returnBatchSelectionToCollection()
    func appendCurrentBatchSelectionPhoto()
    func renameLook(id: String, name: String)
}

@MainActor
final class EditorCoordinator: ObservableObject {
    weak var backend: (any EditorCoordinatorBackend)?
    private let draftStoreProvider: () throws -> any EditorToolDraftStoring
    let photoSourceLoader: (PhotosPickerItem) async throws -> PhotoImportSource
    private let releaseImportedFile: (URL) -> Void

    // MARK: - Recent photos & legacy asset edit state
    @Published var showingRecentPhotos = false
    @Published var recentPhotoFilter = PhotoEditFilter.all
    @Published var recentPhotoScrollID: String?
    @Published var recentPhotoToOpen: RecentPhoto?
    @Published var recentImportRequested = false
    @Published var recentOpenError: String?
    @Published var recentFailedPhoto: RecentPhoto?
    @Published var recentReselection: RecentPhoto?
    @Published var showingLegacyAssetEdit = false
    var legacyAssetEditDecision: CheckedContinuation<Bool?, Never>?

    // MARK: - Settings, tool navigation & workspace draft state
    @Published var settings = RawSettings.default
    @Published var settingsRevision = UUID()
    @Published var workspaceDraft: EditorToolDraft?
    @Published var toolWorkspaceOpen = false
    @Published var workspaceDraftID = UUID()
    @Published var lookSearchExpanded = false
    @Published var photoViewing = PhotoViewingState()
    @Published var photoViewport = PhotoViewport()
    @Published var selectedGroup = EditorAdjustmentGroup.looks
    @Published var selectedAdjustment: AdjustmentKind? = nil
    @Published var selectedHDRRenditionTool: EditorToolSelection? = nil
    @Published var lensSelected = false
    @Published var geometrySelected = false
    @Published var choosingMasterRecipe = false
    @Published var adjustmentsExpanded = true
    @Published var histogramExpanded = false
    @Published var collapsedEditorTool: EditorToolSelection?
    @Published var pendingToolSelection: EditorToolSelection?
    @Published var pendingAdjustmentExpansion: Bool?
    @Published var draftExitPresented = false
    @Published var adjustmentFine = false

    // MARK: - Geometry, lens, HSL, grading, slider & reset state
    @Published var isImporting = false
    @Published var isSaving = false
    @Published var isAdjustingSlider = false
    @Published var rulerFocusPhase = RulerFocusPhase.idle
    var rulerFocusTask: Task<Void, Never>?
    @Published var geometryDraft: GeometrySettings?
    @Published var geometryAspectPreset: CropAspectPreset = .free
    @Published var geometryLockedRatio: Double?
    @Published var geometryAspectSwapped = false
    @Published var geometryGrid = true
    @Published var geometryPerspective = false
    @Published var geometryRotation = false
    @Published var lensDraft: RawSettings?
    @Published var hslChannel = 0
    @Published var hslTargetEnabled = false
    @Published var hslTargetAxis: HSLAxis = .hue
    @Published var hslTargetInteraction = HSLTargetInteraction()
    @Published var hslTargetPoint: CGPoint?
    @Published var hslTargetNotice: HSLTargetAvailability?
    @Published var hslTargetHistoryActive = false
    @Published var gradingZone: ColorGradingZone = .shadows
    @Published var preparedReset: PreparedEditorReset?
    @Published var preparedResetScope: EditorAdjustmentScope?
    @Published var resetConfirmationPresented = false
    @Published var autoExposing = false

    // MARK: - Camera, photo/document/look import & look management modals
    @Published var showingCameraWorkspace = false
    @Published var cameraOriginalToOpen: URL?
    @Published var pendingPhotoImport = false
    @Published var pendingFileImport = false
    @Published var pendingSystemPhotoURLs: [[URL]] = []
    @Published var selectedPhotoItem: PhotosPickerItem?
    var photoImportTask: Task<Void, Never>?
    @Published var photoImportRequestID: UUID?
    @Published var showingPhotoImporter = false
    @Published var documentImportKind = EditorDocumentImportKind.photo
    @Published var showingDocumentImporter = false
    @Published var pendingLookCompatibility: EditorOpaquePresentation?
    var lookCompatibilityCompletion: Any?
    @Published var confirmedLookCompatibility: Any?
    @Published var pendingDCPImportOptions: EditorOpaquePresentation?
    var dcpImportOptionsCompletion: Any?
    @Published var confirmedDCPImportOptions: Any?
    @Published var renamingLook: EditorRenamingLook?
    @Published var renamedLUTName = ""
    @Published var showingLookRename = false
    @Published var showingUnreadableLooks = false

    // MARK: - Processing context, adjustment transfer, presets, batch & export modals
    @Published var showingProcessingContext = false
    @Published var confirmingProcessingRollback = false
    @Published var adjustmentSheet: IOSAdjustmentSheet?
    @Published var pendingAdjustmentAction: IOSAdjustmentAction?
    @Published var queuedPresetAction: IOSAdjustmentAction?
    @Published var applyingPreset: AdjustmentPreset?
    @Published var returnToPresetLibrary = false
    @Published var presetLibraryRevision = UUID()
    var checkedBatchRecovery = false
    @Published var showingBatchSelection = false
    @Published var queuedCollectionEdit: String?
    var collectionBatchHandoff = EditorCollectionBatchHandoff()
    @Published var queuedCollectionExistingBatch = false
    @Published var pendingCollectionNavigation: IOSCollectionNavigation?
    @Published var showingBatchExport = false
    @Published var batchExportHandle: (any EditorBatchExportHandle)?
    @Published var photoInfoMode = PhotoInfoMode.hidden
    @Published var photoInformation: PhotoInformation?
    @Published var showingExportSize = false
    @Published var showingPrivacy = false
    @Published var exportLongEdge: Int?
    @Published var singleExportFormat: BatchOutputFormat = .jpeg
    @Published var fileExportRequest: FileExportRequest?

    init(
        backend: (any EditorCoordinatorBackend)? = nil,
        draftStoreProvider: @escaping () throws -> any EditorToolDraftStoring = { try EditorToolDraftStore.appStore() },
        photoSourceLoader: @escaping (PhotosPickerItem) async throws -> PhotoImportSource = { try await PhotoImportFile.load(from: $0) },
        releaseImportedFile: @escaping (URL) -> Void = { PhotoImportFile.release($0) }
    ) {
        self.backend = backend
        self.draftStoreProvider = draftStoreProvider
        self.photoSourceLoader = photoSourceLoader
        self.releaseImportedFile = releaseImportedFile
    }

    func attachIfNeeded(backend: any EditorCoordinatorBackend) {
        if self.backend !== backend {
            self.backend = backend
        }
    }

    // MARK: - Derived state

    var showingBefore: Bool {
        get { photoViewing.holdingBefore }
        set {
            if newValue { photoViewing.beginHolding(isDraft: isEditorDraftActive) }
            else { photoViewing.endTemporaryViewing() }
        }
    }

    var editingLocked: Bool {
        isImporting || isSaving || (backend?.isBusy == true) || (batchExportHandle?.isRunning == true)
    }

    var editorBusy: Bool {
        (backend?.isBusy == true) || (backend?.isLoadingLUTs == true) || (backend?.isImportingLooks == true) || editingLocked
    }

    var workingSettings: RawSettings {
        get { editorDraftSnapshot.projecting(on: settings) }
        set {
            guard !editorBusy else { return }
            if var draft = workspaceDraft {
                draft.update(newValue, geometry: geometryDraftState, interactive: isAdjustingSlider)
                workspaceDraft = draft
            } else {
                settings = newValue
            }
        }
    }

    var geometryDraftState: EditorGeometryDraftState {
        EditorGeometryDraftState(
            preset: geometryAspectPreset.rawValue,
            lockedRatio: geometryLockedRatio,
            swapped: geometryAspectSwapped,
            grid: geometryGrid,
            includesLens: workspaceDraft?.step.geometry.includesLens ?? false
        )
    }

    var effectivePreviewSettings: RawSettings {
        editorDraftSnapshot.projecting(on: settings)
    }

    var editorDraftSnapshot: EditorDraftSnapshot {
        EditorDraftSnapshot(
            geometry: geometryDraft,
            lens: lensDraft,
            tool: collapsedEditorTool != nil ? .film : currentEditorTool,
            destination: pendingToolSelection,
            workspace: !toolWorkspaceOpen ? nil : workspaceDraft
        )
    }

    var draftPreviewSettings: RawSettings {
        previewSettings(for: editorDraftSnapshot)
    }

    func previewSettings(for draft: EditorDraftSnapshot) -> RawSettings {
        var result = draft.projecting(on: settings)
        if geometrySelected { result.setGeometrySettings(GeometrySettings()) }
        return result
    }

    var isEditorDraftActive: Bool {
        toolWorkspaceOpen && workspaceDraft != nil
    }

    var isEditorDraftChanged: Bool {
        editorDraftSnapshot.isChanged(from: settings)
    }

    var currentEditorTool: EditorToolSelection {
        if let collapsedEditorTool { return collapsedEditorTool }
        if geometrySelected { return .geometry }
        if lensSelected { return .lens }
        if choosingMasterRecipe { return .recipe }
        if let selectedHDRRenditionTool { return selectedHDRRenditionTool }
        return selectedAdjustment.map(EditorToolSelection.adjustment) ?? .film
    }

    var hslTargetActive: Bool {
        hslTargetEnabled && selectedAdjustment == .hsl && isEditorDraftActive &&
            currentEditorTool == .adjustment(.hsl) && !editorBusy &&
            adjustmentSheet == nil && !draftExitPresented && !resetConfirmationPresented
    }

    var canStartFileExport: Bool {
        !isSaving && !showingExportSize && fileExportRequest == nil
    }

    var resetSnapshot: PhotoEditState {
        let state = backend?.currentEditState(settings: settings)
            ?? PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 0))
        return state.replacing(settings: effectivePreviewSettings, preservingFilmID: state.filmID)
    }

    var resetContext: EditorAdjustmentContext {
        let wb = backend?.cameraWhiteBalance
        return EditorAdjustmentContext(
            isRaw: backend?.isRawSource == true,
            defaultExposureMode: RawSettings.default.exposureMode,
            cameraTemperature: wb?.isCalibrated == true ? wb?.temperature : nil,
            cameraTint: wb?.isCalibrated == true ? wb?.tint : nil
        )
    }

    func resetModified(_ scope: EditorAdjustmentScope) -> Bool {
        EditorAdjustmentRules.isModified(scope, snapshot: resetSnapshot, context: resetContext)
    }

    // MARK: - Draft & tool navigation transitions

    func syncGeometryDraft() {
        guard var draft = workspaceDraft, draft.tool == .geometry || draft.tool == .lens else { return }
        var value = draft.value
        if let geometryDraft { value.setGeometrySettings(geometryDraft) }
        if let lensDraft { value.lensCorrection = lensDraft.lensCorrection }
        draft.update(value, geometry: geometryDraftState, interactive: isAdjustingSlider)
        workspaceDraft = draft
    }

    func undoEditorDraft() {
        workspaceDraft?.undo()
        restoreDraftControls()
    }

    func redoEditorDraft() {
        workspaceDraft?.redo()
        restoreDraftControls()
    }

    func restoreDraftControls() {
        guard let draft = workspaceDraft else { return }
        if geometrySelected { geometryDraft = draft.value.geometrySettings }
        if lensSelected { lensDraft = draft.value }
        geometryAspectPreset = CropAspectPreset(rawValue: draft.step.geometry.preset) ?? .free
        geometryLockedRatio = draft.step.geometry.lockedRatio
        geometryAspectSwapped = draft.step.geometry.swapped
        geometryGrid = draft.step.geometry.grid
    }

    func preserveEditorDraft() {
        guard var draft = workspaceDraft, let identity = backend?.sourceIdentity else { return }
        syncGeometryDraft()
        draft = workspaceDraft ?? draft
        draft.finishInteraction()
        do {
            try draftStoreProvider().save(identity: identity, draft: draft)
        } catch {
            backend?.statusMessage = L10n.text("无法保存编辑草稿。")
        }
    }

    func restoreEditorDraft() {
        guard workspaceDraft == nil, let identity = backend?.sourceIdentity, !editorBusy else { return }
        do {
            guard let draft = try draftStoreProvider().load(identity: identity, committed: settings) else { return }
            activateEditorTool(draft.tool)
            workspaceDraft = draft
            restoreDraftControls()
            previewEditorDraft()
        } catch {
            backend?.statusMessage = L10n.text("无法恢复编辑草稿，已保留已应用的调整。")
        }
    }

    func clearRecoverableDraft() {
        guard let identity = backend?.sourceIdentity else { return }
        try? draftStoreProvider().clear(identity: identity)
    }

    func selectEditorTool(_ selection: EditorToolSelection) {
        guard !editorBusy else { return }
        closeQuickPresets()
        if selection == currentEditorTool && toolWorkspaceOpen {
            if !adjustmentsExpanded { requestAdjustmentExpansion(true) }
            return
        }
        if isEditorDraftChanged {
            pendingToolSelection = selection
            draftExitPresented = true
            return
        }
        activateEditorTool(selection)
    }

    func activateEditorTool(_ selection: EditorToolSelection, resettingFine: Bool = true, leavingWorkspace: Bool = false) {
        backend?.closeQuickPresets()
        cancelHSLTarget()
        cancelSliderInteraction()
        if resettingFine && selection != currentEditorTool { adjustmentFine = false }
        collapsedEditorTool = nil
        adjustmentsExpanded = true
        let leavingDraft = isEditorDraftActive || leavingWorkspace
        if leavingDraft {
            clearRecoverableDraft()
            backend?.discardDraftSaveFailure(settings: settings)
        }
        pendingToolSelection = nil
        draftExitPresented = false
        cancelRulerFocus()
        geometryDraft = nil
        lensDraft = nil
        geometrySelected = selection == .geometry
        lensSelected = selection == .lens
        choosingMasterRecipe = selection == .recipe
        selectedGroup = EditorAdjustmentRules.groupFor(selection)
        if case .adjustment(let adjustment) = selection {
            selectedAdjustment = adjustment
            selectedHDRRenditionTool = nil
        } else if selection.hdrRenditionKeyPath != nil {
            selectedAdjustment = nil
            selectedHDRRenditionTool = selection
        } else {
            selectedAdjustment = nil
            selectedHDRRenditionTool = nil
        }
        if geometrySelected {
            geometryAspectPreset = .free
            geometryLockedRatio = nil
            geometryAspectSwapped = false
            geometryDraft = settings.geometrySettings
        }
        if lensSelected { lensDraft = settings }
        workspaceDraftID = UUID()
        workspaceDraft = EditorToolDraft(tool: selection, original: settings)
        toolWorkspaceOpen = true
        backend?.hasAdjustmentDraft = editorDraftSnapshot.isActive
        if leavingDraft && !geometrySelected && !lensSelected {
            backend?.committedPreviewSettings = settings
            backend?.updateCoordinatorPreview(settings: settings, includeHistogram: true, quality: .final)
        } else if geometrySelected || lensSelected {
            previewEditorDraft()
        }
    }

    func applyEditorDraft() {
        guard commitEditorDraft() else { return }
        finishEditorTool()
    }

    func finishEditorTool() {
        cancelHSLTarget()
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        toolWorkspaceOpen = false
        pendingToolSelection = nil
        geometrySelected = false
        lensSelected = false
        choosingMasterRecipe = false
        geometryDraft = nil
        lensDraft = nil
        backend?.hasAdjustmentDraft = false
        backend?.committedPreviewSettings = settings
        backend?.updateCoordinatorPreview(settings: settings, includeHistogram: true, quality: .final)
    }

    func commitEditorDraft() -> Bool {
        guard let backend,
              !editorBusy,
              !backend.previewRendering,
              !backend.previewResizePending,
              !backend.previewFailed,
              !isAdjustingSlider else { return false }
        if !isEditorDraftChanged {
            discardEditorDraft()
            return true
        }
        let snapshot = editorDraftSnapshot
        guard let prepared = backend.prepareDraft(settings: settings, revision: settingsRevision, draft: snapshot),
              backend.saveDraft(prepared, settings: settings, revision: settingsRevision, draft: snapshot) else {
            return false
        }
        backend.committedPreviewSettings = prepared.candidate.settings
        settings = prepared.candidate.settings
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        geometryDraft = nil
        lensDraft = nil
        cancelRulerFocus()
        return true
    }

    func cancelEditorDraft() {
        discardEditorDraft()
        finishEditorTool()
    }

    func closeEditorDraftCleanly() -> Bool {
        cancelSliderInteraction()
        cancelHSLTarget()
        if isEditorDraftChanged && !commitEditorDraft() { return false }
        if isEditorDraftActive || toolWorkspaceOpen { finishEditorTool() }
        backend?.hasAdjustmentDraft = false
        return true
    }

    func discardEditorDraft() {
        cancelHSLTarget()
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        geometryDraft = nil
        lensDraft = nil
        backend?.discardDraftSaveFailure(settings: settings)
        cancelRulerFocus()
    }

    func finishDraftNavigation(apply: Bool, continueImport: (() -> Void)? = nil, continueCollection: (() -> Void)? = nil) {
        let leavingWorkspace = isEditorDraftActive
        if apply {
            guard commitEditorDraft() else { return }
        } else {
            discardEditorDraft()
        }
        toolWorkspaceOpen = false
        if pendingCollectionNavigation != nil {
            finishEditorTool()
            if let continueCollection {
                continueCollection()
            } else {
                continueCollectionNavigationWithoutFetch()
            }
            return
        }
        if pendingAdjustmentAction != nil {
            finishEditorTool()
            continueAdjustmentAction()
            return
        }
        if !pendingSystemPhotoURLs.isEmpty {
            finishEditorTool()
            return
        }
        if pendingFileImport || pendingPhotoImport {
            finishEditorTool()
            if let continueImport {
                continueImport()
            } else {
                continueEditorImport()
            }
            return
        }
        let selection = pendingToolSelection
        let expansion = pendingAdjustmentExpansion
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        if expansion == false {
            completeAdjustmentExpansion(false, closingWorkspace: leavingWorkspace)
            return
        }
        if let selection {
            activateEditorTool(selection, leavingWorkspace: leavingWorkspace)
        }
        if let expansion {
            completeAdjustmentExpansion(expansion)
        }
        if selection == nil && expansion == nil {
            finishEditorTool()
            collapsedEditorTool = nil
            adjustmentsExpanded = true
        }
    }

    func retryEditorSave(continueImport: (() -> Void)? = nil, continueCollection: (() -> Void)? = nil) {
        if isEditorDraftActive && backend?.hasFailedDraftSave == true {
            if pendingToolSelection != nil || pendingAdjustmentExpansion != nil || pendingFileImport ||
                pendingPhotoImport || !pendingSystemPhotoURLs.isEmpty || pendingAdjustmentAction != nil ||
                pendingCollectionNavigation != nil {
                finishDraftNavigation(apply: true, continueImport: continueImport, continueCollection: continueCollection)
            } else {
                applyEditorDraft()
            }
        } else if !pendingSystemPhotoURLs.isEmpty {
            continueImport?()
        } else if pendingFileImport || pendingPhotoImport {
            if let continueImport { continueImport() } else { continueEditorImport() }
        } else if pendingCollectionNavigation != nil {
            if let continueCollection { continueCollection() } else { continueCollectionNavigationWithoutFetch() }
        } else if pendingAdjustmentAction != nil {
            continueAdjustmentAction()
        } else {
            backend?.retrySave(settings: settings)
        }
    }

    func selectEditorGroup(_ group: EditorAdjustmentGroup) {
        guard !editorBusy else { return }
        closeQuickPresets()
        guard !isEditorDraftActive else { return }
        collapsedEditorTool = nil
        selectedGroup = group
        adjustmentsExpanded = true
    }

    func normalizeHDRNavigation(isHDREditing: Bool) {
        guard !isHDREditing else { return }
        if selectedGroup == .hdrRendition || selectedHDRRenditionTool != nil {
            selectedGroup = .light
            selectedHDRRenditionTool = nil
            selectedAdjustment = .exposure
        }
        if let collapsed = collapsedEditorTool, EditorAdjustmentRules.groupFor(collapsed) == .hdrRendition {
            collapsedEditorTool = nil
        }
    }

    func requestToolWorkspaceExit() {
        guard toolWorkspaceOpen, !editorBusy else { return }
        if !hslTargetEnabled { cancelSliderInteraction() }
        if isEditorDraftChanged {
            pendingToolSelection = nil
            pendingAdjustmentExpansion = nil
            draftExitPresented = true
        } else {
            finishEditorTool()
            collapsedEditorTool = nil
            adjustmentsExpanded = true
        }
    }

    func requestAdjustmentExpansion(_ expanded: Bool) {
        guard !editorBusy else { return }
        if !expanded && isEditorDraftChanged {
            pendingToolSelection = currentEditorTool
            pendingAdjustmentExpansion = false
            draftExitPresented = true
        } else {
            completeAdjustmentExpansion(expanded)
        }
    }

    func completeAdjustmentExpansion(_ expanded: Bool, closingWorkspace: Bool = false) {
        if !expanded && !hslTargetEnabled { cancelSliderInteraction() }
        if expanded {
            if let tool = collapsedEditorTool { activateEditorTool(tool) }
        } else if closingWorkspace || isEditorDraftActive || geometrySelected || lensSelected {
            let tool = currentEditorTool
            let group = selectedGroup
            finishEditorTool()
            collapsedEditorTool = tool
            selectedGroup = group
        }
        adjustmentsExpanded = expanded
    }

    func cancelDraftNavigation(onSystemPhotoSkipped: (@MainActor @Sendable () -> Void)? = nil) {
        let skippedSystemPhoto = !pendingSystemPhotoURLs.isEmpty
        if skippedSystemPhoto {
            let skipped = pendingSystemPhotoURLs.removeFirst()
            for url in skipped { releaseImportedFile(url) }
        }
        pendingCollectionNavigation = nil
        pendingAdjustmentAction = nil
        pendingFileImport = false
        pendingPhotoImport = false
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        if skippedSystemPhoto, let onSystemPhotoSkipped {
            DispatchQueue.main.async(execute: onSystemPhotoSkipped)
        }
    }

    func resetForNewSource() {
        workspaceDraft = nil
        toolWorkspaceOpen = false
        workspaceDraftID = UUID()
        geometrySelected = false
        lensSelected = false
        cancelHSLTarget()
        gradingZone = .shadows
        photoViewing.sourceChanged()
        photoViewport = PhotoViewport()
        pendingFileImport = false
        pendingPhotoImport = false
        pendingAdjustmentAction = nil
        queuedPresetAction = nil
        applyingPreset = nil
        returnToPresetLibrary = false
        if adjustmentSheet == .presetSave || adjustmentSheet == .presetApply { adjustmentSheet = nil }
        adjustmentFine = false
        geometryDraft = nil
        lensDraft = nil
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        preparedReset = nil
        preparedResetScope = nil
        resetConfirmationPresented = false
        draftExitPresented = false
        cancelRulerFocus()
        let clearedTool = EditorToolSourceState(
            collapsedEditorTool: collapsedEditorTool,
            choosingMasterRecipe: choosingMasterRecipe
        ).afterSourceChange
        collapsedEditorTool = clearedTool.collapsedEditorTool
        choosingMasterRecipe = clearedTool.choosingMasterRecipe
    }

    // MARK: - Reset workflow

    func prepareEditorReset(_ scope: EditorAdjustmentScope) -> EditorResetPreparation {
        guard let backend else { return .blocked(.sourceNotReady) }
        return backend.prepareReset(scope, settings: settings, revision: settingsRevision, draft: editorDraftSnapshot)
    }

    @discardableResult
    func commitEditorReset(_ prepared: PreparedEditorReset) -> Bool {
        guard let backend, !editorBusy,
              let candidate = backend.commitReset(prepared, settings: settings, revision: settingsRevision,
                                                  draft: editorDraftSnapshot) else {
            return false
        }
        if prepared.updatesDraft {
            if currentEditorTool == .geometry || currentEditorTool == .lens {
                var geometry = geometryDraftState
                if preparedResetScope == .group(.geometry) { geometry.includesLens = true }
                workspaceDraft?.update(candidate.settings, geometry: geometry)
                if geometrySelected { geometryDraft = candidate.settings.geometrySettings }
                if lensSelected { lensDraft = candidate.settings }
            } else {
                workspaceDraft?.update(candidate.settings)
            }
        } else {
            let parametersChanged = settings != candidate.settings
            workingSettings = candidate.settings
            if !parametersChanged {
                settingsRevision = UUID()
                queueEditorSettingsChange(candidate.settings)
            }
        }
        return true
    }

    func requestEditorReset(_ scope: EditorAdjustmentScope) {
        guard !editorBusy else { return }
        presentEditorReset(scope)
    }

    func presentEditorReset(_ scope: EditorAdjustmentScope) {
        switch prepareEditorReset(scope) {
        case .unchanged:
            break
        case .blocked(let reason):
            backend?.statusMessage = reason.message
        case .prepared(let candidate):
            preparedResetScope = scope
            preparedReset = candidate
            if candidate.requiresConfirmation {
                resetConfirmationPresented = true
            } else {
                confirmEditorReset()
            }
        }
    }

    func confirmEditorReset() {
        guard let candidate = preparedReset else { return }
        if !commitEditorReset(candidate) {
            backend?.statusMessage = L10n.text("照片或调整已变化，请重新确认重置。")
        }
        preparedReset = nil
        preparedResetScope = nil
    }

    func cancelEditorReset() {
        preparedReset = nil
        preparedResetScope = nil
    }

    // MARK: - Settings, previews & slider interaction

    func handleSettingsChange(_ newValue: RawSettings) {
        normalizeHDRNavigation(isHDREditing: newValue.isHDREditing)
        settingsRevision = UUID()
        backend?.committedPreviewSettings = newValue
        if backend?.consumeRestoredSettings(newValue) == true { return }
        if backend?.consumePersistedEditorSettings(newValue) == true { return }
        queueEditorSettingsChange(newValue)
    }

    func handleDraftSnapshotChange(old: EditorDraftSnapshot, draft: EditorDraftSnapshot) {
        backend?.hasAdjustmentDraft = draft.isActive
        if draft.isActive, previewSettings(for: old) != previewSettings(for: draft) {
            previewEditorDraft()
        }
    }

    func queueEditorSettingsChange(_ newSettings: RawSettings) {
        showingBefore = false
        backend?.queueSettingsSave(newSettings)
        if isAdjustingSlider {
            backend?.scheduleCoordinatorPreviewUpdate(settings: draftPreviewSettings, delay: 0.08,
                                                      includeHistogram: false, quality: .interactive)
        } else {
            _ = backend?.saveCurrentSettings(newSettings)
            backend?.updateCoordinatorPreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
        }
    }

    func previewEditorDraft() {
        guard let backend, !editorBusy, backend.hasImage else { return }
        showingBefore = false
        backend.committedPreviewSettings = draftPreviewSettings
        if isAdjustingSlider {
            backend.scheduleCoordinatorPreviewUpdate(settings: draftPreviewSettings, delay: 0.08,
                                                     includeHistogram: false, quality: .interactive)
        } else {
            backend.updateCoordinatorPreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
        }
    }

    func setSliderEditing(_ editing: Bool, reduceMotion: Bool = false) {
        guard !editorBusy else {
            isAdjustingSlider = false
            cancelRulerFocus()
            return
        }
        let wasEditing = isAdjustingSlider
        if !isEditorDraftActive {
            if editing && !wasEditing {
                guard backend?.beginAdjustmentInteraction(settings: settings) == true else { return }
            } else if !editing && (wasEditing || backend?.adjustmentInteractionRejected == true) {
                _ = backend?.endAdjustmentInteraction(settings: settings)
            }
        }
        isAdjustingSlider = editing
        updateRulerFocus(editing: editing, wasEditing: wasEditing, reduceMotion: reduceMotion)
        if !editing {
            workspaceDraft?.finishInteraction()
            if !geometrySelected {
                backend?.updateCoordinatorPreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
            }
        }
    }

    func cancelSliderInteraction() {
        hslTargetInteraction.cancel()
        hslTargetHistoryActive = false
        hslTargetPoint = nil
        hslTargetNotice = nil
        if let original = backend?.cancelAdjustmentInteraction() {
            settings = original
            backend?.updateCoordinatorPreview(settings: original, includeHistogram: true, quality: .final)
        }
        isAdjustingSlider = false
        cancelRulerFocus()
    }

    func cancelHSLTarget() {
        guard hslTargetPoint != nil || hslTargetNotice != nil || hslTargetInteraction.isWaiting ||
              hslTargetInteraction.isDragging || hslTargetInteraction.selection != nil ||
              hslTargetHistoryActive else { return }
        hslTargetInteraction.cancel()
        hslTargetPoint = nil
        hslTargetNotice = nil
        if hslTargetHistoryActive {
            hslTargetHistoryActive = false
            cancelSliderInteraction()
        }
    }

    func updateRulerFocus(editing: Bool, wasEditing: Bool, reduceMotion: Bool = false) {
        rulerFocusTask?.cancel()
        if editing {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { rulerFocusPhase = .dragging }
            return
        }
        guard wasEditing, !reduceMotion else {
            rulerFocusPhase = .idle
            return
        }
        rulerFocusPhase = .holding
        rulerFocusTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            withAnimation(.easeOut(duration: 0.18)) { rulerFocusPhase = .restoring }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            rulerFocusPhase = .idle
        }
    }

    func cancelRulerFocus() {
        rulerFocusTask?.cancel()
        rulerFocusTask = nil
        rulerFocusPhase = .idle
        isAdjustingSlider = false
    }

    // MARK: - Adjustment transfer, quick presets & history modals

    func showQuickPresets() {
        guard !editorBusy, backend?.hasImage == true else { return }
        guard closeEditorDraftCleanly() else { return }
        collapsedEditorTool = nil
        backend?.quickPresetsVisible = true
        selectedGroup = .looks
        adjustmentsExpanded = true
    }

    func closeQuickPresets() {
        backend?.closeQuickPresets()
        selectedGroup = EditorAdjustmentRules.groupFor(currentEditorTool)
    }

    func queuePresetAction(_ action: IOSAdjustmentAction) {
        queuedPresetAction = action
        adjustmentSheet = nil
    }

    func finishAdjustmentSheet() {
        presetLibraryRevision = UUID()
        if let action = queuedPresetAction {
            queuedPresetAction = nil
            requestAdjustmentAction(action)
        } else if returnToPresetLibrary {
            returnToPresetLibrary = false
            applyingPreset = nil
            adjustmentSheet = .presets
        } else {
            applyingPreset = nil
        }
    }

    func requestAdjustmentAction(_ action: IOSAdjustmentAction) {
        guard !editorBusy, backend?.hasImage == true else { return }
        if backend?.quickPresetStateIsPreparing == true { return }
        cancelHSLTarget()
        cancelSliderInteraction()
        pendingAdjustmentAction = action
        if isEditorDraftChanged {
            draftExitPresented = true
            return
        }
        if isEditorDraftActive { finishEditorTool() }
        continueAdjustmentAction()
    }

    func continueAdjustmentAction() {
        guard let backend,
              let action = pendingAdjustmentAction,
              backend.saveCurrentSettings(settings) else { return }
        pendingAdjustmentAction = nil
        backend.hasAdjustmentDraft = false
        switch action {
        case .copy:
            adjustmentSheet = .copy
        case .paste:
            adjustmentSheet = .paste
        case .presetSave:
            adjustmentSheet = .presetSave
        case .presetApply(let preset):
            showQuickPresets()
            backend.applyPresetToCurrentPhoto(preset, settings: settings)
        case .presetApplyMultiple(let preset):
            applyingPreset = preset
            returnToPresetLibrary = true
            adjustmentSheet = .presetApply
        case .history:
            backend.clearAdjustmentHistoryRequest()
            adjustmentSheet = .history
        case .undo, .redo:
            let results = backend.performAdjustmentHistoryStep(undo: action == .undo)
            if results.contains(where: { [.failed, .blocked, .conflict].contains($0.status) }) {
                adjustmentSheet = .history
            }
        }
    }

    // MARK: - Collection / batch / export / recent / import modal navigation

    func openBatchSelection() {
        guard closeEditorDraftCleanly() else { return }
        backend?.appendCurrentBatchSelectionPhoto()
        showingBatchSelection = true
    }

    func requestCollectionNavigation(_ action: IOSCollectionNavigation, onEdit: ((String) -> Void)? = nil) {
        guard !editorBusy else { return }
        cancelSliderInteraction()
        pendingCollectionNavigation = action
        if isEditorDraftChanged {
            draftExitPresented = true
            return
        }
        if isEditorDraftActive || toolWorkspaceOpen { finishEditorTool() }
        continueCollectionNavigation(onEdit: onEdit)
    }

    func continueCollectionNavigation(onEdit: ((String) -> Void)? = nil) {
        guard let action = pendingCollectionNavigation,
              backend?.saveCurrentSettings(settings) == true else { return }
        pendingCollectionNavigation = nil
        switch action {
        case .returnToCollection:
            backend?.returnBatchSelectionToCollection()
            showingBatchSelection = true
        case .edit(let id):
            onEdit?(id)
        }
    }

    private func continueCollectionNavigationWithoutFetch() {
        continueCollectionNavigation(onEdit: nil)
    }

    func resolveCollectionDraft(_ key: String, apply: Bool) -> Bool {
        guard let backend, backend.sourceIdentity?.key == key, !editorBusy else { return false }
        if apply {
            if backend.hasActiveAdjustmentInteraction {
                guard backend.endAdjustmentInteraction(settings: settings) else { return false }
                isAdjustingSlider = false
            }
            if isEditorDraftChanged && !commitEditorDraft() { return false }
            if isEditorDraftActive || toolWorkspaceOpen { finishEditorTool() }
            backend.hasAdjustmentDraft = false
            return backend.saveCurrentSettings(settings)
        }
        cancelSliderInteraction()
        discardEditorDraft()
        finishEditorTool()
        do {
            let restored = try backend.restoreCommittedSettings()
            settings = restored
            backend.updateCoordinatorPreview(settings: restored, includeHistogram: true, quality: .final)
            return true
        } catch {
            return false
        }
    }

    func showRecentPhotos() {
        guard !editorBusy, !isEditorDraftActive, backend?.saveCurrentSettings(settings) == true else { return }
        showingBefore = false
        showingRecentPhotos = true
    }

    func finishRecentPhotos(onOpenRecent: (RecentPhoto) -> Void) {
        if recentImportRequested {
            recentImportRequested = false
            requestEditorImport(file: false)
        } else if let photo = recentPhotoToOpen {
            recentPhotoToOpen = nil
            onOpenRecent(photo)
        }
    }

    func requestSingleExport(_ format: BatchOutputFormat) {
        guard closeEditorDraftCleanly() else { return }
        singleExportFormat = format
        exportLongEdge = nil
        showingExportSize = true
    }

    func requestEditorImport(file: Bool, recent: RecentPhoto? = nil) {
        guard !editorBusy else { return }
        recentReselection = recent
        photoViewing.endTemporaryViewing()
        pendingFileImport = file
        pendingPhotoImport = !file
        if isEditorDraftChanged {
            draftExitPresented = true
            return
        }
        if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
        continueEditorImport()
    }

    func continueEditorImport() {
        guard pendingFileImport || pendingPhotoImport else { return }
        guard backend?.saveCurrentSettings(settings) == true else { return }
        if pendingFileImport { documentImportKind = .photo }
        showingDocumentImporter = pendingFileImport
        showingPhotoImporter = pendingPhotoImport
        pendingFileImport = false
        pendingPhotoImport = false
    }

    func requestLookImport() {
        guard !editorBusy, !isEditorDraftActive || currentEditorTool == .film else { return }
        documentImportKind = .looks
        showingDocumentImporter = true
    }

    func loadPhotoSource(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        try await PhotoImportFile.loadSource { try await photoSourceLoader(item) }
    }

    func cancelPhotoImport() {
        finishLegacyAssetEditDecision(nil)
        recentReselection = nil
        photoImportRequestID = nil
        photoImportTask?.cancel()
        photoImportTask = nil
        selectedPhotoItem = nil
        backend?.cancelActiveImageImport()
        isImporting = false
    }

    func finishLegacyAssetEditDecision(_ restore: Bool?) {
        let decision = legacyAssetEditDecision
        legacyAssetEditDecision = nil
        showingLegacyAssetEdit = false
        decision?.resume(returning: restore)
    }

    func beginLookRename(id: String, name: String) {
        renamingLook = EditorRenamingLook(id: id, name: name)
        renamedLUTName = name
        showingLookRename = true
    }

    func cancelLookRename() {
        renamingLook = nil
        showingLookRename = false
    }

    func completeLookRename() {
        if let look = renamingLook {
            backend?.renameLook(id: look.id, name: renamedLUTName)
        }
        renamingLook = nil
        showingLookRename = false
    }

    func presentCameraWorkspace() {
        photoViewing.endTemporaryViewing()
        preserveEditorDraft()
        showingCameraWorkspace = true
    }

    func presentProcessingContext() {
        showingProcessingContext = true
    }

    func dismissProcessingContext() {
        showingProcessingContext = false
    }

    func presentPrivacy() {
        showingPrivacy = true
    }

    func presentUnreadableLooks() {
        showingUnreadableLooks = true
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .background || phase == .inactive {
            preserveEditorDraft()
            cancelSliderInteraction()
            _ = backend?.saveCurrentSettings(settings)
        }
        if phase == .background {
            batchExportHandle?.cancel(forBackground: true)
            backend?.cancelHDRExport()
        }
        if phase != .active {
            collectionBatchHandoff.cancelAutomaticStart()
            backend?.cancelCollectionExportPreparation()
            backend?.cancelQuickPreset()
            cancelRulerFocus()
            photoViewing.endTemporaryViewing()
        }
    }
}
