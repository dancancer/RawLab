import Photos
import PhotosUI
import SwiftUI
import UIKit

final class BatchExportModel: ObservableObject {
    @Published private(set) var job: BatchExportJob
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isStopping = false
    @Published private(set) var isReady = false
    @Published var validationMessage: String?
    var onDiscard: () -> Void = { }

    private let journalStore: BatchJournalStore?
    private let queue = DispatchQueue(label: "com.rawlab.batch", qos: .userInitiated)
    private let cancellation = NSLock()
    private var didCancel = false
    private var backgroundInterruption = false

    init(source: BatchSourceSnapshot, editor: RawEditorViewModel) {
        var source = source
        source.lookName = editor.availableLUTs.first { $0.id == source.settings.lutID }?.name ?? "中性"
        job = BatchExportJob(source: source, targets: [])
        do { journalStore = try BatchJournalStore.appStore() }
        catch { journalStore = nil; validationMessage = "无法保存批量任务：\(error.localizedDescription)" }
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

    init(job: BatchExportJob, journalStore: BatchJournalStore) {
        self.job = job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
        self.journalStore = journalStore
        isReady = true
        validationMessage = self.job.globalError
    }

    var selectedCount: Int { job.targets.count }
    var completedCount: Int { job.targets.filter { $0.status == .succeeded }.count }
    var failedCount: Int { job.targets.filter { $0.status == .failed }.count }
    var pendingCount: Int { job.targets.filter { [.pending, .cancelled, .processing].contains($0.status) }.count }
    var uncertainCount: Int { job.targets.filter { [.publishing, .needsConfirmation].contains($0.status) }.count }
    var canChangeTargets: Bool { isReady && !isRunning && !isPreparing && job.status == .draft }
    var canStart: Bool { isReady && !isRunning && !isPreparing && journalStore != nil && pendingCount + failedCount > 0 }
    var stateTitle: String {
        if isPreparing { return "正在准备 RAW…" }
        if isStopping { return "正在停止…" }
        if isRunning { return "正在导出" }
        switch job.status {
        case .cancelled: return "导出已取消"
        case .interrupted: return "导出已中断"
        case .completed: return "导出完成"
        case .partialFailure: return "部分照片导出失败"
        case .failed: return "导出已停止"
        default: return "批量导出"
        }
    }

    func addTargets(_ targets: [BatchTarget]) {
        guard canChangeTargets else { return }
        var existing = Set(job.targets.map(\.id))
        for target in targets where existing.insert(target.id).inserted { job.targets.append(target) }
        job.targets = OutputNameAllocator.assignUniqueNames(job.targets)
        saveJournal()
    }

    func removeTarget(id: String) {
        guard canChangeTargets else { return }
        job.targets.removeAll { $0.id == id }
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
                guard file.isRaw else { failures.append("普通图片未加入，请选择 RAW。"); continue }
                let target: BatchTarget = try await perform {
                    let identity = try item.itemIdentifier.flatMap { $0.isEmpty ? nil : PhotoIdentity(resourceIdentifier: $0) }
                        ?? PhotoIdentity.fallback(for: file.url)
                    let owned = try BatchInputStore.copy(file.url, identity: identity, jobID: jobID, root: journalStore.directory)
                    _ = try Sony2FujiProcessor().processRaw(url: owned, settings: .default, previewLongEdge: 160, lutURL: nil)
                    return BatchTarget(identity: identity, sourceURL: owned, displayName: file.url.lastPathComponent)
                }
                targets.append(target)
            } catch { failures.append("所选 RAW：\(error.localizedDescription)") }
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

    private func run(failuresOnly: Bool) {
        guard canStart, let journalStore else { return }
        var snapshot = job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
        guard snapshot.source.settings.lutID == nil ||
                snapshot.source.lookURL.map({ FileManager.default.isReadableFile(atPath: $0.path) }) == true else {
            validationMessage = "任务外观不可用，请放弃此任务并重新创建。"
            return
        }
        isRunning = true; isStopping = false; validationMessage = nil
        cancellation.lock(); didCancel = false; cancellation.unlock()
        backgroundInterruption = false
        let failedIDs = failuresOnly ? Set(snapshot.targets.filter { $0.status == .failed }.map(\.id)) : nil
        queue.async { [self] in
            do {
                try PhotoLibraryBatchWriter.authorize()
                let result = try BatchExportRunner.run(job: snapshot, journalStore: journalStore,
                    render: { target, settings in
                        try self.render(target: target, settings: settings, look: snapshot.source.lookURL)
                    },
                    write: { data, name, target, checkpoint in
                        try PhotoLibraryBatchWriter.write(data: data, outputName: name, target: target, checkpoint: checkpoint)
                    },
                    shouldCancel: { self.isCancellationRequested },
                    didUpdate: { updated in
                        snapshot = updated
                        DispatchQueue.main.async { self.job = updated }
                    },
                    onlyIDs: failedIDs)
                DispatchQueue.main.async {
                    self.job = result
                    if self.backgroundInterruption && result.status == .cancelled { self.job.status = .interrupted }
                    self.isRunning = false; self.isStopping = false
                    self.validationMessage = self.job.globalError
                    self.saveJournal()
                }
            } catch {
                let recovered = snapshot.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.job = recovered
                    self.job.status = .interrupted
                    self.job.globalError = message
                    self.validationMessage = message
                    self.isRunning = false; self.isStopping = false
                    self.saveJournal()
                }
            }
        }
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
        guard !isRunning, let index = job.targets.firstIndex(where: { $0.id == id && $0.status == .needsConfirmation }) else { return }
        job.targets[index].status = saved ? .succeeded : .pending
        job.targets[index].errorMessage = nil
        if !saved { job.targets[index].outputAssetIdentifier = nil }
        if job.targets.allSatisfy({ $0.status == .succeeded }) { job.status = .completed }
        saveJournal()
    }

    func reconcilePhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            if status == .authorized || status == .limited {
                job = job.recovered(assetExists: PhotoLibraryBatchWriter.assetExists)
                saveJournal()
            } else { validationMessage = "未获得相册读取权限，请手动核对保存结果，或在系统设置中授权。" }
        }
    }

    @discardableResult func discard() -> Bool {
        guard !isRunning, !isPreparing, let journalStore else { return false }
        do { try journalStore.discard(id: job.id); onDiscard(); return true }
        catch { validationMessage = error.localizedDescription; return false }
    }

    func preview(target: BatchTarget) async throws -> UIImage {
        guard !isRunning, !isPreparing else { throw BatchExportError.target("请等待当前任务完成。") }
        let snapshot = job.source
        return try await perform {
            if snapshot.settings.lutID != nil && snapshot.lookURL.map({ FileManager.default.isReadableFile(atPath: $0.path) }) != true {
                throw BatchExportError.global("任务外观不可用。")
            }
            let processor = Sony2FujiProcessor()
            let result = try processor.processRaw(url: target.sourceURL, settings: snapshot.settings,
                                                   previewLongEdge: 1280, lutURL: snapshot.lookURL)
            guard let image = processor.makeUIImage(from: result.buffer, orientation: result.orientation) else {
                throw BatchExportError.target("无法显示预览。")
            }
            return image
        }
    }

    private func render(target: BatchTarget, settings: RawSettings, look: URL?) throws -> Data {
        guard target.sourceKind == .raw else { throw BatchExportError.target("不是 RAW 照片。") }
        return try autoreleasepool {
            let processor = Sony2FujiProcessor()
            let result = try processor.processRaw(url: target.sourceURL, settings: settings, previewLongEdge: nil, lutURL: look)
            return try processor.makeJPEGData(from: result.buffer, sourceURL: target.sourceURL, orientation: result.orientation, quality: 0.92)
        }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private func saveJournal() {
        guard let journalStore else { return }
        do { try journalStore.save(job) }
        catch { validationMessage = "任务记录未保存：\(error.localizedDescription)" }
    }
}

private enum PhotoLibraryBatchWriter {
    static func authorize() throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status = $0; semaphore.signal() }
            semaphore.wait()
        }
        guard status == .authorized || status == .limited else {
            throw BatchExportError.global("无法保存照片，请在系统设置中允许 RawLab 添加照片。")
        }
    }

    static func assetExists(_ identifier: String) -> Bool? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        if PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0 { return true }
        return status == .authorized ? false : nil
    }

    static func write(data: Data, outputName: String, target: BatchTarget,
                      checkpoint: @escaping (String) throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        var checkpointError: Error?
        var didSucceed = false
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = outputName
            request.addResource(with: .photo, data: data, options: options)
            if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                do { try checkpoint(identifier) } catch { checkpointError = error }
            }
        }) { success, error in
            didSucceed = success; writeError = error; semaphore.signal()
        }
        semaphore.wait()
        if !didSucceed { throw BatchExportError.global(writeError?.localizedDescription ?? "保存 \(target.displayName) 失败。") }
        if checkpointError != nil { throw BatchExportError.uncertain("照片已写入，但任务记录未更新，请先核对保存结果。") }
    }
}
