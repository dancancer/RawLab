import Foundation
import CryptoKit

enum BatchSourceKind: String, Codable, Equatable {
    case raw
    case raster
}

enum BatchTargetStatus: String, Codable, Equatable {
    case pending
    case processing
    case publishing
    case needsConfirmation
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .pending: return "等待导出"
        case .processing: return "正在显影"
        case .publishing: return "正在保存"
        case .needsConfirmation: return "保存结果待确认"
        case .succeeded: return "已保存"
        case .failed: return "导出失败"
        case .cancelled: return "未处理"
        }
    }
}

enum BatchJobStatus: String, Codable, Equatable {
    case draft
    case running
    case completed
    case partialFailure
    case cancelled
    case interrupted
    case failed
}

enum BatchOutputFormat: String, Codable, Equatable {
    case jpeg
}

enum BatchExportError: LocalizedError {
    case target(String)
    case global(String)
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case .target(let message), .global(let message), .uncertain(let message):
            return message
        }
    }
}

struct BatchSourceSnapshot: Codable, Equatable {
    let identity: PhotoIdentity
    var sourceURL: URL
    let displayName: String
    let sourceKind: BatchSourceKind
    let settings: RawSettings
    var lookURL: URL?
    var lookName: String?

    init(identity: PhotoIdentity,
         sourceURL: URL,
         displayName: String,
         sourceKind: BatchSourceKind = .raw,
         settings: RawSettings) {
        self.identity = identity
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.settings = settings
    }
}

struct BatchTarget: Codable, Equatable, Identifiable {
    let identity: PhotoIdentity
    var sourceURL: URL
    let displayName: String
    var sourceKind: BatchSourceKind
    var status: BatchTargetStatus
    var errorMessage: String?
    var outputName: String
    var outputAssetIdentifier: String?

    var id: String { identity.key }

    init(identity: PhotoIdentity,
         sourceURL: URL,
         displayName: String,
         sourceKind: BatchSourceKind = .raw,
         status: BatchTargetStatus = .pending,
         errorMessage: String? = nil,
         outputName: String? = nil) {
        self.identity = identity
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.status = status
        self.errorMessage = errorMessage
        self.outputName = outputName ?? OutputNameAllocator.baseName(for: displayName)
    }
}

struct BatchExportJob: Codable, Equatable, Identifiable {
    let id: UUID
    var source: BatchSourceSnapshot
    var targets: [BatchTarget]
    var status: BatchJobStatus
    var outputFormat: BatchOutputFormat
    var createdAt: Date
    var updatedAt: Date
    var globalError: String?

    init(id: UUID = UUID(),
         source: BatchSourceSnapshot,
         targets: [BatchTarget],
         outputFormat: BatchOutputFormat = .jpeg,
         status: BatchJobStatus = .draft,
         createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.targets = OutputNameAllocator.assignUniqueNames(targets)
        self.status = status
        self.outputFormat = outputFormat
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.globalError = nil
    }
}

extension BatchExportJob {
    func recovered(assetExists: (String) -> Bool? = { _ in nil }) -> BatchExportJob {
        var copy = self
        for index in copy.targets.indices {
            switch copy.targets[index].status {
            case .processing:
                copy.targets[index].status = .pending
            case .publishing, .needsConfirmation:
                if let asset = copy.targets[index].outputAssetIdentifier, let exists = assetExists(asset) {
                    copy.targets[index].status = exists ? .succeeded : .pending
                    if !exists { copy.targets[index].outputAssetIdentifier = nil }
                    copy.targets[index].errorMessage = nil
                } else {
                    copy.targets[index].status = .needsConfirmation
                    copy.targets[index].errorMessage = "保存时发生中断，请先核对照片图库，避免重复生成。"
                }
            default: break
            }
        }
        if status == .running || copy.targets.contains(where: { $0.status == .needsConfirmation }) { copy.status = .interrupted }
        if !copy.targets.isEmpty && copy.targets.allSatisfy({ $0.status == .succeeded }) { copy.status = .completed }
        return copy
    }
}

final class BatchJournalStore {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func appStore() throws -> BatchJournalStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try BatchJournalStore(directory: root.appendingPathComponent("RawLab/BatchJobs", isDirectory: true))
    }

    func save(_ job: BatchExportJob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let destination = directory.appendingPathComponent("\(job.id.uuidString).json")
        try encoder.encode(job).write(to: destination, options: .atomic)
    }

    func load(id: UUID) throws -> BatchExportJob? {
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return relocateOwnedFiles(try JSONDecoder().decode(BatchExportJob.self, from: Data(contentsOf: file)))
    }

    func pendingJobs() throws -> [BatchExportJob] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.compactMap { url -> BatchExportJob? in
            let original = try JSONDecoder().decode(BatchExportJob.self, from: Data(contentsOf: url))
            let recovered = relocateOwnedFiles(original).recovered()
            if recovered.status == .completed { try discard(id: recovered.id); return nil }
            if recovered != original { try save(recovered) }
            return recovered
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func relocateOwnedFiles(_ original: BatchExportJob) -> BatchExportJob {
        let root = directory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        func relocate(_ url: URL) -> URL {
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "inputs" && parent.deletingLastPathComponent().lastPathComponent == original.id.uuidString {
                return root.appendingPathComponent("inputs", isDirectory: true).appendingPathComponent(url.lastPathComponent)
            }
            if parent.lastPathComponent == original.id.uuidString { return root.appendingPathComponent(url.lastPathComponent) }
            return url
        }
        var job = original
        job.source.sourceURL = relocate(job.source.sourceURL)
        job.source.lookURL = job.source.lookURL.map(relocate)
        for index in job.targets.indices { job.targets[index].sourceURL = relocate(job.targets[index].sourceURL) }
        return job
    }

    func discard(id: UUID) throws {
        let record = directory.appendingPathComponent("\(id.uuidString).json")
        let inputs = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: inputs.path) { try FileManager.default.removeItem(at: inputs) }
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }
}

enum BatchInputStore {
    static func directory(for jobID: UUID, root: URL? = nil) throws -> URL {
        let base: URL
        if let root {
            base = root
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
                .appendingPathComponent("RawLab/BatchJobs", isDirectory: true)
        }
        let directory = base.appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func copy(_ sourceURL: URL, identity: PhotoIdentity, jobID: UUID, root: URL? = nil) throws -> URL {
        let directory = try directory(for: jobID, root: root)
        let ext = sourceURL.pathExtension.isEmpty ? "raw" : sourceURL.pathExtension
        let destination = directory.appendingPathComponent(safeFileName(identity.key) + "." + ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        let temporary = directory.appendingPathComponent(".copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func safeFileName(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(_ job: inout BatchExportJob, look: URL?, root: URL? = nil) throws {
        job.source.sourceURL = try copy(job.source.sourceURL, identity: job.source.identity, jobID: job.id, root: root)
        if job.source.settings.lutID != nil {
            guard let look, FileManager.default.isReadableFile(atPath: look.path) else {
                throw BatchExportError.global("所选外观不可用，请重新选择外观。")
            }
            let folder = try directory(for: job.id, root: root).deletingLastPathComponent()
            let destination = folder.appendingPathComponent("look.\(look.pathExtension)")
            if look != destination && !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: look, to: destination)
            }
            job.source.lookURL = destination
        }
    }
}

enum OutputNameAllocator {
    static func baseName(for displayName: String) -> String {
        let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "RawLab" : base) + ".jpg"
    }

    static func assignUniqueNames(_ targets: [BatchTarget]) -> [BatchTarget] {
        var used = Set<String>()
        return targets.map { target in
            var candidate = target.outputName
            let base = URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base)-\(suffix).jpg"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            var copy = target
            copy.outputName = candidate
            return copy
        }
    }
}

struct BatchExportRunner {
    typealias Renderer = (_ target: BatchTarget, _ settings: RawSettings) throws -> Data
    typealias Writer = (_ data: Data, _ outputName: String, _ target: BatchTarget, _ checkpoint: @escaping (String) throws -> Void) throws -> Void
    typealias Cancellation = () -> Bool

    static func run(job: BatchExportJob,
                    journalStore: BatchJournalStore?,
                    render: @escaping Renderer,
                    write: @escaping Writer,
                    shouldCancel: @escaping Cancellation = { false },
                    didUpdate: @escaping (BatchExportJob) -> Void = { _ in },
                    onlyIDs: Set<String>? = nil) throws -> BatchExportJob {
        var job = job
        job.status = .running
        job.globalError = nil
        try journalStore?.save(job)
        didUpdate(job)

        for index in job.targets.indices {
            guard [.pending, .failed, .cancelled].contains(job.targets[index].status),
                  onlyIDs == nil || onlyIDs!.contains(job.targets[index].id) else { continue }
            if shouldCancel() {
                markRemainingCancelled(&job, from: index)
                job.status = .cancelled
                job.updatedAt = Date()
                try journalStore?.save(job)
                didUpdate(job)
                return job
            }

            job.targets[index].status = .processing
            job.targets[index].errorMessage = nil
            try journalStore?.save(job)
            didUpdate(job)
            do {
                let data = try render(job.targets[index], job.source.settings)
                job.targets[index].status = .publishing
                try journalStore?.save(job)
                didUpdate(job)
                try write(data, job.targets[index].outputName, job.targets[index]) { identifier in
                    job.targets[index].outputAssetIdentifier = identifier
                    try journalStore?.save(job)
                    didUpdate(job)
                }
                job.targets[index].status = .succeeded
            } catch let error as BatchExportError {
                switch error {
                case .uncertain(let message):
                    job.targets[index].status = .needsConfirmation
                    job.targets[index].errorMessage = message
                    job.globalError = message
                    job.status = .interrupted
                    try journalStore?.save(job)
                    didUpdate(job)
                    return job
                case .target(let message):
                    job.targets[index].status = .failed
                    job.targets[index].errorMessage = message
                case .global(let message):
                    job.targets[index].status = .failed
                    job.targets[index].errorMessage = message
                    job.globalError = message
                    job.status = .failed
                    job.updatedAt = Date()
                    try journalStore?.save(job)
                    didUpdate(job)
                    return job
                }
            } catch {
                job.targets[index].status = .failed
                job.targets[index].errorMessage = error.localizedDescription
            }
            job.updatedAt = Date()
            try journalStore?.save(job)
            didUpdate(job)
        }

        if job.status != .cancelled && job.status != .failed {
            if job.targets.contains(where: { [.pending, .cancelled, .needsConfirmation].contains($0.status) }) { job.status = .interrupted }
            else { job.status = job.targets.contains(where: { $0.status == .failed }) ? .partialFailure : .completed }
        }
        job.updatedAt = Date()
        try journalStore?.save(job)
        didUpdate(job)
        return job
    }

    static func retryFailed(job: BatchExportJob,
                            journalStore: BatchJournalStore?,
                            render: @escaping Renderer,
                            write: @escaping Writer,
                            shouldCancel: @escaping Cancellation = { false },
                            didUpdate: @escaping (BatchExportJob) -> Void = { _ in }) throws -> BatchExportJob {
        var retry = job
        let failedIDs = Set(job.targets.filter { $0.status == .failed }.map(\.id))
        for index in retry.targets.indices where retry.targets[index].status == .failed {
            retry.targets[index].status = .pending
            retry.targets[index].errorMessage = nil
        }
        retry.status = .draft
        return try run(job: retry, journalStore: journalStore, render: render, write: write,
                       shouldCancel: shouldCancel, didUpdate: didUpdate, onlyIDs: failedIDs)
    }

    private static func markRemainingCancelled(_ job: inout BatchExportJob, from index: Int) {
        for remaining in index..<job.targets.count where [.pending, .processing, .failed, .cancelled].contains(job.targets[remaining].status) {
            job.targets[remaining].status = .cancelled
        }
    }
}
