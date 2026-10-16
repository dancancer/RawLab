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
        case .pending: return L10n.text("等待导出")
        case .processing: return L10n.text("正在显影")
        case .publishing: return L10n.text("正在保存")
        case .needsConfirmation: return L10n.text("保存结果待确认")
        case .succeeded: return L10n.text("已保存")
        case .failed: return L10n.text("导出失败")
        case .cancelled: return L10n.text("未处理")
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

enum BatchOutputFormat: String, Codable, Equatable, Hashable {
    case jpeg
    case renderedDNG = "dng"

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .renderedDNG: return L10n.text("DNG · 渲染型")
        }
    }

    var suffix: String {
        switch self {
        case .jpeg: return "jpg"
        case .renderedDNG: return "dng"
        }
    }
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

    func settings(for targetKind: BatchSourceKind) -> RawSettings {
        guard sourceKind == .raster, targetKind == .raw else { return settings }
        var result = settings
        result.exposureMode = RawSettings.default.exposureMode
        result.whiteBalanceMode = .camera
        result.temperature = 6500
        if result.masterRecipeID == nil { result.tint = 0 }
        result.noiseReduction = 0
        result.lensCorrection = nil
        return result
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
    var outputFileURL: URL?

    var id: String { identity.key }

    init(identity: PhotoIdentity,
         sourceURL: URL,
         displayName: String,
         sourceKind: BatchSourceKind = .raw,
         status: BatchTargetStatus = .pending,
         errorMessage: String? = nil,
         outputName: String? = nil,
         outputFileURL: URL? = nil) {
        self.identity = identity
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.status = status
        self.errorMessage = errorMessage
        self.outputName = outputName ?? OutputNameAllocator.baseName(for: displayName)
        self.outputFileURL = outputFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case identity, sourceURL, displayName, sourceKind, status, errorMessage
        case outputName, outputAssetIdentifier, outputFileURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(PhotoIdentity.self, forKey: .identity)
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        displayName = try values.decode(String.self, forKey: .displayName)
        sourceKind = try values.decodeIfPresent(BatchSourceKind.self, forKey: .sourceKind) ?? .raw
        status = try values.decodeIfPresent(BatchTargetStatus.self, forKey: .status) ?? .pending
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        outputName = try values.decodeIfPresent(String.self, forKey: .outputName)
            ?? OutputNameAllocator.baseName(for: displayName)
        outputAssetIdentifier = try values.decodeIfPresent(String.self, forKey: .outputAssetIdentifier)
        outputFileURL = try values.decodeIfPresent(URL.self, forKey: .outputFileURL)
    }
}

struct BatchExportJob: Codable, Equatable, Identifiable {
    let id: UUID
    var source: BatchSourceSnapshot
    var targets: [BatchTarget]
    var status: BatchJobStatus
    var outputFormat: BatchOutputFormat
    var longEdge: Int?
    var createdAt: Date
    var updatedAt: Date
    var globalError: String?

    init(id: UUID = UUID(),
         source: BatchSourceSnapshot,
         targets: [BatchTarget],
         outputFormat: BatchOutputFormat = .jpeg,
         longEdge: Int? = nil,
         status: BatchJobStatus = .draft,
         createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.targets = OutputNameAllocator.assignUniqueNames(targets, suffix: outputFormat.suffix)
        self.status = status
        self.outputFormat = outputFormat
        self.longEdge = ExportSize.normalized(longEdge)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.globalError = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, targets, status, outputFormat, longEdge, createdAt, updatedAt, globalError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(BatchSourceSnapshot.self, forKey: .source)
        targets = try values.decode([BatchTarget].self, forKey: .targets)
        status = try values.decode(BatchJobStatus.self, forKey: .status)
        outputFormat = try values.decodeIfPresent(BatchOutputFormat.self, forKey: .outputFormat) ?? .jpeg
        longEdge = try values.decodeIfPresent(Int.self, forKey: .longEdge)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        globalError = try values.decodeIfPresent(String.self, forKey: .globalError)
    }
}

extension BatchExportJob {
    func recovered(assetExists: (String) -> Bool? = { _ in nil },
                   fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> BatchExportJob {
        var copy = self
        func existingDNGOutput(for target: BatchTarget) -> URL? {
            let currentDestination = BatchFileOutputStore.destination(jobID: id, outputName: target.outputName)
            if fileExists(currentDestination) { return currentDestination }
            if let output = target.outputFileURL, fileExists(output) { return output }
            if let asset = target.outputAssetIdentifier,
               asset.hasPrefix("file:") {
                let output = URL(fileURLWithPath: String(asset.dropFirst(5)))
                if fileExists(output) { return output }
            }
            return nil
        }

        for index in copy.targets.indices {
            switch copy.targets[index].status {
            case .processing:
                copy.targets[index].status = .pending
            case .succeeded:
                guard outputFormat == .renderedDNG else { break }
                if let output = existingDNGOutput(for: copy.targets[index]) {
                    copy.targets[index].outputFileURL = output
                    copy.targets[index].outputAssetIdentifier = nil
                    copy.targets[index].errorMessage = nil
                } else {
                    copy.targets[index].outputFileURL = nil
                    copy.targets[index].outputAssetIdentifier = nil
                    copy.targets[index].status = .pending
                    copy.targets[index].errorMessage = nil
                }
            case .publishing, .needsConfirmation:
                if outputFormat == .renderedDNG {
                    if let output = existingDNGOutput(for: copy.targets[index]) {
                        copy.targets[index].outputFileURL = output
                        copy.targets[index].outputAssetIdentifier = nil
                        copy.targets[index].status = .succeeded
                    } else {
                        copy.targets[index].outputFileURL = nil
                        copy.targets[index].outputAssetIdentifier = nil
                        copy.targets[index].status = .pending
                    }
                    if copy.globalError == copy.targets[index].errorMessage { copy.globalError = nil }
                    copy.targets[index].errorMessage = nil
                } else if let asset = copy.targets[index].outputAssetIdentifier, let exists = assetExists(asset) {
                    copy.targets[index].status = exists ? .succeeded : .pending
                    if !exists { copy.targets[index].outputAssetIdentifier = nil }
                    copy.targets[index].errorMessage = nil
                } else {
                    copy.targets[index].status = .needsConfirmation
                    copy.targets[index].errorMessage = L10n.text("保存时发生中断，请先核对照片图库，避免重复生成。")
                }
            default: break
            }
        }
        if status == .running || copy.targets.contains(where: { $0.status == .needsConfirmation }) { copy.status = .interrupted }
        if outputFormat == .renderedDNG && copy.status == .completed &&
            copy.targets.contains(where: { $0.status != .succeeded }) {
            copy.status = .interrupted
        }
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
            // JPEG completion is fully owned by Photos; DNG files remain in Documents/Exports
            // until the user explicitly finishes or discards the recovered job.
            if recovered.status == .completed && recovered.outputFormat == .jpeg {
                try discard(id: recovered.id)
                return nil
            }
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
        if job.source.settings.hasLook {
            guard let look, FileManager.default.isReadableFile(atPath: look.path) else {
                throw BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))
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

enum BatchFileOutputStore {
    static func root() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    static func directory(for jobID: UUID) throws -> URL {
        let directory = root().appendingPathComponent(jobID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BatchExportError.global(error.localizedDescription)
        }
        return directory
    }

    static func destination(jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(outputName)
    }

    static func temporaryURL(for jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(".rawlab-\(UUID().uuidString)-\(outputName)")
    }
}

enum BatchFileWriter {
    static func write(file: URL, outputName: String, jobID: UUID,
                      checkpoint: @escaping (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BatchExportError.target(L10n.text("渲染型 DNG 未生成。"))
        }
        let directory = try BatchFileOutputStore.directory(for: jobID)
        let destination = directory.appendingPathComponent(outputName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: file,
                                                          backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: file, to: destination)
            }
        } catch {
            throw BatchExportError.global(error.localizedDescription)
        }
        do {
            try checkpoint("file:\(destination.path)")
        } catch {
            throw BatchExportError.uncertain(L10n.text("DNG 已生成，但任务记录未更新，请先核对保存结果。"))
        }
    }
}

enum OutputNameAllocator {
    static func baseName(for displayName: String, suffix: String = "jpg") -> String {
        let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "RawLab" : base) + "." + suffix
    }

    static func assignUniqueNames(_ targets: [BatchTarget], suffix: String = "jpg") -> [BatchTarget] {
        var used = Set<String>()
        return targets.map { target in
            let original = URL(fileURLWithPath: target.outputName).deletingPathExtension().lastPathComponent
            let base = original.isEmpty ? URL(fileURLWithPath: target.displayName).deletingPathExtension().lastPathComponent : original
            var candidate = (base.isEmpty ? "RawLab" : base) + "." + suffix
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base)-\(number).\(suffix)"
                number += 1
            }
            used.insert(candidate.lowercased())
            var copy = target
            copy.outputName = candidate
            return copy
        }
    }
}

struct BatchExportRunner {
    typealias Cancellation = () -> Bool

    static func run<Payload>(job: BatchExportJob,
                    journalStore: BatchJournalStore?,
                    render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                    write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                      _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                    cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
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
            job.targets[index].outputAssetIdentifier = nil
            job.targets[index].outputFileURL = nil
            try journalStore?.save(job)
            didUpdate(job)
            do {
                let payload = try render(job.targets[index], job.source.settings)
                defer { cleanup(payload) }
                job.targets[index].status = .publishing
                try journalStore?.save(job)
                didUpdate(job)
                try write(payload, job.targets[index].outputName, job.targets[index]) { identifier in
                    if identifier.hasPrefix("file:") {
                        job.targets[index].outputFileURL = URL(fileURLWithPath: String(identifier.dropFirst(5)))
                        job.targets[index].outputAssetIdentifier = nil
                    } else {
                        job.targets[index].outputAssetIdentifier = identifier
                        job.targets[index].outputFileURL = nil
                    }
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

    static func retryFailed<Payload>(job: BatchExportJob,
                            journalStore: BatchJournalStore?,
                            render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                            write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                              _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                            cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
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
                       cleanup: cleanup,
                       shouldCancel: shouldCancel, didUpdate: didUpdate, onlyIDs: failedIDs)
    }

    private static func markRemainingCancelled(_ job: inout BatchExportJob, from index: Int) {
        for remaining in index..<job.targets.count where [.pending, .processing, .failed, .cancelled].contains(job.targets[remaining].status) {
            job.targets[remaining].status = .cancelled
        }
    }
}
