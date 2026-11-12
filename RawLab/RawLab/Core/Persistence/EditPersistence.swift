import CryptoKit
import Foundation
import Darwin

struct PhotoIdentity: Codable, Equatable, Hashable, Sendable {
    let resourceIdentifier: String?
    let contentIdentifier: String?
    let legacyContentIdentifier: String?

    init(resourceIdentifier: String) {
        self.resourceIdentifier = resourceIdentifier.isEmpty ? nil : resourceIdentifier
        self.contentIdentifier = nil
        self.legacyContentIdentifier = nil
    }

    init(contentIdentifier: String) {
        self.resourceIdentifier = nil
        self.contentIdentifier = contentIdentifier.isEmpty ? nil : contentIdentifier
        self.legacyContentIdentifier = nil
    }

    init(resourceIdentifier: String?, contentIdentifier: String?, legacyContentIdentifier: String? = nil) {
        self.resourceIdentifier = resourceIdentifier?.isEmpty == true ? nil : resourceIdentifier
        self.contentIdentifier = contentIdentifier?.isEmpty == true ? nil : contentIdentifier
        self.legacyContentIdentifier = legacyContentIdentifier?.isEmpty == true ? nil : legacyContentIdentifier
    }

    var key: String {
        if let resourceIdentifier {
            return "photo:\(resourceIdentifier)"
        }
        if let contentIdentifier {
            return "content:\(contentIdentifier)"
        }
        return "content:missing"
    }

    // Photos keeps the asset identifier when its underlying bytes change.
    fileprivate var editKey: String {
        guard let resourceIdentifier, let contentIdentifier else { return key }
        return "photo-content:\(resourceIdentifier.utf8.count):\(resourceIdentifier):\(contentIdentifier)"
    }

    static func fallback(for url: URL, resourceIdentifier: String? = nil) throws -> PhotoIdentity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return PhotoIdentity(resourceIdentifier: resourceIdentifier,
                             contentIdentifier: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

struct PhotoEditState: Codable, Equatable {
    let settings: RawSettings
    let filmID: String?
    let updatedAt: Date

    init(settings: RawSettings, filmID: String? = nil, updatedAt: Date = Date()) {
        self.settings = settings
        self.filmID = filmID ?? settings.lutID
        self.updatedAt = updatedAt
    }

    // 显式 nil 身份不能触发普通初始化入口的 LUT 回退。
    func replacing(settings: RawSettings, preservingFilmID filmID: String?) -> PhotoEditState {
        PhotoEditState(settings: settings, exactFilmID: filmID, updatedAt: updatedAt)
    }

    private init(settings: RawSettings, exactFilmID: String?, updatedAt: Date) {
        self.settings = settings
        self.filmID = exactFilmID
        self.updatedAt = updatedAt
    }

    func hasSameAdjustments(as other: PhotoEditState) -> Bool {
        settings == other.settings && filmID == other.filmID
    }

    func withUpdatedAt(_ date: Date) -> PhotoEditState {
        .init(settings: settings, exactFilmID: filmID, updatedAt: date)
    }
}

struct PhotoEditRecord: Equatable {
    let identity: PhotoIdentity
    let state: PhotoEditState?

    func hasSameAdjustments(as other: PhotoEditRecord?) -> Bool {
        guard let other, identity == other.identity else { return false }
        switch (state, other.state) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameAdjustments(as: rhs)
        default: return false
        }
    }
}

enum AdjustmentCommitError: Error {
    case photoChanged
    case expired
    case historyOrder
}

enum EditPersistenceError: LocalizedError {
    case invalidIdentity
    case corruptStore
    case legacyAssetEditNeedsDecision

    var errorDescription: String? {
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

final class EditPersistence {
    private struct StoredProcessingMigration: Codable {
        let identity: PhotoIdentity
        var receipt: ProcessingMigrationReceipt<PhotoEditState>
    }
    private struct StoreFile: Codable {
        var version: Int?
        var records: [String: PhotoEditState]
        // Old registries may contain this field. It is read once to migrate
        // deletion markers in memory and is not emitted by new writes.
        var revisions: [String: String]?
        // A deletion marker keeps the PhotoKit content fallback from restoring
        // an edit after reset without reviving the old revision mechanism.
        var deleted: Set<String>?
        var processingMigrations: [String: StoredProcessingMigration]?
    }

    let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let writeData: (Data, URL) throws -> Void
    private let snapshotLock = NSLock()
    private var lastReadableStore = StoreFile(records: [:])

    init(directory: URL, writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("edits.json")
        self.writeData = writeData
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try readStore()
    }

    static func appStore() throws -> EditPersistence {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try EditPersistence(directory: root.appendingPathComponent("RawLab/Edits", isDirectory: true))
    }

    func state(for identity: PhotoIdentity) -> PhotoEditState? {
        do { return try readState(for: identity).state }
        catch {
            // 旧读取接口在 I/O 失败时保留已载入值；事务读取始终抛错，不能用缓存提交。
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return record(identity, from: lastReadableStore).state
        }
    }

    func state(for url: URL) -> PhotoEditState? {
        guard let identity = try? PhotoIdentity.fallback(for: url) else { return nil }
        return state(for: identity)
    }

    func save(_ identity: PhotoIdentity, state: PhotoEditState) throws {
        try validate(identity)
        try withWriteLock {
            var store = try readStore()
            _ = try write(state, identity: identity, store: &store)
        }
    }

    func save(_ url: URL, state: PhotoEditState) throws {
        try save(try PhotoIdentity.fallback(for: url), state: state)
    }

    func reset(_ identity: PhotoIdentity) throws {
        try validate(identity)
        try withWriteLock {
            var store = try readStore()
            _ = try write(nil, identity: identity, clearsProcessingMigration: true, store: &store)
        }
    }

    func reset(_ url: URL) throws {
        try reset(try PhotoIdentity.fallback(for: url))
    }

    func readState(for identity: PhotoIdentity, requiringLegacyDecision: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        let store = try readStore()
        if requiringLegacyDecision, unverifiedAssetEdit(for: identity, from: store) != nil {
            throw EditPersistenceError.legacyAssetEditNeedsDecision
        }
        return record(identity, from: store)
    }

    func unverifiedAssetEdit(for identity: PhotoIdentity) throws -> PhotoEditState? {
        // Records written before content binding have only the Photos asset identifier.
        try unverifiedAssetEdit(for: identity, from: readStore())
    }

    func resolveUnverifiedAssetEdit(for identity: PhotoIdentity, expected: PhotoEditState, restore: Bool) throws {
        try withWriteLock {
            var store = try readStore()
            guard unverifiedAssetEdit(for: identity, from: store) == expected else { throw AdjustmentCommitError.expired }
            if restore {
                _ = try write(expected, identity: identity, store: &store)
            } else {
                store.deleted = (store.deleted ?? []).union([identity.editKey])
                try persistStore(&store)
            }
        }
    }

    private func unverifiedAssetEdit(for identity: PhotoIdentity, from store: StoreFile) -> PhotoEditState? {
        guard identity.editKey != identity.key else { return nil }
        let existing = recordKey(identity, from: store)
        guard store.records[existing] == nil, store.deleted?.contains(existing) != true else { return nil }
        return store.records[identity.key]
    }

    func processingMigration(for identity: PhotoIdentity) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        try validate(identity)
        return storedMigration(identity, from: try readStore())?.receipt
    }

    func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?,
                                   quality: ProcessingMigrationQuality) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try withWriteLock {
            var store = try readStore()
            guard record(expected.identity, from: store) == expected, let original = expected.state,
                  (1...2).contains(original.settings.processing.version), quality.isValid else {
                throw AdjustmentCommitError.expired
            }
            if let previous = storedMigration(expected.identity, from: store),
               !previous.receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) {
                throw AdjustmentCommitError.expired
            }
            if let candidate {
                guard candidate.settings.processing == .current, quality.passes else { throw AdjustmentCommitError.expired }
                store.records[expected.identity.editKey] = candidate
                store.deleted?.remove(expected.identity.editKey)
            }
            var receipts = store.processingMigrations ?? [:]
            receipts[expected.identity.editKey] = StoredProcessingMigration(identity: expected.identity,
                receipt: .init(status: candidate == nil ? .kept : .migrated, original: original, quality: quality))
            store.processingMigrations = receipts
            try persistStore(&store)
            return record(expected.identity, from: store)
        }
    }

    func rollbackProcessingMigration(expected: PhotoEditRecord) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try withWriteLock {
            var store = try readStore()
            guard record(expected.identity, from: store) == expected,
                  var receipt = storedMigration(expected.identity, from: store)?.receipt,
                  receipt.status == .migrated else { throw AdjustmentCommitError.expired }
            store.records[expected.identity.editKey] = receipt.original
            store.deleted?.remove(expected.identity.editKey)
            receipt.status = .rolledBack
            var receipts = store.processingMigrations ?? [:]
            receipts[expected.identity.editKey] = StoredProcessingMigration(identity: expected.identity, receipt: receipt)
            store.processingMigrations = receipts
            try persistStore(&store)
            return record(expected.identity, from: store)
        }
    }

    func resolvingLegacyContent(for identity: PhotoIdentity,
                                load: () async -> String?) async -> PhotoIdentity {
        guard identity.resourceIdentifier != nil, identity.legacyContentIdentifier == nil,
              let store = try? readStore() else { return identity }
        let current = record(identity, from: store)
        // 只有可能命中旧入口记录时才额外读取 transferable，删除标记也必须阻止兜底。
        guard current.state == nil, store.deleted?.contains(recordKey(identity, from: store)) != true,
              store.records.keys.contains(where: { $0.hasPrefix("content:") }),
              let legacy = await load() else { return identity }
        return PhotoIdentity(resourceIdentifier: identity.resourceIdentifier,
                             contentIdentifier: identity.contentIdentifier, legacyContentIdentifier: legacy)
    }

    @discardableResult
    func saveState(identity: PhotoIdentity, state: PhotoEditState?,
                   clearsProcessingMigration: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        return try withWriteLock {
            var store = try readStore()
            return try write(state, identity: identity, clearsProcessingMigration: clearsProcessingMigration, store: &store)
        }
    }

    func saveTransferredState(_ state: PhotoEditState, expected: PhotoEditRecord) throws -> PhotoEditRecord {
        let identity = expected.identity
        try validate(identity)
        return try withWriteLock {
            var store = try readStore()
            guard unverifiedAssetEdit(for: identity, from: store) == nil else {
                throw EditPersistenceError.legacyAssetEditNeedsDecision
            }
            guard record(identity, from: store).hasSameAdjustments(as: expected) else {
                throw AdjustmentCommitError.expired
            }
            return try write(state, identity: identity, store: &store)
        }
    }

    private func validate(_ identity: PhotoIdentity) throws {
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else { throw EditPersistenceError.invalidIdentity }
    }

    private func record(_ identity: PhotoIdentity, from store: StoreFile) -> PhotoEditRecord {
        .init(identity: identity, state: store.records[recordKey(identity, from: store)])
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
        if let stored = receipts[identity.editKey] ?? receipts[identity.key],
           stored.identity.resourceIdentifier == identity.resourceIdentifier,
           stored.identity.contentIdentifier == identity.contentIdentifier {
            return stored
        }
        let key = recordKey(identity, from: store)
        guard let stored = receipts[key], stored.identity.resourceIdentifier == nil, stored.identity.key == key else { return nil }
        return stored
    }

    private func readStore() throws -> StoreFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = StoreFile(records: [:])
            remember(empty)
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let store = try JSONDecoder().decode(StoreFile.self, from: data)
            guard store.version == nil || store.version == 1,
                  store.revisions?.values.allSatisfy({ !$0.isEmpty }) ?? true else { throw EditPersistenceError.corruptStore }
            var normalized = store
            if let revisions = store.revisions {
                let tombstones = Set(revisions.keys.filter { store.records[$0] == nil })
                normalized.deleted = (normalized.deleted ?? []).union(tombstones)
                normalized.revisions = nil
            }
            remember(normalized)
            return normalized
        } catch { throw EditPersistenceError.corruptStore }
    }

    private func matchesMigrationIdentity(_ stored: PhotoIdentity, _ identity: PhotoIdentity) -> Bool {
        stored.resourceIdentifier == identity.resourceIdentifier &&
            stored.contentIdentifier == identity.contentIdentifier
    }

    private func hasClearableProcessingMigration(_ identity: PhotoIdentity, in store: StoreFile) -> Bool {
        let receipts = store.processingMigrations ?? [:]
        if identity.editKey != identity.key, receipts[identity.editKey] != nil { return true }
        if let stored = receipts[identity.key], matchesMigrationIdentity(stored.identity, identity) { return true }
        return storedMigration(identity, from: store) != nil
    }

    private func clearProcessingMigration(for identity: PhotoIdentity, in store: inout StoreFile) {
        guard var receipts = store.processingMigrations else { return }
        if identity.editKey != identity.key {
            receipts.removeValue(forKey: identity.editKey)
        }
        if let stored = receipts[identity.key], matchesMigrationIdentity(stored.identity, identity) {
            receipts.removeValue(forKey: identity.key)
        }
        store.processingMigrations = receipts.isEmpty ? nil : receipts
    }

    private func write(_ state: PhotoEditState?, identity: PhotoIdentity,
                       clearsProcessingMigration: Bool = false, store: inout StoreFile) throws -> PhotoEditRecord {
        let current = record(identity, from: store)
        let clearsMigration = clearsProcessingMigration && hasClearableProcessingMigration(identity, in: store)
        if !clearsMigration {
            if let previous = current.state, let state, previous.hasSameAdjustments(as: state) { return current }
            if current.state == nil && state == nil { return current }
        }
        store.version = 1
        if clearsProcessingMigration {
            clearProcessingMigration(for: identity, in: &store)
        } else if state != nil, store.processingMigrations?[identity.editKey] == nil,
                  let previous = storedMigration(identity, from: store) {
            // 从内容别名转成 PhotoKit 主记录时，迁移回退也跟随该照片，不能丢在旧入口下。
            var receipts = store.processingMigrations ?? [:]
            receipts[identity.editKey] = StoredProcessingMigration(identity: identity, receipt: previous.receipt)
            store.processingMigrations = receipts
        }
        if let state {
            store.records[identity.editKey] = state
            store.deleted?.remove(identity.editKey)
        } else {
            store.records.removeValue(forKey: identity.editKey)
            store.deleted = (store.deleted ?? []).union([identity.editKey])
        }
        try persistStore(&store)
        return record(identity, from: store)
    }

    private func persistStore(_ store: inout StoreFile) throws {
        store.version = 1
        // Revisions are a legacy read-only field. The first normal write
        // rewrites the registry without carrying that map forward.
        store.revisions = nil
        if store.deleted?.isEmpty == true { store.deleted = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(store), fileURL)
        remember(store)
    }

    private func remember(_ store: StoreFile) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        lastReadableStore = store
    }

    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let descriptor = open(directory.appendingPathComponent(".edits.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
