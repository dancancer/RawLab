import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    struct RenderWork: Equatable {
        let file: URL
        let settings: Adjustments
        let lut: URL?
        let edge: Int?
        let pass: RenderPass
        let draftEpoch: UUID
        let editingGeometry: Bool
    }

    @Published var settings = Adjustments() { didSet { if !updatingMetadata && oldValue != settings { edited() } } }
    @Published var geometryDraft: MacGeometryDraft?
    @Published var geometryDraftPreviewReady = false
    @Published var geometryDraftTab = MacGeometryTab.crop
    @Published var cropAspectPreset = CropAspectPreset.free
    @Published var cropAspectSwapped = false
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
        geometryDraft != nil && geometryDraftSettings.isValid && invalidGeometryDraftInputs.isEmpty &&
            geometryDraftPreviewReady && !busy && !geometryCropInteracting && !exporting
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
    var cropAspectRatio: Double? { cropAspectPreset.ratio(for: geometryCanvasSize, swapped: cropAspectSwapped) }
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
            if !updatingMetadata {
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
    @Published var file: URL?
    @Published var neutral: RenderedImage?
    @Published var result: RenderedImage?
    @Published var busy = false
    @Published var autoExposing = false
    var editRevision = UUID()
    @Published var exporting = false
    @Published var lookLibraryBusy = false
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
    var originalCache: (file: URL, frame: RenderedImage)?
    var geometryReferenceCache: (file: URL, geometry: GeometrySettings, lens: LensCorrectionSettings, frame: RenderedImage)?
    var editStore: EditPersistence?
    let editDirectory: URL
    let batchJournal: BatchJournal
    var saveWork: DispatchWorkItem?
    var dirty = false
    var lookLibrary: LookLibrary?
    let onUsage: (UsageEvent) -> Void
    var pendingImportEvent = false
    var selectedFilm: Film? { films.first { $0.id == selectedFilmID } }
    var selectedMasterRecipe: MasterRecipe? { settings.masterRecipe }
    var missingFilm: Bool { !selectedFilmID.isEmpty && (selectedFilm == nil || !FileManager.default.isReadableFile(atPath: selectedFilm!.url.path)) }
    var missingMasterRecipe: Bool {
        guard let recipe = selectedMasterRecipe else { return false }
        return recipe.lutURL() == nil
    }
    var canApplySettings: Bool { file != nil && result != nil && !busy && !exporting && !lookLibraryBusy && !missingFilm && !missingMasterRecipe && geometryDraft == nil }


    init(lookDirectory: URL = LookLibrary.defaultDirectory,
         editDirectory: URL = EditPersistence.defaultDirectory,
         batchDirectory: URL = BatchJournal.defaultDirectory,
         onUsage: @escaping (UsageEvent) -> Void = { _ in }) {
        self.onUsage = onUsage
        self.editDirectory = editDirectory
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
    deinit { debounceTimer?.cancel(); viewportResizeWork?.cancel(); saveWork?.cancel() }
}
