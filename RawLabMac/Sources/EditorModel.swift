import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    struct AISnapshot {
        let file: URL
        let identity: OriginalFileIdentity
        let state: PhotoEditState
        let look: URL?
        let lookName: String
        let lookIdentity: OriginalFileIdentity?
        let revision: UInt64

        init(file: URL, state: PhotoEditState, look: URL?, lookName: String, revision: UInt64) throws {
            self.file = file.standardizedFileURL
            identity = try OriginalFileIdentity(file)
            self.state = state; self.look = look; self.lookName = lookName; self.revision = revision
            lookIdentity = try look.map { try OriginalFileIdentity($0) }
        }

        func matches(file: URL?, state: PhotoEditState, revision: UInt64) -> Bool {
            guard file?.standardizedFileURL == self.file, state == self.state, revision == self.revision,
                  (try? OriginalFileIdentity(self.file)) == identity else { return false }
            if let look { return (try? OriginalFileIdentity(look)) == lookIdentity }
            return true
        }
    }

    private struct RenderWork: Equatable {
        let file: URL
        let settings: Adjustments
        let lut: URL?
        let edge: Int?
        let pass: RenderPass
    }

    @Published var settings = Adjustments() { didSet { if !updatingMetadata && oldValue != settings { edited() } } }
    private var updatingMetadata = false
    @Published var films = Film.bundled()
    @Published var selectedFilmID = "" { didSet { if !updatingMetadata { edited() } } }
    @Published var fullResolution = false { didSet { schedule() } }
    @Published private(set) var file: URL?
    @Published private(set) var neutral: RenderedImage?
    @Published private(set) var result: RenderedImage?
    @Published private(set) var busy = false
    @Published private(set) var exporting = false
    @Published private(set) var lookLibraryBusy = false
    @Published var error: String?
    @Published var lookImportReport: String?
    @Published private(set) var status = ""
    @Published private(set) var saveStatus = ""
    @Published private(set) var saveError: String?
    @Published private(set) var batch: BatchExportModel?
    @Published var exportLongEdge: Int?
    @Published private(set) var canRestoreAI = false
    private var aiRestorePoint: AISnapshot?
    private var editRevision: UInt64 = 0
    private let queue = DispatchQueue(label: "rawlab.render", qos: .userInitiated)
    private let debounceQueue = DispatchQueue(label: "rawlab.render.debounce", qos: .userInitiated)
    private var scheduler = RenderScheduler<RenderWork>()
    private var debounceTimer: DispatchSourceTimer?
    private var workerActive = false
    private var engine: RenderEngine?
    // 仅在串行渲染队列读写；原图不随编辑参数或预览尺寸重新生成。
    private var originalCache: (file: URL, frame: RenderedImage)?
    private var editStore: EditPersistence?
    private let editDirectory: URL
    private let batchJournal: BatchJournal
    private var saveWork: DispatchWorkItem?
    private var dirty = false
    private var lookLibrary: LookLibrary?
    var selectedFilm: Film? { films.first { $0.id == selectedFilmID } }
    var missingFilm: Bool { !selectedFilmID.isEmpty && (selectedFilm == nil || !FileManager.default.isReadableFile(atPath: selectedFilm!.url.path)) }
    var canApplySettings: Bool { file != nil && result != nil && !busy && !exporting && !lookLibraryBusy && !missingFilm }

    init(lookDirectory: URL = LookLibrary.defaultDirectory,
         editDirectory: URL = EditPersistence.defaultDirectory,
         batchDirectory: URL = BatchJournal.defaultDirectory) {
        self.editDirectory = editDirectory
        batchJournal = BatchJournal(directory: batchDirectory)
        do {
            let library = try LookLibrary(directory: lookDirectory)
            lookLibrary = library
            films += library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id, isAI: $0.aiGenerated == true) }
        } catch {
            self.error = error.localizedDescription
        }
        selectedFilmID = films.first(where: { $0.name == "PROVIA" })?.id ?? films.first?.id ?? ""
        do { editStore = try EditPersistence(directory: editDirectory) }
        catch { saveError = "无法读取调整记录：\(error.localizedDescription)" }
        do {
            if let job = try batchJournal.load() { attachBatch(job) }
        } catch { self.error = "无法读取上次批量任务：\(error.localizedDescription)" }
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.launchNextRender() }
        }
        timer.resume()
        debounceTimer = timer
    }
    deinit { debounceTimer?.cancel(); saveWork?.cancel() }

    private func edited() {
        guard file != nil else { return }
        editRevision &+= 1
        dirty = true
        saveStatus = ""
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
            let filmID = selectedFilm.map { film in
                film.managedID ?? "builtin:\(film.url.lastPathComponent)"
            } ?? selectedFilmID
            try editStore!.save(file, state: PhotoEditState(settings: settings, filmID: filmID))
            dirty = false; saveError = nil; saveStatus = "调整已保存"
            clearSaveStatusLater()
            return true
        } catch {
            saveError = "调整未保存：\(error.localizedDescription)"
            return false
        }
    }

    private func clearSaveStatusLater() {
        let message = saveStatus
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.saveStatus == message { self?.saveStatus = "" }
        }
    }

    @discardableResult func applyCurrentSettings(to urls: [URL]) throws -> Int {
        guard file != nil, !exporting, !lookLibraryBusy, !missingFilm else {
            throw RenderError.failed("当前照片的设置尚不可用。")
        }
        let targets = Array(Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
        guard !targets.isEmpty else { return 0 }
        let filmID = selectedFilm.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? selectedFilmID
        if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
        try editStore!.save(targets, state: PhotoEditState(settings: settings, filmID: filmID))
        status = "已将当前设置应用到 \(targets.count) 张照片"
        return targets.count
    }

    func confirmApplySettings(to url: URL, directory: Bool) {
        guard canApplySettings else { return }
        do {
            let targets = directory ? try DirectoryContents.read(url).photos : [url]
            guard !targets.isEmpty else { throw RenderError.failed("此目录没有 RAW 照片。") }
            let alert = NSAlert()
            alert.messageText = "应用当前设置到 \(targets.count) 张照片？"
            alert.informativeText = "将替换目标照片的本机调整记录，不改写原始 RAW。" +
                (directory ? "仅包含此目录中的 RAW，不包含子目录。" : "")
            alert.addButton(withTitle: "应用当前设置"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { try applyCurrentSettings(to: targets) }
        } catch { self.error = error.localizedDescription }
    }

    func prepareBatch() -> Bool {
        guard !busy, !exporting, !lookLibraryBusy, result != nil, !missingFilm, let file else { return false }
        if batch?.validating == true || batch?.previewing == true { return true }
        if let batch, batch.job.started && batch.job.succeededCount < batch.job.selectedCount {
            let alert = NSAlert()
            alert.messageText = "上次批量任务尚未完成"
            alert.informativeText = "继续查看上次任务，或保留已导出文件并新建任务。"
            alert.addButton(withTitle: "查看任务"); alert.addButton(withTitle: "新建任务")
            if alert.runModal() == .alertFirstButtonReturn { return true }
        }
        do {
            if let batch { try batchJournal.discard(batch.job) }
            var job = BatchExportJob(source: file, settings: settings, look: nil, lookName: selectedFilm?.name ?? "中性")
            job.longEdge = exportLongEdge
            job.look = try batchJournal.snapshotLook(selectedFilm?.url, for: job.id)
            try batchJournal.save(job)
            attachBatch(job)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func attachBatch(_ job: BatchExportJob) {
        let model = BatchExportModel(job: job, journal: batchJournal)
        model.onActivity = { [weak self] active in self?.exporting = active }
        model.onDiscard = { [weak self] in self?.batch = nil }
        batch = model
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "打开 RAW 照片"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !exporting else { return }
        if file == url && result != nil { return }
        guard saveEdits() else { return }
        editRevision &+= 1
        aiRestorePoint = nil; canRestoreAI = false
        scheduler.setInteracting(false)
        var restored: PhotoEditState?
        do { restored = try editStore?.state(for: url) }
        catch { saveError = "无法恢复调整：\(error.localizedDescription)" }
        file = url; neutral = nil; result = nil; error = nil; status = ""
        updatingMetadata = true
        settings = restored?.settings ?? Adjustments()
        let filmID = restored?.filmID ?? films.first(where: { $0.name == "PROVIA" })?.id ?? ""
        selectedFilmID = films.first(where: { $0.id == filmID || "builtin:\($0.url.lastPathComponent)" == filmID })?.id ?? filmID
        updatingMetadata = false
        dirty = false
        saveStatus = restored == nil ? "" : "已恢复上次调整"
        clearSaveStatusLater()
        schedule()
    }
    func importLUT() {
        guard !lookLibraryBusy, !exporting else { return }
        let panel = NSOpenPanel()
        panel.title = "导入外观"
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
                "已导入 \(imported) 个外观，\(failures.count) 个文件导入失败：\n" + failures.joined(separator: "\n")
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
        alert.messageText = "重命名外观"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: film.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { renameLook(id: id, name: field.stringValue) }
    }

    func removeLookPanel(_ film: Film) {
        guard let id = film.managedID, !lookLibraryBusy, !exporting else { return }
        let alert = NSAlert()
        alert.messageText = "移除“\(film.name)”？"
        alert.informativeText = "将移除 RawLab 保存的外观副本，原始文件不会被删除。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
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
                let updated = library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id, isAI: $0.aiGenerated == true) }
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
    var canStartAI: Bool { file != nil && result != nil && !busy && !exporting && !lookLibraryBusy && !missingFilm }

    @MainActor func freezeAIEdit() throws -> AISnapshot {
        guard canStartAI, let file else { throw RenderError.failed("请等待照片完成精确预览后再仿色。") }
        guard saveEdits() else { throw RenderError.failed("请先保存当前调整，再开始 AI 仿色。") }
        return try AISnapshot(file: file, state: PhotoEditState(settings: settings, filmID: selectedFilmID),
                              look: selectedFilm?.url, lookName: selectedFilm?.name ?? "中性", revision: editRevision)
    }

    @MainActor func isCurrentAIEdit(_ snapshot: AISnapshot) -> Bool {
        snapshot.matches(file: file, state: PhotoEditState(settings: settings, filmID: selectedFilmID), revision: editRevision)
    }

    @MainActor func applyAILook(_ source: URL, name: String, strength: Double, snapshot: AISnapshot) async throws {
        guard !exporting, !lookLibraryBusy, isCurrentAIEdit(snapshot), strength.isFinite, (0...2).contains(strength),
              let library = lookLibrary else { throw RenderError.failed("照片或调整已变化，请关闭面板后重新生成。") }
        let builtinFilms = films.filter { $0.managedID == nil }
        lookLibraryBusy = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async(execute: DispatchWorkItem {
                do {
                    let look = try library.importLook(from: source, name: name)
                    let updated = builtinFilms + library.looks.map {
                        Film(name: $0.name, url: library.url(for: $0), managedID: $0.id, isAI: $0.aiGenerated == true)
                    }
                    DispatchQueue.main.async {
                        do {
                            guard self.isCurrentAIEdit(snapshot), !self.exporting else {
                                throw RenderError.failed("照片或调整已变化，AI 外观没有应用。")
                            }
                            var settings = snapshot.state.settings.aiBaseline; settings.strength = strength
                            try self.commitAIState(PhotoEditState(settings: settings, filmID: look.id), films: updated)
                            self.aiRestorePoint = snapshot; self.canRestoreAI = true
                            self.lookLibraryBusy = false
                            continuation.resume()
                        } catch {
                            self.queue.async(execute: DispatchWorkItem {
                                try? library.remove(id: look.id)
                                DispatchQueue.main.async {
                                    self.lookLibraryBusy = false
                                    continuation.resume(throwing: error)
                                }
                            })
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.lookLibraryBusy = false
                        continuation.resume(throwing: error)
                    }
                }
            })
        }
    }

    @MainActor private func commitAIState(_ state: PhotoEditState, films updated: [Film]) throws {
        guard let file else { throw RenderError.failed("当前照片不可用。") }
        if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
        let film = updated.first { $0.id == state.filmID }
        let persistedID = film.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? state.filmID
        try editStore!.save(file, state: PhotoEditState(settings: state.settings, filmID: persistedID))
        saveWork?.cancel(); dirty = false
        updatingMetadata = true
        films = updated; settings = state.settings; selectedFilmID = state.filmID
        updatingMetadata = false
        editRevision &+= 1
        saveError = nil; saveStatus = "调整已保存"; clearSaveStatusLater()
        schedule()
    }

    @MainActor func restoreAIEdit() throws {
        guard let snapshot = aiRestorePoint, file?.standardizedFileURL == snapshot.file,
              !busy, !exporting, !lookLibraryBusy,
              (try? OriginalFileIdentity(snapshot.file)) == snapshot.identity else {
            throw RenderError.failed("当前无法恢复 AI 仿色前的调整。")
        }
        if let look = snapshot.look {
            guard (try? OriginalFileIdentity(look)) == snapshot.lookIdentity,
                  films.contains(where: { $0.id == snapshot.state.filmID }) else {
                throw RenderError.failed("仿色前的外观已被移除或更改，无法恢复。")
            }
        }
        try commitAIState(snapshot.state, films: films)
        aiRestorePoint = nil; canRestoreAI = false
    }

    @MainActor func restoreAIEditPanel() {
        let alert = NSAlert()
        alert.messageText = "恢复 AI 仿色前的调整？"
        alert.informativeText = "本次 AI 应用后的手动调整也会被替换，原始照片不会改变。"
        alert.addButton(withTitle: "恢复调整"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try restoreAIEdit() } catch { self.error = error.localizedDescription }
    }

    func setInteracting(_ value: Bool) {
        guard scheduler.interacting != value else { return }
        scheduler.setInteracting(value)
        guard file != nil else { refreshBusy(); return }
        if value { schedule() } else { schedule(forceExact: true) }
    }
    func schedule() {
        schedule(forceExact: false)
    }
    private func schedule(forceExact: Bool) {
        guard let file else { return }
        guard !missingFilm else {
            result = nil
            error = "上次使用的外观不可用，请重新选择或导入外观。"
            return
        }
        let interactive = scheduler.interacting && !forceExact
        let work = RenderWork(file: file, settings: settings, lut: selectedFilm?.url,
                              edge: interactive ? 1000 : (fullResolution ? nil : 2000),
                              pass: interactive ? .interactive : .exact)
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
                    if let original = try self.engine!.render(work.file, settings: Adjustments(), lut: nil, edge: nil) {
                        self.originalCache = (work.file, original)
                    }
                }
                let neutral = self.originalCache?.frame
                let result = try self.engine!.render(work.file, settings: work.settings, lut: work.lut,
                                                     edge: work.edge, output: nil,
                                                     interactive: work.pass == .interactive)
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
            guard sameFile, !missingFilm else { break }
            if let failure {
                if completion == .publishExact || scheduler.latest?.id == request.id {
                    self.result = nil
                    self.error = failure.localizedDescription
                }
            } else if let neutral, let result {
                self.neutral = neutral
                self.result = result
                updatingMetadata = true
                settings.resolveWhiteBalance(result.asShotWhiteBalance)
                settings.resolveRawNoiseReductionSupport(result.supportsRawNoiseReduction)
                updatingMetadata = false
                if completion == .publishInteractive {
                    status = "交互预览… \(result.image.width) × \(result.image.height) · sRGB"
                } else {
                    status = "\(request.value.edge == nil ? "原尺寸" : "预览") \(result.image.width) × \(result.image.height) · sRGB"
                }
            }
        case .discard, .ignored:
            break
        }
        launchNextRender()
        refreshBusy()
    }

    private func refreshBusy() {
        busy = workerActive || scheduler.isBusy
    }
    func export(png: Bool) {
        guard !busy, !exporting, !lookLibraryBusy, !missingFilm, result != nil, let file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [png ? .png : .jpeg]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" +
            (selectedFilm?.name ?? "neutral") + (png ? ".png" : ".jpg")
        let sizePicker = NSHostingView(rootView: ExportSizeAccessory(model: self).padding(12).frame(width: 360))
        sizePicker.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        panel.accessoryView = sizePicker
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        let settings = settings, lut = selectedFilm?.url, longEdge = exportLongEdge
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                _ = try self.engine!.render(file, settings: settings, lut: lut, edge: nil, output: output,
                                             interactive: false, exportLongEdge: longEdge)
                DispatchQueue.main.async { self.exporting = false; self.status = "已导出：\(output.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription }
            }
        }
    }
}
