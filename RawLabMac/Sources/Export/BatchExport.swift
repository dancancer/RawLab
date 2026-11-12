import Foundation
import CryptoKit
import Darwin

enum BatchSettingsMode: String, Codable {
    case uniformFrozen = "uniform_frozen", perTargetFrozen = "per_target_frozen"
}

struct BatchFrozenSettings: Codable {
    var version = 1
    var settingsVersion = 1
    let ordinal: Int
    let settings: Adjustments
    let look: URL?
    let lookSHA256: String?
    let lookName: String
    let outputFormat: ExportFormat
    let longEdge: Int?

    static func checksum(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard version == 1, settingsVersion == 1, ordinal >= 0,
              longEdge == nil || (1...65535).contains(longEdge!),
              settings.isHDREditing || settings.masterRecipeID == nil || look != nil,
              (look == nil && lookSHA256 == nil) || (look != nil && lookSHA256?.count == 64 &&
                lookSHA256!.allSatisfy { "0123456789abcdef".contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func verifyLook() throws {
        guard let look else { return }
        guard let expected = lookSHA256, (try? Self.checksum(look)) == expected else {
            throw BatchExportFailure.missingLook
        }
    }
}

enum BatchItemStatus: String, Codable {
    case waiting, running, publishing, succeeded, failed
    var title: String {
        switch self {
        case .waiting: return L10n.text("等待导出")
        case .running, .publishing: return L10n.text("正在导出")
        case .succeeded: return L10n.text("已导出")
        case .failed: return L10n.text("导出失败")
        }
    }
}

struct BatchExportItem: Codable, Identifiable {
    let id: UUID
    let input: URL
    let identity: OriginalFileIdentity
    var selected = false
    var status = BatchItemStatus.waiting
    var output: URL?
    var completedIdentity: OriginalFileIdentity?
    var error: String?
    var validationError: String?
    var noticeKey: String?
    var resolvedX3fMode: X3fMode?
    var frozen: BatchFrozenSettings?
    var resourceIdentifier: String?

    init(url: URL) throws {
        id = UUID()
        input = url.resolvingSymlinksInPath().standardizedFileURL
        identity = try OriginalFileIdentity(input)
        resourceIdentifier = try Self.resourceKey(input)
    }

    static func resourceKey(_ url: URL) throws -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return path }
        return "\(device.uint64Value):\(inode.uint64Value)"
    }
}

struct BatchExportJob: Codable {
    var version = 1
    let id: UUID
    let source: URL
    let settings: Adjustments
    var look: URL?
    let lookName: String
    var items: [BatchExportItem] = []
    var outputDirectory: URL?
    var png = false
    var outputFormat: ExportFormat?
    var longEdge: Int?
    var started = false
    var interrupted = false
    var cancelled = false
    var failure: String?
    var settingsMode: BatchSettingsMode?

    enum CodingKeys: String, CodingKey {
        case version, id, source, settings, look, lookName, items, outputDirectory, png, outputFormat,
             longEdge, started, interrupted, cancelled, failure
        case settingsMode = "settings_mode"
    }

    var mode: BatchSettingsMode { settingsMode ?? .uniformFrozen }

    func validate() throws {
        guard (1...3).contains(version) else { throw CocoaError(.fileReadCorruptFile) }
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

    typealias X3fModeResolver = (URL) throws -> X3fMode

    static func x3fModeResolver(
        store: EditPersistence? = nil,
        directory: URL = EditPersistence.defaultDirectory,
        defaultMode: @escaping X3fModeResolver = RenderEngine.x3fDefaultMode(for:)
    ) -> X3fModeResolver {
        { input in
            let persistence = try store ?? EditPersistence(directory: directory)
            if let saved = try persistence.state(for: input)?.settings.x3fMode {
                return saved
            }
            return try defaultMode(input)
        }
    }

    static func resolveX3fMode(for input: URL) throws -> X3fMode {
        try x3fModeResolver()(input)
    }

    func snapshot(for item: BatchExportItem,
                  resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> BatchFrozenSettings {
        if mode == .perTargetFrozen {
            guard let frozen = item.frozen else { throw CocoaError(.fileReadCorruptFile) }
            try frozen.validate()
            return frozen
        }
        return BatchFrozenSettings(ordinal: 0,
            settings: try settings(for: item.input, resolveX3fMode: resolveX3fMode), look: look,
            lookSHA256: nil, lookName: lookName, outputFormat: format, longEdge: longEdge)
    }

    init(source: URL, settings: Adjustments, look: URL?, lookName: String) {
        id = UUID()
        self.source = source
        self.settings = settings
        self.look = look
        self.lookName = lookName
    }

    var selectedCount: Int { items.filter(\.selected).count }
    var succeededCount: Int { items.filter { $0.selected && $0.status == .succeeded }.count }
    var failedCount: Int { items.filter { $0.selected && $0.status == .failed }.count }
    var remainingCount: Int { selectedCount - succeededCount - failedCount }
    var format: ExportFormat {
        get { outputFormat ?? (png ? .png : .jpeg) }
        set { outputFormat = newValue; png = newValue == .png; version = max(version, 2) }
    }
    var suffix: String { format.suffix }

    func settings(for input: URL,
                  resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> Adjustments {
        if RenderEngine.isRasterInput(input) { return settings.resolvedForRaster }
        var resolved = settings
        if RenderEngine.isRasterInput(source), !RenderEngine.isRasterInput(input) {
            // 普通图像上不可用的相机参数不能在 RAW 目标上重新生效。
            let recipeTint = resolved.masterRecipe != nil ? resolved.tint : nil
            resolved.exposureMode = Adjustments().exposureMode
            resolved.resolveWhiteBalance(nil)
            resolved.resetWhiteBalance()
            if let recipeTint { resolved.tint = recipeTint }
            resolved.rawNoiseReduction = 0
            resolved.lensCorrection = nil
        }
        if RenderEngine.isX3fInput(input) {
            // 优先读取目标已保存编辑记录的 x3fMode，缺失时才回退 RenderEngine.x3fDefaultMode(for:)。
            let mode = try resolveX3fMode(input)
            resolved.selectX3fMode(mode)
        }
        return resolved
    }
}

final class BatchJournal {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Batch", isDirectory: true)
    }
    let directory: URL
    private(set) var lastQuarantinedURL: URL?
    private var quarantinedError: Error?
    private var url: URL { directory.appendingPathComponent("job.json") }

    init(directory: URL = BatchJournal.defaultDirectory) { self.directory = directory }

    func consumeQuarantinedError() -> Error? {
        defer { quarantinedError = nil }
        return quarantinedError
    }

    func save(_ job: BatchExportJob) throws {
        try job.validate()
        _ = try readJob()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }

    func snapshotLook(_ original: URL?, for id: UUID) throws -> URL? {
        guard let original else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(id.uuidString).\(original.pathExtension)")
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    private func readJob() throws -> BatchExportJob? {
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
            let job = try JSONDecoder().decode(BatchExportJob.self, from: data)
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
        if isIntegerAbove(object["version"], limit: 3) || hasFutureSettings(object["settings"]) {
            return true
        }
        if let items = object["items"] as? [Any] {
            for case let item as [String: Any] in items {
                guard let frozen = item["frozen"] as? [String: Any] else { continue }
                if isIntegerAbove(frozen["version"], limit: 1) ||
                   isIntegerAbove(frozen["settingsVersion"], limit: 1) ||
                   hasFutureSettings(frozen["settings"]) {
                    return true
                }
            }
        }
        return false
    }

    func load() throws -> BatchExportJob? {
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

    func discard(_ job: BatchExportJob) throws {
        if try readJob() != nil { try FileManager.default.removeItem(at: url) }
        releaseResources(job)
    }

    func releaseResources(_ job: BatchExportJob) {
        for item in job.items { cleanup(job, item: item) }
        if let look = job.look, look.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
           look.deletingPathExtension().lastPathComponent == job.id.uuidString {
            try? FileManager.default.removeItem(at: look)
        }
        for item in job.items {
            if let look = item.frozen?.look, look.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
               look.deletingPathExtension().lastPathComponent == item.id.uuidString {
                try? FileManager.default.removeItem(at: look)
            }
        }
    }

    private func cleanup(_ job: BatchExportJob, item: BatchExportItem) {
        guard let directory = job.outputDirectory else { return }
        let suffix = job.mode == .perTargetFrozen ? (item.frozen?.outputFormat.suffix ?? job.format.suffix) : job.format.suffix
        let temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(suffix)")
        try? FileManager.default.removeItem(at: temp)
    }
}

extension OriginalFileIdentity {
    func matchesContent(_ other: OriginalFileIdentity) -> Bool {
        size == other.size && modified == other.modified && fileNumber == other.fileNumber
    }
}

enum BatchRunScope { case unfinished, failed }

enum BatchExportFailure: LocalizedError {
    case destination, changedInput, missingLook, noSelection
    var errorDescription: String? {
        switch self {
        case .destination: return L10n.text("无法写入输出目录，请检查访问权限和剩余空间。")
        case .changedInput: return L10n.text("原始文件已被替换，请重新选择照片。")
        case .missingLook: return L10n.text("任务使用的外观文件不可用，请重新创建任务。")
        case .noSelection: return L10n.text("请至少选择一张照片。")
        }
    }
}

enum BatchExportRunner {
    typealias Render = (URL, Adjustments, URL?, URL) throws -> Void
    typealias RenderSnapshot = (URL, BatchFrozenSettings, URL) throws -> Void

    static func run(job: inout BatchExportJob, journal: BatchJournal, scope: BatchRunScope,
                    resolveX3fMode: BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode(for:),
                    shouldCancel: () -> Bool, didUpdate: (BatchExportJob) -> Void = { _ in },
                    render: Render) throws {
        try runSnapshots(job: &job, journal: journal, scope: scope, resolveX3fMode: resolveX3fMode,
                         shouldCancel: shouldCancel, didUpdate: didUpdate) { input, snapshot, output in
            try render(input, snapshot.settings, snapshot.look, output)
        }
    }

    static func runSnapshots(job: inout BatchExportJob, journal: BatchJournal, scope: BatchRunScope,
                             resolveX3fMode: BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode(for:),
                             shouldCancel: () -> Bool, didUpdate: (BatchExportJob) -> Void = { _ in },
                             render: RenderSnapshot) throws {
        try job.validate()
        guard let directory = job.outputDirectory else { throw BatchExportFailure.destination }
        guard job.selectedCount > 0 else { throw BatchExportFailure.noSelection }
        if job.mode == .uniformFrozen, let look = job.look, !FileManager.default.isReadableFile(atPath: look.path) {
            throw BatchExportFailure.missingLook
        }
        try verifyDestination(directory)
        job.started = true; job.interrupted = false; job.cancelled = false; job.failure = nil
        try journal.save(job)
        do {
            for index in job.items.indices {
                let item = job.items[index]
                guard item.selected, item.status != .succeeded,
                      scope != .failed || item.status == .failed else { continue }
                if shouldCancel() { job.cancelled = true; break }
                try verifyDestination(directory)
                job.items[index].status = .running
                job.items[index].error = nil
                try journal.save(job)
                didUpdate(job)
                try export(index, job: &job, journal: journal, directory: directory,
                           resolveX3fMode: resolveX3fMode, shouldCancel: shouldCancel, render: render)
                didUpdate(job)
                if shouldCancel() { job.cancelled = true; break }
            }
        } catch {
            job.interrupted = true; job.failure = error.localizedDescription
            try? journal.save(job)
            didUpdate(job)
            throw error
        }
        try journal.save(job)
        didUpdate(job)
    }

    private static func export(_ index: Int, job: inout BatchExportJob, journal: BatchJournal,
                               directory: URL, resolveX3fMode: BatchExportJob.X3fModeResolver,
                               shouldCancel: () -> Bool, render: RenderSnapshot) throws {
        let item = job.items[index]
        let snapshot: BatchFrozenSettings
        let temp: URL
        var cleanupTemp: URL?
        defer { if let cleanupTemp { try? FileManager.default.removeItem(at: cleanupTemp) } }
        do {
            guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
            if job.mode == .perTargetFrozen {
                guard try BatchExportItem.resourceKey(item.input) == item.resourceIdentifier else { throw BatchExportFailure.changedInput }
            }
            snapshot = try job.snapshot(for: item, resolveX3fMode: resolveX3fMode)
            if job.mode == .uniformFrozen {
                job.items[index].resolvedX3fMode = RenderEngine.isX3fInput(item.input) ? snapshot.settings.x3fMode : nil
            }
            if job.mode == .perTargetFrozen {
                try snapshot.verifyLook()
            }
            temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(snapshot.outputFormat.suffix)")
            cleanupTemp = temp
            try render(item.input, snapshot, temp)
        } catch RenderError.aiCancelled where shouldCancel() {
            job.items[index].status = .waiting
            job.items[index].error = nil
            try journal.save(job)
            return
        } catch {
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try journal.save(job)
            if isStorageFailure(error) { throw error }
            try verifyDestination(directory)
            return
        }
        let name = item.input.deletingPathExtension().lastPathComponent + "-" + safeName(snapshot.lookName)
        let output = uniqueOutput(directory: directory, name: name, suffix: snapshot.outputFormat.suffix)
        // 在发布前记录 inode；重启能识别已发布但尚未来得及记成功的成片。
        job.items[index].output = output
        job.items[index].completedIdentity = try OriginalFileIdentity(temp)
        job.items[index].status = .publishing
        try journal.save(job)
        do {
            try FileManager.default.moveItem(at: temp, to: output)
        } catch {
            job.items[index].status = .failed
            job.items[index].error = error.localizedDescription
            try journal.save(job)
            if isStorageFailure(error) { throw error }
            return
        }
        job.items[index].status = .succeeded
        job.items[index].error = nil
        try journal.save(job)
    }

    static func uniqueOutput(directory: URL, name: String, suffix: String) -> URL {
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
        if case RenderError.outputIO = error { return true }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [28, 13, 30].contains(error.code))
    }
}
