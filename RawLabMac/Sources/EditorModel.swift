import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class EditorModel: ObservableObject {
    private struct RenderWork: Equatable {
        let file: URL
        let settings: Adjustments
        let lut: URL?
        let edge: Int?
        let pass: RenderPass
    }

    @Published var settings = Adjustments() { didSet { if !updatingMetadata { schedule() } } }
    private var updatingMetadata = false
    @Published var films = Film.bundled()
    @Published var selectedFilmID = "" { didSet { schedule() } }
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
    private let queue = DispatchQueue(label: "rawlab.render", qos: .userInitiated)
    private let debounceQueue = DispatchQueue(label: "rawlab.render.debounce", qos: .userInitiated)
    private var scheduler = RenderScheduler<RenderWork>()
    private var debounceTimer: DispatchSourceTimer?
    private var workerActive = false
    private var engine: RenderEngine?
    private var editSession = PhotoEditSession()
    private var lookLibrary: LookLibrary?
    var selectedFilm: Film? { films.first { $0.id == selectedFilmID } }

    init(lookDirectory: URL = LookLibrary.defaultDirectory) {
        do {
            let library = try LookLibrary(directory: lookDirectory)
            lookLibrary = library
            films += library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
        } catch {
            self.error = error.localizedDescription
        }
        selectedFilmID = films.first(where: { $0.name == "PROVIA" })?.id ?? films.first?.id ?? ""
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.launchNextRender() }
        }
        timer.resume()
        debounceTimer = timer
    }
    deinit { debounceTimer?.cancel() }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "打开 RAW 照片"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !exporting else { return }
        if file == url && result != nil { return }
        scheduler.setInteracting(false)
        if let file { editSession.save(file, settings: settings, filmID: selectedFilmID) }
        let restored = editSession.state(for: url,
            defaultFilmID: films.first(where: { $0.name == "PROVIA" })?.id ?? "")
        file = url; neutral = nil; result = nil; error = nil; status = ""
        settings = restored.settings
        selectedFilmID = films.contains(where: { $0.id == restored.filmID }) ? restored.filmID : ""
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
                let updated = library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.films = self.films.filter { $0.managedID == nil } + updated
                    self.lookLibraryBusy = false
                    if let selectedID = change.selectedID { self.selectedFilmID = selectedID }
                    else if !self.selectedFilmID.isEmpty && !self.films.contains(where: { $0.id == self.selectedFilmID }) {
                        self.selectedFilmID = ""
                    }
                    self.error = nil
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
        if value { schedule() } else { schedule(forceExact: true) }
    }
    func schedule() {
        schedule(forceExact: false)
    }
    private func schedule(forceExact: Bool) {
        guard let file else { return }
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
                let neutral = try self.engine!.render(work.file, settings: work.settings, lut: nil,
                                                       edge: work.edge, output: nil,
                                                       interactive: work.pass == .interactive)
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
            guard sameFile else { break }
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
        guard !busy, !exporting, !lookLibraryBusy, result != nil, let file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [png ? .png : .jpeg]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" +
            (selectedFilm?.name ?? "neutral") + (png ? ".png" : ".jpg")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        let settings = settings, lut = selectedFilm?.url
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                _ = try self.engine!.render(file, settings: settings, lut: lut, edge: nil, output: output,
                                             interactive: false)
                DispatchQueue.main.async { self.exporting = false; self.status = "已导出：\(output.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription }
            }
        }
    }
}
