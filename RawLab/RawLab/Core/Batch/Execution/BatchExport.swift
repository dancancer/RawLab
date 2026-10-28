import Photos
import PhotosUI
import SwiftUI
import UIKit

final class BatchExportModel: ObservableObject {
    typealias JPEGWriter = (Data, String, BatchTarget, (String) throws -> Void) throws -> Void

    @Published private(set) var job: BatchExportJob
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isStopping = false
    @Published private(set) var isReady = false
    @Published private(set) var fileExportURLs: [URL]?
    @Published private(set) var fileExportStatus: FileExportStatus = .none
    @Published var shouldPresentFileExport = false
    @Published var validationMessage: String?
    var onDiscard: () -> Void = { }
    var onUsage: (UsageEvent) -> Void = { _ in }

    private let journalStore: BatchJournalStore?
    private let jpegWriter: JPEGWriter?
    let queue = DispatchQueue(label: "com.rawlab.batch", qos: .userInitiated)
    private let cancellation = NSLock()
    private var didCancel = false
    private var backgroundInterruption = false
    private(set) var hdrPreparation: IOSHDRBatchPreparation?

    enum FileExportStatus: Equatable {
        case none
        case pending
        case exported
        case cancelled
    }

    init(source: BatchSourceSnapshot, editor: RawEditorViewModel) {
        var source = source
        source.lookName = source.settings.masterRecipe?.name ?? editor.availableLUTs.first { $0.id == source.settings.lutID }?.name ?? "中性"
        job = BatchExportJob(source: source, targets: [])
        jpegWriter = nil
        do { journalStore = try BatchJournalStore.appStore() }
        catch { journalStore = nil; validationMessage = L10n.format("任务未保存：%@", String(describing: error.localizedDescription)) }
        if source.settings.isHDREditing {
            job.outputFormat = .hdrJPEG
            hdrPreparation=IOSHDRBatchPreparation(source:source,editor:editor)
        }
        guard let journalStore else { return }
        let look = editor.lutURL(for: source.settings)
        var snapshot = job
        isPreparing = true
        queue.async { [weak self] in
            do {
                try BatchInputStore.prepare(&snapshot, look: look, root: journalStore.directory)
                try journalStore.save(snapshot)
                let prepared = snapshot
                DispatchQueue.main.async { self?.job = prepared; self?.isPreparing = false; self?.isReady = true }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.validationMessage = message; self?.isPreparing = false }
            }
        }
    }

    init(job: BatchExportJob, journalStore: BatchJournalStore, jpegWriter: JPEGWriter? = nil,editor: RawEditorViewModel? = nil) {
        let recovered = job.outputFormat == .renderedDNG
            ? job.recovered()
            : job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
        self.job = recovered
        self.journalStore = journalStore
        self.jpegWriter = jpegWriter
        if job.source.settings.isHDREditing,let editor { hdrPreparation=IOSHDRBatchPreparation(source:job.source,editor:editor) }
        isReady = true
        validationMessage = recovered.globalError
        if recovered.outputFormat == .renderedDNG {
            let outputs = recovered.targets.compactMap(\.outputFileURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            fileExportURLs = outputs.isEmpty ? nil : outputs
            fileExportStatus = outputs.isEmpty ? .none : .pending
        }
    }

    var selectedCount: Int { job.targets.count }
    var completedCount: Int { job.targets.filter { $0.status == .succeeded }.count }
    var failedCount: Int { job.targets.filter { $0.status == .failed }.count }
    var pendingCount: Int { job.targets.filter { [.pending, .cancelled, .processing].contains($0.status) }.count }
    var uncertainCount: Int { job.targets.filter { [.publishing, .needsConfirmation].contains($0.status) }.count }
    var canChangeTargets: Bool { job.settingsMode == .uniformFrozen && isReady && !isRunning && !isPreparing && job.status == .draft }
    var canStart: Bool { isReady && !isRunning && !isPreparing && journalStore != nil && pendingCount + failedCount > 0 }
    var stateTitle: String {
        if isPreparing { return L10n.text("正在准备照片…") }
        if isStopping { return L10n.text("正在停止…") }
        if isRunning { return L10n.text("正在导出") }
        switch job.status {
        case .cancelled: return L10n.text("导出已取消")
        case .interrupted: return L10n.text("导出已中断")
        case .completed: return L10n.text("导出完成")
        case .partialFailure: return L10n.text("部分照片导出失败")
        case .failed: return L10n.text("导出已停止")
        default: return L10n.text("批量导出")
        }
    }

    func addTargets(_ targets: [BatchTarget]) {
        guard canChangeTargets else { return }
        var existing = Set(job.targets.map(\.id))
        for target in targets where existing.insert(target.id).inserted { job.targets.append(target) }
        job.targets = OutputNameAllocator.assignUniqueNames(job.targets, suffix: job.outputFormat.suffix)
        saveJournal()
    }

    func setFormat(_ format: BatchOutputFormat) {
        guard canChangeTargets else { return }
        job.outputFormat = format
        job.targets = OutputNameAllocator.assignUniqueNames(job.targets, suffix: format.suffix)
        saveJournal()
    }

    func removeTarget(id: String) {
        guard canChangeTargets else { return }
        job.targets.removeAll { $0.id == id }
        saveJournal()
    }

    func setLongEdge(_ value: Int?) {
        guard canChangeTargets, ExportSize.isValid(value) else { return }
        job.longEdge = value
        saveJournal()
    }

    func addPickerItems(_ items: [PhotosPickerItem]) async {
        guard canChangeTargets, let journalStore else { return }
        await MainActor.run { isPreparing = true; validationMessage = nil }
        let jobID = job.id
        var targets: [BatchTarget] = []
        var failures: [String] = []
        for item in items {
            do {
                let file = try await PhotoImportFile.load(from: item)
                defer { PhotoImportFile.release(file.url) }
                let itemIdentity = item.itemIdentifier.flatMap { $0.isEmpty ? nil : PhotoIdentity(resourceIdentifier: $0) }
                let identity = try await perform {
                    try itemIdentity ?? PhotoIdentity.fallback(for: file.url)
                }
                let target = try await prepareTarget(file, identity: identity, jobID: jobID,
                                                     journalStore: journalStore)
                targets.append(target)
            } catch { failures.append(L10n.format("所选照片：%@", String(describing: error.localizedDescription))) }
        }
        let loaded = targets, errors = failures
        await MainActor.run {
            isPreparing = false
            addTargets(loaded)
            if !errors.isEmpty { validationMessage = errors.joined(separator: "\n") }
        }
    }

    func addFiles(_ urls: [URL]) async {
        guard canChangeTargets, let journalStore else { return }
        await MainActor.run { isPreparing = true; validationMessage = nil }
        let jobID = job.id
        var targets: [BatchTarget] = []
        var failures: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try await perform { try PhotoImportFile.retainSource(url) }
                defer { PhotoImportFile.release(source.url) }
                let identity = try await perform { try PhotoIdentity.fallback(for: source.url) }
                targets.append(try await prepareTarget(source, identity: identity, jobID: jobID,
                                                       journalStore: journalStore))
            } catch {
                failures.append(L10n.format("所选照片：%@", String(describing: error.localizedDescription)))
            }
        }
        let loaded = targets, errors = failures
        await MainActor.run {
            isPreparing = false
            addTargets(loaded)
            if !errors.isEmpty { validationMessage = errors.joined(separator: "\n") }
        }
    }

    func start() { run(failuresOnly: false) }
    func retryFailed() { run(failuresOnly: true) }

    private func freezeHDRJob(_ draft: BatchExportJob,journal: BatchJournalStore) throws -> BatchExportJob {
        guard draft.settingsMode == .uniformFrozen,draft.source.settings.isHDREditing else { return draft }
        guard let hdrPreparation else { throw BatchExportError.global(L10n.text("当前照片的设置尚不可用。")) }
        var result=draft,owned=[URL](),published=false
        defer { if !published { for url in owned { try? FileManager.default.removeItem(at:url) } } }
        for index in result.targets.indices {
            if isCancellationRequested { throw CancellationError() }
            let prepared=try hdrPreparation.prepare(result.targets[index],ordinal:index,format:draft.outputFormat,longEdge:draft.longEdge)
            guard draft.outputFormat != .hdrJPEG || prepared.settings.isHDREditing else {
                throw BatchExportError.target(L10n.text("HDR JPEG 需要启用 HDR 编辑。")+" "+result.targets[index].displayName)
            }
            var frozen=prepared
            if let original=prepared.lookURL {
                let folder=try BatchInputStore.directory(for:draft.id,root:journal.directory).deletingLastPathComponent()
                let copy=folder.appendingPathComponent("hdr-look-\(UUID().uuidString).\(original.pathExtension)")
                try FileManager.default.copyItem(at:original,to:copy); owned.append(copy); frozen.lookURL=copy
            }
            try frozen.verifyFiles(input:result.targets[index].sourceURL)
            result.targets[index].frozen=frozen
        }
        result.version=2; result.settingsMode = .perTargetFrozen
        try result.validate(); try journal.save(result); published=true
        return result
    }

    private func run(failuresOnly: Bool) {
        guard canStart, let journalStore else { return }
        var snapshot = job.outputFormat == .renderedDNG
            ? job.recovered()
            : job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
        guard snapshot.settingsMode == .perTargetFrozen || !snapshot.source.settings.hasLook ||
                snapshot.source.lookURL.map({ FileManager.default.isReadableFile(atPath: $0.path) }) == true else {
            validationMessage = L10n.text("任务使用的外观文件不可用，请重新创建任务。")
            return
        }
        isRunning = true; isStopping = false; validationMessage = nil
        cancellation.lock(); didCancel = false; cancellation.unlock()
        backgroundInterruption = false
        let failedIDs = failuresOnly ? Set(snapshot.targets.filter { $0.status == .failed }.map(\.id)) : nil
        let succeededBefore = snapshot.targets.filter { $0.status == .succeeded }.count
        queue.async { [self] in
            var attempted = Set<String>()
            do {
                snapshot=try freezeHDRJob(snapshot,journal:journalStore)
                let result: BatchExportJob
                if snapshot.outputFormat == .renderedDNG {
                    result = try BatchExportRunner.run(job: snapshot, journalStore: journalStore,
                        render: { target, resolvedSettings in
                            return try self.renderDNG(target: target, settings: resolvedSettings,
                                                      look: snapshot.look(for: target),
                                                      longEdge: snapshot.longEdge(for: target), jobID: snapshot.id)
                        },
                        write: { file, name, _, checkpoint in
                            try BatchFileWriter.write(file: file, outputName: name,
                                                      jobID: snapshot.id, checkpoint: checkpoint)
                        },
                        cleanup: { file in try? FileManager.default.removeItem(at: file) },
                        shouldCancel: { self.isCancellationRequested },
                        didUpdate: { updated in
                            attempted.formUnion(updated.targets.filter { $0.status == .processing }.map(\.id))
                            snapshot = updated
                            DispatchQueue.main.async { self.job = updated }
                        },
                        onlyIDs: failedIDs)
                } else if let jpegWriter {
                    result = try BatchExportRunner.run(job: snapshot, journalStore: journalStore,
                        render: { target, resolvedSettings in
                            return try self.render(target: target, settings: resolvedSettings,
                                                   look: snapshot.look(for: target),
                                                   longEdge: snapshot.longEdge(for: target),format:snapshot.outputFormat)
                        },
                        write: jpegWriter,
                        shouldCancel: { self.isCancellationRequested },
                        didUpdate: { updated in
                            attempted.formUnion(updated.targets.filter { $0.status == .processing }.map(\.id))
                            snapshot = updated
                            DispatchQueue.main.async { self.job = updated }
                        },
                        onlyIDs: failedIDs)
                } else {
                    try PhotoLibraryBatchWriter.authorize()
                    result = try BatchExportRunner.run(job: snapshot, journalStore: journalStore,
                        render: { target, resolvedSettings in
                            return try self.render(target: target, settings: resolvedSettings,
                                                   look: snapshot.look(for: target),
                                                   longEdge: snapshot.longEdge(for: target),format:snapshot.outputFormat)
                        },
                        write: { data, name, target, checkpoint in
                            try PhotoLibraryBatchWriter.write(data: data, outputName: name,
                                                              target: target, checkpoint: checkpoint)
                        },
                        shouldCancel: { self.isCancellationRequested },
                        didUpdate: { updated in
                            attempted.formUnion(updated.targets.filter { $0.status == .processing }.map(\.id))
                            snapshot = updated
                            DispatchQueue.main.async { self.job = updated }
                        },
                        onlyIDs: failedIDs)
                }
                let failed = result.targets.filter { attempted.contains($0.id) && $0.status == .failed }.count
                DispatchQueue.main.async {
                    self.job = result
                    if self.backgroundInterruption && result.status == .cancelled { self.job.status = .interrupted }
                    self.isRunning = false; self.isStopping = false
                    self.validationMessage = self.job.globalError
                    if result.outputFormat == .renderedDNG {
                        self.fileExportURLs = result.targets.compactMap(\.outputFileURL)
                            .filter { FileManager.default.fileExists(atPath: $0.path) }
                        if self.fileExportURLs?.isEmpty == false {
                            self.fileExportStatus = .pending
                            self.shouldPresentFileExport = result.status == .completed
                        }
                    }
                    self.saveJournal()
                    self.reportUsage(succeededBefore: succeededBefore, failed: failed)
                }
            } catch {
                let preparationFailed=snapshot.settingsMode == .uniformFrozen && snapshot.source.settings.isHDREditing && attempted.isEmpty
                let cancelled=error is CancellationError
                let recovered = snapshot.outputFormat == .renderedDNG
                    ? snapshot.recovered()
                    : snapshot.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
                let message = error.localizedDescription
                let failed = recovered.targets.filter { attempted.contains($0.id) && $0.status == .failed }.count
                DispatchQueue.main.async {
                    self.job = recovered
                    // 预检没有生成或发布任何目标，保留草稿可编辑，允许改格式/移除不兼容项。
                    self.job.status = preparationFailed ? (cancelled ? .cancelled : .draft) : .interrupted
                    self.job.globalError = message
                    self.validationMessage = message
                    self.isRunning = false; self.isStopping = false
                    self.saveJournal()
                    self.reportUsage(succeededBefore: succeededBefore, failed: failed)
                }
            }
        }
    }

    private func reportUsage(succeededBefore: Int, failed: Int) {
        let succeeded = max(0, job.targets.filter { $0.status == .succeeded }.count - succeededBefore)
        let outcome: UsageBatchOutcome
        switch job.status {
        case .completed: outcome = .completed
        case .partialFailure: outcome = .partial
        case .cancelled: outcome = .cancelled
        default: outcome = .interrupted
        }
        onUsage(.batchExportCompleted(succeeded: succeeded, failed: failed, outcome: outcome))
    }

    func cancel(forBackground: Bool = false) {
        guard isRunning else { return }
        isStopping = true
        backgroundInterruption = backgroundInterruption || forBackground
        cancellation.lock(); didCancel = true; cancellation.unlock()
    }

    private var isCancellationRequested: Bool {
        cancellation.lock(); defer { cancellation.unlock() }
        return didCancel
    }

    func confirmPublication(id: String, saved: Bool) {
        guard !isRunning, !isPreparing else { return }
        if job.outputFormat == .renderedDNG {
            reconcileDNGFiles()
            return
        }
        guard let index = job.targets.firstIndex(where: { $0.id == id && $0.status == .needsConfirmation }) else { return }
        job.targets[index].status = saved ? .succeeded : .pending
        job.targets[index].errorMessage = nil
        if !saved { job.targets[index].outputAssetIdentifier = nil }
        if job.targets.allSatisfy({ $0.status == .succeeded }) { job.status = .completed }
        saveJournal()
    }

    func reconcilePublication() async {
        guard !isRunning, !isPreparing else { return }
        if job.outputFormat == .renderedDNG {
            await MainActor.run { reconcileDNGFiles() }
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            if status == .authorized || status == .limited {
                job = job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
                saveJournal()
            } else { validationMessage = L10n.text("未获得相册读取权限，请手动核对保存结果，或在系统设置中授权。") }
        }
    }

    private func reconcileDNGFiles() {
        job = job.recovered()
        let outputs = job.targets.compactMap(\.outputFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        fileExportURLs = outputs.isEmpty ? nil : outputs
        fileExportStatus = outputs.isEmpty ? .none : .pending
        validationMessage = job.globalError
        saveJournal()
    }

    func presentFileExport() {
        guard fileExportURLs?.isEmpty == false else { return }
        shouldPresentFileExport = true
    }

    func finishFileExport(_ exported: Bool) {
        shouldPresentFileExport = false
        fileExportStatus = exported ? .exported : .cancelled
    }

    @discardableResult func discard() -> Bool {
        guard !isRunning, !isPreparing, let journalStore else { return false }
        do { try journalStore.discard(id: job.id); onDiscard(); return true }
        catch { validationMessage = error.localizedDescription; return false }
    }

    struct Preview {
        let image: UIImage
        var hdr: HDRPresentation? = nil
    }
    func preview(target: BatchTarget) async throws -> Preview {
        guard !isRunning, !isPreparing else { throw BatchExportError.target(L10n.text("请等待当前任务完成。")) }
        let snapshot = job
        return try await perform {
            try snapshot.validate()
            let prepared=snapshot.settingsMode == .uniformFrozen ? try self.hdrPreparation?.prepare(target,ordinal:0,format:snapshot.outputFormat,longEdge:snapshot.longEdge) : nil
            let targetSettings: RawSettings,look: URL?
            if let prepared { targetSettings=prepared.settings; look=prepared.lookURL }
            else { targetSettings=try snapshot.settings(for:target); look=try snapshot.look(for:target) }
            if snapshot.settingsMode == .perTargetFrozen { try target.frozen!.verifyFiles(input: target.sourceURL) }
            if targetSettings.hasLook && look.map({ FileManager.default.isReadableFile(atPath: $0.path) }) != true {
                throw BatchExportError.global(L10n.text("任务使用的外观文件不可用，请重新创建任务。"))
            }
            let processor = Sony2FujiProcessor()
            if targetSettings.isHDREditing,let hdr=targetSettings.hdr {
                let pair=try processor.processHDR(url:target.sourceURL,settings:hdr,previewLongEdge:1280)
                let presentation=try HDRPresentation(pair)
                return Preview(image:UIImage(cgImage:presentation.sdrImage),hdr:presentation)
            }
            let result: Sony2FujiProcessor.ProcessResult
            if target.sourceKind == .raw {
                result = try processor.processRaw(url: target.sourceURL, settings: targetSettings,
                                                  previewLongEdge: 1280, lutURL: look)
            } else {
                let raster = try processor.loadRasterBuffer(url: target.sourceURL)
                let buffer = try processor.processBuffer(buffer: raster.buffer, settings: targetSettings,
                                                         previewLongEdge: 1280, lutURL: look)
                result = Sony2FujiProcessor.ProcessResult(buffer: buffer, orientation: .up,
                                                          rawWhiteBalance: nil)
            }
            guard let image = processor.makeUIImage(from: result.buffer, orientation: result.orientation) else {
                throw BatchExportError.target(L10n.text("无法显示处理结果"))
            }
            return Preview(image:image)
        }
    }


    private func saveJournal() {
        guard let journalStore else { return }
        do { try journalStore.save(job) }
        catch { validationMessage = L10n.format("任务未保存：%@", String(describing: error.localizedDescription)) }
    }
}
