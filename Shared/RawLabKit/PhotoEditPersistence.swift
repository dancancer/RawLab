import Foundation

public enum EditPersistenceError: LocalizedError, Sendable {
    case invalidIdentity
    case corruptStore
    case legacyAssetEditNeedsDecision

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return L10n.text("无法识别原始照片，调整尚未保存。")
        case .corruptStore:
            return L10n.text("无法读取已保存的调整，原有记录未被覆盖。")
        case .legacyAssetEditNeedsDecision:
            return L10n.text("请先打开这张照片，确认是否恢复旧调整。")
        }
    }
}

public extension UnusableEditRecordError {
    init(underlying: Error? = nil) {
        self.init(L10n.text("无法读取已保存的调整，原有记录未被覆盖。"), underlying: underlying)
    }
}

public struct PhotoEditState: Codable, Equatable {
    public let settings: RawSettings
    public let filmID: String?
    public let updatedAt: Date

    public init(settings: RawSettings, filmID: String? = nil, updatedAt: Date = Date()) {
        self.settings = settings
        self.filmID = filmID ?? settings.lutID
        self.updatedAt = updatedAt
    }

    // 显式 nil 身份不能触发普通初始化入口的 LUT 回退。
    public func replacing(settings: RawSettings, preservingFilmID filmID: String?) -> PhotoEditState {
        PhotoEditState(settings: settings, exactFilmID: filmID, updatedAt: updatedAt)
    }

    private init(settings: RawSettings, exactFilmID: String?, updatedAt: Date) {
        self.settings = settings
        self.filmID = exactFilmID
        self.updatedAt = updatedAt
    }

    public func hasSameAdjustments(as other: PhotoEditState) -> Bool {
        settings == other.settings && filmID == other.filmID
    }

    public func withUpdatedAt(_ date: Date) -> PhotoEditState {
        .init(settings: settings, exactFilmID: filmID, updatedAt: date)
    }
}

public struct PhotoEditRecord: Equatable {
    public let identity: PhotoIdentity
    public let state: PhotoEditState?

    public init(identity: PhotoIdentity, state: PhotoEditState?) {
        self.identity = identity
        self.state = state
    }

    public func hasSameAdjustments(as other: PhotoEditRecord?) -> Bool {
        guard let other, identity == other.identity else { return false }
        switch (state, other.state) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameAdjustments(as: rhs)
        default: return false
        }
    }
}

public final class EditPersistence: @unchecked Sendable {
    public static var willSaveRecord: ((PhotoIdentity, PhotoEditState?) throws -> Void)?
    public static var onSaveRecord: ((PhotoIdentity, PhotoEditState?) -> Void)?

    private struct StoredProcessingMigration: Codable {
        let identity: PhotoIdentity
        var receipt: ProcessingMigrationReceipt<PhotoEditState>
    }
    private struct StoreFile {
        var version: Int?
        var records: [String: Data]
        // A deletion marker keeps the PhotoKit content fallback from restoring
        // an edit after reset without reviving the old revision mechanism.
        var deleted: Set<String>?
        var processingMigrations: [String: Data]?
    }

    private static let sharedRegistryCache = EditStoreRegistryCache<StoreFile>(
        maximumEntries: EditStoreRegistryCache<StoreFile>.maximumEntriesDefault
    )
    private static let registryMetricsLock = NSLock()
    private static var _registryDiskReadCount = 0
    private static var _registryDiskReadCountsByPath: [String: Int] = [:]

    public static var registryDiskReadCount: Int {
        registryMetricsLock.lock(); defer { registryMetricsLock.unlock() }
        return _registryDiskReadCount
    }

    public static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        let path = FileDigestCache.canonicalPath(for: directory)
        registryMetricsLock.lock(); defer { registryMetricsLock.unlock() }
        return _registryDiskReadCountsByPath[path, default: 0]
    }

    private static func recordRegistryDiskRead(forDirectory directory: URL) {
        let path = FileDigestCache.canonicalPath(for: directory)
        registryMetricsLock.lock(); defer { registryMetricsLock.unlock() }
        _registryDiskReadCount += 1
        _registryDiskReadCountsByPath[path, default: 0] += 1
    }

    public let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let writeData: (Data, URL) throws -> Void
    private let snapshotLock = NSLock()
    private var lastReadableStore = StoreFile(records: [:])

    public init(directory: URL, writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("edits.json")
        self.writeData = writeData
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try readStore()
    }

    public static func appStore() throws -> EditPersistence {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try EditPersistence(directory: root.appendingPathComponent("RawLab/Edits", isDirectory: true))
    }

    public func state(for identity: PhotoIdentity) throws -> PhotoEditState? {
        do { return try readState(for: identity).state }
        catch let error as UnusableEditRecordError { throw error }
        catch {
            // 旧读取接口在 I/O 失败时保留已载入值；单条坏记录始终抛错，事务读取始终抛错。
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return try record(identity, from: lastReadableStore).state
        }
    }

    public func state(for url: URL) throws -> PhotoEditState? {
        guard let identity = try? PhotoIdentity.fallback(for: url) else { return nil }
        return try state(for: identity)
    }

    public func save(_ identity: PhotoIdentity, state: PhotoEditState) throws {
        try validate(identity)
        try withWriteLock {
            var store = try readStore()
            _ = try write(state, identity: identity, store: &store)
        }
    }

    public func save(_ url: URL, state: PhotoEditState) throws {
        try save(try PhotoIdentity.fallback(for: url), state: state)
    }

    public func reset(_ identity: PhotoIdentity) throws {
        try validate(identity)
        try withWriteLock {
            var store = try readStore()
            _ = try write(nil, identity: identity, clearsProcessingMigration: true, store: &store)
        }
    }

    public func reset(_ url: URL) throws {
        try reset(try PhotoIdentity.fallback(for: url))
    }

    @discardableResult
    public func resetToUnmodified(_ identity: PhotoIdentity) throws -> PhotoEditRecord {
        try validate(identity)
        return try withWriteLock {
            var store = try readStore()
            let resolvedKey = recordKey(identity, from: store)
            let hadFallbackRecord = store.records[resolvedKey] != nil
            let hadOwnRecord = store.records.removeValue(forKey: identity.editKey) != nil
            let hadUnverifiedLegacy = identity.editKey != identity.key &&
                store.deleted?.contains(identity.editKey) != true &&
                store.records[identity.key] != nil
            let clearedMigration = clearProcessingMigration(for: identity, in: &store)
            if hadOwnRecord || hadFallbackRecord || hadUnverifiedLegacy || clearedMigration {
                store.deleted = (store.deleted ?? []).union([identity.editKey])
                try persistStore(&store)
            }
            return PhotoEditRecord(identity: identity, state: nil)
        }
    }

    public func readState(for identity: PhotoIdentity, requiringLegacyDecision: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        let store = try readStore()
        if requiringLegacyDecision, try unverifiedAssetEdit(for: identity, from: store) != nil {
            throw EditPersistenceError.legacyAssetEditNeedsDecision
        }
        return try record(identity, from: store)
    }

    /// Evaluates a batch of identities against a single store snapshot, isolating per-record errors.
    public func readStates(for identities: [PhotoIdentity],
                           requiringLegacyDecision: Bool = false) throws -> [PhotoIdentity: Result<PhotoEditRecord, Error>] {
        let store = try readStore()
        var results = [PhotoIdentity: Result<PhotoEditRecord, Error>](minimumCapacity: identities.count)
        for identity in identities where results[identity] == nil {
            do {
                try validate(identity)
                if requiringLegacyDecision, try unverifiedAssetEdit(for: identity, from: store) != nil {
                    results[identity] = .failure(EditPersistenceError.legacyAssetEditNeedsDecision)
                } else {
                    results[identity] = .success(try record(identity, from: store))
                }
            } catch {
                results[identity] = .failure(error)
            }
        }
        return results
    }

    public func unverifiedAssetEdit(for identity: PhotoIdentity) throws -> PhotoEditState? {
        // Records written before content binding have only the Photos asset identifier.
        try unverifiedAssetEdit(for: identity, from: readStore())
    }

    public func resolveUnverifiedAssetEdit(for identity: PhotoIdentity, expected: PhotoEditState, restore: Bool) throws {
        try withWriteLock {
            var store = try readStore()
            guard try unverifiedAssetEdit(for: identity, from: store) == expected else { throw AdjustmentCommitError.expired }
            if restore {
                _ = try write(expected, identity: identity, store: &store)
            } else {
                store.deleted = (store.deleted ?? []).union([identity.editKey])
                try persistStore(&store)
            }
        }
    }

    private func unverifiedAssetEdit(for identity: PhotoIdentity, from store: StoreFile) throws -> PhotoEditState? {
        guard identity.editKey != identity.key else { return nil }
        let existing = recordKey(identity, from: store)
        guard store.records[existing] == nil, store.deleted?.contains(existing) != true else { return nil }
        return try store.records[identity.key].map(Self.parseState)
    }

    public func processingMigration(for identity: PhotoIdentity) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        try validate(identity)
        return storedMigration(identity, from: try readStore())?.receipt
    }

    public func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?,
                                          quality: ProcessingMigrationQuality) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try withWriteLock {
            var store = try readStore()
            guard try record(expected.identity, from: store) == expected, let original = expected.state,
                  (1...2).contains(original.settings.processing.version), quality.isValid else {
                throw AdjustmentCommitError.expired
            }
            if let previous = storedMigration(expected.identity, from: store),
               !previous.receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) {
                throw AdjustmentCommitError.expired
            }
            if let candidate {
                guard candidate.settings.processing == .current, quality.passes else { throw AdjustmentCommitError.expired }
                store.records[expected.identity.editKey] = try Self.encodeState(candidate)
                store.deleted?.remove(expected.identity.editKey)
            }
            var receipts = store.processingMigrations ?? [:]
            receipts[expected.identity.editKey] = try Self.encodeMigration(StoredProcessingMigration(identity: expected.identity,
                receipt: .init(status: candidate == nil ? .kept : .migrated, original: original, quality: quality)))
            store.processingMigrations = receipts
            try persistStore(&store)
            return try record(expected.identity, from: store)
        }
    }

    public func rollbackProcessingMigration(expected: PhotoEditRecord) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try withWriteLock {
            var store = try readStore()
            guard try record(expected.identity, from: store) == expected,
                  var receipt = storedMigration(expected.identity, from: store)?.receipt,
                  receipt.status == .migrated else { throw AdjustmentCommitError.expired }
            store.records[expected.identity.editKey] = try Self.encodeState(receipt.original)
            store.deleted?.remove(expected.identity.editKey)
            receipt.status = .rolledBack
            var receipts = store.processingMigrations ?? [:]
            receipts[expected.identity.editKey] = try Self.encodeMigration(StoredProcessingMigration(identity: expected.identity, receipt: receipt))
            store.processingMigrations = receipts
            try persistStore(&store)
            return try record(expected.identity, from: store)
        }
    }

    public func resolvingLegacyContent(for identity: PhotoIdentity,
                                       load: () async -> String?) async -> PhotoIdentity {
        guard identity.resourceIdentifier != nil, identity.legacyContentIdentifier == nil,
              let store = try? readStore() else { return identity }
        let key = recordKey(identity, from: store)
        // 只有可能命中旧入口记录时才额外读取 transferable，删除标记也必须阻止兜底。
        guard store.records[key] == nil, store.deleted?.contains(key) != true,
              store.records.keys.contains(where: { $0.hasPrefix("content:") }),
              let legacy = await load() else { return identity }
        return PhotoIdentity(resourceIdentifier: identity.resourceIdentifier,
                             contentIdentifier: identity.contentIdentifier, legacyContentIdentifier: legacy)
    }

    @discardableResult
    public func saveState(identity: PhotoIdentity, state: PhotoEditState?,
                          clearsProcessingMigration: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        return try withWriteLock {
            var store = try readStore()
            return try write(state, identity: identity, clearsProcessingMigration: clearsProcessingMigration, store: &store)
        }
    }

    public func saveTransferredState(_ state: PhotoEditState, expected: PhotoEditRecord) throws -> PhotoEditRecord {
        let identity = expected.identity
        try validate(identity)
        return try withWriteLock {
            var store = try readStore()
            guard try unverifiedAssetEdit(for: identity, from: store) == nil else {
                throw EditPersistenceError.legacyAssetEditNeedsDecision
            }
            guard try record(identity, from: store).hasSameAdjustments(as: expected) else {
                throw AdjustmentCommitError.expired
            }
            return try write(state, identity: identity, store: &store)
        }
    }

    private func validate(_ identity: PhotoIdentity) throws {
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else { throw EditPersistenceError.invalidIdentity }
    }

    private func record(_ identity: PhotoIdentity, from store: StoreFile) throws -> PhotoEditRecord {
        let state = try store.records[recordKey(identity, from: store)].map(Self.parseState)
        return .init(identity: identity, state: state)
    }

    private func recordKey(_ identity: PhotoIdentity, from store: StoreFile) -> String {
        var key = identity.editKey
        // 删除标记也是主记录，不能在重置后重新载入旧的内容记录。
        if identity.resourceIdentifier != nil {
            if store.records[key] == nil, store.deleted?.contains(key) != true,
               store.deleted?.contains(identity.key) == true { return identity.key }
            for content in [identity.contentIdentifier, identity.legacyContentIdentifier].compactMap({ $0 }) {
                guard store.records[key] == nil, store.deleted?.contains(key) != true else { break }
                key = PhotoIdentity(contentIdentifier: content).key
            }
        }
        return key
    }

    private func storedMigration(_ identity: PhotoIdentity, from store: StoreFile) -> StoredProcessingMigration? {
        // 拒绝迁移只写回执，不创建资源编辑记录；先读取该照片自身的回执。
        let receipts = store.processingMigrations ?? [:]
        // legacyContentIdentifier 只帮助查找旧记录，建立资源记录后重开不会再补取。
        let primary = Self.tryParseMigration(receipts[identity.editKey]) ?? Self.tryParseMigration(receipts[identity.key])
        if let stored = primary,
           stored.identity.resourceIdentifier == identity.resourceIdentifier,
           stored.identity.contentIdentifier == identity.contentIdentifier {
            return stored
        }
        let key = recordKey(identity, from: store)
        guard let stored = Self.tryParseMigration(receipts[key]),
              stored.identity.resourceIdentifier == nil, stored.identity.key == key else { return nil }
        return stored
    }

    private func readStore() throws -> StoreFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Self.sharedRegistryCache.invalidate(fileURL: fileURL)
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Self.sharedRegistryCache.invalidate(fileURL: fileURL)
            let empty = StoreFile(records: [:])
            remember(empty)
            return empty
        }
        let initialPath = FileDigestCache.canonicalPath(for: fileURL)
        if let initialFingerprint = FileStatFingerprint(resolvedPath: initialPath),
           let cached = Self.sharedRegistryCache.cachedStore(forPath: initialPath, fingerprint: initialFingerprint) {
            remember(cached)
            return cached
        }

        let stripe = Self.sharedRegistryCache.stripeLock(for: initialPath)
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                Self.sharedRegistryCache.invalidate(fileURL: fileURL)
                let empty = StoreFile(records: [:])
                remember(empty)
                return empty
            }
            let beforePath = FileDigestCache.canonicalPath(for: fileURL)
            let before = FileStatFingerprint(resolvedPath: beforePath)
            if let before, let cached = Self.sharedRegistryCache.cachedStore(forPath: beforePath, fingerprint: before) {
                remember(cached)
                return cached
            }
            let startEpoch = Self.sharedRegistryCache.epoch(for: beforePath)
            Self.recordRegistryDiskRead(forDirectory: directory)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                Self.sharedRegistryCache.invalidate(fileURL: fileURL)
                throw error
            }
            let normalized: StoreFile
            do {
                normalized = try Self.decodeStoreFile(from: data)
            } catch {
                let afterPath = FileDigestCache.canonicalPath(for: fileURL)
                let after = FileStatFingerprint(resolvedPath: afterPath)
                if attempt < 2, (after != before || afterPath != beforePath) {
                    continue
                }
                Self.sharedRegistryCache.invalidate(fileURL: fileURL)
                throw EditPersistenceError.corruptStore
            }
            let afterPath = FileDigestCache.canonicalPath(for: fileURL)
            let after = FileStatFingerprint(resolvedPath: afterPath)
            let endEpoch = Self.sharedRegistryCache.epoch(for: beforePath)
            if let before, afterPath == beforePath, after == before, endEpoch == startEpoch {
                Self.sharedRegistryCache.store(normalized, fingerprint: before, forPath: beforePath, expectedEpoch: startEpoch)
                remember(normalized)
                return normalized
            }
            if attempt == 2 {
                remember(normalized)
                return normalized
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    private static func decodeStoreFile(from data: Data) throws -> StoreFile {
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw EditPersistenceError.corruptStore
        }
        let root = try EditStoreJSONCodec.scanJSONObjectSlices(data, error: EditPersistenceError.corruptStore)
        let version: Int?
        if let versionSlice = root["version"], String(data: versionSlice, encoding: .utf8) != "null" {
            guard EditStoreJSONCodec.isVersionOne(versionSlice) else { throw EditPersistenceError.corruptStore }
            version = 1
        } else {
            version = nil
        }
        guard let recordsSlice = root["records"] else { throw EditPersistenceError.corruptStore }
        let records = try EditStoreJSONCodec.scanJSONObjectSlices(recordsSlice, error: EditPersistenceError.corruptStore)
        var deleted: Set<String>?
        if let deletedSlice = root["deleted"], String(data: deletedSlice, encoding: .utf8) != "null" {
            deleted = Set(try JSONDecoder().decode([String].self, from: deletedSlice))
        }
        if let revisionsSlice = root["revisions"], String(data: revisionsSlice, encoding: .utf8) != "null" {
            _ = try EditStoreJSONCodec.scanJSONObjectSlices(revisionsSlice, error: EditPersistenceError.corruptStore)
            let revisions = try JSONDecoder().decode([String: String].self, from: revisionsSlice)
            guard revisions.values.allSatisfy({ !$0.isEmpty }) else { throw EditPersistenceError.corruptStore }
            let tombstones = Set(revisions.keys.filter { records[$0] == nil })
            deleted = (deleted ?? []).union(tombstones)
        }
        let migrations: [String: Data]?
        if let migrationsSlice = root["processingMigrations"],
           String(data: migrationsSlice, encoding: .utf8) != "null" {
            migrations = try EditStoreJSONCodec.scanJSONObjectSlices(migrationsSlice, error: EditPersistenceError.corruptStore)
        } else {
            migrations = nil
        }
        return StoreFile(version: version, records: records,
                         deleted: deleted?.isEmpty == true ? nil : deleted,
                         processingMigrations: migrations)
    }

    private static func validateState(_ state: PhotoEditState, rawData: Data? = nil) throws {
        let s = state.settings
        guard state.updatedAt.timeIntervalSince1970.isFinite,
              s.exposure.isFinite, (-5.0...5.0).contains(s.exposure),
              s.contrast.isFinite, (0.0...2.0).contains(s.contrast),
              s.saturation.isFinite, (0.0...2.0).contains(s.saturation),
              s.temperature.isFinite, RawSettings.temperatureRange.contains(s.temperature),
              s.tint.isFinite, RawSettings.tintRange.contains(s.tint),
              s.highlights.isFinite, (-1.0...1.0).contains(s.highlights),
              s.shadows.isFinite, (-1.0...1.0).contains(s.shadows),
              s.toneCurve.isFinite, (-1.0...1.0).contains(s.toneCurve),
              s.noiseReduction.isFinite, (0.0...1.0).contains(s.noiseReduction),
              s.sharpening.isFinite, (0.0...2.0).contains(s.sharpening),
              s.lutStrength.isFinite, RawSettings.lutStrengthRange.contains(s.lutStrength),
              (s.hdr?.isValid ?? true),
              s.geometry.isValid, s.denoise.isValid, s.hsl.isValid,
              (s.toneControls?.isValid ?? true), (s.atmosphere?.isValid ?? true),
              (s.colorGrading?.isValid ?? true), (s.toneCurveConfig?.isValid ?? true),
              s.photoEffects.isValid, (0...2).contains(s.displayChromaDenoise),
              (s.lensCorrection?.focalLength.map { $0.isFinite && $0 > 0 } ?? true),
              (s.lensCorrection?.cropFactor.map { $0.isFinite && $0 > 0 } ?? true),
              (s.masterRecipeID == nil || s.masterRecipe != nil),
              [2, 3, 4].contains(s.masterRecipeSettingsVersion) else {
            throw EditPersistenceError.corruptStore
        }
        if let rawData,
           let root = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
           let settingsDict = root["settings"] as? [String: Any] {
            if let mode = settingsDict["exposureMode"] as? Int, !(0...2).contains(mode) {
                throw EditPersistenceError.corruptStore
            }
            if let chroma = settingsDict["displayChromaDenoise"] as? Int, !(0...2).contains(chroma) {
                throw EditPersistenceError.corruptStore
            }
            if let effects = settingsDict["photoEffects"] as? [String: Any] {
                for parameter in PhotoEffectParameter.allCases {
                    if let number = effects[parameter.rawValue] as? Double,
                       !number.isFinite || !parameter.range.contains(number) {
                        throw EditPersistenceError.corruptStore
                    }
                }
            }
        }
    }

    private static func parseState(_ data: Data) throws -> PhotoEditState {
        do {
            let state = try JSONDecoder().decode(PhotoEditState.self, from: data)
            try validateState(state, rawData: data)
            return state
        } catch let error as UnusableEditRecordError {
            throw error
        } catch {
            throw UnusableEditRecordError(underlying: error)
        }
    }

    private static func tryParseMigration(_ data: Data?) -> StoredProcessingMigration? {
        guard let data,
              let stored = try? JSONDecoder().decode(StoredProcessingMigration.self, from: data),
              (try? validateState(stored.receipt.original)) != nil else { return nil }
        return stored
    }

    private static func encodeState(_ state: PhotoEditState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        try validateState(state)
        return encoded
    }

    private static func encodeMigration(_ migration: StoredProcessingMigration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(migration)
    }

    private func matchesMigrationIdentity(_ stored: PhotoIdentity, _ identity: PhotoIdentity) -> Bool {
        stored.resourceIdentifier == identity.resourceIdentifier &&
            stored.contentIdentifier == identity.contentIdentifier
    }

    private func hasClearableProcessingMigration(_ identity: PhotoIdentity, in store: StoreFile) -> Bool {
        let receipts = store.processingMigrations ?? [:]
        if receipts[identity.editKey] != nil { return true }
        if identity.editKey != identity.key,
           let stored = Self.tryParseMigration(receipts[identity.key]),
           matchesMigrationIdentity(stored.identity, identity) { return true }
        return false
    }

    @discardableResult
    private func clearProcessingMigration(for identity: PhotoIdentity, in store: inout StoreFile) -> Bool {
        guard var receipts = store.processingMigrations else { return false }
        var removed = receipts.removeValue(forKey: identity.editKey) != nil
        if identity.editKey != identity.key,
           let stored = Self.tryParseMigration(receipts[identity.key]),
           matchesMigrationIdentity(stored.identity, identity) {
            removed = receipts.removeValue(forKey: identity.key) != nil || removed
        }
        store.processingMigrations = receipts.isEmpty ? nil : receipts
        return removed
    }

    private func write(_ state: PhotoEditState?, identity: PhotoIdentity,
                       clearsProcessingMigration: Bool = false, store: inout StoreFile) throws -> PhotoEditRecord {
        let current = try record(identity, from: store)
        let clearsMigration = clearsProcessingMigration && hasClearableProcessingMigration(identity, in: store)
        if !clearsMigration {
            if let previous = current.state, let state, previous.hasSameAdjustments(as: state) { return current }
            if current.state == nil && state == nil { return current }
        }
        try Self.willSaveRecord?(identity, state)
        let encodedState = try state.map(Self.encodeState)
        store.version = 1
        if clearsProcessingMigration {
            clearProcessingMigration(for: identity, in: &store)
        } else if state != nil, store.processingMigrations?[identity.editKey] == nil,
                  let previous = storedMigration(identity, from: store) {
            // 从内容别名转成 PhotoKit 主记录时，迁移回退也跟随该照片，不能丢在旧入口下。
            var receipts = store.processingMigrations ?? [:]
            receipts[identity.editKey] = try Self.encodeMigration(
                StoredProcessingMigration(identity: identity, receipt: previous.receipt))
            store.processingMigrations = receipts
        }
        if let encodedState {
            store.records[identity.editKey] = encodedState
            Self.onSaveRecord?(identity, state)
            store.deleted?.remove(identity.editKey)
        } else {
            store.records.removeValue(forKey: identity.editKey)
            store.deleted = (store.deleted ?? []).union([identity.editKey])
        }
        try persistStore(&store)
        return try record(identity, from: store)
    }

    private func persistStore(_ store: inout StoreFile) throws {
        store.version = 1
        if store.deleted?.isEmpty == true { store.deleted = nil }
        if store.processingMigrations?.isEmpty == true { store.processingMigrations = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data("{".utf8)
        var hasField = false
        func appendComma() {
            if hasField { out.append(UInt8(ascii: ",")) }
            hasField = true
        }
        if let deleted = store.deleted, !deleted.isEmpty {
            appendComma()
            out.append(contentsOf: "\"deleted\":".utf8)
            out.append(try encoder.encode(deleted.sorted()))
        }
        if let migrations = store.processingMigrations, !migrations.isEmpty {
            appendComma()
            out.append(contentsOf: "\"processingMigrations\":".utf8)
            try EditStoreJSONCodec.appendRawMap(migrations, encoder: encoder, to: &out)
        }
        appendComma()
        out.append(contentsOf: "\"records\":".utf8)
        try EditStoreJSONCodec.appendRawMap(store.records, encoder: encoder, to: &out)
        appendComma()
        out.append(contentsOf: "\"version\":1}".utf8)
        Self.sharedRegistryCache.invalidate(fileURL: fileURL)
        do {
            try writeData(out, fileURL)
        } catch {
            Self.sharedRegistryCache.invalidate(fileURL: fileURL)
            throw error
        }
        // 写后不再整体失效自废：用写后新指纹原地更新缓存条目，下一次 readStore 直接命中（写失败仍走上面的失效路径）。
        Self.sharedRegistryCache.updateAfterWrite(fileURL: fileURL, store: store)
        remember(store)
    }

    private func remember(_ store: StoreFile) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        lastReadableStore = store
    }

    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try EditStoreFileLock.withExclusiveLock(directory: directory, lockFileName: ".edits.lock", createDirectory: false, body: body)
    }
}
