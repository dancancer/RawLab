import RawLabKit
import RawLabNative
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    enum AIDenoiseState: Equatable {
        case idle, running(Int, UInt64, UInt64), ready, cancelled, failed(String)
        var isRunning: Bool { if case .running = self { return true }; return false }
        var progressTitle: String {
            guard case .running(let phase, _, _) = self else { return "" }
            switch phase {
            case 2: return L10n.text("正在处理 RAW 噪声")
            case 3: return L10n.text("正在处理颜色噪声")
            case 4: return L10n.text("正在保存 AI 结果")
            default: return L10n.text("正在准备 AI 降噪")
            }
        }
    }
    struct AIWorkIdentity: Equatable {
        let source: RawWhiteBalanceCacheKey
        let isHDR: Bool
        let processing: ProcessingIdentity
        let x3fMode: X3fMode
        let whiteBalance: [Float]
        let lens: LensCorrectionSettings
        init(_ file: URL, settings: Adjustments) throws {
            source = try RawWhiteBalanceCacheKey(file)
            isHDR = settings.isHDREditing
            processing = settings.processing
            x3fMode = settings.x3fMode
            whiteBalance = settings.aiWhiteBalanceSignature
            lens = settings.lensSettings
        }
    }
    enum ResetBlockedReason: Equatable {
        case sourceUnavailable
        case geometryDraftActive
        case geometryDraftRequired
        case invalidDraftInputs
        case adjustment(EditorResetBlockedReason)
    }

    enum ResetPreparation: Equatable {
        case unchanged
        case prepared(PreparedReset)
        case blocked(ResetBlockedReason)
    }

    struct PreparedReset: Equatable {
        let scope: EditorResetScope
        let source: URL
        let identity: OriginalFileIdentity
        let revision: UUID
        let original: MacPhotoEditState
        let candidate: MacPhotoEditState
        let selectedFilmID: String
        let draft: MacGeometryDraft?
    }

    struct RenderWork: Equatable {
        let file: URL
        let settings: Adjustments
        let source: MacReferenceSource
        let lut: URL?
        let edge: Int?
        let pass: RenderPass
        let draftEpoch: UUID
        let editingGeometry: Bool
        let previewScope: MacExactPreviewCache.Scope?
    }

    @Published var adjustmentNavigation = EditorAdjustmentNavigation() { didSet {
        if quickPresetsVisible && (adjustmentNavigation.expandedGroup != .looks || oldValue.tool != adjustmentNavigation.tool) { closeQuickPresets() }
    } }
    @Published var resetConfirmation: PreparedReset?
    @Published var resetConfirmationScope: EditorResetScope?
    @Published var resetBlockedMessage: String?
    var resetReturnTool: EditorAdjustmentTool?
    var resetReturnGeometryTab: MacGeometryTab?
    var resetSource: URL?

    @Published var settings = Adjustments() { didSet {
        if !updatingMetadata && oldValue != settings {
            edited()
            if sharpenMaskPreviewActive && (oldValue.sharpenV2Settings.radius != settings.sharpenV2Settings.radius ||
                oldValue.sharpenV2Settings.masking != settings.sharpenV2Settings.masking) {
                refreshSharpenMaskPreviewIfNeeded()
            }
        }
    } }
    func selectX3fMode(_ mode: X3fMode) {
        guard RenderEngine.isX3fInput(file), settings.x3fMode != mode else { return }
        var next = settings
        // 一次提交显影身份和兼容设置，保存与预览始终使用同一候选状态。
        next.selectX3fMode(mode)
        settings = next
    }
    var canUseLensPanel: Bool {
        file != nil && !(RenderEngine.isX3fInput(file) && settings.x3fMode == .normal)
    }
    var canUseLensCorrection: Bool {
        file != nil && !RenderEngine.isRasterInput(file) &&
            !(RenderEngine.isX3fInput(file) && settings.x3fMode == .normal)
    }
    @Published var geometryDraft: MacGeometryDraft?
    @Published var geometryDraftPreviewReady = false
    @Published var geometryDraftTab = MacGeometryTab.crop
    @Published var cropAspectPreset = CropAspectPreset.free
    @Published var cropAspectSwapped = false
    @Published var cropLockedRatio: Double?
    @Published var cropGridEnabled = true
    @Published var geometryDraftDeparturePending = false
    @Published var invalidGeometryDraftInputs = Set<String>()
    @Published var geometryCropInteracting = false
    @Published var geometryDraftRevision = 0
    @Published var pendingGeometryPresentation: GeometrySettings?
    var geometryDraftEntryResult: RenderedImage?
    var geometryDraftEntryNeutral: RenderedImage?
    var geometryDraftEpoch = UUID()
    var geometryDepartureAction: (() -> Void)?
    var geometryDepartureStay: (() -> Void)?
    var geometryDraftEntrySaveError: String?
    var geometryDraftSaveFailed = false
    var geometryDraftSettings: GeometrySettings { geometryDraft?.geometry ?? settings.geometrySettings }
    var lensDraftSettings: LensCorrectionSettings { geometryDraft?.lens ?? settings.lensSettings }
    var geometryDraftHasChanges: Bool { geometryDraft?.hasChanges == true || !invalidGeometryDraftInputs.isEmpty }
    var geometryCropInputEnabled: Bool { geometryDraft != nil && geometryDraftTab == .crop }
    var geometryDraftCanApply: Bool {
        geometryDraft?.hasChanges == true && geometryDraftSettings.isValid && invalidGeometryDraftInputs.isEmpty &&
            geometryDraftPreviewReady && !busy && !previewOutdated && !geometryCropInteracting && !exporting
    }
    var lensDraftPreviewIsCurrent: Bool { geometryDraftPreviewReady && !busy }
    var canComparePreview: Bool { geometryDraft == nil && pendingGeometryPresentation == nil }
    var geometryCanvasSize: CGSize {
        guard let result else { return CGSize(width: 1, height: 1) }
        let source = CGSize(width: CGFloat(result.nativeWidth ?? result.image.width),
                            height: CGFloat(result.nativeHeight ?? result.image.height))
        guard let draft = geometryDraft else { return source }
        return MacStraightenPreview(source: source, degrees: draft.geometry.straightenDegrees).safeCanvas
    }
    var cropAspectRatio: Double? {
        if let cropLockedRatio { return cropAspectSwapped ? 1 / cropLockedRatio : cropLockedRatio }
        return cropAspectPreset.ratio(for: geometryCanvasSize, swapped: cropAspectSwapped)
    }
    var geometryPreviewSettings: Adjustments {
        guard let draft = geometryDraft else { return settings }
        var preview = settings
        preview.setGeometrySettings(draft.previewGeometry)
        preview.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        return preview
    }
    var updatingMetadata = false
    @Published var films = Film.bundled()
    @Published var lookBrowser = LookBrowserState()
    @Published var recentLooks = RecentLooks()
    let recentLooksURL: URL
    @Published var selectedFilmID = "" {
        didSet {
            if selectedFilmID.hasPrefix("recipe-lut:") { independentRecipeLookIDs.insert(selectedFilmID) }
            if !updatingMetadata && (oldValue != selectedFilmID || settings.masterRecipeID != nil) {
                if settings.masterRecipeID != nil {
                    guard settings.clearMasterRecipe(isRaw: adjustmentContext.isRaw) else {
                        updatingMetadata = true; selectedFilmID = oldValue; updatingMetadata = false
                        resetBlockedMessage = L10n.text("现有参数范围无法保留配方的全部效果。你可以取消，或另行确认重置全部调整。")
                        return
                    }
                }
                edited()
            }
        }
    }
    @Published var fullResolution = false {
        didSet {
            if fullResolution { cancelViewportResize() }
            schedule()
        }
    }
    var previewLongEdge = 2000
    var renderPreviewLongEdge = 2000
    @Published var hslTargetEnabled = false { didSet {
        if hslTargetEnabled { inspection.pinModeEnabled = false }
    } }
    @Published var hslTargetAxis: HSLAxis = .hue
    @Published var hslTargetInteraction = HSLTargetInteraction()
    @Published var hslTargetPoint: CGPoint?
    @Published var hslTargetNotice: HSLTargetAvailability?
    @Published var inspection = InspectionSessionState() { didSet {
        if !oldValue.pinModeEnabled && inspection.pinModeEnabled {
            cancelHSLTarget(); hslTargetEnabled = false
            cancelCurveTarget(); curveTargetEnabled = false
            cancelWBProbe(); wbEyedropperEnabled = false
            cancelPointColorEyedropper()
        }
    } }
    var sourceNativeSize: CGSize?
    enum WBProbeNotice: Equatable { case overexposed, outside, stale, unavailable, failed }
    @Published var wbEyedropperEnabled = false { didSet {
        if wbEyedropperEnabled { inspection.pinModeEnabled = false }
    } }
    @Published var wbProbeSampling = false
    @Published var wbProbeNotice: WBProbeNotice?
    @Published var pointColorEyedropperEnabled = false { didSet {
        if pointColorEyedropperEnabled { inspection.pinModeEnabled = false }
    } }
    @Published var selectedPointColorSwatchIndex = 0
    @Published var selectedSelectiveColorBandIndex = 0
    var hslTargetHistoryActive = false
    var hslPendingKeyDelta: Double = 0
    @Published var curveTargetEnabled = false { didSet {
        if curveTargetEnabled { inspection.pinModeEnabled = false }
    } }
    @Published var curveTargetChannel: ToneCurveChannel = .rgb
    @Published var curveTargetInteraction = CurveTargetInteraction()
    @Published var curveTargetPoint: CGPoint?
    @Published var curveTargetNotice: HSLTargetAvailability?
    var curveTargetHistoryActive = false
    var curvePendingKeyDelta: Double = 0
    var hslAcceptedRequest: RenderRequest<RenderWork>?
    var hslAcceptedSettings: Adjustments?
    var hslSourceRevision: UInt64 = 1
    @Published var sourceRevision = UUID() { didSet {
        cancelProcessingMigration()
        processingMigrationReceipt = nil
        pendingAllResetRevision = nil
        pendingMigrationClearToken = nil
        pendingExternalReload = nil
        deferredExternalEditsCheck = false
        deferredExternalReloadAccept = false
        dismissedExternalReloadFingerprints.removeAll()
        hslSourceRevision &+= 1; hslAcceptedRequest = nil; hslAcceptedSettings = nil
        inspection.resetForNewSource()
        InspectionSamplerCache.shared.clear()
        InspectionOverlayRenderer.shared.clear()
        sourceNativeSize = nil
        wbEyedropperEnabled = false; wbProbeSampling = false; wbProbeNotice = nil
        pointColorEyedropperEnabled = false; selectedPointColorSwatchIndex = 0
        closeQuickPresets()
        cancelCollectionExportPreparation()
        clearSharpenMaskPreviewCache()
    } }
    @Published var file: URL?
    @Published var sourceIsHDR=false
    @Published var rawHDRSource: HDRSourceInfo?
    var sourceSupportsCameraHDR: Bool { rawHDRSource != nil }
    var sourceIsBayerHDR: Bool { rawHDRSource?.isCameraRAW == true }
    @Published var importing=false
    var pendingOpenID=UUID()
    @Published var neutral: RenderedImage?
    @Published var result: RenderedImage? { didSet {
        if sharpenMaskPreviewActive { refreshSharpenMaskPreviewIfNeeded() }
    } }
    @Published var busy = false { didSet { if oldValue && !busy { resumeResetToolIfReady() } } }
    @Published var autoExposing = false
    var editRevision = UUID() { didSet {
        cancelProcessingMigration()
        exactPreviewCache.useScope(nil)
        if quickPresetState.isPreparing { cancelQuickPreset() }
        if collectionExportPreparing { cancelCollectionExportPreparation() }
    } }
    @Published var exporting = false
    @Published var previewThumbnailAIRunning = false
    @Published var aiState = AIDenoiseState.idle
    @Published var aiModelPackageState: AIModelPackageState = .unavailable
    let aiModelManager: AIModelPackageManager
    private var aiModelStateCancellable: AnyCancellable?
    private var batchStateCancellable: AnyCancellable?
    var aiIdentity: AIWorkIdentity?
    var aiGeneration = UUID()
    var aiPreparation: AIPreparation?
    var aiDebounce: DispatchWorkItem?
    var aiManuallyRequested = false
    var aiRequiresExplicitRetry = false
    // 全窗口串行化，避免多个整图推理同时争用内存。
    static let aiQueue = DispatchQueue(label: "rawlab.ai.prepare", qos: .utility)
    static let sharedAIModelManager = AIModelPackageManager(
        store: RenderEngine.aiModelStore,
        isRuntimeSupported: { RenderEngine.aiModelDownloadSupported },
        overrideProvider: { RenderEngine.resolvedAIModelOverride },
        bundledProvider: { RenderEngine.bundledAIModel }
    )
    var prepareAIOperation: (URL, Adjustments, AIPreparation) throws -> Void = {
        try RenderEngine().prepareAI($0, settings: $1, progress: $2)
    }
    var aiModelDownloadVisible: Bool {
        aiModelPackageState != .unavailable
    }
    var hasAIModel: Bool {
        aiModelPackageState.isInstalled || RenderEngine.resolvedAIModelDirectory != nil
    }
    var aiControlsVisible: Bool {
        if settings.isHDREditing {
            return settings.hdrCameraAIEnabled || (RenderEngine.hdrCameraAIAvailable && (hasAIModel || aiModelDownloadVisible) &&
                RenderEngine.isHDRCameraAICandidate(info: rawHDRSource, settings: settings))
        }
        return RenderEngine.aiAvailable || settings.aiDenoiseEnabled
    }
    var canStartAI: Bool {
        if settings.isHDREditing {
            return RenderEngine.hdrCameraAIAvailable && hasAIModel &&
                RenderEngine.isHDRCameraAICandidate(info: rawHDRSource, settings: settings) &&
                !exporting && geometryDraft == nil && !aiModelPackageState.isBusy
        }
        return file != nil && !RenderEngine.isRasterInput(file) && RenderEngine.aiAvailable &&
            !(RenderEngine.isX3fInput(file) && settings.x3fMode == .normal) &&
            hasAIModel && !exporting && geometryDraft == nil && !aiModelPackageState.isBusy
    }
    @Published var unreadableLooks: [LookLibrary.UnreadableLook] = []
    @Published var lookLibraryBusy = false
    @Published var previewOutdated = false
    @Published var error: String?
    @Published var lookImportReport: String?
    enum Status {
        case none, applied(Int), interactive(Int, Int), preview(Int, Int, original: Bool), exported(String)
    }
    @Published var statusState = Status.none
    var status: String {
        switch statusState {
        case .none: return ""
        case .applied(let count): return L10n.format("已将当前设置应用到 %@ 张照片", String(count))
        case .interactive(let width, let height):
            return settings.isHDREditing ? L10n.format("交互预览… %@ × %@ · HDR",String(width),String(height)) :
                L10n.format("交互预览… %@ × %@ · sRGB", String(width), String(height))
        case .preview(let width, let height, let original):
            return "\(original ? L10n.text("原尺寸") : L10n.text("预览")) \(width) × \(height) · \(settings.isHDREditing ? "HDR" : "sRGB")"
        case .exported(let name): return L10n.format("已导出：%@", name)
        }
    }
    @Published var saveStatusKey = ""
    // Q3/Q4：粘贴面板内嵌的一次性提示（按实际应用结果过滤），不随状态条 3 秒超时消失。
    @Published var adjustmentPasteNotices: [AdjustmentTransferNotice] = []
    var pendingSDRFallbackNotice = false
    var sourceUsesSDRFallback = false
    var probeHDRSource: HDRSourceInfo.Probe = { try HDRSourceInfo.probe($0, onSDRFallback: $1) }
    var saveStatus: String { L10n.text(saveStatusKey) }
    @Published var saveError: String?
    @Published var batch: BatchExportModel? {
        didSet {
            batchStateCancellable?.cancel()
            batchStateCancellable = batch.map { model in
                model.$running
                    .combineLatest(model.$previewing, model.$validating)
                    .dropFirst()
                    .sink { [weak self] _, _, _ in self?.objectWillChange.send() }
            }
        }
    }
    @Published var batchSelection = BatchSelectionSession<String>()
    @Published var batchSelectionPhotos: [String: MacCollectionPhoto] = [:]
    @Published var collectionExportPreparing = false
    @Published var collectionExportReview: MacCollectionExportReview?
    @Published var collectionExportError: String?
    var collectionExportGeneration = UUID()
    let collectionExportQueue = DispatchQueue(label: "rawlab.collection.prepare", qos: .userInitiated)
    var prepareCollectionExportOperation: (MacCollectionExportPreparation) throws -> MacCollectionExportReview = { try $0.prepare() }
    @Published var collectionError: String?
    @Published var exportLongEdge: Int?
    @Published var exportOutputSharpening: OutputSharpening = .off
    let queue = DispatchQueue(label: "rawlab.render", qos: .userInitiated)
    let debounceQueue = DispatchQueue(label: "rawlab.render.debounce", qos: .userInitiated)
    var scheduler = RenderScheduler<RenderWork>()
    var debounceTimer: DispatchSourceTimer?
    var viewportResizeWork: DispatchWorkItem?
    var workerActive = false
    var engine: RenderEngine?
    // 与请求调度器一样，仅主线程访问。
    var exactPreviewCache = MacExactPreviewCache()
    // 仅渲染队列读写；主线程使用已发布的来源身份。
    var acceptedOriginalSource: MacReferenceSource?
    var originalCache: (key: MacNeutralReferenceKey, frame: RenderedImage)?
    var geometryReferenceCache: (key: MacNeutralReferenceKey, frame: RenderedImage)?
    var editStore: MacEditPersistence? {
        didSet {
            if editStore !== oldValue {
                adjustmentSession = editStore.map(AdjustmentTransferSession.init)
                committedEdit = nil
                unsettledAsyncCommitTokens.removeAll()
                pendingExternalReload = nil
                deferredExternalEditsCheck = false
                deferredExternalReloadAccept = false
            }
        }
    }
    var adjustmentSession: AdjustmentTransferSession?
    var committedEdit: MacPhotoEditRecord?
    var unsettledAsyncCommitTokens: [UUID] = []
    var hasPendingEditCommits: Bool {
        editStore?.hasPendingCommits == true || adjustmentSession?.hasPendingCommits == true
    }
    private(set) var lookInvalidationDiagnostics: [String] = []
    func recordLookInvalidationDiagnostics(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        lookInvalidationDiagnostics = messages
    }
    @Published var processingMigrationReceipt: ProcessingMigrationReceipt<MacPhotoEditState>?
    @Published var matchingProcessing = false
    var processingMigrationCancellation: ProcessingMigrationCancellation?
    var processingMigrationAttemptSource: UUID?
    var pendingAllResetRevision: UUID?
    var pendingMigrationClearToken: UUID?
    static let processingMigrationQueue = DispatchQueue(label: "rawlab.processing-migration", qos: .utility)
    var interactionEntry: MacPhotoEditState?
    var interactionWasDirty = false
    @Published var completedEditPreview: (record: MacPhotoEditRecord, image: CGImage)?
    @Published var adjustmentHistoryRevision = 0
    @Published var adjustmentClipboard: AdjustmentTransferPayload?
    @Published var adjustmentSheet: AdjustmentSheetKind?
    @Published var sharpenMaskPreviewActive = false
    @Published var sharpenMaskOverlay: CGImage?
    private let sharpenMaskQueue = DispatchQueue(label: "rawlab.sharpen-mask-preview", qos: .userInteractive)
    private var sharpenMaskRequestEpoch: UInt64 = 0
    private var cachedMaskSourceFrameID: ObjectIdentifier?
    private var cachedMaskSourceSize: (width: Int, height: Int) = (0, 0)
    private var cachedMaskSourceData: Data?
    var sharpenMaskCacheBytes: Int { cachedMaskSourceData?.count ?? 0 }
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    @Published var adjustmentSheetInCollection = false
    var adjustmentSheetPayload: AdjustmentTransferPayload?
    var adjustmentSheetPreset: AdjustmentPreset?
    var adjustmentSheetStartsPresetSave = false
    var adjustmentSheetTargets: [URL]?
    var adjustmentSheetExcludedSource: String?
    var adjustmentSheetExcludedIdentity: String?
    var pendingAdjustmentHistory: AdjustmentHistoryRequest?
    @Published var independentRecipeLookIDs = Set<String>()
    @Published var adjustmentOutcomes: [AdjustmentTransferOutcome] = []
    var lastAdjustmentTransaction: UUID?
    var presetStore: AdjustmentPresetStore
    @Published var quickPresetsVisible = false
    @Published var quickPresetState = QuickPresetState.idle
    var quickPresetGeneration = UUID()
    let quickPresetQueue = DispatchQueue(label: "rawlab.preset.prepare", qos: .userInitiated)
    var prepareQuickPresetOperation: (AdjustmentTransferSession, AdjustmentTransferPayload, [AdjustmentTransferTarget]) throws -> PreparedAdjustmentTransfer = {
        try $0.prepare(payload: $1, targets: $2, action: .preset)
    }
    var confirmUnusableRecordReset: ((URL, String) -> Bool)?
    let editDirectory: URL
    let presetDirectory: URL
    let batchJournal: MacBatchJournal
    var updateJournalLoadFailed = false
    var saveWork: DispatchWorkItem?
    var dirty = false
    @Published var pendingExternalReload: PendingExternalReload?
    @Published var presetLibraryRevision: UInt64 = 0
    var dismissedExternalReloadFingerprints: Set<FileStatFingerprint> = []
    var deferredExternalEditsCheck = false
    var deferredExternalReloadAccept = false
    var externalStoreWatcher: ExternalStoreFileWatcher?
    var lookLibrary: LookLibrary?
    let onUsage: (UsageEvent) -> Void
    var pendingImportEvent = false
    var selectedFilm: Film? {
        Film.independentRecipe(selectedFilmID) ?? films.first { $0.id == selectedFilmID }
    }
    var filmChoices: [Film] { films + independentRecipeLookIDs.sorted().compactMap(Film.independentRecipe) }
    var selectedMasterRecipe: MasterRecipe? { settings.masterRecipe }
    var missingFilm: Bool { !settings.isHDREditing && !selectedFilmID.isEmpty && (selectedFilm == nil || !FileManager.default.isReadableFile(atPath: selectedFilm!.url.path)) }
    var missingMasterRecipe: Bool {
        guard !settings.isHDREditing,let recipe = selectedMasterRecipe else { return false }
        return recipe.lutURL() == nil
    }
    private var canChangePhotoSettings: Bool {
        file != nil && !busy && !importing && !exporting && !aiState.isRunning && !lookLibraryBusy &&
            !missingFilm && !missingMasterRecipe && geometryDraft == nil
    }
    var canApplySettings: Bool { canChangePhotoSettings && result != nil && !previewOutdated }
    var canApplyHDRCameraDevelopment: Bool {
        canApplySettings || (canChangePhotoSettings && settings.hdr?.cameraDevelopmentSettings.cameraProfile != nil)
    }
    var canExport: Bool { canApplySettings && (!settings.isHDREditing || settings.hdr?.missingResourceMessage == nil) }


    init(lookDirectory: URL = LookLibrary.defaultDirectory,
         editDirectory: URL = MacEditPersistence.defaultDirectory,
         batchDirectory: URL = MacBatchJournal.defaultDirectory,
         presetDirectory: URL = AdjustmentPresetStore.defaultDirectory,
         aiModelManager: AIModelPackageManager = EditorModel.sharedAIModelManager,
         onUsage: @escaping (UsageEvent) -> Void = { _ in }) {
        self.aiModelManager = aiModelManager
        aiModelPackageState = aiModelManager.state
        recentLooksURL = editDirectory.appendingPathComponent("recent-looks.json")
        self.onUsage = onUsage
        self.editDirectory = editDirectory
        self.presetDirectory = presetDirectory
        presetStore = AdjustmentPresetStore(directory: presetDirectory)
        batchJournal = MacBatchJournal(directory: batchDirectory)
        recentLooks = RecentLooks.load(from: recentLooksURL)
        independentRecipeLookIDs.formUnion(recentLooks.ids.filter { $0.hasPrefix("recipe-lut:") })
        do {
            let library = try LookLibrary(directory: lookDirectory)
            lookLibrary = library
            unreadableLooks = library.unreadableLooks
            films += library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id, colorNotice: $0.colorNotice, isCompatibility: $0.isCompatibility) }
            pruneRecentLooks()
        } catch {
            self.error = error.localizedDescription
        }
        selectedFilmID = ""
        do { editStore = try MacEditPersistence(directory: editDirectory, diagnostics: DiagnosticCenter.appErrorDiagnostics) }
        catch {
            DiagnosticCenter.appErrorDiagnostics.record(error as NSError, operation: .editPersistence, stage: "openStore")
            saveError = L10n.format("无法读取调整记录：%@", String(describing: error.localizedDescription))
        }
        do {
            if let job = try batchJournal.load() {
                attachBatch(job)
            } else if let quarantined = batchJournal.consumeQuarantinedError() {
                self.error = L10n.format("无法读取上次批量任务：%@", String(describing: quarantined.localizedDescription))
            }
        } catch { updateJournalLoadFailed = true; self.error = L10n.format("无法读取上次批量任务：%@", String(describing: error.localizedDescription)) }
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.launchNextRender() }
        }
        timer.resume()
        debounceTimer = timer
        startExternalStoreWatcher()
        let pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressureSource.setEventHandler { [weak self] in self?.reclaimPreviewCaches() }
        pressureSource.resume()
        memoryPressureSource = pressureSource
        aiModelManager.refresh()
        aiModelPackageState = aiModelManager.state
        aiModelStateCancellable = aiModelManager.$state.dropFirst().sink { [weak self] newState in
            guard let self else { return }
            let previousDirectory = Self.installedAIModelDirectory(for: self.aiModelPackageState)
            let nextDirectory = Self.installedAIModelDirectory(for: newState)
            self.aiModelPackageState = newState
            if previousDirectory != nextDirectory {
                self.handleAIModelAvailabilityChanged(installed: newState.isInstalled)
            }
        }
    }
    deinit {
        aiModelStateCancellable?.cancel()
        batchStateCancellable?.cancel()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        externalStoreWatcher?.stop(); debounceTimer?.cancel(); viewportResizeWork?.cancel(); saveWork?.cancel(); aiDebounce?.cancel(); aiPreparation?.cancel()
    }
}

extension EditorModel {
    func reclaimPreviewCaches() {
        exactPreviewCache.useScope(nil)
        completedEditPreview = nil
        InspectionSamplerCache.shared.clear()
        InspectionOverlayRenderer.shared.clear()
        clearSharpenMaskPreviewCache()
        queue.async { [weak self] in
            if let self {
                self.originalCache = nil
                self.geometryReferenceCache = nil
                self.engine = nil
            }
            HDRSourceCache.shared.clear()
        }
    }

    func clearSharpenMaskPreviewCache() {
        sharpenMaskRequestEpoch &+= 1
        sharpenMaskPreviewActive = false
        sharpenMaskOverlay = nil
        cachedMaskSourceFrameID = nil
        cachedMaskSourceSize = (0, 0)
        cachedMaskSourceData = nil
    }

    func setSharpenMaskPreview(_ active: Bool) {
        guard active != sharpenMaskPreviewActive else {
            if active { refreshSharpenMaskPreviewIfNeeded() }
            return
        }
        sharpenMaskPreviewActive = active
        if active {
            refreshSharpenMaskPreviewIfNeeded()
        } else {
            sharpenMaskRequestEpoch &+= 1
            sharpenMaskOverlay = nil
        }
    }

    func refreshSharpenMaskPreviewIfNeeded() {
        guard sharpenMaskPreviewActive, let frame = result, !settings.isHDREditing, geometryDraft == nil else {
            sharpenMaskOverlay = nil
            return
        }
        let source = sourceRevision
        let radius = settings.sharpenV2Settings.radius
        let masking = settings.sharpenV2Settings.masking
        let cgImage = frame.image
        let frameID = ObjectIdentifier(cgImage)
        sharpenMaskRequestEpoch &+= 1
        let epoch = sharpenMaskRequestEpoch
        let cached = (cachedMaskSourceFrameID == frameID) ? cachedMaskSourceData : nil
        let cachedSize = cachedMaskSourceSize
        sharpenMaskQueue.async { [weak self] in
            let prepared: (width: Int, height: Int, data: Data)? = if let cached, cachedSize.width > 0, cachedSize.height > 0 {
                (cachedSize.width, cachedSize.height, cached)
            } else {
                RenderEngine.extractRGBA8Preview(from: cgImage)
            }
            guard let prepared,
                  let maskImage = RenderEngine.renderSharpenMaskPreview(fromRGBA8: prepared.data,
                      width: prepared.width, height: prepared.height, radius: radius, masking: masking) else {
                return
            }
            DispatchQueue.main.async {
                guard let self, self.sourceRevision == source, self.sharpenMaskRequestEpoch == epoch,
                      self.sharpenMaskPreviewActive else { return }
                self.cachedMaskSourceFrameID = frameID
                self.cachedMaskSourceSize = (prepared.width, prepared.height)
                self.cachedMaskSourceData = prepared.data
                self.sharpenMaskOverlay = maskImage
            }
        }
    }
}

extension EditorModel {
    func downloadAIModel() {
        aiModelManager.startDownload()
    }

    func cancelAIModelDownload() {
        aiModelManager.cancelDownload()
    }

    var canRemoveDownloadedAIModel: Bool {
        !aiState.isRunning
            && !busy
            && !exporting
            && !importing
            && !autoExposing
            && !wbProbeSampling
            && !hslTargetInteraction.isWaiting
            && !curveTargetInteraction.isWaiting
            && !collectionExportPreparing
            && !previewThumbnailAIRunning
            && batch?.running != true
            && batch?.previewing != true
            && batch?.validating != true
    }

    func removeDownloadedAIModel() {
        guard canRemoveDownloadedAIModel else { return }
        aiModelManager.removeDownloadedModel()
    }

    private static func installedAIModelDirectory(for state: AIModelPackageState) -> URL? {
        if case .installed(let source, _) = state { return source.url }
        return nil
    }

    private func handleAIModelAvailabilityChanged(installed: Bool) {
        queue.async { [weak self] in
            self?.engine = nil
        }
        // 通知缩略图协调器重刷可见瓦片，确保下载/替换/移除模型后侧栏与网格即时更新。
        NotificationCenter.default.post(name: RenderEngine.aiModelAvailabilityDidChangeNotification, object: nil)
        if installed {
            if settings.activeAIDenoise && file != nil && (aiRequiresExplicitRetry || aiState != .ready) && !aiState.isRunning {
                requestAIDenoise()
            }
        } else {
            aiIdentity = nil
        }
    }

    func handleAIFailure(_ failure: Error) {
        guard settings.activeAIDenoise else { return }
        if case RenderError.aiNotReady = failure {
            aiResultUnavailable()
        } else if case RenderError.aiFailed(let message) = failure {
            DiagnosticCenter.recordBreadcrumb(level: .error, category: "ai", stage: "aiDenoiseFailed", message: message)
            aiRequiresExplicitRetry = true
            aiState = .failed(message)
        } else { return }
        previewOutdated = true
        scheduler.invalidatePending()
        refreshBusy()
    }

    func aiResultUnavailable() {
        // 已发布结果被删掉或淘汰后需重新准备；失败/取消则等待用户明确重试。
        if aiState == .ready { aiIdentity = nil; aiState = .idle }
        synchronizeAI()
    }

    func resetAITask() {
        aiGeneration = UUID()
        aiDebounce?.cancel(); aiDebounce = nil
        aiPreparation?.cancel(); aiPreparation = nil
        aiIdentity = nil; aiManuallyRequested = false; aiState = .idle
        aiRequiresExplicitRetry = false
    }

    func setAIEnabled(_ enabled: Bool) {
        if enabled { requestAIDenoise() }
        else {
            let wasEnabled = settings.activeAIDenoise
            resetAITask(); settings.activeAIDenoise = false
            if !wasEnabled { schedule() }
        }
    }

    func cancelAIDenoise() {
        aiGeneration = UUID()
        aiDebounce?.cancel(); aiDebounce = nil
        aiPreparation?.cancel(); aiPreparation = nil
        aiManuallyRequested = false; aiState = .cancelled
        // 已保存的 AI 外观不静默关闭；取消重建后，导出继续报告结果未就绪。
        resumeOrdinaryPreviewAfterAI()
    }

    private func resumeOrdinaryPreviewAfterAI() {
        guard !settings.activeAIDenoise else { return }
        // 首次准备尚未改变外观；重绘当前普通参数，同时保留失败或取消提示。
        aiIdentity = nil
        schedule()
    }

    func requestAIDenoise() {
        aiManuallyRequested = !settings.activeAIDenoise
        aiRequiresExplicitRetry = false
        aiIdentity = nil
        // 旧预览不能在重试或取消后覆盖新的 AI 状态。
        scheduler.invalidatePending()
        previewOutdated = true
        refreshBusy()
        synchronizeAI(delay: 0)
    }

    func synchronizeAI(delay: Double = 0.6) {
        guard settings.activeAIDenoise || aiManuallyRequested else {
            if aiIdentity != nil || aiPreparation != nil || aiDebounce != nil { resetAITask() }
            return
        }
        guard !aiRequiresExplicitRetry, let file else { return }
        if !settings.isHDREditing && RenderEngine.isX3fInput(file) && settings.x3fMode == .normal {
            resetAITask()
            aiState = .failed(L10n.text("此 X3F 显影模式不支持 AI 降噪。"))
            return
        }
        do {
            let snapshot = geometryPreviewSettings
            let identity = try AIWorkIdentity(file, settings: snapshot)
            guard identity != aiIdentity else { return }
            aiGeneration = UUID()
            aiDebounce?.cancel(); aiPreparation?.cancel(); aiPreparation = nil
            aiIdentity = identity
            aiState = .running(1, 0, 0)
            let generation = aiGeneration, operation = prepareAIOperation
            let progress = AIPreparation { [weak self] phase, done, total in
                DispatchQueue.main.async {
                    guard let self, self.aiGeneration == generation else { return }
                    self.aiState = .running(phase, done, total)
                }
            }
            aiPreparation = progress
            let start = DispatchWorkItem { [weak self] in
                guard let self, self.aiGeneration == generation else { return }
                self.aiDebounce = nil
                Self.aiQueue.async { [weak self] in
                    let outcome = Result {
                        guard !progress.isCancelled else { throw RenderError.aiCancelled }
                        try operation(file, snapshot, progress)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.aiGeneration == generation else { return }
                        self.aiPreparation = nil
                        guard self.file == file,
                              (try? AIWorkIdentity(file, settings: self.geometryPreviewSettings)) == identity else {
                            self.aiManuallyRequested = false
                            self.aiState = .failed(L10n.text("照片或白平衡已变化，请重新准备 AI 降噪。"))
                            self.resumeOrdinaryPreviewAfterAI()
                            return
                        }
                        self.aiManuallyRequested = false
                        switch outcome {
                        case .success:
                            self.aiState = .ready
                            if !self.settings.activeAIDenoise { self.settings.activeAIDenoise = true }
                            self.schedule()
                        case .failure(let failure):
                            self.aiState = progress.isCancelled ? .cancelled : .failed(failure.localizedDescription)
                            if !progress.isCancelled, case RenderError.aiFailed = failure {
                                self.aiRequiresExplicitRetry = true
                            }
                            self.resumeOrdinaryPreviewAfterAI()
                        }
                    }
                }
            }
            aiDebounce = start
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
        } catch {
            aiGeneration = UUID()
            aiDebounce?.cancel(); aiDebounce = nil
            aiPreparation?.cancel(); aiPreparation = nil
            aiManuallyRequested = false
            aiState = .failed(error.localizedDescription)
            resumeOrdinaryPreviewAfterAI()
        }
    }
}
