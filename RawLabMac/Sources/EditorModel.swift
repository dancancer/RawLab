import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MacGeometryTab: String, CaseIterable {
    case crop, perspective, lens

    var title: String {
        L10n.text(self == .crop ? "裁切" : self == .perspective ? "透视" : "镜头")
    }
}

struct MacGeometryDraft: Equatable {
    let originalGeometry: GeometrySettings
    let originalLens: LensCorrectionSettings
    var geometry: GeometrySettings
    var lens: LensCorrectionSettings

    init(geometry: GeometrySettings, lens: LensCorrectionSettings) {
        originalGeometry = geometry; originalLens = lens
        self.geometry = geometry; self.lens = lens
    }

    var hasChanges: Bool { geometry != originalGeometry || lens != originalLens }
    var previewGeometry: GeometrySettings {
        var full = geometry
        full.cropX = 0; full.cropY = 0; full.cropWidth = 1; full.cropHeight = 1
        full.straightenDegrees = 0
        return full
    }
}

enum MacGeometryDeparture { case apply, discard, stay }

final class EditorModel: ObservableObject {
    private struct RenderWork: Equatable {
        let file: URL
        let settings: Adjustments
        let lut: URL?
        let edge: Int?
        let pass: RenderPass
        let draftEpoch: UUID
        let editingGeometry: Bool
    }

    @Published var settings = Adjustments() { didSet { if !updatingMetadata && oldValue != settings { edited() } } }
    @Published private(set) var geometryDraft: MacGeometryDraft?
    @Published private(set) var geometryDraftPreviewReady = false
    @Published private(set) var geometryDraftTab = MacGeometryTab.crop
    @Published private(set) var cropAspectPreset = CropAspectPreset.free
    @Published private(set) var cropAspectSwapped = false
    @Published var cropGridEnabled = true
    @Published private(set) var geometryDraftDeparturePending = false
    @Published private(set) var invalidGeometryDraftInputs = Set<String>()
    @Published private(set) var geometryCropInteracting = false
    @Published private(set) var geometryDraftRevision = 0
    @Published private(set) var pendingGeometryPresentation: GeometrySettings?
    private var geometryDraftEntryResult: RenderedImage?
    private var geometryDraftEntryNeutral: RenderedImage?
    private var geometryDraftEpoch = UUID()
    private var geometryDepartureAction: (() -> Void)?
    private var geometryDepartureStay: (() -> Void)?
    private var geometryDraftEntrySaveError: String?
    private var geometryDraftSaveFailed = false
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
    private var updatingMetadata = false
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
    private(set) var previewLongEdge = 2000
    private(set) var renderPreviewLongEdge = 2000
    @Published private(set) var file: URL?
    @Published private(set) var neutral: RenderedImage?
    @Published private(set) var result: RenderedImage?
    @Published private(set) var busy = false
    @Published private(set) var autoExposing = false
    private var editRevision = UUID()
    @Published private(set) var exporting = false
    @Published private(set) var lookLibraryBusy = false
    @Published var error: String?
    @Published var lookImportReport: String?
    private enum Status {
        case none, applied(Int), interactive(Int, Int), preview(Int, Int, original: Bool), exported(String)
    }
    @Published private var statusState = Status.none
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
    @Published private(set) var saveStatusKey = ""
    var saveStatus: String { L10n.text(saveStatusKey) }
    @Published private(set) var saveError: String?
    @Published private(set) var batch: BatchExportModel?
    @Published var exportLongEdge: Int?
    private let queue = DispatchQueue(label: "rawlab.render", qos: .userInitiated)
    private let debounceQueue = DispatchQueue(label: "rawlab.render.debounce", qos: .userInitiated)
    private var scheduler = RenderScheduler<RenderWork>()
    private var debounceTimer: DispatchSourceTimer?
    private var viewportResizeWork: DispatchWorkItem?
    private var workerActive = false
    private var engine: RenderEngine?
    private var originalCache: (file: URL, frame: RenderedImage)?
    private var geometryReferenceCache: (file: URL, geometry: GeometrySettings, lens: LensCorrectionSettings, frame: RenderedImage)?
    private var editStore: EditPersistence?
    private let editDirectory: URL
    private let batchJournal: BatchJournal
    private var saveWork: DispatchWorkItem?
    private var dirty = false
    private var lookLibrary: LookLibrary?
    var selectedFilm: Film? { films.first { $0.id == selectedFilmID } }
    var selectedMasterRecipe: MasterRecipe? { settings.masterRecipe }
    var missingFilm: Bool { !selectedFilmID.isEmpty && (selectedFilm == nil || !FileManager.default.isReadableFile(atPath: selectedFilm!.url.path)) }
    var missingMasterRecipe: Bool {
        guard let recipe = selectedMasterRecipe else { return false }
        return recipe.lutURL() == nil
    }
    var canApplySettings: Bool { file != nil && result != nil && !busy && !exporting && !lookLibraryBusy && !missingFilm && !missingMasterRecipe && geometryDraft == nil }

    @discardableResult func beginGeometryDraft(tab: MacGeometryTab = .crop) -> Bool {
        if tab == .lens && RenderEngine.isRasterInput(file) { return false }
        if geometryDraft != nil { return selectGeometryDraftTab(tab) }
        guard file != nil, result != nil, !exporting, !lookLibraryBusy, saveEdits() else { return false }
        geometryDraftEntrySaveError = saveError
        geometryDraftSaveFailed = false
        geometryDraftEntryResult = result; geometryDraftEntryNeutral = neutral
        geometryDraftEpoch = UUID(); editRevision = UUID()
        geometryDraft = MacGeometryDraft(geometry: settings.geometrySettings, lens: settings.lensSettings)
        geometryDraftTab = tab; geometryDraftPreviewReady = false
        cropAspectPreset = .free; cropAspectSwapped = false
        invalidGeometryDraftInputs.removeAll()
        batch?.sourceEditingGeometry = true
        scheduler.setInteracting(false)
        schedule(forceExact: true)
        return true
    }

    @discardableResult func selectGeometryDraftTab(_ tab: MacGeometryTab) -> Bool {
        if tab == .lens && RenderEngine.isRasterInput(file) { return false }
        guard geometryDraft != nil, invalidGeometryDraftInputs.isEmpty else { return false }
        geometryDraftTab = tab
        return true
    }

    func updateGeometryDraft(_ edit: (inout GeometrySettings) -> Void) {
        guard var draft = geometryDraft else { return }
        let before = draft.previewGeometry
        let previousAngle = draft.geometry.straightenDegrees
        edit(&draft.geometry)
        guard draft.geometry.isValid, draft != geometryDraft else { return }
        geometryDraft = draft
        // Crop selection is an overlay on the already rendered, transformed canvas.
        if before != draft.previewGeometry {
            geometryDraftPreviewReady = false
            schedule()
        } else if geometryDraftPreviewReady, previousAngle != draft.geometry.straightenDegrees,
                  let ratio = cropAspectRatio {
            let rect = CropInteraction.dragging(CropInteraction.rect(from: draft.geometry), handle: .bottomRight,
                translation: .zero, canvasSize: geometryCanvasSize, ratio: ratio)
            draft.geometry = CropInteraction.applying(rect: rect, to: draft.geometry)
            geometryDraft = draft
        }
    }

    func updateLensDraft(_ edit: (inout LensCorrectionSettings) -> Void) {
        guard var draft = geometryDraft else { return }
        edit(&draft.lens)
        guard draft != geometryDraft else { return }
        geometryDraft = draft; geometryDraftPreviewReady = false
        schedule()
    }

    func setGeometryDraftParameter(_ parameter: GeometryParameter, to value: Double) {
        guard value.isFinite else { return }
        updateGeometryDraft { geometry in
            let range = parameter.range(for: geometry)
            geometry[keyPath: parameter.keyPath] = min(range.upperBound, max(range.lowerBound, value))
            if (parameter == .cropWidth || parameter == .cropHeight), let ratio = cropAspectRatio {
                if parameter == .cropHeight {
                    geometry.cropWidth = min(1 - geometry.cropX,
                        geometry.cropHeight * ratio * Double(geometryCanvasSize.height / geometryCanvasSize.width))
                }
                let rect = CropInteraction.dragging(CropInteraction.rect(from: geometry), handle: .bottomRight,
                    translation: .zero, canvasSize: geometryCanvasSize, ratio: ratio)
                geometry = CropInteraction.applying(rect: rect, to: geometry)
            }
        }
    }

    func setGeometryDraftInputValidity(identifier: String, isValid: Bool) {
        guard geometryDraft != nil else { return }
        if isValid { invalidGeometryDraftInputs.remove(identifier) }
        else { invalidGeometryDraftInputs.insert(identifier) }
    }

    func setGeometryCropInteracting(_ interacting: Bool) {
        guard geometryCropInteracting != interacting else { return }
        geometryCropInteracting = interacting
        // @Published 在赋值前通知；原生手势同步刷新后还需读取已写入的状态。
        objectWillChange.send()
    }

    func selectCropAspect(_ preset: CropAspectPreset) {
        guard geometryDraftPreviewReady else { return }
        cropAspectPreset = preset
        fitDraftCropAspect()
    }

    func swapCropAspect() {
        guard geometryDraftPreviewReady, cropAspectRatio != nil else { return }
        cropAspectSwapped.toggle(); fitDraftCropAspect()
    }

    private func fitDraftCropAspect() {
        let rect = MacCropInteraction.fitting(ratio: cropAspectRatio, in: geometryCanvasSize,
                                             around: CropInteraction.rect(from: geometryDraftSettings))
        updateGeometryDraft { $0 = CropInteraction.applying(rect: rect, to: $0) }
    }

    func resetGeometryDraft() {
        cropAspectPreset = .free; cropAspectSwapped = false
        geometryDraftRevision &+= 1
        invalidGeometryDraftInputs.removeAll()
        updateGeometryDraft { $0 = GeometrySettings() }
    }

    func resetLensDraft() {
        geometryDraftRevision &+= 1
        updateLensDraft { $0 = LensCorrectionSettings() }
    }

    @discardableResult func applyGeometryDraft() -> Bool {
        guard geometryDraftCanApply, let draft = geometryDraft, let file else { return false }
        var committed = settings
        committed.geometry = draft.geometry.isIdentity ? nil : draft.geometry
        committed.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        do {
            if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
            try editStore!.save(file, state: editState(settings: committed))
        } catch {
            geometryDraftSaveFailed = true
            saveError = L10n.format("调整未保存：%@", error.localizedDescription)
            return false
        }
        saveWork?.cancel()
        updatingMetadata = true; settings = committed; updatingMetadata = false
        dirty = false; saveError = nil; saveStatusKey = "调整已保存"
        // 精确渲染完成前沿用同一底图的已裁切显示，避免闪回未旋转画面。
        pendingGeometryPresentation = draft.geometry
        clearSaveStatusLater(); endGeometryDraft(); schedule(forceExact: true)
        return true
    }

    func cancelGeometryDraft() {
        guard geometryDraft != nil else { return }
        // Discarding an unsaved draft restores the saved entry state, including
        // its feedback. Do not clear an unrelated error that predated the task.
        if geometryDraftSaveFailed { saveError = geometryDraftEntrySaveError }
        result = geometryDraftEntryResult; neutral = geometryDraftEntryNeutral
        endGeometryDraft(); schedule(forceExact: true)
    }

    private func endGeometryDraft() {
        geometryDraft = nil; geometryDraftPreviewReady = false
        geometryCropInteracting = false; invalidGeometryDraftInputs.removeAll()
        geometryDraftEntrySaveError = nil; geometryDraftSaveFailed = false
        geometryDraftEntryResult = nil; geometryDraftEntryNeutral = nil
        geometryDraftEpoch = UUID(); editRevision = UUID()
        scheduler.setInteracting(false)
        batch?.sourceEditingGeometry = false
    }

    func requestLeavingGeometryDraft(_ action: @escaping () -> Void, onStay: @escaping () -> Void = {}) {
        guard !geometryDraftDeparturePending else { return }
        // A valid text draft can still be uncommitted when a file is dropped.
        // Resolve the native field before deciding whether the task has changes.
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if geometryDraftHasChanges {
            geometryDepartureAction = action; geometryDepartureStay = onStay
            geometryDraftDeparturePending = true
        } else {
            cancelGeometryDraft(); action()
        }
    }

    func resolveGeometryDraftDeparture(_ choice: MacGeometryDeparture) {
        guard geometryDraftDeparturePending else { return }
        if choice == .apply && !applyGeometryDraft() { return }
        if choice == .discard { cancelGeometryDraft() }
        let action = choice == .stay ? geometryDepartureStay : geometryDepartureAction
        geometryDepartureAction = nil; geometryDepartureStay = nil
        geometryDraftDeparturePending = false
        action?()
    }

    private func editState(settings: Adjustments) -> PhotoEditState {
        let filmID = selectedFilm.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? selectedFilmID
        return PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: settings.masterRecipeID)
    }

    func selectMasterRecipe(_ recipe: MasterRecipe?) {
        guard geometryDraft == nil else { return }
        guard recipe != nil || settings.masterRecipeID != nil else { return }
        updatingMetadata = true
        if let recipe {
            settings.applyMasterRecipe(recipe)
            selectedFilmID = ""
        } else {
            settings.clearMasterRecipe()
        }
        updatingMetadata = false
        edited()
    }

    init(lookDirectory: URL = LookLibrary.defaultDirectory,
         editDirectory: URL = EditPersistence.defaultDirectory,
         batchDirectory: URL = BatchJournal.defaultDirectory) {
        self.editDirectory = editDirectory
        batchJournal = BatchJournal(directory: batchDirectory)
        do {
            let library = try LookLibrary(directory: lookDirectory)
            lookLibrary = library
            films += library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
        } catch {
            self.error = error.localizedDescription
        }
        selectedFilmID = films.first(where: { $0.name == "PROVIA" })?.id ?? films.first?.id ?? ""
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

    private func edited() {
        editRevision = UUID()
        guard file != nil else { return }
        dirty = true
        saveStatusKey = ""
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveEdits() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        schedule()
    }

    @discardableResult func saveEdits() -> Bool {
        saveWork?.cancel()
        guard let file, dirty else { return true }
        do {
            if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
            try editStore!.save(file, state: editState(settings: settings))
            dirty = false; saveError = nil; saveStatusKey = "调整已保存"
            clearSaveStatusLater()
            return true
        } catch {
            saveError = L10n.format("调整未保存：%@", String(describing: error.localizedDescription))
            return false
        }
    }

    private func clearSaveStatusLater() {
        let message = saveStatusKey
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.saveStatusKey == message { self?.saveStatusKey = "" }
        }
    }

    @discardableResult func applyCurrentSettings(to urls: [URL]) throws -> Int {
        guard file != nil, !exporting, !lookLibraryBusy, !missingFilm, !missingMasterRecipe, geometryDraft == nil else {
            throw RenderError.failed(L10n.text("当前照片的设置尚不可用。"))
        }
        let targets = Array(Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
        guard !targets.isEmpty else { return 0 }
        let filmID = selectedFilm.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? selectedFilmID
        if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
        try editStore!.save(targets, state: PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: settings.masterRecipeID))
        statusState = .applied(targets.count)
        return targets.count
    }

    func confirmApplySettings(to url: URL, directory: Bool) {
        guard canApplySettings else { return }
        do {
            let targets = directory ? try DirectoryContents.read(url).photos : [url]
            guard !targets.isEmpty else { throw RenderError.failed(L10n.text("此目录没有照片。")) }
            let alert = NSAlert()
            alert.messageText = L10n.format("应用当前设置到 %@ 张照片？", String(describing: targets.count))
            alert.informativeText = L10n.text("将替换目标照片的本机调整记录，不改写原始文件。") +
                (directory ? L10n.text("仅包含此目录中的照片，不包含子目录。") : "")
            alert.addButton(withTitle: L10n.text("应用当前设置")); alert.addButton(withTitle: L10n.text("取消"))
            if alert.runModal() == .alertFirstButtonReturn { try applyCurrentSettings(to: targets) }
        } catch { self.error = error.localizedDescription }
    }

    func prepareBatch() -> Bool {
        guard !busy, !exporting, !lookLibraryBusy, result != nil, !missingFilm, !missingMasterRecipe, geometryDraft == nil, let file else { return false }
        if batch?.validating == true || batch?.previewing == true { return true }
        if let batch, batch.job.started && batch.job.succeededCount < batch.job.selectedCount {
            let alert = NSAlert()
            alert.messageText = L10n.text("上次批量任务尚未完成")
            alert.informativeText = L10n.text("继续查看上次任务，或保留已导出文件并新建任务。")
            alert.addButton(withTitle: L10n.text("查看任务")); alert.addButton(withTitle: L10n.text("新建任务"))
            if alert.runModal() == .alertFirstButtonReturn { return true }
        }
        do {
            if let batch { try batchJournal.discard(batch.job) }
            let lookURL = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
            let lookName = settings.masterRecipe?.name ?? selectedFilm?.name ?? "中性"
            var job = BatchExportJob(source: file, settings: settings, look: nil, lookName: lookName)
            job.longEdge = exportLongEdge
            job.look = try batchJournal.snapshotLook(lookURL, for: job.id)
            try batchJournal.save(job)
            attachBatch(job)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func attachBatch(_ job: BatchExportJob) {
        let model = BatchExportModel(job: job, journal: batchJournal)
        model.sourceEditingGeometry = geometryDraft != nil
        model.onActivity = { [weak self] active in self?.exporting = active }
        model.onDiscard = { [weak self] in self?.batch = nil }
        batch = model
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.text("打开照片")
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !exporting else { return }
        if file == url && result != nil { return }
        if geometryDraft != nil {
            requestLeavingGeometryDraft { [weak self] in self?.open(url) }
            return
        }
        guard saveEdits() else { return }
        cancelViewportResize()
        editRevision = UUID()
        scheduler.setInteracting(false)
        var restored: PhotoEditState?
        do { restored = try editStore?.state(for: url) }
        catch { saveError = L10n.format("无法恢复调整：%@", String(describing: error.localizedDescription)) }
        file = url; neutral = nil; result = nil; error = nil; statusState = .none
        updatingMetadata = true
        settings = restored?.settings ?? Adjustments()
        if let masterRecipeID = restored?.masterRecipeID {
            settings.masterRecipeID = masterRecipeID
        }
        let filmID = restored?.filmID ?? films.first(where: { $0.name == "PROVIA" })?.id ?? ""
        if settings.masterRecipeID != nil {
            selectedFilmID = ""
        } else {
            selectedFilmID = films.first(where: { $0.id == filmID || "builtin:\($0.url.lastPathComponent)" == filmID })?.id ?? filmID
        }
        updatingMetadata = false
        dirty = false
        saveStatusKey = restored == nil ? "" : "已恢复上次调整"
        clearSaveStatusLater()
        schedule()
    }
    func autoExposure() {
        guard let file, result != nil, !autoExposing, !exporting, geometryDraft == nil else { return }
        let snapshot = settings, revision = editRevision
        autoExposing = true
        queue.async { [weak self] in
            let result = Result { try RenderEngine().autoExposure(file, settings: snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.autoExposing = false
                guard self.file == file, self.editRevision == revision, self.settings == snapshot else { return }
                switch result {
                case .success(let ev): self.settings.exposure = ev
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func importLUT() {
        guard !lookLibraryBusy, !exporting, geometryDraft == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入外观")
        panel.allowedContentTypes = ["cube", "rlook"].map { UTType(filenameExtension: $0) ?? .data }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            importLooks(panel.urls)
        }
    }

    func importLook(_ url: URL) {
        importLooks([url])
    }

    func importLooks(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        changeLookLibrary { library in
            var selectedID: String?
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    selectedID = try library.importLook(from: url).id
                    imported += 1
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            let report = failures.isEmpty ? nil :
                L10n.format("已导入 %@ 个外观，%@ 个文件导入失败：\n", String(describing: imported), String(describing: failures.count)) + failures.joined(separator: "\n")
            return (selectedID, report)
        }
    }

    func renameLook(id: String, name: String) {
        changeLookLibrary { try $0.rename(id: id, to: name); return (nil, nil) }
    }

    func removeLook(id: String) {
        changeLookLibrary { try $0.remove(id: id); return (nil, nil) }
    }

    func renameLookPanel(_ film: Film) {
        guard let id = film.managedID, !lookLibraryBusy, !exporting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("重命名外观")
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("取消"))
        let field = NSTextField(string: film.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { renameLook(id: id, name: field.stringValue) }
    }

    func removeLookPanel(_ film: Film) {
        guard let id = film.managedID, !lookLibraryBusy, !exporting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("移除“%@”？", String(describing: film.name))
        alert.informativeText = L10n.text("将移除 RawLab 保存的外观副本，原始文件不会被删除。")
        alert.addButton(withTitle: L10n.text("移除"))
        alert.addButton(withTitle: L10n.text("取消"))
        if alert.runModal() == .alertFirstButtonReturn { removeLook(id: id) }
    }

    private func changeLookLibrary(_ operation: @escaping (LookLibrary) throws -> (selectedID: String?, report: String?)) {
        guard !lookLibraryBusy, !exporting else { return }
        guard let library = lookLibrary else { error = LookLibraryError.invalidRegistry.localizedDescription; return }
        lookLibraryBusy = true
        lookImportReport = nil
        // 与渲染共用串行队列，移除外观时不会删除正在读取的文件。
        queue.async { [weak self] in
            do {
                let change = try operation(library)
                let updated = library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.films = self.films.filter { $0.managedID == nil } + updated
                    self.lookLibraryBusy = false
                    self.error = nil
                    if let selectedID = change.selectedID { self.selectedFilmID = selectedID }
                    else if !self.selectedFilmID.isEmpty && !self.films.contains(where: { $0.id == self.selectedFilmID }) {
                        self.schedule()
                    }
                    self.lookImportReport = change.report
                }
            } catch {
                DispatchQueue.main.async {
                    self?.lookLibraryBusy = false
                    self?.error = error.localizedDescription
                }
            }
        }
    }
    func setInteracting(_ value: Bool) {
        guard scheduler.interacting != value else { return }
        scheduler.setInteracting(value)
        guard file != nil else { refreshBusy(); return }
        if geometryDraft != nil {
            // Focus and crop-only edits reuse the transformed canvas. Transform
            // updates schedule their own exact pass; ending a gesture flushes it.
            if !value && !geometryDraftPreviewReady { schedule(forceExact: true) }
            refreshBusy()
            return
        }
        if value { schedule() } else { schedule(forceExact: true) }
    }
    func schedule() {
        schedule(forceExact: false)
    }
    func updatePreviewLongEdge(_ edge: Int) {
        let edge = min(65535, max(1, edge))
        guard previewLongEdge != edge else { return }
        previewLongEdge = edge
        viewportResizeWork?.cancel()
        viewportResizeWork = nil
        let holdProxy = settings.isDenoiseEnabled && result?.isFullResolution == false && !fullResolution
        if holdProxy {
            // 连续改变布局时沿用当前降噪尺度，停稳后只计算最后一个尺寸。
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.viewportResizeWork = nil
                self.renderPreviewLongEdge = self.previewLongEdge
                self.schedule()
                self.refreshBusy()
            }
            viewportResizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            refreshBusy()
        } else {
            renderPreviewLongEdge = edge
            if !fullResolution || scheduler.interacting { schedule() }
        }
    }
    private func cancelViewportResize() {
        viewportResizeWork?.cancel()
        viewportResizeWork = nil
        renderPreviewLongEdge = previewLongEdge
    }
    private func schedule(forceExact: Bool) {
        guard let file else { return }
        if !settings.isDenoiseEnabled { cancelViewportResize() }
        guard !missingFilm, !missingMasterRecipe else {
            result = nil
            error = missingMasterRecipe ? L10n.text("大师配方外观文件不可用。") : L10n.text("上次使用的外观不可用，请重新选择或导入外观。")
            return
        }
        let preview = geometryPreviewSettings
        let interactive = geometryDraft == nil && scheduler.interacting && !forceExact && preview.geometrySettings.isIdentity
        let effectiveLUT = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
        let work = RenderWork(file: file, settings: preview, lut: effectiveLUT,
                              edge: interactive || !fullResolution ? renderPreviewLongEdge : nil,
                              pass: interactive ? .interactive : .exact,
                              draftEpoch: geometryDraftEpoch, editingGeometry: geometryDraft != nil)
        _ = scheduler.submit(work, fileID: file.standardizedFileURL.path, pass: work.pass)
        busy = true
        error = nil
        if interactive {
            // The serial worker is the throttle while dragging. Start the first
            // preview immediately; later slider events only replace `pending`.
            if !workerActive { launchNextRender() }
        } else {
            debounceTimer?.schedule(deadline: .now() + 0.15, repeating: .never, leeway: .milliseconds(5))
        }
    }

    private func launchNextRender() {
        guard !workerActive, let request = scheduler.startNext() else {
            refreshBusy()
            return
        }
        workerActive = true
        let work = request.value
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                if self.originalCache?.file != work.file {
                    self.originalCache = nil
                    self.geometryReferenceCache = nil
                    if let original = try self.engine!.render(work.file, settings: Adjustments(), lut: nil, edge: nil) {
                        self.originalCache = (work.file, original)
                    }
                }
                let neutral: RenderedImage?
                if work.editingGeometry || work.settings.geometrySettings.isIdentity {
                    neutral = self.originalCache?.frame
                } else if let cached = self.geometryReferenceCache, cached.file == work.file,
                          cached.geometry == work.settings.geometrySettings, cached.lens == work.settings.lensSettings {
                    neutral = cached.frame
                } else {
                    neutral = try self.engine!.render(work.file, settings: work.settings.neutralGeometrySettings,
                                                      lut: nil, edge: nil)
                    if let neutral {
                        self.geometryReferenceCache = (work.file, work.settings.geometrySettings, work.settings.lensSettings, neutral)
                    }
                }
                let result = try self.engine!.render(work.file, settings: work.settings, lut: work.lut,
                                                     edge: work.edge, output: nil,
                                                     interactive: work.pass == .interactive,
                                                     viewportPreview: work.edge != nil)
                DispatchQueue.main.async {
                    self.finish(request, neutral: neutral, result: result, failure: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finish(request, neutral: nil, result: nil, failure: error)
                }
            }
        }
        refreshBusy()
    }

    private func finish(_ request: RenderRequest<RenderWork>, neutral: RenderedImage?, result: RenderedImage?, failure: Error?) {
        workerActive = false
        let completion = scheduler.finish(request)
        let sameFile = request.value.file.standardizedFileURL == file?.standardizedFileURL
        switch completion {
        case .publishInteractive, .publishExact:
            guard sameFile, request.value.draftEpoch == geometryDraftEpoch,
                  !missingFilm, !missingMasterRecipe else { break }
            // 拖动仍可显示较早参数，但窗口尺寸变化后不能发布旧尺寸。
            if completion == .publishInteractive && request.value.edge != renderPreviewLongEdge { break }
            if let failure {
                if completion == .publishExact || scheduler.latest?.id == request.id {
                    self.result = nil
                    self.error = failure.localizedDescription
                }
            } else if let neutral, let result {
                let previousCanvas = geometryCanvasSize
                if !request.value.editingGeometry { pendingGeometryPresentation = nil }
                self.neutral = neutral
                self.result = result
                if let draft = geometryDraft,
                   request.value.settings.geometrySettings == draft.previewGeometry,
                   request.value.settings.lensSettings == draft.lens {
                    // A new orientation/perspective/lens canvas can change its
                    // physical aspect. Keep the user's chosen ratio in that canvas.
                    if previousCanvas != geometryCanvasSize, let ratio = cropAspectRatio {
                        let rect = CropInteraction.dragging(CropInteraction.rect(from: draft.geometry), handle: .bottomRight,
                            translation: .zero, canvasSize: geometryCanvasSize, ratio: ratio)
                        updateGeometryDraft { $0 = CropInteraction.applying(rect: rect, to: $0) }
                    }
                    geometryDraftPreviewReady = true
                }
                updatingMetadata = true
                settings.resolveWhiteBalance(result.asShotWhiteBalance)
                settings.resolveRawNoiseReductionSupport(result.supportsRawNoiseReduction)
                updatingMetadata = false
                if completion == .publishInteractive {
                    statusState = .interactive(result.image.width, result.image.height)
                } else {
                    statusState = .preview(result.image.width, result.image.height, original: request.value.edge == nil)
                }
            }
        case .discard, .ignored:
            break
        }
        launchNextRender()
        refreshBusy()
    }

    private func refreshBusy() {
        busy = workerActive || scheduler.isBusy || viewportResizeWork != nil
    }
    func export(png: Bool) {
        export(format: png ? .png : .jpeg)
    }

    func export(format: ExportFormat) {
        guard !busy, !exporting, !lookLibraryBusy, !missingFilm, !missingMasterRecipe, result != nil, geometryDraft == nil, let file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let lookName = settings.masterRecipe?.name ?? selectedFilm?.name ?? "neutral"
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" +
            lookName + "." + format.suffix
        let sizePicker = NSHostingView(rootView: ExportSizeAccessory(model: self).padding(12).frame(width: 360))
        sizePicker.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        panel.accessoryView = sizePicker
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        let settings = settings, lut = settings.masterRecipe?.lutURL() ?? selectedFilm?.url, longEdge = exportLongEdge
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                _ = try self.engine!.render(file, settings: settings, lut: lut, edge: nil, output: output,
                                             interactive: false, exportLongEdge: longEdge)
                DispatchQueue.main.async { self.exporting = false; self.statusState = .exported(output.lastPathComponent) }
            } catch {
                DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription }
            }
        }
    }
}
