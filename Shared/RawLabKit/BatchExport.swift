import CryptoKit
import Foundation

public protocol BatchRenderError: Error {
    var isAICancelled: Bool { get }
    var isOutputIO: Bool { get }
}

public enum BatchExportEnvironment {
    public static var isRasterInput: (URL) -> Bool = { PhotoInputClassification.isRasterInput($0) }
    public static var isX3fInput: (URL) -> Bool = { $0.pathExtension.lowercased() == "x3f" }
    public static var defaultX3fMode: (URL) throws -> X3fMode = { _ in throw CocoaError(.featureUnsupported) }
    public static var isAICancelledError: (Error) -> Bool = { ($0 as? BatchRenderError)?.isAICancelled == true }
    public static var isOutputIOError: (Error) -> Bool = { ($0 as? BatchRenderError)?.isOutputIO == true }
}
public typealias MacBatchExportEnvironment = BatchExportEnvironment

public enum BatchJournalVersionKey: String, CaseIterable, Sendable {
    case job, frozen, frozenSettings, processing, masterRecipeSettings, hdrProcessing, hdrRecord, hdrCameraDevelopment
    public var maxSupportedVersion: Int {
        switch self {
        case .job: return 3
        case .frozen, .frozenSettings, .hdrCameraDevelopment: return 1
        case .processing: return ProcessingIdentity.current.version
        case .masterRecipeSettings: return 4
        case .hdrProcessing: return 9
        case .hdrRecord: return 10
        }
    }
}
public enum BatchSourceKind: String, Codable, Equatable, Sendable { case raw, raster }
public enum BatchTargetStatus: String, Codable, Equatable, Sendable {
    case pending, processing, publishing, needsConfirmation, succeeded, failed, cancelled
    public var title: String {
        switch self {
        case .pending: return L10n.text("等待导出"); case .processing: return L10n.text("正在显影")
        case .publishing: return L10n.text("正在保存"); case .needsConfirmation: return L10n.text("保存结果待确认")
        case .succeeded: return L10n.text("已保存"); case .failed: return L10n.text("导出失败"); case .cancelled: return L10n.text("未处理")
        }
    }
}
public enum BatchJobStatus: String, Codable, Equatable, Sendable { case draft, running, completed, partialFailure, cancelled, interrupted, failed }
public enum BatchExportError: LocalizedError, CustomNSError {
    case target(String), global(String, underlying: Error? = nil), uncertain(String, underlying: Error? = nil)
    public var errorDescription: String? { switch self { case .target(let m), .global(let m, _), .uncertain(let m, _): return m } }
    public var underlyingError: Error? { switch self { case .target: return nil; case .global(_, let e), .uncertain(_, let e): return e } }
    public var errorUserInfo: [String: Any] {
        var info = [String: Any]()
        if let d = errorDescription { info[NSLocalizedDescriptionKey] = d }; if let e = underlyingError { info[NSUnderlyingErrorKey] = e }; return info
    }
}
public enum BatchItemStatus: String, Codable, Sendable {
    case waiting, running, publishing, succeeded, failed
    public var title: String {
        switch self { case .waiting: return L10n.text("等待导出"); case .running, .publishing: return L10n.text("正在导出"); case .succeeded: return L10n.text("已导出"); case .failed: return L10n.text("导出失败") }
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

internal enum BatchExportCore {
    static let maxSupportedJobVersion = 2

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while true { let c = try h.read(upToCount: 1024 * 1024) ?? Data(); if c.isEmpty { break }; hasher.update(data: c) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateSettings(_ settings: Adjustments) throws {
        do {
            try settings.validateResetValues()
            if settings.isHDREditing { var sdr = settings; sdr.hdr?.mode = .sdr; try sdr.validateResetValues() }
            else if settings.hdr?.isValid == false { throw CocoaError(.fileReadCorruptFile) }
        } catch { throw CocoaError(.fileReadCorruptFile) }
    }

    static func resolveSettings(_ base: Adjustments, isRaw: Bool, isX3f: Bool,
                                defaultRawExposureMode: ExposureMode, resolveX3fMode: () throws -> X3fMode) throws -> Adjustments {
        var r = base; r.exposureMode = isRaw ? defaultRawExposureMode : .sensor
        if isX3f { r.x3fMode = try resolveX3fMode() }
        return r
    }

    static func itemType(atPath path: String) throws -> FileAttributeType? {
        do { return try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType }
        catch let e as NSError where (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) || (e.domain == NSPOSIXErrorDomain && e.code == ENOENT) { return nil }
    }

    static func quarantineCorruptFile(at url: URL, in directory: URL, now: Date = Date()) throws -> URL {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let baseName = "\(url.lastPathComponent).corrupt-\(f.string(from: now))"
        var suffix = 0
        while true {
            let dest = directory.appendingPathComponent(suffix == 0 ? baseName : "\(baseName)-\(suffix)")
            if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: url, to: dest); return dest }
            suffix += 1
        }
    }

    static func writeAtomic(_ data: Data, to destination: URL, in directory: URL, wrapError: ((Error) -> Error)? = nil) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tmp = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) { try? FileManager.default.removeItem(at: destination); try FileManager.default.moveItem(at: tmp, to: destination) }
        } catch { throw wrapError?(error) ?? error }
    }

    static func isUnsupportedFutureJournal(_ data: Data, maxJobVersion: Int = BatchJournalVersionKey.job.maxSupportedVersion) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        func intAbove(_ val: Any?, _ limit: Int) -> Bool {
            guard let n = val as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            let d = n.decimalValue; var r = Decimal(), c = d; NSDecimalRound(&r, &c, 0, .plain)
            return !d.isNaN && d == r && d > Decimal(limit)
        }
        func futureSettings(_ val: Any?) -> Bool {
            guard let s = val as? [String: Any] else { return false }
            if let p = s["processing"] as? [String: Any], p["family"] as? String == "rawlab", intAbove(p["version"], BatchJournalVersionKey.processing.maxSupportedVersion) { return true }
            if intAbove(s["masterRecipeSettingsVersion"], BatchJournalVersionKey.masterRecipeSettings.maxSupportedVersion) { return true }
            if let h = s["hdr"] as? [String: Any] {
                if intAbove(h["hdr_processing_version"], BatchJournalVersionKey.hdrProcessing.maxSupportedVersion) || intAbove(h["record_version"], BatchJournalVersionKey.hdrRecord.maxSupportedVersion) { return true }
                if let cd = h["camera_development"] as? [String: Any], intAbove(cd["version"], BatchJournalVersionKey.hdrCameraDevelopment.maxSupportedVersion) { return true }
            }
            return false
        }
        if intAbove(obj["version"], maxJobVersion) { return true }
        if futureSettings(obj["settings"]) || futureSettings((obj["source"] as? [String: Any])?["settings"]) { return true }
        let entries = (obj["targets"] as? [[String: Any]] ?? []) + (obj["items"] as? [[String: Any]] ?? [])
        return entries.contains {
            guard let f = $0["frozen"] as? [String: Any] else { return false }
            return intAbove(f["version"], BatchJournalVersionKey.frozen.maxSupportedVersion) || intAbove(f["settingsVersion"], BatchJournalVersionKey.frozenSettings.maxSupportedVersion) || futureSettings(f["settings"])
        }
    }

    static func jobDirectory(root: URL, jobID: UUID) throws -> URL {
        let dir = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir }
        catch { throw BatchExportError.global(error.localizedDescription, underlying: error) }
    }
    static func appSupportSubdirectory(_ name: String) -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(name, isDirectory: true)
    }

    static func isOutputIOFailure(_ error: Error, directory: URL) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileWriteUnknownError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain && [ENOSPC, EROFS, EACCES, EPERM, EIO].contains(Int32(ns.code)) { return true }
        return !FileManager.default.isWritableFile(atPath: directory.path)
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "RawLab" : cleaned
    }
}

public struct BatchFrozenSettings: Codable, Equatable {
    public var version = 1, settingsVersion = 1
    public let ordinal: Int; public let settings: Adjustments; public let inputSHA256: String?
    public var lookURL: URL?; public let lookSHA256: String?, lookName: String?
    public let outputFormat: ExportFormat; public let longEdge: Int?; public let outputSharpening: OutputSharpening?
    public var look: URL? { get { lookURL } set { lookURL = newValue } }
    public var effectiveOutputSharpening: OutputSharpening { outputFormat == .renderedDNG ? .off : (outputSharpening ?? .off) }

    public init(version: Int = 1, settingsVersion: Int = 1, ordinal: Int, settings: Adjustments, inputSHA256: String? = nil,
                lookURL: URL? = nil, lookSHA256: String? = nil, lookName: String? = nil, outputFormat: ExportFormat, longEdge: Int? = nil, outputSharpening: OutputSharpening? = nil) {
        self.version = version; self.settingsVersion = settingsVersion; self.ordinal = ordinal; self.settings = settings
        self.inputSHA256 = inputSHA256; self.lookURL = lookURL; self.lookSHA256 = lookSHA256; self.lookName = lookName
        self.outputFormat = outputFormat; self.longEdge = longEdge; self.outputSharpening = outputSharpening
    }
    public init(version: Int = 1, settingsVersion: Int = 1, ordinal: Int, settings: Adjustments, look: URL?,
                lookSHA256: String?, lookName: String?, outputFormat: ExportFormat, longEdge: Int?, outputSharpening: OutputSharpening? = nil) {
        self.init(version: version, settingsVersion: settingsVersion, ordinal: ordinal, settings: settings, inputSHA256: nil,
                  lookURL: look, lookSHA256: lookSHA256, lookName: lookName, outputFormat: outputFormat, longEdge: longEdge, outputSharpening: outputSharpening)
    }
    public enum CodingKeys: String, CodingKey { case version, settingsVersion, ordinal, settings, inputSHA256, lookURL, look, lookSHA256, lookName, outputFormat, longEdge, outputSharpening }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1; settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        ordinal = try c.decode(Int.self, forKey: .ordinal); settings = try c.decode(Adjustments.self, forKey: .settings)
        inputSHA256 = try c.decodeIfPresent(String.self, forKey: .inputSHA256)
        lookURL = try c.decodeIfPresent(URL.self, forKey: .lookURL) ?? c.decodeIfPresent(URL.self, forKey: .look)
        lookSHA256 = try c.decodeIfPresent(String.self, forKey: .lookSHA256); lookName = try c.decodeIfPresent(String.self, forKey: .lookName)
        outputFormat = try c.decode(ExportFormat.self, forKey: .outputFormat); longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge)
        outputSharpening = try c.decodeIfPresent(OutputSharpening.self, forKey: .outputSharpening)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(settingsVersion, forKey: .settingsVersion)
        try c.encode(ordinal, forKey: .ordinal); try c.encode(settings, forKey: .settings)
        if let inputSHA256 { try c.encode(inputSHA256, forKey: .inputSHA256); try c.encodeIfPresent(lookURL, forKey: .lookURL) }
        else { try c.encodeIfPresent(lookURL, forKey: .look) }
        try c.encodeIfPresent(lookSHA256, forKey: .lookSHA256); try c.encodeIfPresent(lookName, forKey: .lookName)
        try c.encode(outputFormat, forKey: .outputFormat); try c.encodeIfPresent(longEdge, forKey: .longEdge)
        try c.encodeIfPresent(outputSharpening, forKey: .outputSharpening)
    }
    public static func checksum(_ url: URL) throws -> String {
        try MacResourceDigestCache.shared.fingerprintDigest(for: url).digest.map { String(format: "%02x", $0) }.joined()
    }
    public static func validateSettings(_ settings: Adjustments) throws { try BatchExportCore.validateSettings(settings) }
    public func validate() throws {
        func digest(_ v: String?) -> Bool { v?.count == 64 && v!.allSatisfy { "0123456789abcdef".contains($0) } }
        guard version == 1, settingsVersion == 1, ordinal >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        if let inputSHA256 {
            guard ExportSize.isValid(longEdge), digest(inputSHA256),
                  (lookURL == nil && lookSHA256 == nil && !settings.hasLook) || (lookURL != nil && digest(lookSHA256)) else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard longEdge.map({ (1...65535).contains($0) }) ?? true,
                  settings.isHDREditing || settings.masterRecipeID == nil || lookURL != nil,
                  (lookURL == nil && lookSHA256 == nil) || (lookURL != nil && digest(lookSHA256)) else { throw CocoaError(.fileReadCorruptFile) }
        }
        try Self.validateSettings(settings)
    }
    public func verifyFiles(input: URL) throws {
        if let inputSHA256, (try? PhotoIdentity.cachedFallback(for: input).contentIdentifier) != inputSHA256 {
            throw BatchExportError.target(L10n.text("原始文件已被替换，请重新选择照片。"))
        }
        if let lookURL, (try? PhotoIdentity.cachedFallback(for: lookURL).contentIdentifier) != lookSHA256 {
            throw BatchExportError.target(L10n.text("任务使用的外观文件不可用，请重新创建任务。"))
        }
    }
    public func verifyLook() throws {
        if let lookURL { guard let expected = lookSHA256, (try? Self.checksum(lookURL)) == expected else { throw BatchExportFailure.missingLook } }
    }
}
public typealias MacBatchFrozenSettings = BatchFrozenSettings

public struct BatchSourceSnapshot: Codable, Equatable {
    public let identity: PhotoIdentity; public var sourceFile: PhotoSourceFile; public let displayName: String
    public let sourceKind: BatchSourceKind; public let settings: Adjustments; public var lookURL: URL?; public var lookName: String?

    enum CodingKeys: String, CodingKey { case sourceFile = "sourceURL", identity, displayName, sourceKind, settings, lookURL, lookName }
    public init(identity: PhotoIdentity, sourceFile: PhotoSourceFile, displayName: String, sourceKind: BatchSourceKind = .raw,
                settings: Adjustments, lookURL: URL? = nil, lookName: String? = nil) {
        self.identity = identity; self.sourceFile = sourceFile; self.displayName = displayName
        self.sourceKind = sourceKind; self.settings = settings; self.lookURL = lookURL; self.lookName = lookName
    }
    public init(identity: PhotoIdentity, sourceURL: URL, displayName: String, sourceKind: BatchSourceKind = .raw,
                settings: Adjustments, lookURL: URL? = nil, lookName: String? = nil) {
        self.init(identity: identity, sourceFile: .externallyManaged(sourceURL), displayName: displayName,
                  sourceKind: sourceKind, settings: settings, lookURL: lookURL, lookName: lookName)
    }
    public var sourceURL: URL { get { sourceFile.withReadAccess { $0 } } set { sourceFile = .externallyManaged(newValue) } }
    public func settings(for targetKind: BatchSourceKind) -> Adjustments {
        if sourceKind == .raw, targetKind == .raster { var r = settings; r.lensCorrection = nil; return r }
        guard sourceKind == .raster, targetKind == .raw else { return settings }
        var r = settings; r.exposureMode = Adjustments.default.exposureMode; r.whiteBalanceMode = .camera; r.temperature = 6500
        if r.masterRecipeID == nil { r.tint = 0 }; r.lensCorrection = nil; return r
    }
    public func settings(for target: BatchTarget, resolveX3fMode: BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> Adjustments {
        var r = settings(for: target.sourceKind); if target.isX3f { r.selectX3fMode(try resolveX3fMode(target.identity, target.sourceURL)) }; return r
    }
}

public struct BatchTarget: Codable, Equatable, Identifiable {
    public let identity: PhotoIdentity; public var sourceURL: URL; public let displayName: String; public var sourceKind: BatchSourceKind
    public var status: BatchTargetStatus; public var errorMessage: String?, outputName: String, outputAssetIdentifier: String?, outputFileURL: URL?; public var frozen: BatchFrozenSettings?
    public var id: String { identity.key }
    public var isX3f: Bool { sourceKind == .raw && (BatchExportEnvironment.isX3fInput(sourceURL) || URL(fileURLWithPath: displayName).pathExtension.lowercased() == "x3f") }

    public init(identity: PhotoIdentity, sourceURL: URL, displayName: String, sourceKind: BatchSourceKind = .raw, status: BatchTargetStatus = .pending,
                errorMessage: String? = nil, outputName: String? = nil, outputFileURL: URL? = nil, outputAssetIdentifier: String? = nil, frozen: BatchFrozenSettings? = nil) {
        self.identity = identity; self.sourceURL = sourceURL; self.displayName = displayName; self.sourceKind = sourceKind
        self.status = status; self.errorMessage = errorMessage; self.outputName = outputName ?? OutputNameAllocator.baseName(for: displayName)
        self.outputAssetIdentifier = outputAssetIdentifier; self.outputFileURL = outputFileURL; self.frozen = frozen
    }
    enum CodingKeys: String, CodingKey { case identity, sourceURL, displayName, sourceKind, status, errorMessage, outputName, outputAssetIdentifier, outputFileURL, frozen }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(PhotoIdentity.self, forKey: .identity); sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        displayName = try c.decode(String.self, forKey: .displayName); sourceKind = try c.decodeIfPresent(BatchSourceKind.self, forKey: .sourceKind) ?? .raw
        status = try c.decodeIfPresent(BatchTargetStatus.self, forKey: .status) ?? .pending; errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        outputName = try c.decodeIfPresent(String.self, forKey: .outputName) ?? OutputNameAllocator.baseName(for: displayName)
        outputAssetIdentifier = try c.decodeIfPresent(String.self, forKey: .outputAssetIdentifier)
        outputFileURL = try c.decodeIfPresent(URL.self, forKey: .outputFileURL); frozen = try c.decodeIfPresent(BatchFrozenSettings.self, forKey: .frozen)
    }
}

public struct BatchExportJob: Codable, Equatable, Identifiable {
    public static var defaultX3fModeProvider: ((URL) throws -> X3fMode)? {
        get { BatchExportEnvironment.defaultX3fMode }
        set { BatchExportEnvironment.defaultX3fMode = newValue ?? { _ in throw CocoaError(.featureUnsupported) } }
    }
    public var version = 1; public var settingsMode: BatchSettingsMode = .uniformFrozen; public let id: UUID
    public var source: BatchSourceSnapshot; public var targets: [BatchTarget]; public var status: BatchJobStatus; public var outputFormat: ExportFormat
    public var longEdge: Int?, outputSharpening: OutputSharpening?; public var createdAt: Date, updatedAt: Date, globalError: String?
    public var effectiveOutputSharpening: OutputSharpening { outputFormat == .renderedDNG ? .off : (outputSharpening ?? .off) }

    public init(id: UUID = UUID(), source: BatchSourceSnapshot, targets: [BatchTarget], outputFormat: ExportFormat = .jpeg,
                longEdge: Int? = nil, outputSharpening: OutputSharpening? = nil, status: BatchJobStatus = .draft, createdAt: Date = Date()) {
        self.id = id; self.source = source; self.targets = OutputNameAllocator.assignUniqueNames(targets, suffix: outputFormat.suffix)
        self.status = status; self.outputFormat = outputFormat; self.longEdge = ExportSize.normalized(longEdge)
        self.outputSharpening = outputSharpening; self.createdAt = createdAt; self.updatedAt = createdAt; self.globalError = nil
    }
    enum CodingKeys: String, CodingKey {
        case version, id, source, targets, status, outputFormat, longEdge, createdAt, updatedAt, globalError
        case outputSharpening = "output_sharpening", settingsMode = "settings_mode"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1; settingsMode = try c.decodeIfPresent(BatchSettingsMode.self, forKey: .settingsMode) ?? .uniformFrozen
        id = try c.decode(UUID.self, forKey: .id); source = try c.decode(BatchSourceSnapshot.self, forKey: .source)
        targets = try c.decode([BatchTarget].self, forKey: .targets); status = try c.decode(BatchJobStatus.self, forKey: .status)
        outputFormat = try c.decodeIfPresent(ExportFormat.self, forKey: .outputFormat) ?? .jpeg; longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge)
        outputSharpening = try c.decodeIfPresent(OutputSharpening.self, forKey: .outputSharpening)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        globalError = try c.decodeIfPresent(String.self, forKey: .globalError); try validate()
    }
    public func validate() throws {
        guard (1...BatchExportCore.maxSupportedJobVersion).contains(version) else { throw CocoaError(.fileReadCorruptFile) }
        guard settingsMode == .perTargetFrozen else { guard version == 1, targets.allSatisfy({ $0.frozen == nil }) else { throw CocoaError(.fileReadCorruptFile) }; return }
        guard version == 2, !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else { throw CocoaError(.fileReadCorruptFile) }
        for (index, target) in targets.enumerated() {
            guard let frozen = target.frozen, frozen.ordinal == index, frozen.outputFormat == outputFormat,
                  frozen.longEdge == longEdge, frozen.effectiveOutputSharpening == effectiveOutputSharpening else { throw CocoaError(.fileReadCorruptFile) }
            try frozen.validate()
        }
    }
    public typealias X3fModeResolver = (PhotoIdentity, URL) throws -> X3fMode
    public static func x3fModeResolver(store: EditPersistence? = nil, x3fDefaultMode: @escaping (URL) throws -> X3fMode = Self.defaultX3fMode(for:)) -> X3fModeResolver {
        { id, url in try (try store ?? EditPersistence.appStore()).readState(for: id).state?.settings.x3fMode ?? x3fDefaultMode(url) }
    }
    public static func resolveX3fMode(identity: PhotoIdentity, url: URL) throws -> X3fMode { try x3fModeResolver()(identity, url) }
    public static func defaultX3fMode(for url: URL) throws -> X3fMode { try BatchExportEnvironment.defaultX3fMode(url) }
    private func requireFrozen(for target: BatchTarget) throws -> BatchFrozenSettings {
        guard let f = target.frozen else { throw CocoaError(.fileReadCorruptFile) }; return f
    }
    public func settings(for target: BatchTarget, resolveX3fMode: X3fModeResolver = Self.resolveX3fMode) throws -> Adjustments {
        settingsMode == .perTargetFrozen ? try requireFrozen(for: target).settings : try source.settings(for: target, resolveX3fMode: resolveX3fMode)
    }
    public func look(for target: BatchTarget) throws -> URL? { settingsMode == .perTargetFrozen ? try requireFrozen(for: target).lookURL : source.lookURL }
    public func longEdge(for target: BatchTarget) throws -> Int? { settingsMode == .perTargetFrozen ? try requireFrozen(for: target).longEdge : longEdge }
    public func recovered(assetExists: (String) -> Bool? = { _ in nil }, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> BatchExportJob {
        var copy = self
        func existingDNGOutput(for t: BatchTarget) -> URL? {
            let cur = BatchFileOutputStore.destination(jobID: id, outputName: t.outputName)
            if fileExists(cur) { return cur }; if let o = t.outputFileURL, fileExists(o) { return o }
            if let a = t.outputAssetIdentifier, a.hasPrefix("file:") { let u = URL(fileURLWithPath: String(a.dropFirst(5))); if fileExists(u) { return u } }
            return nil
        }
        for i in copy.targets.indices {
            switch copy.targets[i].status {
            case .processing: copy.targets[i].status = .pending
            case .succeeded where outputFormat == .renderedDNG:
                if let out = existingDNGOutput(for: copy.targets[i]) { copy.targets[i].outputFileURL = out; copy.targets[i].outputAssetIdentifier = nil; copy.targets[i].errorMessage = nil }
                else { copy.targets[i].outputFileURL = nil; copy.targets[i].outputAssetIdentifier = nil; copy.targets[i].status = .pending; copy.targets[i].errorMessage = nil }
            case .publishing, .needsConfirmation:
                if outputFormat == .renderedDNG {
                    if let out = existingDNGOutput(for: copy.targets[i]) { copy.targets[i].outputFileURL = out; copy.targets[i].outputAssetIdentifier = nil; copy.targets[i].status = .succeeded }
                    else { copy.targets[i].outputFileURL = nil; copy.targets[i].outputAssetIdentifier = nil; copy.targets[i].status = .pending }
                    if copy.globalError == copy.targets[i].errorMessage { copy.globalError = nil }; copy.targets[i].errorMessage = nil
                } else if let a = copy.targets[i].outputAssetIdentifier, let ok = assetExists(a) {
                    copy.targets[i].status = ok ? .succeeded : .pending; if !ok { copy.targets[i].outputAssetIdentifier = nil }; copy.targets[i].errorMessage = nil
                } else {
                    copy.targets[i].status = .needsConfirmation; copy.targets[i].errorMessage = L10n.text("保存时发生中断，请先核对照片图库，避免重复生成。")
                }
            default: break
            }
        }
        if status == .running || copy.targets.contains(where: { $0.status == .needsConfirmation }) { copy.status = .interrupted }
        if outputFormat == .renderedDNG && copy.status == .completed && copy.targets.contains(where: { $0.status != .succeeded }) { copy.status = .interrupted }
        if !copy.targets.isEmpty && copy.targets.allSatisfy({ $0.status == .succeeded }) { copy.status = .completed }
        return copy
    }
}

public final class BatchJournalStore {
    public let directory: URL
    public private(set) var lastQuarantinedURL: URL?
    public private(set) var diskReloads = 0
    private struct FileFingerprint: Equatable { let dev, ino, size, mt, mns, ct, cns: Int }
    private var writtenFingerprints: [UUID: FileFingerprint] = [:]

    public init(directory: URL) throws {
        self.directory = directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public static func appStore() throws -> BatchJournalStore { try BatchJournalStore(directory: BatchExportCore.appSupportSubdirectory("RawLab/BatchJobs")) }
    private static func fingerprint(at url: URL) -> FileFingerprint? {
        var info = stat(); guard stat(url.path, &info) == 0 else { return nil }
        return FileFingerprint(dev: Int(info.st_dev), ino: Int(info.st_ino), size: Int(info.st_size),
                               mt: Int(info.st_mtimespec.tv_sec), mns: Int(info.st_mtimespec.tv_nsec), ct: Int(info.st_ctimespec.tv_sec), cns: Int(info.st_ctimespec.tv_nsec))
    }
    public func save(_ job: BatchExportJob) throws {
        try job.validate()
        let dest = directory.appendingPathComponent("\(job.id.uuidString).json")
        if writtenFingerprints[job.id] == nil || writtenFingerprints[job.id] != Self.fingerprint(at: dest) {
            diskReloads += 1; _ = try load(id: job.id)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(job).write(to: dest, options: .atomic)
        writtenFingerprints[job.id] = Self.fingerprint(at: dest)
    }
    public func load(id: UUID) throws -> BatchExportJob? {
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        do { return relocateOwnedFiles(try JSONDecoder().decode(BatchExportJob.self, from: data)) }
        catch {
            if BatchExportCore.isUnsupportedFutureJournal(data, maxJobVersion: BatchExportCore.maxSupportedJobVersion) { throw error }
            try quarantineCorruptJob(at: file, error: error); return nil
        }
    }
    public func pendingJobs() throws -> [BatchExportJob] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.compactMap { url -> BatchExportJob? in
            let data = try Data(contentsOf: url); let original: BatchExportJob
            do { original = try JSONDecoder().decode(BatchExportJob.self, from: data) }
            catch {
                if BatchExportCore.isUnsupportedFutureJournal(data, maxJobVersion: BatchExportCore.maxSupportedJobVersion) { throw error }
                try quarantineCorruptJob(at: url, error: error); return nil
            }
            let recovered = relocateOwnedFiles(original).recovered()
            if recovered.status == .completed && recovered.outputFormat != .renderedDNG { try discard(id: recovered.id); return nil }
            if recovered != original { try save(recovered) }
            return recovered
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    @discardableResult public func quarantineCorruptJob(at url: URL, error: Error? = nil, now: Date = Date()) throws -> URL {
        let q = try BatchExportCore.quarantineCorruptFile(at: url, in: url.deletingLastPathComponent(), now: now)
        NSLog("Quarantined corrupt batch job from %@ to %@ (%@)", url.lastPathComponent, q.lastPathComponent, error.map { String(describing: $0) } ?? "corrupt entry")
        lastQuarantinedURL = q; return q
    }
    private func relocateOwnedFiles(_ original: BatchExportJob) -> BatchExportJob {
        let root = directory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        func rel(_ url: URL) -> URL {
            let p = url.deletingLastPathComponent()
            if p.lastPathComponent == "inputs" && p.deletingLastPathComponent().lastPathComponent == original.id.uuidString {
                return root.appendingPathComponent("inputs", isDirectory: true).appendingPathComponent(url.lastPathComponent)
            }
            return p.lastPathComponent == original.id.uuidString ? root.appendingPathComponent(url.lastPathComponent) : url
        }
        var job = original
        job.source.sourceFile = job.source.sourceFile.withReadAccess { .externallyManaged(rel($0)) }
        job.source.lookURL = job.source.lookURL.map(rel)
        for i in job.targets.indices {
            job.targets[i].sourceURL = rel(job.targets[i].sourceURL)
            let look = job.targets[i].frozen?.lookURL.map(rel); job.targets[i].frozen?.lookURL = look
        }
        return job
    }
    public func removeOrphanedJobDirectories() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(entry.lastPathComponent).json").path) { try? FileManager.default.removeItem(at: entry) }
        }
    }
    public func discard(id: UUID) throws {
        let rec = directory.appendingPathComponent("\(id.uuidString).json"), dir = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        if FileManager.default.fileExists(atPath: rec.path) { try FileManager.default.removeItem(at: rec) }
        writtenFingerprints[id] = nil
    }
}

public enum BatchInputStore {
    public static func directory(for jobID: UUID, root: URL? = nil) throws -> URL {
        let base = root ?? BatchExportCore.appSupportSubdirectory("RawLab/BatchJobs")
        let dir = base.appendingPathComponent(jobID.uuidString, isDirectory: true).appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
    public static func copy(_ sourceURL: URL, identity: PhotoIdentity, jobID: UUID, root: URL? = nil, displayName: String? = nil) throws -> URL {
        let dir = try directory(for: jobID, root: root), dExt = displayName.map { ($0 as NSString).pathExtension } ?? ""
        let ext = !sourceURL.pathExtension.isEmpty ? sourceURL.pathExtension : (!dExt.isEmpty ? dExt : "raw")
        let dest = dir.appendingPathComponent(SHA256.hash(data: Data(identity.key.utf8)).map { String(format: "%02x", $0) }.joined() + "." + ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let acc = sourceURL.startAccessingSecurityScopedResource(); defer { if acc { sourceURL.stopAccessingSecurityScopedResource() } }
        let tmp = dir.appendingPathComponent(".copy-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: sourceURL, to: tmp); try FileManager.default.moveItem(at: tmp, to: dest); return dest
    }
    public static func prepare(_ job: inout BatchExportJob, look: URL?, root: URL? = nil) throws {
        job.source.sourceFile = try job.source.sourceFile.withReadAccess { .externallyManaged(try copy($0, identity: job.source.identity, jobID: job.id, root: root, displayName: job.source.displayName)) }
        if job.source.settings.hasLook {
            guard let look, FileManager.default.isReadableFile(atPath: look.path) else { throw BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。")) }
            let dest = try directory(for: job.id, root: root).deletingLastPathComponent().appendingPathComponent("look.\(look.pathExtension)")
            if look != dest && !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: look, to: dest) }
            job.source.lookURL = dest
        }
    }
}

public enum BatchFileOutputStore {
    public static func root() -> URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("Exports", isDirectory: true)
    }
    public static func directory(for jobID: UUID) throws -> URL { try BatchExportCore.jobDirectory(root: root(), jobID: jobID) }
    public static func destination(jobID: UUID, outputName: String) -> URL { root().appendingPathComponent(jobID.uuidString, isDirectory: true).appendingPathComponent(outputName) }
    public static func temporaryURL(for jobID: UUID, outputName: String) -> URL { root().appendingPathComponent(jobID.uuidString, isDirectory: true).appendingPathComponent(".rawlab-\(UUID().uuidString)-\(outputName)") }
}

public enum BatchFileWriter {
    public static func write(file: URL, outputName: String, jobID: UUID, checkpoint: @escaping (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw BatchExportError.target(L10n.text("渲染型 DNG 未生成。")) }
        let dest = try BatchFileOutputStore.directory(for: jobID).appendingPathComponent(outputName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { _ = try FileManager.default.replaceItemAt(dest, withItemAt: file, backupItemName: nil, options: .usingNewMetadataOnly) }
            else { try FileManager.default.moveItem(at: file, to: dest) }
        } catch { throw BatchExportError.global(error.localizedDescription, underlying: error) }
        do { try checkpoint("file:\(dest.path)") }
        catch { throw BatchExportError.uncertain(L10n.text("DNG 已生成，但任务记录未更新，请先核对保存结果。"), underlying: error) }
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
            let orig = URL(fileURLWithPath: target.outputName).deletingPathExtension().lastPathComponent
            let base = orig.isEmpty ? URL(fileURLWithPath: target.displayName).deletingPathExtension().lastPathComponent : orig
            let prefix = base.isEmpty ? "RawLab" : base; var candidate = prefix + "." + suffix, number = 2
            while used.contains(candidate.lowercased()) { candidate = "\(prefix)-\(number).\(suffix)"; number += 1 }
            used.insert(candidate.lowercased()); var u = target; u.outputName = candidate; return u
        }
    }
}

public struct BatchExportRunner {
    public typealias Cancellation = () -> Bool
    public static func run<Payload>(job: BatchExportJob, journalStore: BatchJournalStore?,
                                    render: @escaping (_ target: BatchTarget, _ settings: Adjustments) throws -> Payload,
                                    write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget, _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                                    cleanup: @escaping (_ payload: Payload) -> Void = { _ in }, shouldCancel: @escaping Cancellation = { false },
                                    didUpdate: @escaping (BatchExportJob) -> Void = { _ in }, onlyIDs: Set<String>? = nil,
                                    didFail: (_ error: Error, _ stage: String) -> Void = { _, _ in },
                                    resolveX3fMode: @escaping BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> BatchExportJob {
        var job = job; try job.validate(); job.status = .running; job.globalError = nil; try journalStore?.save(job); didUpdate(job)
        for i in job.targets.indices where [.pending, .failed, .cancelled].contains(job.targets[i].status) && (onlyIDs == nil || onlyIDs!.contains(job.targets[i].id)) {
            if shouldCancel() { markRemainingCancelled(&job, from: i); job.status = .cancelled; job.updatedAt = Date(); try journalStore?.save(job); didUpdate(job); return job }
            job.targets[i].status = .processing; job.targets[i].errorMessage = nil; job.targets[i].outputAssetIdentifier = nil; job.targets[i].outputFileURL = nil; didUpdate(job)
            do {
                let target = job.targets[i]
                if job.settingsMode == .perTargetFrozen { try target.frozen!.verifyFiles(input: target.sourceURL) }
                let payload = try render(target, job.settings(for: target, resolveX3fMode: resolveX3fMode)); defer { cleanup(payload) }
                if shouldCancel() { throw CancellationError() }
                job.targets[i].status = .publishing; try journalStore?.save(job); didUpdate(job)
                if shouldCancel() { throw CancellationError() }
                try write(payload, job.targets[i].outputName, job.targets[i]) { id in
                    if id.hasPrefix("file:") { job.targets[i].outputFileURL = URL(fileURLWithPath: String(id.dropFirst(5))); job.targets[i].outputAssetIdentifier = nil }
                    else { job.targets[i].outputAssetIdentifier = id; job.targets[i].outputFileURL = nil }
                    try journalStore?.save(job); didUpdate(job)
                }
                job.targets[i].status = .succeeded
            } catch is CancellationError {
                let pub = job.targets[i].outputAssetIdentifier != nil || job.targets[i].outputFileURL != nil
                job.targets[i].status = pub ? .needsConfirmation : .cancelled; markRemainingCancelled(&job, from: i + 1)
                job.status = pub ? .interrupted : .cancelled; job.updatedAt = Date(); try journalStore?.save(job); didUpdate(job); return job
            } catch let error as BatchExportError {
                didFail(error, job.targets[i].status == .publishing ? "publish" : "render")
                switch error {
                case .uncertain(let m, _): job.targets[i].status = .needsConfirmation; job.targets[i].errorMessage = m; job.globalError = m; job.status = .interrupted; try journalStore?.save(job); didUpdate(job); return job
                case .target(let m): job.targets[i].status = .failed; job.targets[i].errorMessage = m
                case .global(let m, _): job.targets[i].status = .failed; job.targets[i].errorMessage = m; job.globalError = m; job.status = .failed; job.updatedAt = Date(); try journalStore?.save(job); didUpdate(job); return job
                }
            } catch {
                didFail(error, job.targets[i].status == .publishing ? "publish" : "render"); job.targets[i].status = .failed; job.targets[i].errorMessage = error.localizedDescription
            }
            job.updatedAt = Date(); try journalStore?.save(job); didUpdate(job)
        }
        if job.status != .cancelled && job.status != .failed {
            job.status = job.targets.contains { [.pending, .cancelled, .needsConfirmation].contains($0.status) } ? .interrupted : (job.targets.contains { $0.status == .failed } ? .partialFailure : .completed)
        }
        job.updatedAt = Date(); try journalStore?.save(job); didUpdate(job); return job
    }
    public static func retryFailed<Payload>(job: BatchExportJob, journalStore: BatchJournalStore?,
                                            render: @escaping (_ target: BatchTarget, _ settings: Adjustments) throws -> Payload,
                                            write: @escaping (_ payload: Payload, _ outputName: String, _ target: BatchTarget, _ checkpoint: @escaping (String) throws -> Void) throws -> Void,
                                            cleanup: @escaping (_ payload: Payload) -> Void = { _ in }, shouldCancel: @escaping Cancellation = { false },
                                            didUpdate: @escaping (BatchExportJob) -> Void = { _ in },
                                            resolveX3fMode: @escaping BatchExportJob.X3fModeResolver = BatchExportJob.resolveX3fMode) throws -> BatchExportJob {
        var retry = job; let failedIDs = Set(job.targets.filter { $0.status == .failed }.map(\.id))
        for i in retry.targets.indices where retry.targets[i].status == .failed { retry.targets[i].status = .pending; retry.targets[i].errorMessage = nil }
        retry.status = .draft
        return try run(job: retry, journalStore: journalStore, render: render, write: write, cleanup: cleanup, shouldCancel: shouldCancel, didUpdate: didUpdate, onlyIDs: failedIDs, resolveX3fMode: resolveX3fMode)
    }
    private static func markRemainingCancelled(_ job: inout BatchExportJob, from index: Int) {
        for r in index..<job.targets.count where [.pending, .processing, .failed, .cancelled].contains(job.targets[r].status) { job.targets[r].status = .cancelled }
    }
}

public struct MacBatchExportItem: Codable, Identifiable {
    public let id: UUID, input: URL, identity: OriginalFileIdentity
    public var selected = false, status = BatchItemStatus.waiting, output: URL?, completedIdentity: OriginalFileIdentity?
    public var error: String?, validationError: String?, noticeKey: String?, resolvedX3fMode: X3fMode?, frozen: MacBatchFrozenSettings?, resourceIdentifier: String?
    public init(url: URL) throws {
        id = UUID(); input = url.resolvingSymlinksInPath().standardizedFileURL
        identity = try OriginalFileIdentity(input); resourceIdentifier = try Self.resourceKey(input)
    }
    public static func resourceKey(_ url: URL) throws -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let dev = attrs[.systemNumber] as? NSNumber, let ino = attrs[.systemFileNumber] as? NSNumber else { return path }
        return "\(dev.uint64Value):\(ino.uint64Value)"
    }
}

public struct MacBatchExportJob: Codable {
    public var version = 1
    public let id: UUID, source: URL, settings: Adjustments, lookName: String
    public var look: URL?, items: [MacBatchExportItem] = [], outputDirectory: URL?, png = false, outputFormat: ExportFormat?, longEdge: Int?, outputSharpening: OutputSharpening?
    public var started = false, interrupted = false, cancelled = false, failure: String?, settingsMode: BatchSettingsMode?
    public var effectiveOutputSharpening: OutputSharpening { format == .renderedDNG ? .off : (outputSharpening ?? .off) }
    public enum CodingKeys: String, CodingKey {
        case version, id, source, settings, look, lookName, items, outputDirectory, png, outputFormat, longEdge, started, interrupted, cancelled, failure
        case outputSharpening = "output_sharpening", settingsMode = "settings_mode"
    }
    public var mode: BatchSettingsMode { settingsMode ?? .uniformFrozen }
    public var selectedCount: Int { items.filter(\.selected).count }
    public var succeededCount: Int { items.filter { $0.selected && $0.status == .succeeded }.count }
    public var failedCount: Int { items.filter { $0.selected && $0.status == .failed }.count }
    public var remainingCount: Int { selectedCount - succeededCount - failedCount }
    public var format: ExportFormat {
        get { outputFormat ?? (png ? .png : .jpeg) }
        set { outputFormat = newValue; png = newValue == .png; version = max(version, 2) }
    }
    public var suffix: String { format.suffix }

    public init(source: URL, settings: Adjustments, look: URL?, lookName: String) {
        self.id = UUID(); self.source = source; self.settings = settings; self.look = look; self.lookName = lookName
    }
    public func validate() throws {
        guard (1...BatchJournalVersionKey.job.maxSupportedVersion).contains(version), longEdge.map({ (1...65535).contains($0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
        try MacBatchFrozenSettings.validateSettings(settings)
        guard mode == .perTargetFrozen else { guard version < 3, items.allSatisfy({ $0.frozen == nil }) else { throw CocoaError(.fileReadCorruptFile) }; return }
        guard version == 3, !items.isEmpty, Set(items.map(\.id)).count == items.count,
              Set(items.map { $0.resourceIdentifier ?? $0.identity.path }).count == items.count,
              Set(items.map(\.input)).count == items.count else { throw CocoaError(.fileReadCorruptFile) }
        for (index, item) in items.enumerated() { guard let frozen = item.frozen, frozen.ordinal == index else { throw CocoaError(.fileReadCorruptFile) }; try frozen.validate() }
    }
    public typealias X3fModeResolver = (URL) throws -> X3fMode
    public static func x3fModeResolver(store: MacEditPersistence? = nil, directory: URL = MacEditPersistence.defaultDirectory,
                                      defaultMode: @escaping (URL) throws -> X3fMode = { try BatchExportEnvironment.defaultX3fMode($0) }) -> X3fModeResolver {
        { url in let p = try store ?? MacEditPersistence(directory: directory); return try p.state(for: url)?.settings.x3fMode ?? defaultMode(url) }
    }
    public static func resolveX3fMode(for input: URL) throws -> X3fMode { try x3fModeResolver()(input) }
    public func snapshot(for item: MacBatchExportItem, resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> MacBatchFrozenSettings {
        if mode == .perTargetFrozen { guard let frozen = item.frozen else { throw CocoaError(.fileReadCorruptFile) }; try frozen.validate(); return frozen }
        return MacBatchFrozenSettings(ordinal: 0, settings: try settings(for: item.input, resolveX3fMode: resolveX3fMode),
                                      look: look, lookSHA256: nil, lookName: lookName, outputFormat: format, longEdge: longEdge, outputSharpening: effectiveOutputSharpening)
    }
    public func settings(for input: URL, resolveX3fMode: X3fModeResolver = Self.resolveX3fMode(for:)) throws -> Adjustments {
        if MacBatchExportEnvironment.isRasterInput(input) { return settings.resolvedForRaster }
        var resolved = settings
        if MacBatchExportEnvironment.isRasterInput(source), !MacBatchExportEnvironment.isRasterInput(input) {
            let recipeTint = resolved.masterRecipe != nil ? resolved.tint : nil
            resolved.exposureMode = Adjustments().exposureMode; resolved.resolveWhiteBalance(nil); resolved.resetWhiteBalance()
            if let recipeTint { resolved.tint = recipeTint }; resolved.rawNoiseReduction = 0; resolved.lensCorrection = nil
        }
        if MacBatchExportEnvironment.isX3fInput(input) { resolved.selectX3fMode(try resolveX3fMode(input)) }
        return resolved
    }
    fileprivate var pendingLookURLs: [URL] {
        (look.map { [$0] } ?? []) + items.filter { [.waiting, .running, .publishing].contains($0.status) }.compactMap { $0.frozen?.look }
    }
}

public final class MacBatchJournal {
    public static var defaultDirectory: URL { BatchExportCore.appSupportSubdirectory("RawLab/Batch") }
    public let directory: URL
    public private(set) var lastQuarantinedURL: URL?
    private var quarantinedError: Error?
    private var url: URL { directory.appendingPathComponent("job.json") }
    private struct FileFingerprint: Equatable { let size: Int; let modified: Date }
    private var writtenFingerprint: FileFingerprint?
    public private(set) var diskReloads = 0

    public init(directory: URL = MacBatchJournal.defaultDirectory) { self.directory = directory }
    public func consumeQuarantinedError() -> Error? { defer { quarantinedError = nil }; return quarantinedError }
    public func save(_ job: MacBatchExportJob) throws {
        quarantinedError = nil; try job.validate()
        let fp = Self.fingerprint(atPath: url.path)
        if writtenFingerprint == nil || writtenFingerprint != fp { diskReloads += 1; _ = try readJob() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        writtenFingerprint = Self.fingerprint(atPath: url.path)
    }
    public func snapshotLook(_ original: URL?, jobID: UUID, contentIdentifier: String?) throws -> URL? {
        guard let original else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(jobID.uuidString)-\(contentIdentifier ?? UUID().uuidString).\(original.pathExtension)")
        if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: original, to: copy) }
        return copy
    }
    private func readJob() throws -> MacBatchExportJob? {
        quarantinedError = nil
        guard try BatchExportCore.itemType(atPath: directory.path) == .typeDirectory else {
            if (try? BatchExportCore.itemType(atPath: directory.path)) == nil { return nil }; throw CocoaError(.fileReadCorruptFile)
        }
        switch try BatchExportCore.itemType(atPath: url.path) { case nil: return nil; case .typeRegular?: break; default: throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        do { let job = try JSONDecoder().decode(MacBatchExportJob.self, from: data); try job.validate(); return job }
        catch {
            if BatchExportCore.isUnsupportedFutureJournal(data) { throw error }
            lastQuarantinedURL = try BatchExportCore.quarantineCorruptFile(at: url, in: directory)
            quarantinedError = error; return nil
        }
    }
    private static func fingerprint(atPath path: String) -> FileFingerprint? {
        guard let v = try? FileManager.default.attributesOfItem(atPath: path), let s = v[.size] as? Int, let m = v[.modificationDate] as? Date else { return nil }
        return FileFingerprint(size: s, modified: m)
    }
    public func load() throws -> MacBatchExportJob? {
        quarantinedError = nil; guard var job = try readJob() else { return nil }
        for i in job.items.indices where [.running, .publishing].contains(job.items[i].status) {
            let item = job.items[i]
            if item.status == .publishing, let output = item.output, let expected = item.completedIdentity,
               let actual = try? OriginalFileIdentity(output), expected.matchesContent(actual) { job.items[i].status = .succeeded }
            else { job.items[i].status = .waiting; job.items[i].error = nil }
            job.interrupted = true; cleanup(job, item: item)
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
        let pairs: [(URL, UUID)] = (job.look.map { [($0, job.id)] } ?? []) + job.items.compactMap { i in i.frozen?.look.map { ($0, i.id) } }
        for (look, id) in pairs where look.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
            && owned(look.deletingPathExtension().lastPathComponent, id) { try? FileManager.default.removeItem(at: look) }
    }
    private func cleanup(_ job: MacBatchExportJob, item: MacBatchExportItem) {
        guard let directory = job.outputDirectory else { return }
        let suffix = job.mode == .perTargetFrozen ? (item.frozen?.outputFormat.suffix ?? job.format.suffix) : job.format.suffix
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(suffix)"))
    }
}

public extension OriginalFileIdentity {
    func matchesContent(_ other: OriginalFileIdentity) -> Bool { size == other.size && modified == other.modified && fileNumber == other.fileNumber }
}

public enum MacBatchExportRunner {
    public typealias Render = (URL, Adjustments, URL?, URL) throws -> Void
    public typealias RenderSnapshot = (URL, MacBatchFrozenSettings, URL) throws -> Void
    private static func save(_ job: MacBatchExportJob, to journal: MacBatchJournal, onQuarantine: (Error) -> Void) throws {
        defer { if let q = journal.consumeQuarantinedError() { onQuarantine(q) } }
        try journal.save(job)
    }
    public static func run(job: inout MacBatchExportJob, journal: MacBatchJournal, scope: BatchRunScope,
                           resolveX3fMode: MacBatchExportJob.X3fModeResolver = MacBatchExportJob.resolveX3fMode(for:),
                           shouldCancel: () -> Bool, didUpdate: (MacBatchExportJob) -> Void = { _ in },
                           onQuarantine: (Error) -> Void = { _ in }, render: Render) throws {
        try runSnapshots(job: &job, journal: journal, scope: scope, resolveX3fMode: resolveX3fMode, shouldCancel: shouldCancel, didUpdate: didUpdate, onQuarantine: onQuarantine) { try render($0, $1.settings, $1.look, $2) }
    }
    public static func runSnapshots(job: inout MacBatchExportJob, journal: MacBatchJournal, scope: BatchRunScope,
                                    resolveX3fMode: MacBatchExportJob.X3fModeResolver = MacBatchExportJob.resolveX3fMode(for:),
                                    shouldCancel: () -> Bool, didUpdate: (MacBatchExportJob) -> Void = { _ in },
                                    onQuarantine: (Error) -> Void = { _ in }, render: RenderSnapshot) throws {
        try job.validate()
        guard let directory = job.outputDirectory else { throw BatchExportFailure.destination }
        guard job.selectedCount > 0 else { throw BatchExportFailure.noSelection }
        if job.mode == .uniformFrozen, let look = job.look, !FileManager.default.isReadableFile(atPath: look.path) { throw BatchExportFailure.missingLook }
        try verifyDestination(directory)
        job.started = true; job.interrupted = false; job.cancelled = false; job.failure = nil
        try save(job, to: journal, onQuarantine: onQuarantine)
        do {
            for i in job.items.indices {
                let item = job.items[i]
                guard item.selected, item.status != .succeeded, scope != .failed || item.status == .failed else { continue }
                if shouldCancel() { job.cancelled = true; break }
                guard FileManager.default.isWritableFile(atPath: directory.path) else { throw BatchExportFailure.destination }
                job.items[i].status = .running; job.items[i].error = nil
                try save(job, to: journal, onQuarantine: onQuarantine); didUpdate(job)
                try export(i, job: &job, journal: journal, directory: directory, resolveX3fMode: resolveX3fMode, shouldCancel: shouldCancel, onQuarantine: onQuarantine, render: render)
                didUpdate(job)
                if shouldCancel() { job.cancelled = true; break }
            }
        } catch {
            job.interrupted = true; job.failure = error.localizedDescription
            try? save(job, to: journal, onQuarantine: onQuarantine); didUpdate(job); throw error
        }
        try save(job, to: journal, onQuarantine: onQuarantine); didUpdate(job)
    }
    private static func export(_ index: Int, job: inout MacBatchExportJob, journal: MacBatchJournal, directory: URL,
                               resolveX3fMode: MacBatchExportJob.X3fModeResolver, shouldCancel: () -> Bool,
                               onQuarantine: (Error) -> Void, render: RenderSnapshot) throws {
        let item = job.items[index], snapshot: MacBatchFrozenSettings, temp: URL
        var cleanupTemp: URL?; defer { if let cleanupTemp { try? FileManager.default.removeItem(at: cleanupTemp) } }
        do {
            guard try OriginalFileIdentity(item.input) == item.identity else { throw BatchExportFailure.changedInput }
            if job.mode == .perTargetFrozen { guard try MacBatchExportItem.resourceKey(item.input) == item.resourceIdentifier else { throw BatchExportFailure.changedInput } }
            snapshot = try job.snapshot(for: item, resolveX3fMode: resolveX3fMode)
            if job.mode == .uniformFrozen { job.items[index].resolvedX3fMode = BatchExportEnvironment.isX3fInput(item.input) ? snapshot.settings.x3fMode : nil }
            if job.mode == .perTargetFrozen { try snapshot.verifyLook() }
            temp = directory.appendingPathComponent(".rawlab-\(job.id)-\(item.id).\(snapshot.outputFormat.suffix)")
            cleanupTemp = temp; try render(item.input, snapshot, temp)
        } catch {
            if BatchExportEnvironment.isAICancelledError(error) && shouldCancel() {
                job.items[index].status = .waiting; job.items[index].error = nil; try save(job, to: journal, onQuarantine: onQuarantine); return
            }
            job.items[index].status = .failed; job.items[index].error = error.localizedDescription; try save(job, to: journal, onQuarantine: onQuarantine)
            if isStorageFailure(error) { throw error }; try verifyDestination(directory); return
        }
        let name = item.input.deletingPathExtension().lastPathComponent + "-" + safeName(snapshot.lookName ?? "")
        let output = uniqueOutput(directory: directory, name: name, suffix: snapshot.outputFormat.suffix)
        job.items[index].output = output; job.items[index].completedIdentity = try OriginalFileIdentity(temp)
        job.items[index].status = .publishing; try save(job, to: journal, onQuarantine: onQuarantine)
        do { try FileManager.default.moveItem(at: temp, to: output) }
        catch {
            job.items[index].status = .failed; job.items[index].error = error.localizedDescription; try save(job, to: journal, onQuarantine: onQuarantine)
            if isStorageFailure(error) { throw error }; return
        }
        job.items[index].status = .succeeded; job.items[index].error = nil; try save(job, to: journal, onQuarantine: onQuarantine)
    }
    public static func uniqueOutput(directory: URL, name: String, suffix: String) -> URL {
        var number = 0; while true { let url = directory.appendingPathComponent(name + (number == 0 ? "" : "-\(number)") + "." + suffix); if !FileManager.default.fileExists(atPath: url.path) { return url }; number += 1 }
    }
    private static func safeName(_ name: String) -> String { String(name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-").prefix(80)) }
    private static func verifyDestination(_ directory: URL) throws {
        let p = directory.appendingPathComponent(".rawlab-write-\(UUID().uuidString)")
        do { try Data([0]).write(to: p, options: .withoutOverwriting); try FileManager.default.removeItem(at: p) } catch { throw BatchExportFailure.destination }
    }
    private static func isStorageFailure(_ error: Error) -> Bool { BatchExportEnvironment.isOutputIOError(error) || BatchExportCore.isOutputIOFailure(error, directory: FileManager.default.temporaryDirectory) }
}
