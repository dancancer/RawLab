import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class BatchCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    private var progress: AIPreparation?
    func attach(_ progress: AIPreparation?) {
        lock.lock(); self.progress = progress; let cancelled = value; lock.unlock()
        if cancelled { progress?.cancel() }
    }
    func cancel() { lock.lock(); value = true; let progress = progress; lock.unlock(); progress?.cancel() }
}

final class BatchExportModel: ObservableObject {
    @Published private(set) var job: BatchExportJob
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published var error: String?
    @Published private(set) var preview: RenderedImage?
    @Published private(set) var previewing = false
    @Published private(set) var validating = false
    private(set) var updateJournalFailed = false
    @Published var previewFile: URL?
    @Published var sourceEditingGeometry = false
    var onActivity: (Bool) -> Void = { _ in }
    var onDiscard: () -> Void = { }
    private let journal: BatchJournal
    private let queue = DispatchQueue(label: "rawlab.batch", qos: .userInitiated)
    private var engine: RenderEngine?
    private var cancellation = BatchCancellation()
    private var previewRevision = UUID()
    private let onUsage: (UsageEvent) -> Void

    init(job: BatchExportJob, journal: BatchJournal, onUsage: @escaping (UsageEvent) -> Void = { _ in }) {
        self.job = job
        self.journal = journal
        self.onUsage = onUsage
        error = job.failure
    }

    var canRun: Bool { !running && !validating && (job.mode == .perTargetFrozen || !sourceEditingGeometry) && job.selectedCount > 0 && job.outputDirectory != nil }
    var title: String {
        if stopping { return L10n.text("正在停止…") }
        if running { return L10n.text("正在导出") }
        if job.interrupted { return L10n.text("导出已中断") }
        if job.cancelled { return L10n.text("导出已取消") }
        return job.started ? L10n.text("导出完成") : L10n.text("批量导出")
    }
    var summary: String {
        if !job.started { return L10n.format("已选 %@ 张", String(describing: job.selectedCount)) }
        return L10n.format("成功 %@ 张 · 失败 %@ 张 · 未处理 %@ 张", String(describing: job.succeededCount), String(describing: job.failedCount), String(describing: job.remainingCount))
    }

    func addFiles() {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择待导出的照片")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        var failures: [String] = []
        var added: [BatchExportItem] = []
        for url in urls {
            do {
                guard DirectoryContents.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw RenderError.failed(L10n.text("不是支持的图像文件"))
                }
                var item = try BatchExportItem(url: url)
                item.selected = true
                if let index = job.items.firstIndex(where: { $0.input == item.input }) {
                    job.items[index].selected = true
                } else { job.items.append(item) }
                added.append(item)
            } catch { failures.append(L10n.format("%@：%@", url.lastPathComponent, error.localizedDescription)) }
        }
        saveDraft()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        guard !added.isEmpty else { return }
        validating = true
        let candidates = added
        let validationJob = job
        queue.async { [self] in
            for item in candidates {
                var failure: String?
                do {
                    if engine == nil { engine = try RenderEngine() }
                    let snapshot = try validationJob.snapshot(for: item)
                    if snapshot.settings.aiDenoiseEnabled {
                        try engine!.prepareAI(item.input, settings: snapshot.settings, progress: AIPreparation { _, _, _ in })
                    }
                    _ = try engine!.render(item.input, settings: snapshot.settings, lut: snapshot.look, edge: 180, interactive: true)
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
        guard job.mode == .uniformFrozen, !running, !job.started, let index = job.items.firstIndex(where: { $0.id == id }) else { return }
        guard !validating, job.items[index].validationError == nil else { return }
        job.items[index].selected = value
        saveDraft()
    }

    func selectAll(_ selected: Bool) {
        guard job.mode == .uniformFrozen, !running, !job.started, !validating else { return }
        for index in job.items.indices { job.items[index].selected = selected && job.items[index].validationError == nil }
        saveDraft()
    }

    func remove(_ id: UUID) {
        guard job.mode == .uniformFrozen, !running, !job.started else { return }
        job.items.removeAll { $0.id == id }
        saveDraft()
    }

    func chooseDirectory() {
        guard job.mode == .uniformFrozen, !running else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择输出文件夹")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = job.outputDirectory
        if panel.runModal() == .OK { job.outputDirectory = panel.url; saveDraft() }
    }

    func setFormat(_ value: ExportFormat) {
        guard job.mode == .uniformFrozen, !running, !job.started else { return }
        job.format = value; saveDraft()
    }

    func setLongEdge(_ value: Int?) {
        guard job.mode == .uniformFrozen, !running, !job.started, value == nil || (1...65535).contains(value!) else { return }
        job.longEdge = value; saveDraft()
    }

    private func saveDraft() {
        do { try journal.save(job); error = nil; updateJournalFailed = false }
        catch { updateJournalFailed = true; self.error = L10n.format("任务未保存：%@", String(describing: error.localizedDescription)) }
    }

    func prepareForUpdate() -> Bool {
        guard !running, !stopping, !validating, !previewing else { return false }
        saveDraft()
        return !updateJournalFailed
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
            var attempted = Set<UUID>()
            do {
                try BatchExportRunner.run(job: &work, journal: journal, scope: scope,
                                         shouldCancel: { cancellation.cancelled }, didUpdate: { updated in
                    attempted.formUnion(updated.items.filter { $0.status == .running }.map(\.id))
                    DispatchQueue.main.async { self.job = updated }
                }) { input, settings, look, output in
                    if self.engine == nil { self.engine = try RenderEngine() }
                    if settings.aiDenoiseEnabled {
                        let progress = AIPreparation { _, _, _ in }
                        cancellation.attach(progress)
                        defer { cancellation.attach(nil) }
                        try self.engine!.prepareAI(input, settings: settings, progress: progress)
                    }
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: 32)
                    let item = snapshot.items.first { $0.input == input }!
                    let longEdge = try snapshot.snapshot(for: item).longEdge
                    _ = try self.engine!.render(input, settings: settings, lut: look, edge: nil, output: output, exportLongEdge: longEdge)
                }
            } catch { failure = error.localizedDescription; work.interrupted = true }
            let final = work, message = failure
            let succeeded = max(0, final.succeededCount - snapshot.succeededCount)
            let failed = final.items.filter { attempted.contains($0.id) && $0.status == .failed }.count
            let outcome: UsageBatchOutcome = final.interrupted ? .interrupted : final.cancelled ? .cancelled : failed > 0 ? .partial : .completed
            DispatchQueue.main.async {
                self.job = final; self.error = message
                self.running = false; self.stopping = false
                self.onActivity(false)
                self.onUsage(.batchExportCompleted(succeeded: succeeded, failed: failed, outcome: outcome))
            }
        }
    }

    func cancel() {
        guard running else { return }
        stopping = true; cancellation.cancel()
    }

    func discardDraft() -> Bool {
        guard !job.started else { return false }
        return discardTask()
    }

    func discardTask() -> Bool {
        guard !running, !validating, !previewing else { return false }
        do { try journal.discard(job); onDiscard(); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func inspect(_ item: BatchExportItem) {
        guard !running else { return }
        let revision = UUID()
        previewRevision = revision; previewFile = item.input; preview = nil; previewing = true; error = nil
        let frozenJob = job
        queue.async { [self] in
            let result = Result { () -> RenderedImage? in
                try frozenJob.validate()
                let snapshot = try frozenJob.snapshot(for: item)
                guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
                if frozenJob.mode == .perTargetFrozen {
                    guard try BatchExportItem.resourceKey(item.input) == item.resourceIdentifier else { throw BatchExportFailure.changedInput }
                    try snapshot.verifyLook()
                }
                if engine == nil { engine = try RenderEngine() }
                if snapshot.settings.aiDenoiseEnabled {
                    try engine!.prepareAI(item.input, settings: snapshot.settings, progress: AIPreparation { _, _, _ in })
                }
                return try engine!.render(item.input, settings: snapshot.settings, lut: snapshot.look, edge: 1600)
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
