import CryptoKit
import Darwin
import Foundation

public protocol BatchRenderError: Error {
    var isAICancelled: Bool { get }
    var isOutputIO: Bool { get }
}

public enum MacBatchExportEnvironment {
    public static var isRasterInput: (URL) -> Bool = { PhotoInputClassification.isRasterInput($0) }
    public static var isX3fInput: (URL) -> Bool = { $0.pathExtension.lowercased() == "x3f" }
    public static var defaultX3fMode: (URL) throws -> X3fMode = { _ in throw CocoaError(.featureUnsupported) }
    public static var isAICancelledError: (Error) -> Bool = { ($0 as? BatchRenderError)?.isAICancelled == true }
    public static var isOutputIOError: (Error) -> Bool = { ($0 as? BatchRenderError)?.isOutputIO == true }
}

public enum BatchJournalVersionKey: String, CaseIterable, Sendable {
    case job
    case frozen
    case frozenSettings
    case processing
    case masterRecipeSettings
    case hdrProcessing
    case hdrRecord
    case hdrCameraDevelopment

    public var maxSupportedVersion: Int {
        switch self {
        case .job: return 3
        case .frozen: return 1
        case .frozenSettings: return 1
        case .processing: return ProcessingIdentity.current.version
        case .masterRecipeSettings: return 4
        case .hdrProcessing: return 8
        case .hdrRecord: return 9
        case .hdrCameraDevelopment: return 1
        }
    }
}

public struct MacBatchFrozenSettings: Codable {
    public var version = 1
    public var settingsVersion = 1
    public let ordinal: Int
    public let settings: Adjustments
    public let look: URL?
    public let lookSHA256: String?
    public let lookName: String
    public let outputFormat: ExportFormat
    public let longEdge: Int?
    public let outputSharpening: OutputSharpening?

    public var effectiveOutputSharpening: OutputSharpening {
        outputFormat == .renderedDNG ? .off : (outputSharpening ?? .off)
    }

    public init(version: Int = 1, settingsVersion: Int = 1, ordinal: Int, settings: Adjustments,
                look: URL?, lookSHA256: String?, lookName: String,
                outputFormat: ExportFormat, longEdge: Int?,
                outputSharpening: OutputSharpening? = nil) {
        self.version = version
        self.settingsVersion = settingsVersion
        self.ordinal = ordinal
        self.settings = settings
        self.look = look
        self.lookSHA256 = lookSHA256
        self.lookName = lookName
        self.outputFormat = outputFormat
        self.longEdge = longEdge
        self.outputSharpening = outputSharpening
    }

    public static func checksum(_ url: URL) throws -> String {
        try MacResourceDigestCache.shared.fingerprintDigest(for: url).digest
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func validateSettings(_ settings: Adjustments) throws {
        do {
            try settings.validateResetValues()
            if settings.isHDREditing {
                var sdr = settings
                sdr.hdr?.mode = .sdr
                try sdr.validateResetValues()
            } else if settings.hdr?.isValid == false {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func validate() throws {
        guard version == BatchJournalVersionKey.frozen.maxSupportedVersion,
              settingsVersion == BatchJournalVersionKey.frozenSettings.maxSupportedVersion,
              ordinal >= 0,
              longEdge == nil || (1...65535).contains(longEdge!),
              settings.isHDREditing || settings.masterRecipeID == nil || look != nil,
              (look == nil && lookSHA256 == nil) || (look != nil && lookSHA256?.count == 64 &&
                lookSHA256!.allSatisfy { "0123456789abcdef".contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Self.validateSettings(settings)
    }

    public func verifyLook() throws {
        guard let look else { return }
        guard let expected = lookSHA256, (try? Self.checksum(look)) == expected else {
            throw BatchExportFailure.missingLook
        }
    }
}

public enum BatchItemStatus: String, Codable, Sendable {
    case waiting, running, publishing, succeeded, failed
    public var title: String {
        switch self {
        case .waiting: return L10n.text("等待导出")
        case .running, .publishing: return L10n.text("正在导出")
        case .succeeded: return L10n.text("已导出")
        case .failed: return L10n.text("导出失败")
        }
    }
}

public struct MacBatchExportItem: Codable, Identifiable {
    public let id: UUID
    public let input: URL
    public let identity: OriginalFileIdentity
    public var selected = false
    public var status = BatchItemStatus.waiting
    public var output: URL?
    public var completedIdentity: OriginalFileIdentity?
    public var error: String?
    public var validationError: String?
    public var noticeKey: String?
    public var resolvedX3fMode: X3fMode?
    public var frozen: MacBatchFrozenSettings?
    public var resourceIdentifier: String?

    public init(url: URL) throws {
        id = UUID()
        input = url.resolvingSymlinksInPath().standardizedFileURL
        identity = try OriginalFileIdentity(input)
        resourceIdentifier = try Self.resourceKey(input)
    }

    public static func resourceKey(_ url: URL) throws -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return path }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }
}

public struct MacBatchExportJob: Codable {
    public var version = 1
    public let id: UUID
    public let source: URL
    public let settings: Adjustments
    public var look: URL?
    public let lookName: String
    public var items: [MacBatchExportItem] = []
    public var outputDirectory: URL?
    public var png = false
    public var outputFormat: ExportFormat?
    public var longEdge: Int?
    public var outputSharpening: OutputSharpening?
    public var started = false
    public var interrupted = false
    public var cancelled = false
    public var failure: String?
    public var settingsMode: BatchSettingsMode?

    public var effectiveOutputSharpening: OutputSharpening {
        format == .renderedDNG ? .off : (outputSharpening ?? .off)
    }

    public enum CodingKeys: String, CodingKey {
        case version, id, source, settings, look, lookName, items, outputDirectory, png, outputFormat,
             longEdge, started, interrupted, cancelled, failure
        case outputSharpening = "output_sharpening"
        case settingsMode = "settings_mode"
    }

    public var mode: BatchSettingsMode { settingsMode ?? .uniformFrozen }

    public func validate() throws {
        guard (1...BatchJournalVersionKey.job.maxSupportedVersion).contains(version),
              longEdge == nil || (1...65535).contains(longEdge!) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try MacBatchFrozenSettings.validateSettings(settings)
        guard mode == .perTargetFrozen else {
            guard version < 3, items.allSatisfy({ $0.frozen == nil }) else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        guard version == 3, !items.isEmpty, Set(items.map(\.id)).count == items.count,
              Set(items.map { $0.resourceIdentifier ?? $0.identity.path }).count == items.count,
              Set(items.map(\.input)).count == items.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (index, item) in items.enumerated() {
            guard let frozen = item.frozen, frozen.ordinal == index else { throw CocoaError(.fileReadCorruptFile) }
            try frozen.validate()
        }
    }

    public typealias X3fModeResolver = (URL) throws -> X3fMode

    public static func x3fModeResolver(
        store: MacEditPersistence? = nil,
        directory: URL = MacEditPersistence.defaultDirectory,
        defaultMode: @escaping X3fModeResolver = { try MacBatchExportEnvironment.defaultX3fMode($0) }
    ) -> X3fModeResolver {
        { input in
            let persistence = try store ?? MacEditPersistence(directory: directory)
            if let saved = try persistence.state(for: input)?.settings.x3fMode {
                return saved
            }
            return try defaultMode(input)
        }
    }

    public static func resolveX3fMode(for input: URL) throws -> X3fMode {
        try x3fModeResolver()(input)
    }

    public func snapshot(for item: MacBatchExportItem,
                         resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> MacBatchFrozenSettings {
        if mode == .perTargetFrozen {
            guard let frozen = item.frozen else { throw CocoaError(.fileReadCorruptFile) }
            try frozen.validate()
            return frozen
        }
        return MacBatchFrozenSettings(ordinal: 0,
            settings: try settings(for: item.input, resolveX3fMode: resolveX3fMode), look: look,
            lookSHA256: nil, lookName: lookName, outputFormat: format, longEdge: longEdge,
            outputSharpening: effectiveOutputSharpening)
    }

    public init(source: URL, settings: Adjustments, look: URL?, lookName: String) {
        id = UUID()
        self.source = source
        self.settings = settings
        self.look = look
        self.lookName = lookName
    }

    public var selectedCount: Int { items.filter(\.selected).count }
    public var succeededCount: Int { items.filter { $0.selected && $0.status == .succeeded }.count }
    public var failedCount: Int { items.filter { $0.selected && $0.status == .failed }.count }
    public var remainingCount: Int { selectedCount - succeededCount - failedCount }
    public var format: ExportFormat {
        get { outputFormat ?? (png ? .png : .jpeg) }
        set { outputFormat = newValue; png = newValue == .png; version = max(version, 2) }
    }
    public var suffix: String { format.suffix }

    public func settings(for input: URL,
                         resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> Adjustments {
        if MacBatchExportEnvironment.isRasterInput(input) { return settings.resolvedForRaster }
        var resolved = settings
        if MacBatchExportEnvironment.isRasterInput(source), !MacBatchExportEnvironment.isRasterInput(input) {
            let recipeTint = resolved.masterRecipe != nil ? resolved.tint : nil
            resolved.exposureMode = Adjustments().exposureMode
            resolved.resolveWhiteBalance(nil)
            resolved.resetWhiteBalance()
            if let recipeTint { resolved.tint = recipeTint }
            resolved.rawNoiseReduction = 0
            resolved.lensCorrection = nil
        }
        if MacBatchExportEnvironment.isX3fInput(input) {
            let mode = try resolveX3fMode(input)
            resolved.selectX3fMode(mode)
        }
        return resolved
    }
}

public final class MacBatchJournal {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Batch", isDirectory: true)
    }
    public let directory: URL
    public private(set) var lastQuarantinedURL: URL?
    private var quarantinedError: Error?
    private var url: URL { directory.appendingPathComponent("job.json") }
    private struct FileFingerprint: Equatable { let size: Int; let modified: Date }
    private var writtenFingerprint: FileFingerprint?
    public private(set) var diskReloads = 0

    public init(directory: URL = MacBatchJournal.defaultDirectory) { self.directory = directory }

    public func consumeQuarantinedError() -> Error? {
        defer { quarantinedError = nil }
        return quarantinedError
    }

    public func save(_ job: MacBatchExportJob) throws {
        quarantinedError = nil
        try job.validate()
        let fingerprint = Self.fingerprint(atPath: url.path)
        if writtenFingerprint == nil || writtenFingerprint != fingerprint {
            diskReloads += 1
            _ = try readJob()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        writtenFingerprint = Self.fingerprint(atPath: url.path)
    }

    public func snapshotLook(_ original: URL?, jobID: UUID, contentIdentifier: String?) throws -> URL? {
        guard let original else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(jobID.uuidString)-\(contentIdentifier ?? UUID().uuidString).\(original.pathExtension)")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: original, to: copy)
        }
        return copy
    }

    private func readJob() throws -> MacBatchExportJob? {
        quarantinedError = nil
        switch try Self.itemType(atPath: directory.path) {
        case nil: return nil
        case .typeDirectory?: break
        default: throw CocoaError(.fileReadCorruptFile)
        }
        switch try Self.itemType(atPath: url.path) {
        case nil: return nil
        case .typeRegular?: break
        default: throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url)
        do {
            let job = try JSONDecoder().decode(MacBatchExportJob.self, from: data)
            try job.validate()
            return job
        } catch {
            if Self.isUnsupportedFutureJournal(data) { throw error }
            lastQuarantinedURL = try quarantineCorruptJob()
            quarantinedError = error
            return nil
        }
    }

    private func quarantineCorruptJob(now: Date = Date()) throws -> URL {
        let baseName = "job.json.corrupt-\(Self.corruptTimestamp(now))"
        var suffix = 0
        while true {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let candidate = directory.appendingPathComponent(name)
            if try Self.itemType(atPath: candidate.path) == nil {
                try FileManager.default.moveItem(at: url, to: candidate)
                return candidate
            }
            suffix += 1
        }
    }

    private static func corruptTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func fingerprint(atPath path: String) -> FileFingerprint? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path),
              let size = values[.size] as? Int,
              let modified = values[.modificationDate] as? Date else { return nil }
        return FileFingerprint(size: size, modified: modified)
    }

    private static func itemType(atPath path: String) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                   underlying.domain == NSPOSIXErrorDomain {
                    if underlying.code == ENOENT { return nil }
                    throw error
                }
                return nil
            }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT { return nil }
            throw error
        }
    }

    private static func isIntegerAbove(_ value: Any?, limit: Int) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
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
           isIntegerAbove(processing["version"], limit: BatchJournalVersionKey.processing.maxSupportedVersion) {
            return true
        }
        if isIntegerAbove(settings["masterRecipeSettingsVersion"],
                          limit: BatchJournalVersionKey.masterRecipeSettings.maxSupportedVersion) {
            return true
        }
        if let hdr = settings["hdr"] as? [String: Any] {
            if isIntegerAbove(hdr["hdr_processing_version"],
                              limit: BatchJournalVersionKey.hdrProcessing.maxSupportedVersion) ||
               isIntegerAbove(hdr["record_version"],
                              limit: BatchJournalVersionKey.hdrRecord.maxSupportedVersion) {
                return true
            }
            if let cameraDev = hdr["camera_development"] as? [String: Any],
               isIntegerAbove(cameraDev["version"],
                              limit: BatchJournalVersionKey.hdrCameraDevelopment.maxSupportedVersion) {
                return true
            }
        }
        return false
    }

    private static func isUnsupportedFutureJournal(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        if isIntegerAbove(object["version"], limit: BatchJournalVersionKey.job.maxSupportedVersion) ||
           hasFutureSettings(object["settings"]) {
            return true
        }
        if let items = object["items"] as? [Any] {
            for case let item as [String: Any] in items {
                guard let frozen = item["frozen"] as? [String: Any] else { continue }
                if isIntegerAbove(frozen["version"], limit: BatchJournalVersionKey.frozen.maxSupportedVersion) ||
                   isIntegerAbove(frozen["settingsVersion"], limit: BatchJournalVersionKey.frozenSettings.maxSupportedVersion) ||
                   hasFutureSettings(frozen["settings"]) {
                    return true
                }
            }
        }
        return false
    }

    public func load() throws -> MacBatchExportJob? {
        quarantinedError = nil
        guard var job = try readJob() else { return nil }
        for index in job.items.indices where [.running, .publishing].contains(job.items[index].status) {
            let item = job.items[index]
            if item.status == .publishing, let output = item.output, let expected = item.completedIdentity,
               let actual = try? OriginalFileIdentity(output), expected.matchesContent(actual) {
                job.items[index].status = .succeeded
            } else {
                job.items[index].status = .waiting
                job.items[index].error = nil
            }
            job.interrupted = true
            cleanup(job, item: item)
        }
        if job.started && job.remainingCount > 0 { job.interrupted = true }
        return job
    }

    public func discard(_ job: MacBatchExportJob) throws {
        quarantinedError = nil
        if try readJob() != nil { try FileManager.default.removeItem(at: url) }
        releaseResources(job)
    }

    public func releaseResources(_ job: MacBatchExportJob) {
        for item in job.items { cleanup(job, item: item) }
        let owned = { (stem: String, id: UUID) in stem == id.uuidString || stem.hasPrefix("\(job.id.uuidString)-") }
        if let look = job.look, look.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
           owned(look.deletingPathExtension().lastPathComponent, job.id) {
            try? FileManager.default.removeItem(at: look)
        }
        for item in job.items {
            if let look = item.frozen?.look, look.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
               owned(look.deletingPathExtension().lastPathComponent, item.id) {
                try? FileManager.default.removeItem(at: look)
            }
        }
    }

    private func cleanup(_ job: MacBatchExportJob, item: MacBatchExportItem) {
        guard let directory = job.outputDirectory else { return }
        let suffix = job.mode == .perTargetFrozen ? (item.frozen?.outputFormat.suffix ?? job.format.suffix) : job.format.suffix
        let temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(suffix)")
        try? FileManager.default.removeItem(at: temp)
    }
}

public extension OriginalFileIdentity {
    func matchesContent(_ other: OriginalFileIdentity) -> Bool {
        size == other.size && modified == other.modified && fileNumber == other.fileNumber
    }
}

public enum BatchRunScope: Sendable { case unfinished, failed }

public enum BatchExportFailure: LocalizedError, Sendable {
    case destination, changedInput, missingLook, noSelection
    public var errorDescription: String? {
        switch self {
        case .destination: return L10n.text("无法写入输出目录，请检查访问权限和剩余空间。")
        case .changedInput: return L10n.text("原始文件已被替换，请重新选择照片。")
        case .missingLook: return L10n.text("任务使用的外观文件不可用，请重新创建任务。")
        case .noSelection: return L10n.text("请至少选择一张照片。")
        }
    }
}

public enum MacBatchExportRunner {
    public typealias Render = (URL, Adjustments, URL?, URL) throws -> Void
    public typealias RenderSnapshot = (URL, MacBatchFrozenSettings, URL) throws -> Void

    private static func save(_ job: MacBatchExportJob, to journal: MacBatchJournal,
                             onQuarantine: (Error) -> Void) throws {
        defer { if let quarantined = journal.consumeQuarantinedError() { onQuarantine(quarantined) } }
        try journal.save(job)
    }

    public static func run(job: inout MacBatchExportJob, journal: MacBatchJournal, scope: BatchRunScope,
                           resolveX3fMode: MacBatchExportJob.X3fModeResolver = MacBatchExportJob.resolveX3fMode(for:),
                           shouldCancel: () -> Bool, didUpdate: (MacBatchExportJob) -> Void = { _ in },
                           onQuarantine: (Error) -> Void = { _ in },
                           render: Render) throws {
        try runSnapshots(job: &job, journal: journal, scope: scope, resolveX3fMode: resolveX3fMode,
                         shouldCancel: shouldCancel, didUpdate: didUpdate, onQuarantine: onQuarantine) { input, snapshot, output in
            try render(input, snapshot.settings, snapshot.look, output)
        }
    }

    public static func runSnapshots(job: inout MacBatchExportJob, journal: MacBatchJournal, scope: BatchRunScope,
                                    resolveX3fMode: MacBatchExportJob.X3fModeResolver = MacBatchExportJob.resolveX3fMode(for:),
                                    shouldCancel: () -> Bool, didUpdate: (MacBatchExportJob) -> Void = { _ in },
                                    onQuarantine: (Error) -> Void = { _ in },
                                    render: RenderSnapshot) throws {
        try job.validate()
        guard let directory = job.outputDirectory else { throw BatchExportFailure.destination }
        guard job.selectedCount > 0 else { throw BatchExportFailure.noSelection }
        if job.mode == .uniformFrozen, let look = job.look, !FileManager.default.isReadableFile(atPath: look.path) {
            throw BatchExportFailure.missingLook
        }
        try verifyDestination(directory)
        job.started = true; job.interrupted = false; job.cancelled = false; job.failure = nil
        try save(job, to: journal, onQuarantine: onQuarantine)
        do {
            for index in job.items.indices {
                let item = job.items[index]
                guard item.selected, item.status != .succeeded,
                      scope != .failed || item.status == .failed else { continue }
                if shouldCancel() { job.cancelled = true; break }
                guard FileManager.default.isWritableFile(atPath: directory.path) else { throw BatchExportFailure.destination }
                job.items[index].status = .running
                job.items[index].error = nil
                try save(job, to: journal, onQuarantine: onQuarantine)
                didUpdate(job)
                try export(index, job: &job, journal: journal, directory: directory,
                           resolveX3fMode: resolveX3fMode, shouldCancel: shouldCancel,
                           onQuarantine: onQuarantine, render: render)
                didUpdate(job)
                if shouldCancel() { job.cancelled = true; break }
            }
        } catch {
            job.interrupted = true; job.failure = error.localizedDescription
            try? save(job, to: journal, onQuarantine: onQuarantine)
            didUpdate(job)
            throw error
        }
        try save(job, to: journal, onQuarantine: onQuarantine)
        didUpdate(job)
    }

    private static func export(_ index: Int, job: inout MacBatchExportJob, journal: MacBatchJournal,
                               directory: URL, resolveX3fMode: MacBatchExportJob.X3fModeResolver,
                               shouldCancel: () -> Bool, onQuarantine: (Error) -> Void,
                               render: RenderSnapshot) throws {
        let item = job.items[index]
        let snapshot: MacBatchFrozenSettings
        let temp: URL
        var cleanupTemp: URL?
        defer { if let cleanupTemp { try? FileManager.default.removeItem(at: cleanupTemp) } }
        do {
            guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
            if job.mode == .perTargetFrozen {
                guard try MacBatchExportItem.resourceKey(item.input) == item.resourceIdentifier else { throw BatchExportFailure.changedInput }
            }
            snapshot = try job.snapshot(for: item, resolveX3fMode: resolveX3fMode)
            if job.mode == .uniformFrozen {
                job.items[index].resolvedX3fMode = MacBatchExportEnvironment.isX3fInput(item.input) ? snapshot.settings.x3fMode : nil
            }
            if job.mode == .perTargetFrozen {
                try snapshot.verifyLook()
            }
            temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(snapshot.outputFormat.suffix)")
            cleanupTemp = temp
            try render(item.input, snapshot, temp)
        } catch {
            if MacBatchExportEnvironment.isAICancelledError(error) && shouldCancel() {
                job.items[index].status = .waiting
                job.items[index].error = nil
                try save(job, to: journal, onQuarantine: onQuarantine)
                return
            }
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try save(job, to: journal, onQuarantine: onQuarantine)
            if isStorageFailure(error) { throw error }
            try verifyDestination(directory)
            return
        }
        let name = item.input.deletingPathExtension().lastPathComponent + "-" + safeName(snapshot.lookName)
        let output = uniqueOutput(directory: directory, name: name, suffix: snapshot.outputFormat.suffix)
        job.items[index].output = output
        job.items[index].completedIdentity = try OriginalFileIdentity(temp)
        job.items[index].status = .publishing
        try save(job, to: journal, onQuarantine: onQuarantine)
        do {
            try FileManager.default.moveItem(at: temp, to: output)
        } catch {
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try save(job, to: journal, onQuarantine: onQuarantine)
            if isStorageFailure(error) { throw error }
            return
        }
        job.items[index].status = .succeeded
        job.items[index].error = nil
        try save(job, to: journal, onQuarantine: onQuarantine)
    }

    public static func uniqueOutput(directory: URL, name: String, suffix: String) -> URL {
        var number = 0
        while true {
            let label = name + (number == 0 ? "" : "-\(number)") + "." + suffix
            let url = directory.appendingPathComponent(label)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    private static func safeName(_ name: String) -> String {
        let text = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
        return String(text.prefix(80))
    }

    private static func verifyDestination(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".rawlab-write-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch { throw BatchExportFailure.destination }
    }

    private static func isStorageFailure(_ error: Error) -> Bool {
        if MacBatchExportEnvironment.isOutputIOError(error) { return true }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [28, 13, 30].contains(error.code))
    }
}
