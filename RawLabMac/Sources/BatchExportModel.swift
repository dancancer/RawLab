import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class BatchCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

final class BatchExportModel: ObservableObject {
    @Published private(set) var job: BatchExportJob
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published var error: String?
    @Published private(set) var preview: RenderedImage?
    @Published private(set) var previewing = false
    @Published private(set) var validating = false
    @Published var previewFile: URL?
    var onActivity: (Bool) -> Void = { _ in }
    var onDiscard: () -> Void = { }
    private let journal: BatchJournal
    private let queue = DispatchQueue(label: "rawlab.batch", qos: .userInitiated)
    private var engine: RenderEngine?
    private var cancellation = BatchCancellation()
    private var previewRevision = UUID()

    init(job: BatchExportJob, journal: BatchJournal) {
        self.job = job
        self.journal = journal
        error = job.failure
    }

    var canRun: Bool { !running && !validating && job.selectedCount > 0 && job.outputDirectory != nil }
    var title: String {
        if stopping { return "正在停止…" }
        if running { return "正在导出" }
        if job.interrupted { return "导出已中断" }
        if job.cancelled { return "导出已取消" }
        return job.started ? "导出完成" : "批量导出"
    }
    var summary: String {
        if !job.started { return "已选 \(job.selectedCount) 张" }
        return "成功 \(job.succeededCount) 张 · 失败 \(job.failedCount) 张 · 未处理 \(job.remainingCount) 张"
    }

    func addFiles() {
        guard !running, !job.started, !validating else { return }
        let panel = NSOpenPanel()
        panel.title = "选择待导出的 RAW 照片"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DirectoryContents.rawExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        guard !running, !job.started, !validating else { return }
        var failures: [String] = []
        var added: [BatchExportItem] = []
        for url in urls {
            do {
                guard DirectoryContents.rawExtensions.contains(url.pathExtension.lowercased()) else {
                    throw RenderError.failed("不是支持的 RAW 文件")
                }
                var item = try BatchExportItem(url: url)
                item.selected = true
                if let index = job.items.firstIndex(where: { $0.input == item.input }) {
                    job.items[index].selected = true
                } else { job.items.append(item) }
                added.append(item)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        saveDraft()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        guard !added.isEmpty else { return }
        validating = true
        let candidates = added
        queue.async { [self] in
            for item in candidates {
                var failure: String?
                do {
                    if engine == nil { engine = try RenderEngine() }
                    _ = try engine!.render(item.input, settings: Adjustments(), lut: nil, edge: 180, interactive: true)
                } catch { failure = error.localizedDescription }
                let message = failure
                DispatchQueue.main.async {
                    if let message, let index = self.job.items.firstIndex(where: { $0.input == item.input }) {
                        self.job.items[index].validationError = message
                        self.job.items[index].selected = false
                    }
                }
            }
            DispatchQueue.main.async { self.validating = false; self.saveDraft() }
        }
    }

    func select(_ id: UUID, _ value: Bool) {
        guard !running, !job.started, let index = job.items.firstIndex(where: { $0.id == id }) else { return }
        guard !validating, job.items[index].validationError == nil else { return }
        job.items[index].selected = value
        saveDraft()
    }

    func selectAll(_ selected: Bool) {
        guard !running, !job.started, !validating else { return }
        for index in job.items.indices { job.items[index].selected = selected && job.items[index].validationError == nil }
        saveDraft()
    }

    func remove(_ id: UUID) {
        guard !running, !job.started else { return }
        job.items.removeAll { $0.id == id }
        saveDraft()
    }

    func chooseDirectory() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = job.outputDirectory
        if panel.runModal() == .OK { job.outputDirectory = panel.url; saveDraft() }
    }

    func setPNG(_ value: Bool) {
        guard !running, !job.started else { return }
        job.png = value; saveDraft()
    }

    func setLongEdge(_ value: Int?) {
        guard !running, !job.started, value == nil || (1...65535).contains(value!) else { return }
        job.longEdge = value; saveDraft()
    }

    private func saveDraft() {
        do { try journal.save(job); error = nil }
        catch { self.error = "任务未保存：\(error.localizedDescription)" }
    }

    func start(_ scope: BatchRunScope = .unfinished) {
        guard canRun else { return }
        let cancellation = BatchCancellation()
        self.cancellation = cancellation
        error = nil; running = true; stopping = false
        onActivity(true)
        let snapshot = job
        queue.async { [self] in
            var work = snapshot
            var failure: String?
            do {
                try BatchExportRunner.run(job: &work, journal: journal, scope: scope,
                                         shouldCancel: { cancellation.cancelled }, didUpdate: { updated in
                    DispatchQueue.main.async { self.job = updated }
                }) { input, settings, look, output in
                    if self.engine == nil { self.engine = try RenderEngine() }
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: 32)
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: nil, output: output, exportLongEdge: snapshot.longEdge)
                }
            } catch { failure = error.localizedDescription; work.interrupted = true }
            let final = work, message = failure
            DispatchQueue.main.async {
                self.job = final; self.error = message
                self.running = false; self.stopping = false
                self.onActivity(false)
            }
        }
    }

    func cancel() {
        guard running else { return }
        stopping = true; cancellation.cancel()
    }

    func discardDraft() -> Bool {
        guard !running, !validating, !previewing, !job.started else { return false }
        do { try journal.discard(job); onDiscard(); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func inspect(_ item: BatchExportItem) {
        guard !running else { return }
        let revision = UUID()
        previewRevision = revision; previewFile = item.input; preview = nil; previewing = true; error = nil
        let settings = job.settings, look = job.look
        queue.async { [self] in
            let result = Result { () -> RenderedImage? in
                guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
                if engine == nil { engine = try RenderEngine() }
                return try engine!.render(item.input, settings: settings, lut: look, edge: 1600)
            }
            DispatchQueue.main.async {
                guard self.previewRevision == revision else { return }
                self.previewing = false
                switch result {
                case .success(let image): self.preview = image
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }

    func reveal(_ output: URL? = nil) {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else if let directory = job.outputDirectory { NSWorkspace.shared.open(directory) }
    }
}
