import CryptoKit
import Darwin
import Foundation

public enum BatchSourceKind: String, Codable, Equatable, Sendable {
    case raw
    case raster
}

public struct BatchFrozenSettings: Codable, Equatable {
    public var version = 1
    public var settingsVersion = 1
    public let ordinal: Int
    public let settings: RawSettings
    public let inputSHA256: String
    public var lookURL: URL?
    public let lookSHA256: String?
    public let lookName: String?
    public let outputFormat: BatchOutputFormat
    public let longEdge: Int?

    public init(version: Int = 1, settingsVersion: Int = 1, ordinal: Int, settings: RawSettings,
                inputSHA256: String, lookURL: URL? = nil, lookSHA256: String? = nil,
                lookName: String? = nil, outputFormat: BatchOutputFormat, longEdge: Int? = nil) {
        self.version = version
        self.settingsVersion = settingsVersion
        self.ordinal = ordinal
        self.settings = settings
        self.inputSHA256 = inputSHA256
        self.lookURL = lookURL
        self.lookSHA256 = lookSHA256
        self.lookName = lookName
        self.outputFormat = outputFormat
        self.longEdge = longEdge
    }

    public func validate() throws {
        func digest(_ value: String?) -> Bool {
            value?.count == 64 && value!.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard version == 1, settingsVersion == 1, ordinal >= 0, ExportSize.isValid(longEdge), digest(inputSHA256),
              (lookURL == nil && lookSHA256 == nil && !settings.hasLook) || (lookURL != nil && digest(lookSHA256)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func verifyFiles(input: URL) throws {
        guard try PhotoIdentity.cachedFallback(for: input).contentIdentifier == inputSHA256 else {
            throw BatchExportError.target(L10n.text("原始文件已被替换，请重新选择照片。"))
        }
        if let lookURL, (try? PhotoIdentity.cachedFallback(for: lookURL).contentIdentifier) != lookSHA256 {
            throw BatchExportError.target(L10n.text("任务使用的外观文件不可用，请重新创建任务。"))
        }
    }
}

public enum BatchTargetStatus: String, Codable, Equatable, Sendable {
    case pending
    case processing
    case publishing
    case needsConfirmation
    case succeeded
    case failed
    case cancelled

    public var title: String {
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

public enum BatchJobStatus: String, Codable, Equatable, Sendable {
    case draft
    case running
    case completed
    case partialFailure
    case cancelled
    case interrupted
    case failed
}

public enum BatchExportError: LocalizedError, CustomNSError {
    case target(String)
    case global(String, underlying: Error? = nil)
    case uncertain(String, underlying: Error? = nil)

    public var errorDescription: String? {
        switch self {
        case .target(let message), .global(let message, _), .uncertain(let message, _):
            return message
        }
    }

    public var underlyingError: Error? {
        switch self {
        case .target: return nil
        case .global(_, let error), .uncertain(_, let error): return error
        }
    }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [:]
        info[NSLocalizedDescriptionKey] = errorDescription
        if let underlyingError { info[NSUnderlyingErrorKey] = underlyingError as NSError }
        return info
    }
}

public struct BatchSourceSnapshot: Codable, Equatable {
    public let identity: PhotoIdentity
    public var sourceFile: PhotoSourceFile
    public let displayName: String
    public let sourceKind: BatchSourceKind
    public let settings: RawSettings
    public var lookURL: URL?
    public var lookName: String?

    private enum CodingKeys: String, CodingKey {
        case sourceFile = "sourceURL"
        case identity, displayName, sourceKind, settings, lookURL, lookName
    }

    public init(identity: PhotoIdentity,
                sourceFile: PhotoSourceFile,
                displayName: String,
                sourceKind: BatchSourceKind = .raw,
                settings: RawSettings,
                lookURL: URL? = nil,
                lookName: String? = nil) {
        self.identity = identity
        self.sourceFile = sourceFile
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.settings = settings
        self.lookURL = lookURL
        self.lookName = lookName
    }

    public func settings(for targetKind: BatchSourceKind) -> RawSettings {
        if sourceKind == .raw, targetKind == .raster {
            var result = settings
            result.lensCorrection = nil
            return result
        }
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

    public func settings(for target: BatchTarget,
                         resolveX3fMode: BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> RawSettings {
        var result = settings(for: target.sourceKind)
        if target.isX3f {
            result.selectX3fMode(try resolveX3fMode(target.identity, target.sourceURL))
        }
        return result
    }
}

public struct BatchTarget: Codable, Equatable, Identifiable {
    public let identity: PhotoIdentity
    public var sourceURL: URL
    public let displayName: String
    public var sourceKind: BatchSourceKind
    public var status: BatchTargetStatus
    public var errorMessage: String?
    public var outputName: String
    public var outputAssetIdentifier: String?
    public var outputFileURL: URL?
    public var frozen: BatchFrozenSettings?

    public var id: String { identity.key }
    public var isX3f: Bool {
        sourceKind == .raw && (sourceURL.pathExtension.lowercased() == "x3f" ||
            (displayName as NSString).pathExtension.lowercased() == "x3f")
    }

    public init(identity: PhotoIdentity,
                sourceURL: URL,
                displayName: String,
                sourceKind: BatchSourceKind = .raw,
                status: BatchTargetStatus = .pending,
                errorMessage: String? = nil,
                outputName: String? = nil,
                outputFileURL: URL? = nil,
                outputAssetIdentifier: String? = nil,
                frozen: BatchFrozenSettings? = nil) {
        self.identity = identity
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.status = status
        self.errorMessage = errorMessage
        self.outputName = outputName ?? OutputNameAllocator.baseName(for: displayName)
        self.outputAssetIdentifier = outputAssetIdentifier
        self.outputFileURL = outputFileURL
        self.frozen = frozen
    }

    private enum CodingKeys: String, CodingKey {
        case identity, sourceURL, displayName, sourceKind, status, errorMessage
        case outputName, outputAssetIdentifier, outputFileURL, frozen
    }

    public init(from decoder: Decoder) throws {
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
        frozen = try values.decodeIfPresent(BatchFrozenSettings.self, forKey: .frozen)
    }
}

public struct BatchExportJob: Codable, Equatable, Identifiable {
    public static var defaultX3fModeProvider: ((URL) throws -> X3fMode)?

    public var version = 1
    public var settingsMode: BatchSettingsMode = .uniformFrozen
    public let id: UUID
    public var source: BatchSourceSnapshot
    public var targets: [BatchTarget]
    public var status: BatchJobStatus
    public var outputFormat: BatchOutputFormat
    public var longEdge: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var globalError: String?

    public init(id: UUID = UUID(),
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
        case version, id, source, targets, status, outputFormat, longEdge, createdAt, updatedAt, globalError
        case settingsMode = "settings_mode"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settingsMode = try values.decodeIfPresent(BatchSettingsMode.self, forKey: .settingsMode) ?? .uniformFrozen
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(BatchSourceSnapshot.self, forKey: .source)
        targets = try values.decode([BatchTarget].self, forKey: .targets)
        status = try values.decode(BatchJobStatus.self, forKey: .status)
        outputFormat = try values.decodeIfPresent(BatchOutputFormat.self, forKey: .outputFormat) ?? .jpeg
        longEdge = try values.decodeIfPresent(Int.self, forKey: .longEdge)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        globalError = try values.decodeIfPresent(String.self, forKey: .globalError)
        try validate()
    }

    public func validate() throws {
        guard (1...2).contains(version) else { throw CocoaError(.fileReadCorruptFile) }
        guard settingsMode == .perTargetFrozen else {
            guard version == 1, targets.allSatisfy({ $0.frozen == nil }) else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        guard version == 2, !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (index, target) in targets.enumerated() {
            guard let frozen = target.frozen, frozen.ordinal == index,
                  frozen.outputFormat == outputFormat, frozen.longEdge == longEdge else { throw CocoaError(.fileReadCorruptFile) }
            try frozen.validate()
        }
    }

    public typealias X3fModeResolver = (PhotoIdentity, URL) throws -> X3fMode

    public static func x3fModeResolver(
        store: EditPersistence? = nil,
        x3fDefaultMode: @escaping (URL) throws -> X3fMode = Self.defaultX3fMode(for:)
    ) -> X3fModeResolver {
        { identity, url in
            let persistence = try store ?? EditPersistence.appStore()
            if let saved = try persistence.readState(for: identity).state?.settings.x3fMode {
                return saved
            }
            return try x3fDefaultMode(url)
        }
    }

    public static func resolveX3fMode(identity: PhotoIdentity, url: URL) throws -> X3fMode {
        try x3fModeResolver()(identity, url)
    }

    public static func defaultX3fMode(for url: URL) throws -> X3fMode {
        guard let provider = defaultX3fModeProvider else {
            throw CocoaError(.featureUnsupported)
        }
        return try provider(url)
    }

    public func settings(for target: BatchTarget,
                         resolveX3fMode: X3fModeResolver = Self.resolveX3fMode) throws -> RawSettings {
        guard settingsMode == .perTargetFrozen else {
            return try source.settings(for: target, resolveX3fMode: resolveX3fMode)
        }
        guard let frozen = target.frozen else { throw CocoaError(.fileReadCorruptFile) }
        return frozen.settings
    }

    public func look(for target: BatchTarget) throws -> URL? {
        guard settingsMode == .perTargetFrozen else { return source.lookURL }
        guard let frozen = target.frozen else { throw CocoaError(.fileReadCorruptFile) }
        return frozen.lookURL
    }

    public func longEdge(for target: BatchTarget) throws -> Int? {
        guard settingsMode == .perTargetFrozen else { return longEdge }
        guard let frozen = target.frozen else { throw CocoaError(.fileReadCorruptFile) }
        return frozen.longEdge
    }

    public func recovered(assetExists: (String) -> Bool? = { _ in nil },
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

public final class BatchJournalStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func appStore() throws -> BatchJournalStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try BatchJournalStore(directory: root.appendingPathComponent("RawLab/BatchJobs", isDirectory: true))
    }

    public private(set) var lastQuarantinedURL: URL?
    private struct FileFingerprint: Equatable {
        let device: Int; let inode: Int; let size: Int
        let modified: Int; let modifiedNanoseconds: Int
        let statusChanged: Int; let statusChangedNanoseconds: Int
    }
    private var writtenFingerprints: [UUID: FileFingerprint] = [:]
    public private(set) var diskReloads = 0

    public func save(_ job: BatchExportJob) throws {
        try job.validate()
        let destination = directory.appendingPathComponent("\(job.id.uuidString).json")
        let fingerprint = Self.fingerprint(at: destination)
        if writtenFingerprints[job.id] == nil || writtenFingerprints[job.id] != fingerprint {
            diskReloads += 1
            _ = try load(id: job.id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(job).write(to: destination, options: .atomic)
        writtenFingerprints[job.id] = Self.fingerprint(at: destination)
    }

    private static func fingerprint(at url: URL) -> FileFingerprint? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileFingerprint(device: Int(info.st_dev), inode: Int(info.st_ino), size: Int(info.st_size),
                               modified: Int(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
                               statusChanged: Int(info.st_ctimespec.tv_sec), statusChangedNanoseconds: Int(info.st_ctimespec.tv_nsec))
    }

    public func load(id: UUID) throws -> BatchExportJob? {
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        do {
            return relocateOwnedFiles(try JSONDecoder().decode(BatchExportJob.self, from: data))
        } catch {
            if Self.isUnsupportedFutureJournal(data) { throw error }
            try quarantineCorruptJob(at: file, error: error)
            return nil
        }
    }

    public func pendingJobs() throws -> [BatchExportJob] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.compactMap { url -> BatchExportJob? in
            let data = try Data(contentsOf: url)
            let original: BatchExportJob
            do {
                original = try JSONDecoder().decode(BatchExportJob.self, from: data)
            } catch {
                if Self.isUnsupportedFutureJournal(data) { throw error }
                try quarantineCorruptJob(at: url, error: error)
                return nil
            }
            let recovered = relocateOwnedFiles(original).recovered()
            if recovered.status == .completed && recovered.outputFormat != .renderedDNG {
                try discard(id: recovered.id)
                return nil
            }
            if recovered != original { try save(recovered) }
            return recovered
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func quarantineCorruptJob(at url: URL, error: Error? = nil, now: Date = Date()) throws -> URL {
        let baseName = "\(url.lastPathComponent).corrupt-\(Self.corruptTimestamp(now))"
        var suffix = 0
        while true {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.moveItem(at: url, to: candidate)
                let reason = error.map { String(describing: $0) } ?? "corrupt entry"
                NSLog("Quarantined corrupt batch job from %@ to %@ (%@)", url.lastPathComponent, candidate.lastPathComponent, reason)
                lastQuarantinedURL = candidate
                return candidate
            }
            suffix += 1
        }
    }

    private static func isIntegerAbove(_ value: Any?, limit: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let decimal = number.decimalValue
        var rounded = Decimal()
        var copy = decimal
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard !decimal.isNaN, decimal == rounded else { return false }
        return decimal > Decimal(limit)
    }

    private static func hasFutureSettings(_ value: Any?) -> Bool {
        guard let settings = value as? [String: Any] else { return false }
        if let processing = settings["processing"] as? [String: Any],
           processing["family"] as? String == "rawlab",
           isIntegerAbove(processing["version"], limit: ProcessingIdentity.current.version) {
            return true
        }
        if isIntegerAbove(settings["masterRecipeSettingsVersion"], limit: 4) { return true }
        if let hdr = settings["hdr"] as? [String: Any] {
            if isIntegerAbove(hdr["hdr_processing_version"], limit: 8) ||
               isIntegerAbove(hdr["record_version"], limit: 9) {
                return true
            }
            if let cameraDev = hdr["camera_development"] as? [String: Any],
               isIntegerAbove(cameraDev["version"], limit: 1) {
                return true
            }
        }
        return false
    }

    private static func isUnsupportedFutureJournal(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        if isIntegerAbove(object["version"], limit: 2) { return true }
        if let source = object["source"] as? [String: Any], hasFutureSettings(source["settings"]) { return true }
        if let targets = object["targets"] as? [Any] {
            for case let target as [String: Any] in targets {
                guard let frozen = target["frozen"] as? [String: Any] else { continue }
                if isIntegerAbove(frozen["version"], limit: 1) ||
                   isIntegerAbove(frozen["settingsVersion"], limit: 1) ||
                   hasFutureSettings(frozen["settings"]) {
                    return true
                }
            }
        }
        return false
    }

    private static func corruptTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
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
        job.source.sourceFile = job.source.sourceFile.withReadAccess { .externallyManaged(relocate($0)) }
        job.source.lookURL = job.source.lookURL.map(relocate)
        for index in job.targets.indices {
            job.targets[index].sourceURL = relocate(job.targets[index].sourceURL)
            let relocatedLook = job.targets[index].frozen?.lookURL.map(relocate)
            job.targets[index].frozen?.lookURL = relocatedLook
        }
        return job
    }

    public func removeOrphanedJobDirectories() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let record = directory.appendingPathComponent("\(entry.lastPathComponent).json")
            if !FileManager.default.fileExists(atPath: record.path) { try? FileManager.default.removeItem(at: entry) }
        }
    }

    public func discard(id: UUID) throws {
        let record = directory.appendingPathComponent("\(id.uuidString).json")
        let inputs = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: inputs.path) { try FileManager.default.removeItem(at: inputs) }
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
        writtenFingerprints[id] = nil
    }
}

public enum BatchInputStore {
    public static func directory(for jobID: UUID, root: URL? = nil) throws -> URL {
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

    public static func copy(_ sourceURL: URL, identity: PhotoIdentity, jobID: UUID, root: URL? = nil,
                            displayName: String? = nil) throws -> URL {
        let directory = try directory(for: jobID, root: root)
        let displayExt = displayName.map { ($0 as NSString).pathExtension } ?? ""
        let ext = !sourceURL.pathExtension.isEmpty ? sourceURL.pathExtension : (!displayExt.isEmpty ? displayExt : "raw")
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

    public static func prepare(_ job: inout BatchExportJob, look: URL?, root: URL? = nil) throws {
        job.source.sourceFile = try job.source.sourceFile.withReadAccess {
            .externallyManaged(try copy($0, identity: job.source.identity, jobID: job.id, root: root,
                                        displayName: job.source.displayName))
        }
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

public enum BatchFileOutputStore {
    public static func root() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    public static func directory(for jobID: UUID) throws -> URL {
        let directory = root().appendingPathComponent(jobID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BatchExportError.global(error.localizedDescription, underlying: error)
        }
        return directory
    }

    public static func destination(jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(outputName)
    }

    public static func temporaryURL(for jobID: UUID, outputName: String) -> URL {
        root().appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent(".rawlab-\(UUID().uuidString)-\(outputName)")
    }
}

public enum BatchFileWriter {
    public static func write(file: URL, outputName: String, jobID: UUID,
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
            throw BatchExportError.global(error.localizedDescription, underlying: error)
        }
        do {
            try checkpoint("file:\(destination.path)")
        } catch {
            throw BatchExportError.uncertain(L10n.text("DNG 已生成，但任务记录未更新，请先核对保存结果。"),
                                             underlying: error)
        }
    }
}

public enum OutputNameAllocator {
    public static func baseName(for displayName: String, suffix: String = "jpg") -> String {
        let base = URL(fileURLWithPath: displayName).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "RawLab" : base) + "." + suffix
    }

    public static func assignUniqueNames(_ targets: [BatchTarget], suffix: String = "jpg") -> [BatchTarget] {
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

public struct BatchExportRunner {
    public typealias Cancellation = () -> Bool

    public static func run<Payload>(job: BatchExportJob,
                                    journalStore: BatchJournalStore?,
                                    render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                                    write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                                      _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                                    cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
                                    shouldCancel: @escaping Cancellation = { false },
                                    didUpdate: @escaping (BatchExportJob) -> Void = { _ in },
                                    onlyIDs: Set<String>? = nil,
                                    didFail: (_ error: Error, _ stage: String) -> Void = { _, _ in },
                                    resolveX3fMode: @escaping BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> BatchExportJob {
        var job = job
        try job.validate()
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
            didUpdate(job)
            do {
                let target = job.targets[index]
                if job.settingsMode == .perTargetFrozen { try target.frozen!.verifyFiles(input: target.sourceURL) }
                let payload = try render(target, job.settings(for: target, resolveX3fMode: resolveX3fMode))
                defer { cleanup(payload) }
                if shouldCancel() { throw CancellationError() }
                job.targets[index].status = .publishing
                try journalStore?.save(job)
                didUpdate(job)
                if shouldCancel() { throw CancellationError() }
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
            } catch is CancellationError {
                let hasPublication = job.targets[index].outputAssetIdentifier != nil || job.targets[index].outputFileURL != nil
                job.targets[index].status = hasPublication ? .needsConfirmation : .cancelled
                markRemainingCancelled(&job, from: index + 1)
                job.status = hasPublication ? .interrupted : .cancelled
                job.updatedAt = Date()
                try journalStore?.save(job)
                didUpdate(job)
                return job
            } catch let error as BatchExportError {
                didFail(error, job.targets[index].status == .publishing ? "publish" : "render")
                switch error {
                case .uncertain(let message, _):
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
                case .global(let message, _):
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
                didFail(error, job.targets[index].status == .publishing ? "publish" : "render")
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

    public static func retryFailed<Payload>(job: BatchExportJob,
                                            journalStore: BatchJournalStore?,
                                            render: @escaping (_ target: BatchTarget, _ settings: RawSettings) throws -> Payload,
                                            write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget,
                                                              _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                                            cleanup: @escaping (_ payload: Payload) -> Void = { _ in },
                                            shouldCancel: @escaping Cancellation = { false },
                                            didUpdate: @escaping (BatchExportJob) -> Void = { _ in },
                                            resolveX3fMode: @escaping BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> BatchExportJob {
        var retry = job
        let failedIDs = Set(job.targets.filter { $0.status == .failed }.map(\.id))
        for index in retry.targets.indices where retry.targets[index].status == .failed {
            retry.targets[index].status = .pending
            retry.targets[index].errorMessage = nil
        }
        retry.status = .draft
        return try run(job: retry, journalStore: journalStore, render: render, write: write,
                       cleanup: cleanup,
                       shouldCancel: shouldCancel, didUpdate: didUpdate, onlyIDs: failedIDs,
                       resolveX3fMode: resolveX3fMode)
    }

    private static func markRemainingCancelled(_ job: inout BatchExportJob, from index: Int) {
        for remaining in index..<job.targets.count where [.pending, .processing, .failed, .cancelled].contains(job.targets[remaining].status) {
            job.targets[remaining].status = .cancelled
        }
    }
}
