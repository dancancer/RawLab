import AppKit
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
        let processing: ProcessingIdentity
        let whiteBalance: [Float]
        let lens: LensCorrectionSettings
        init(_ file: URL, settings: Adjustments) throws {
            source = try RawWhiteBalanceCacheKey(file)
            processing = settings.processing
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
        let original: PhotoEditState
        let candidate: PhotoEditState
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
    }

    @Published var adjustmentNavigation = EditorAdjustmentNavigation()
    @Published var resetConfirmation: PreparedReset?
    @Published var resetConfirmationScope: EditorResetScope?
    @Published var resetBlockedMessage: String?
    var resetReturnTool: EditorAdjustmentTool?
    var resetReturnGeometryTab: MacGeometryTab?
    var resetSource: URL?

    @Published var settings = Adjustments() { didSet { if !updatingMetadata && oldValue != settings { edited() } } }
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
        preview.geometry = draft.previewGeometry.isIdentity ? nil : draft.previewGeometry
        preview.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        return preview
    }
    var updatingMetadata = false
    @Published var films = Film.bundled()
    @Published var selectedFilmID = "" {
        didSet {
            if selectedFilmID.hasPrefix("recipe-lut:") { independentRecipeLookIDs.insert(selectedFilmID) }
            if !updatingMetadata && (oldValue != selectedFilmID || settings.masterRecipeID != nil) {
                if settings.masterRecipeID != nil {
                    settings.clearMasterRecipe()
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
    @Published var sourceRevision = UUID()
    @Published var file: URL?
    @Published var neutral: RenderedImage?
    @Published var result: RenderedImage?
    @Published var busy = false { didSet { if oldValue && !busy { resumeResetToolIfReady() } } }
    @Published var autoExposing = false
    var editRevision = UUID()
    @Published var exporting = false
    @Published var aiState = AIDenoiseState.idle
    var aiIdentity: AIWorkIdentity?
    var aiGeneration = UUID()
    var aiPreparation: AIPreparation?
    var aiDebounce: DispatchWorkItem?
    var aiManuallyRequested = false
    var aiRequiresExplicitRetry = false
    // 全窗口串行化，避免多个整图推理同时争用内存。
    static let aiQueue = DispatchQueue(label: "rawlab.ai.prepare", qos: .utility)
    var prepareAIOperation: (URL, Adjustments, AIPreparation) throws -> Void = {
        try RenderEngine().prepareAI($0, settings: $1, progress: $2)
    }
    var aiControlsVisible: Bool { RenderEngine.aiAvailable || settings.aiDenoiseEnabled }
    var canStartAI: Bool {
        file != nil && !RenderEngine.isRasterInput(file) && RenderEngine.aiAvailable &&
            RenderEngine.bundledAIModel != nil && !exporting && geometryDraft == nil
    }
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
        case .interactive(let width, let height): return L10n.format("交互预览… %@ × %@ · sRGB", String(width), String(height))
        case .preview(let width, let height, let original):
            return "\(original ? L10n.text("原尺寸") : L10n.text("预览")) \(width) × \(height) · sRGB"
        case .exported(let name): return L10n.format("已导出：%@", name)
        }
    }
    @Published var saveStatusKey = ""
    var saveStatus: String { L10n.text(saveStatusKey) }
    @Published var saveError: String?
    @Published var batch: BatchExportModel?
    @Published var exportLongEdge: Int?
    let queue = DispatchQueue(label: "rawlab.render", qos: .userInitiated)
    let debounceQueue = DispatchQueue(label: "rawlab.render.debounce", qos: .userInitiated)
    var scheduler = RenderScheduler<RenderWork>()
    var debounceTimer: DispatchSourceTimer?
    var viewportResizeWork: DispatchWorkItem?
    var workerActive = false
    var engine: RenderEngine?
    var originalCache: (key: MacNeutralReferenceKey, frame: RenderedImage)?
    var geometryReferenceCache: (key: MacNeutralReferenceKey, frame: RenderedImage)?
    var editStore: EditPersistence? {
        didSet {
            if editStore !== oldValue {
                adjustmentSession = editStore.map(AdjustmentTransferSession.init)
                committedEdit = nil
            }
        }
    }
    var adjustmentSession: AdjustmentTransferSession?
    var committedEdit: VersionedPhotoEdit?
    var interactionEntry: PhotoEditState?
    var interactionWasDirty = false
    @Published var adjustmentHistoryRevision = 0
    @Published var adjustmentClipboard: AdjustmentTransferPayload?
    @Published var adjustmentSheet: AdjustmentSheetKind?
    var adjustmentSheetPayload: AdjustmentTransferPayload?
    var adjustmentSheetTargets: [URL]?
    var adjustmentSheetExcludedSource: String?
    var pendingAdjustmentHistory: AdjustmentHistoryRequest?
    @Published var independentRecipeLookIDs = Set<String>()
    @Published var adjustmentOutcomes: [AdjustmentTransferOutcome] = []
    var lastAdjustmentTransaction: UUID?
    var presetStore: AdjustmentPresetStore
    let editDirectory: URL
    let batchJournal: BatchJournal
    var saveWork: DispatchWorkItem?
    var dirty = false
    var lookLibrary: LookLibrary?
    let onUsage: (UsageEvent) -> Void
    var pendingImportEvent = false
    var selectedFilm: Film? {
        Film.independentRecipe(selectedFilmID) ?? films.first { $0.id == selectedFilmID }
    }
    var filmChoices: [Film] { films + independentRecipeLookIDs.sorted().compactMap(Film.independentRecipe) }
    var selectedMasterRecipe: MasterRecipe? { settings.masterRecipe }
    var missingFilm: Bool { !selectedFilmID.isEmpty && (selectedFilm == nil || !FileManager.default.isReadableFile(atPath: selectedFilm!.url.path)) }
    var missingMasterRecipe: Bool {
        guard let recipe = selectedMasterRecipe else { return false }
        return recipe.lutURL() == nil
    }
    var canApplySettings: Bool { file != nil && result != nil && !busy && !previewOutdated && !exporting && !aiState.isRunning && !lookLibraryBusy && !missingFilm && !missingMasterRecipe && geometryDraft == nil }
    var canExport: Bool { canApplySettings }


    init(lookDirectory: URL = LookLibrary.defaultDirectory,
         editDirectory: URL = EditPersistence.defaultDirectory,
         batchDirectory: URL = BatchJournal.defaultDirectory,
         presetDirectory: URL = AdjustmentPresetStore.defaultDirectory,
         onUsage: @escaping (UsageEvent) -> Void = { _ in }) {
        self.onUsage = onUsage
        self.editDirectory = editDirectory
        presetStore = AdjustmentPresetStore(directory: presetDirectory)
        batchJournal = BatchJournal(directory: batchDirectory)
        do {
            let library = try LookLibrary(directory: lookDirectory)
            lookLibrary = library
            films += library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
        } catch {
            self.error = error.localizedDescription
        }
        selectedFilmID = ""
        do { editStore = try EditPersistence(directory: editDirectory) }
        catch { saveError = L10n.format("无法读取调整记录：%@", String(describing: error.localizedDescription)) }
        do {
            if let job = try batchJournal.load() { attachBatch(job) }
        } catch { self.error = L10n.format("无法读取上次批量任务：%@", String(describing: error.localizedDescription)) }
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.launchNextRender() }
        }
        timer.resume()
        debounceTimer = timer
    }
    deinit { debounceTimer?.cancel(); viewportResizeWork?.cancel(); saveWork?.cancel(); aiDebounce?.cancel(); aiPreparation?.cancel() }
}

extension EditorModel {
    func handleAIFailure(_ failure: Error) {
        guard settings.aiDenoiseEnabled else { return }
        if case RenderError.aiNotReady = failure {
            aiResultUnavailable()
        } else if case RenderError.aiFailed(let message) = failure {
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
            let wasEnabled = settings.aiDenoiseEnabled
            resetAITask(); settings.aiDenoiseEnabled = false
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
        guard !settings.aiDenoiseEnabled else { return }
        // 首次准备尚未改变外观；重绘当前普通参数，同时保留失败或取消提示。
        aiIdentity = nil
        schedule()
    }

    func requestAIDenoise() {
        aiManuallyRequested = !settings.aiDenoiseEnabled
        aiRequiresExplicitRetry = false
        aiIdentity = nil
        // 旧预览不能在重试或取消后覆盖新的 AI 状态。
        scheduler.invalidatePending()
        previewOutdated = true
        refreshBusy()
        synchronizeAI(delay: 0)
    }

    func synchronizeAI(delay: Double = 0.6) {
        guard settings.aiDenoiseEnabled || aiManuallyRequested else {
            if aiIdentity != nil || aiPreparation != nil || aiDebounce != nil { resetAITask() }
            return
        }
        guard !aiRequiresExplicitRetry, let file else { return }
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
                            if !self.settings.aiDenoiseEnabled { self.settings.aiDenoiseEnabled = true }
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
