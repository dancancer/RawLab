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

    /// Computes or returns a cached content identity validated by the resolved file's stat fingerprint.
    static func cachedFallback(for url: URL,
                               resourceIdentifier: String? = nil,
                               digestCache: FileDigestCache = .shared) throws -> PhotoIdentity {
        PhotoIdentity(resourceIdentifier: resourceIdentifier,
                      contentIdentifier: try digestCache.digest(for: url))
    }
}

private typealias POSIXStat = Darwin.stat

private struct FileStatFingerprint: Equatable {
    let device: dev_t
    let inode: UInt64
    let size: Int64
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }

    init(statBuffer st: POSIXStat) {
        self.device = st.st_dev
        self.inode = UInt64(st.st_ino)
        self.size = Int64(st.st_size)
        self.mode = st.st_mode
        self.modifiedSeconds = st.st_mtimespec.tv_sec
        self.modifiedNanoseconds = st.st_mtimespec.tv_nsec
        self.changedSeconds = st.st_ctimespec.tv_sec
        self.changedNanoseconds = st.st_ctimespec.tv_nsec
    }

    init?(resolvedPath: String) {
        var st = POSIXStat()
        guard stat(resolvedPath, &st) == 0 else { return nil }
        self.init(statBuffer: st)
    }

    static func fileDescriptor(_ fd: Int32) -> FileStatFingerprint? {
        var st = POSIXStat()
        guard fstat(fd, &st) == 0 else { return nil }
        return FileStatFingerprint(statBuffer: st)
    }
}

private struct BoundedLRUCache<Key: Hashable, Value> {
    let maximumEntries: Int
    private var entries: [Key: Value] = [:]
    private var order: [Key] = []

    init(maximumEntries: Int) {
        self.maximumEntries = max(0, maximumEntries)
    }

    var count: Int { entries.count }

    mutating func value(forKey key: Key) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    mutating func setValue(_ value: Value, forKey key: Key) {
        guard maximumEntries > 0 else { return }
        if entries[key] != nil {
            entries[key] = value
            touch(key)
            return
        }
        entries[key] = value
        order.append(key)
        while order.count > maximumEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    mutating func removeValue(forKey key: Key) {
        guard entries.removeValue(forKey: key) != nil else { return }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let idx = order.firstIndex(of: key) else { return }
        if idx != order.count - 1 {
            order.remove(at: idx)
            order.append(key)
        }
    }
}

/// Bounded LRU SHA-256 cache validated against canonical path + POSIX stat fingerprint + pre/post stability.
final class FileDigestCache: @unchecked Sendable {
    static let defaultMaximumEntries = 128
    static let shared = FileDigestCache()

    private struct Entry {
        let fingerprint: FileStatFingerprint
        let digest: String
    }

    let maximumEntries: Int
    private let cacheLock = NSLock()
    private let metricsLock = NSLock()
    private let stripeLocks: [NSLock] = (0..<16).map { _ in NSLock() }
    private var cache: BoundedLRUCache<String, Entry>
    private var invalidationEpochs: [String: UInt64] = [:]
    private var _digestComputeCount = 0
    private var _digestComputeCountsByPath: [String: Int] = [:]
    private let readObserver: ((URL, Int) -> Void)?

    init(maximumEntries: Int = FileDigestCache.defaultMaximumEntries,
         readObserver: ((URL, Int) -> Void)? = nil) {
        let bounded = max(0, maximumEntries)
        self.maximumEntries = bounded
        self.cache = BoundedLRUCache(maximumEntries: bounded)
        self.readObserver = readObserver
    }

    var digestComputeCount: Int {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return _digestComputeCount
    }

    func digestComputeCount(for url: URL) -> Int {
        let resolved = Self.canonicalPath(for: url)
        metricsLock.lock(); defer { metricsLock.unlock() }
        return _digestComputeCountsByPath[resolved, default: 0]
    }

    var entryCount: Int {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache.count
    }

    func invalidate(for url: URL) {
        let resolved = Self.canonicalPath(for: url)
        let raw = url.standardizedFileURL.path
        cacheLock.lock(); defer { cacheLock.unlock() }
        invalidationEpochs[resolved, default: 0] &+= 1
        cache.removeValue(forKey: resolved)
        if raw != resolved {
            invalidationEpochs[raw, default: 0] &+= 1
            cache.removeValue(forKey: raw)
        }
    }

    func invalidateAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        for key in invalidationEpochs.keys {
            invalidationEpochs[key, default: 0] &+= 1
        }
        cache.removeAll()
    }

    /// Returns the hex SHA-256 digest for a regular file, reusing a cached digest when stat metadata is unchanged.
    func digest(for url: URL, maximumBytes: Int? = nil) throws -> String {
        guard url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        let initialPath = Self.canonicalPath(for: url)
        let initialFingerprint: FileStatFingerprint
        do {
            initialFingerprint = try Self.statOrThrow(resolvedPath: initialPath)
        } catch {
            invalidate(for: url)
            throw error
        }
        guard initialFingerprint.isRegularFile else { throw CocoaError(.fileReadCorruptFile) }
        if let maximumBytes {
            guard initialFingerprint.size > 0 && initialFingerprint.size <= Int64(maximumBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let hit = cachedDigest(forPath: initialPath, fingerprint: initialFingerprint) {
            return hit
        }

        let stripe = stripeLocks[Self.stripeIndex(for: initialPath)]
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            let resolvedPath = Self.canonicalPath(for: url)
            let before: FileStatFingerprint
            do {
                before = try Self.statOrThrow(resolvedPath: resolvedPath)
            } catch {
                invalidate(for: url)
                throw error
            }
            guard before.isRegularFile else { throw CocoaError(.fileReadCorruptFile) }
            if let maximumBytes {
                guard before.size > 0 && before.size <= Int64(maximumBytes) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if let hit = cachedDigest(forPath: resolvedPath, fingerprint: before) {
                return hit
            }
            let startEpoch = epoch(for: resolvedPath)
            let fd = Darwin.open(resolvedPath, O_RDONLY)
            if fd < 0 {
                let code = errno
                if code == ENOENT { invalidate(for: url) }
                throw Self.posixOrCocoaError(for: code)
            }
            defer { Darwin.close(fd) }
            guard let fdBefore = FileStatFingerprint.fileDescriptor(fd), fdBefore.isRegularFile else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if fdBefore != before { continue }

            recordCompute(forPath: resolvedPath)
            readObserver?(url, attempt)
            let (digest, totalBytes) = try Self.hashFileDescriptor(fd, maximumBytes: maximumBytes)
            guard let fdAfter = FileStatFingerprint.fileDescriptor(fd) else {
                continue
            }
            let afterPath = Self.canonicalPath(for: url)
            let afterStat = FileStatFingerprint(resolvedPath: afterPath)
            if fdAfter == fdBefore && afterPath == resolvedPath && afterStat == fdBefore {
                if let maximumBytes, totalBytes == 0 || totalBytes > maximumBytes {
                    throw CocoaError(.fileReadCorruptFile)
                }
                store(Entry(fingerprint: fdBefore, digest: digest), forPath: resolvedPath, expectedEpoch: startEpoch)
                return digest
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    fileprivate static func canonicalURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    fileprivate static func canonicalPath(for url: URL) -> String {
        canonicalURL(for: url).path
    }

    private static func stripeIndex(for key: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 16)
    }

    private func cachedDigest(forPath path: String, fingerprint: FileStatFingerprint) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let entry = cache.value(forKey: path), entry.fingerprint == fingerprint else { return nil }
        return entry.digest
    }

    private func epoch(for path: String) -> UInt64 {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return invalidationEpochs[path, default: 0]
    }

    private func store(_ entry: Entry, forPath path: String, expectedEpoch: UInt64) {
        guard maximumEntries > 0 else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard invalidationEpochs[path, default: 0] == expectedEpoch else { return }
        cache.setValue(entry, forKey: path)
    }

    private func recordCompute(forPath path: String) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        _digestComputeCount += 1
        _digestComputeCountsByPath[path, default: 0] += 1
    }

    private static func hashFileDescriptor(_ fd: Int32, maximumBytes: Int?) throws -> (String, Int) {
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress, chunkSize)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += count
            if let maximumBytes, total > maximumBytes {
                throw CocoaError(.fileReadCorruptFile)
            }
            hasher.update(data: buffer.prefix(count))
        }
        if maximumBytes != nil && total == 0 {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    private static func statOrThrow(resolvedPath: String) throws -> FileStatFingerprint {
        var st = POSIXStat()
        guard stat(resolvedPath, &st) == 0 else {
            throw posixOrCocoaError(for: errno)
        }
        return FileStatFingerprint(statBuffer: st)
    }

    private static func posixOrCocoaError(for code: Int32) -> Error {
        if code == ENOENT { return CocoaError(.fileNoSuchFile) }
        if code == EACCES || code == EPERM { return CocoaError(.fileReadNoPermission) }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
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

struct UnusableEditRecordError: LocalizedError {
    let message: String
    let underlying: Error?

    init(_ message: String = L10n.text("无法读取已保存的调整，原有记录未被覆盖。"), underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }

    var errorDescription: String? { message }
}

final class EditPersistence {
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

    private final class RegistryCache: @unchecked Sendable {
        static let shared = RegistryCache(maximumEntries: 32)
        static let maximumEntriesDefault = 32

        private struct Entry {
            let fingerprint: FileStatFingerprint
            let store: StoreFile
        }

        private let lock = NSLock()
        private let stripeLocks: [NSLock] = (0..<16).map { _ in NSLock() }
        private var cache: BoundedLRUCache<String, Entry>
        private var invalidationEpochs: [String: UInt64] = [:]

        init(maximumEntries: Int = RegistryCache.maximumEntriesDefault) {
            self.cache = BoundedLRUCache(maximumEntries: max(0, maximumEntries))
        }

        func stripeLock(for resolvedPath: String) -> NSLock {
            stripeLocks[Self.stripeIndex(for: resolvedPath)]
        }

        func cachedStore(forPath path: String, fingerprint: FileStatFingerprint) -> StoreFile? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = cache.value(forKey: path), entry.fingerprint == fingerprint else { return nil }
            return entry.store
        }

        func epoch(for path: String) -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return invalidationEpochs[path, default: 0]
        }

        func store(_ store: StoreFile, fingerprint: FileStatFingerprint, forPath path: String, expectedEpoch: UInt64) {
            lock.lock(); defer { lock.unlock() }
            guard invalidationEpochs[path, default: 0] == expectedEpoch else { return }
            cache.setValue(Entry(fingerprint: fingerprint, store: store), forKey: path)
        }

        func invalidate(fileURL: URL) {
            let resolved = FileDigestCache.canonicalPath(for: fileURL)
            let raw = fileURL.standardizedFileURL.path
            lock.lock(); defer { lock.unlock() }
            invalidationEpochs[resolved, default: 0] &+= 1
            cache.removeValue(forKey: resolved)
            if raw != resolved {
                invalidationEpochs[raw, default: 0] &+= 1
                cache.removeValue(forKey: raw)
            }
        }

        private static func stripeIndex(for key: String) -> Int {
            var hash: UInt64 = 14695981039346656037
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
            return Int(hash % 16)
        }
    }

    private static let registryMetricsLock = NSLock()
    private static var _registryDiskReadCount = 0
    private static var _registryDiskReadCountsByPath: [String: Int] = [:]

    static var registryDiskReadCount: Int {
        registryMetricsLock.lock(); defer { registryMetricsLock.unlock() }
        return _registryDiskReadCount
    }

    static func registryDiskReadCount(forDirectory directory: URL) -> Int {
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

    func state(for identity: PhotoIdentity) throws -> PhotoEditState? {
        do { return try readState(for: identity).state }
        catch let error as UnusableEditRecordError { throw error }
        catch {
            // 旧读取接口在 I/O 失败时保留已载入值；单条坏记录始终抛错，事务读取始终抛错。
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return try record(identity, from: lastReadableStore).state
        }
    }

    func state(for url: URL) throws -> PhotoEditState? {
        guard let identity = try? PhotoIdentity.fallback(for: url) else { return nil }
        return try state(for: identity)
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

    @discardableResult
    func resetToUnmodified(_ identity: PhotoIdentity) throws -> PhotoEditRecord {
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

    func readState(for identity: PhotoIdentity, requiringLegacyDecision: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        let store = try readStore()
        if requiringLegacyDecision, try unverifiedAssetEdit(for: identity, from: store) != nil {
            throw EditPersistenceError.legacyAssetEditNeedsDecision
        }
        return try record(identity, from: store)
    }

    /// Evaluates a batch of identities against a single store snapshot, isolating per-record errors.
    func readStates(for identities: [PhotoIdentity],
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

    func unverifiedAssetEdit(for identity: PhotoIdentity) throws -> PhotoEditState? {
        // Records written before content binding have only the Photos asset identifier.
        try unverifiedAssetEdit(for: identity, from: readStore())
    }

    func resolveUnverifiedAssetEdit(for identity: PhotoIdentity, expected: PhotoEditState, restore: Bool) throws {
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

    func processingMigration(for identity: PhotoIdentity) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        try validate(identity)
        return storedMigration(identity, from: try readStore())?.receipt
    }

    func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?,
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

    func rollbackProcessingMigration(expected: PhotoEditRecord) throws -> PhotoEditRecord {
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

    func resolvingLegacyContent(for identity: PhotoIdentity,
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
            RegistryCache.shared.invalidate(fileURL: fileURL)
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            RegistryCache.shared.invalidate(fileURL: fileURL)
            let empty = StoreFile(records: [:])
            remember(empty)
            return empty
        }
        let initialPath = FileDigestCache.canonicalPath(for: fileURL)
        if let initialFingerprint = FileStatFingerprint(resolvedPath: initialPath),
           let cached = RegistryCache.shared.cachedStore(forPath: initialPath, fingerprint: initialFingerprint) {
            remember(cached)
            return cached
        }

        let stripe = RegistryCache.shared.stripeLock(for: initialPath)
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                RegistryCache.shared.invalidate(fileURL: fileURL)
                let empty = StoreFile(records: [:])
                remember(empty)
                return empty
            }
            let beforePath = FileDigestCache.canonicalPath(for: fileURL)
            let before = FileStatFingerprint(resolvedPath: beforePath)
            if let before, let cached = RegistryCache.shared.cachedStore(forPath: beforePath, fingerprint: before) {
                remember(cached)
                return cached
            }
            let startEpoch = RegistryCache.shared.epoch(for: beforePath)
            Self.recordRegistryDiskRead(forDirectory: directory)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                RegistryCache.shared.invalidate(fileURL: fileURL)
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
                RegistryCache.shared.invalidate(fileURL: fileURL)
                throw EditPersistenceError.corruptStore
            }
            let afterPath = FileDigestCache.canonicalPath(for: fileURL)
            let after = FileStatFingerprint(resolvedPath: afterPath)
            let endEpoch = RegistryCache.shared.epoch(for: beforePath)
            if let before, afterPath == beforePath, after == before, endEpoch == startEpoch {
                RegistryCache.shared.store(normalized, fingerprint: before, forPath: beforePath, expectedEpoch: startEpoch)
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
        let root = try Self.scanJSONObjectSlices(data)
        let version: Int?
        if let versionSlice = root["version"], String(data: versionSlice, encoding: .utf8) != "null" {
            guard Self.isVersionOne(versionSlice) else { throw EditPersistenceError.corruptStore }
            version = 1
        } else {
            version = nil
        }
        guard let recordsSlice = root["records"] else { throw EditPersistenceError.corruptStore }
        let records = try Self.scanJSONObjectSlices(recordsSlice)
        var deleted: Set<String>?
        if let deletedSlice = root["deleted"], String(data: deletedSlice, encoding: .utf8) != "null" {
            deleted = Set(try JSONDecoder().decode([String].self, from: deletedSlice))
        }
        if let revisionsSlice = root["revisions"], String(data: revisionsSlice, encoding: .utf8) != "null" {
            _ = try Self.scanJSONObjectSlices(revisionsSlice)
            let revisions = try JSONDecoder().decode([String: String].self, from: revisionsSlice)
            guard revisions.values.allSatisfy({ !$0.isEmpty }) else { throw EditPersistenceError.corruptStore }
            let tombstones = Set(revisions.keys.filter { records[$0] == nil })
            deleted = (deleted ?? []).union(tombstones)
        }
        let migrations: [String: Data]?
        if let migrationsSlice = root["processingMigrations"],
           String(data: migrationsSlice, encoding: .utf8) != "null" {
            migrations = try Self.scanJSONObjectSlices(migrationsSlice)
        } else {
            migrations = nil
        }
        return StoreFile(version: version, records: records,
                         deleted: deleted?.isEmpty == true ? nil : deleted,
                         processingMigrations: migrations)
    }

    private static func isVersionOne(_ slice: Data) -> Bool {
        guard !slice.contains(UInt8(ascii: ".")),
              !slice.contains(UInt8(ascii: "e")),
              !slice.contains(UInt8(ascii: "E")),
              let value = try? JSONDecoder().decode(Int.self, from: slice) else { return false }
        return value == 1
    }

    private static func scanJSONObjectSlices(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        var index = 0
        let end = bytes.count
        let decoder = JSONDecoder()

        func skipWhitespace() {
            while index < end {
                let b = bytes[index]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
                else { break }
            }
        }

        func skipString() throws {
            guard index < end, bytes[index] == 0x22 else { throw EditPersistenceError.corruptStore }
            index += 1
            while index < end {
                let b = bytes[index]
                if b == 0x5C {
                    index += 2
                    if index > end { throw EditPersistenceError.corruptStore }
                } else if b == 0x22 {
                    index += 1
                    return
                } else {
                    index += 1
                }
            }
            throw EditPersistenceError.corruptStore
        }

        func scanValue() throws -> Data {
            skipWhitespace()
            guard index < end else { throw EditPersistenceError.corruptStore }
            let start = index
            let first = bytes[index]
            if first == 0x22 {
                try skipString()
            } else if first == 0x7B || first == 0x5B {
                var depth = 1
                index += 1
                while index < end && depth > 0 {
                    let b = bytes[index]
                    if b == 0x22 { try skipString() }
                    else if b == 0x7B || b == 0x5B { depth += 1; index += 1 }
                    else if b == 0x7D || b == 0x5D { depth -= 1; index += 1 }
                    else { index += 1 }
                }
                guard depth == 0 else { throw EditPersistenceError.corruptStore }
            } else {
                while index < end {
                    let b = bytes[index]
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x2C || b == 0x7D || b == 0x5D { break }
                    index += 1
                }
                guard index > start else { throw EditPersistenceError.corruptStore }
            }
            return Data(bytes[start..<index])
        }

        skipWhitespace()
        guard index < end, bytes[index] == 0x7B else { throw EditPersistenceError.corruptStore }
        index += 1
        skipWhitespace()
        var result: [String: Data] = [:]
        if index < end, bytes[index] == 0x7D {
            index += 1
            skipWhitespace()
            guard index == end else { throw EditPersistenceError.corruptStore }
            return result
        }
        while true {
            skipWhitespace()
            let keyStart = index
            try skipString()
            let key = try decoder.decode(String.self, from: Data(bytes[keyStart..<index]))
            guard result[key] == nil else { throw EditPersistenceError.corruptStore }
            skipWhitespace()
            guard index < end, bytes[index] == 0x3A else { throw EditPersistenceError.corruptStore }
            index += 1
            result[key] = try scanValue()
            skipWhitespace()
            guard index < end else { throw EditPersistenceError.corruptStore }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                index += 1
                skipWhitespace()
                guard index == end else { throw EditPersistenceError.corruptStore }
                return result
            } else {
                throw EditPersistenceError.corruptStore
            }
        }
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
            try Self.appendRawMap(migrations, encoder: encoder, to: &out)
        }
        appendComma()
        out.append(contentsOf: "\"records\":".utf8)
        try Self.appendRawMap(store.records, encoder: encoder, to: &out)
        appendComma()
        out.append(contentsOf: "\"version\":1}".utf8)
        RegistryCache.shared.invalidate(fileURL: fileURL)
        do {
            try writeData(out, fileURL)
        } catch {
            RegistryCache.shared.invalidate(fileURL: fileURL)
            throw error
        }
        RegistryCache.shared.invalidate(fileURL: fileURL)
        remember(store)
    }

    private static func appendRawMap(_ map: [String: Data], encoder: JSONEncoder, to out: inout Data) throws {
        out.append(UInt8(ascii: "{"))
        var first = true
        for key in map.keys.sorted() {
            if !first { out.append(UInt8(ascii: ",")) }
            first = false
            out.append(try encoder.encode(key))
            out.append(UInt8(ascii: ":"))
            out.append(map[key]!)
        }
        out.append(UInt8(ascii: "}"))
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
