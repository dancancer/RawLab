import Darwin
import Foundation

public struct EditRegistryEnvelope: Sendable {
    public var version: Int?
    public var records: [String: Data]
    public var deleted: Set<String>?
    public var processingMigrations: [String: Data]?

    public init(
        version: Int? = nil,
        records: [String: Data] = [:],
        deleted: Set<String>? = nil,
        processingMigrations: [String: Data]? = nil
    ) {
        self.version = version
        self.records = records
        self.deleted = deleted
        self.processingMigrations = processingMigrations
    }
}

public protocol EditRegistrySchema {
    associatedtype IdentityKey
    associatedtype State: Codable, Equatable
    associatedtype Record: Equatable

    static var requiresExistingDirectoryOnRead: Bool { get }
    static var createDirectoryOnLock: Bool { get }
    static var requiresVersionOnDecode: Bool { get }
    static var supportsDeletedTombstones: Bool { get }
    static var allowUTF8BOM: Bool { get }

    static func futureVersionError() -> Error
    static func rootCorruptError(underlying: Error) -> Error
    static func didQuarantine(at url: URL, error: Error)
}

private final class SchemaRegistryStorage: @unchecked Sendable {
    let cache = EditStoreRegistryCache<EditRegistryEnvelope>(
        maximumEntries: EditStoreRegistryCache<EditRegistryEnvelope>.maximumEntriesDefault
    )
    let metricsLock = NSLock()
    var diskReadCount = 0
    var diskReadCountsByDirectory: [String: Int] = [:]
}

private enum EditRegistryStorageTable {
    private static let lock = NSLock()
    private static var storages: [ObjectIdentifier: SchemaRegistryStorage] = [:]

    static func storage<Schema: EditRegistrySchema>(for _: Schema.Type) -> SchemaRegistryStorage {
        let key = ObjectIdentifier(Schema.self)
        lock.lock(); defer { lock.unlock() }
        if let existing = storages[key] { return existing }
        let created = SchemaRegistryStorage()
        storages[key] = created
        return created
    }
}

public final class EditRegistryStore<Schema: EditRegistrySchema>: @unchecked Sendable {
    private struct FutureStoreVersionError: Error {}

    private enum StoreReadOutcome {
        case ok(EditRegistryEnvelope)
        case rootCorrupt(Error)
    }

    private struct QueuedPathFailure {
        let sequence: UInt64
        let blockThroughSequence: UInt64
        let error: Error
    }

    private final class PendingCommitEntry {
        let sequence: UInt64
        let key: String
        let postDelivery: Bool
        let completion: ((Result<Schema.Record, Error>) -> Void)?
        var ioCompleted = false
        var delivered = false
        var result: Result<Schema.Record, Error>?
        var didDeliver: (() -> Void)?

        init(
            sequence: UInt64,
            key: String,
            postDelivery: Bool,
            completion: ((Result<Schema.Record, Error>) -> Void)?
        ) {
            self.sequence = sequence
            self.key = key
            self.postDelivery = postDelivery
            self.completion = completion
        }
    }

    public static var registryDiskReadCount: Int {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        storage.metricsLock.lock(); defer { storage.metricsLock.unlock() }
        return storage.diskReadCount
    }

    public static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        let path = FileDigestCache.canonicalPath(for: directory)
        storage.metricsLock.lock(); defer { storage.metricsLock.unlock() }
        return storage.diskReadCountsByDirectory[path, default: 0]
    }

    private static func recordDiskRead(forDirectory directory: URL) {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        let path = FileDigestCache.canonicalPath(for: directory)
        storage.metricsLock.lock(); defer { storage.metricsLock.unlock() }
        storage.diskReadCount += 1
        storage.diskReadCountsByDirectory[path, default: 0] += 1
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("edits.json") }
    public var canonicalDirectoryPath: String { FileDigestCache.canonicalPath(for: directory) }

    private let writeData: (Data, URL) throws -> Void
    private let inProcessWriteLock = NSLock()
    private let snapshotLock = NSLock()
    private var _lastReadableEnvelope = EditRegistryEnvelope(records: [:])
    private var _lastQuarantinedURL: URL?
    private var _quarantinedError: Error?
    private var _lastWriteFingerprint: FileStatFingerprint?

    private let ioQueue = DispatchQueue(label: "rawlab.edit-registry-store.io", qos: .utility)
    private let pendingLock = NSLock()
    private var nextCommitSequence: UInt64 = 0
    private var pendingCommits: [PendingCommitEntry] = []
    private var failedPathsInQueue: [String: QueuedPathFailure] = [:]
    private var activeDeliveryFailureStates: [Bool] = []

    public init(
        directory: URL,
        writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.directory = directory
        self.writeData = writeData
    }

    public var lastReadableEnvelope: EditRegistryEnvelope {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _lastReadableEnvelope
    }

    public var lastQuarantinedURL: URL? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _lastQuarantinedURL
    }

    public var lastWriteFingerprint: FileStatFingerprint? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _lastWriteFingerprint
    }

    public func consumeQuarantinedError() -> Error? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        defer { _quarantinedError = nil }
        return _quarantinedError
    }

    private func remember(_ envelope: EditRegistryEnvelope) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        _lastReadableEnvelope = envelope
    }

    public func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        inProcessWriteLock.lock(); defer { inProcessWriteLock.unlock() }
        return try EditStoreFileLock.withExclusiveLock(
            directory: directory,
            lockFileName: ".edits.lock",
            createDirectory: Schema.createDirectoryOnLock,
            body: body
        )
    }

    public func readEnvelope(allowCache: Bool = true, holdingWriteLock: Bool = false) throws -> EditRegistryEnvelope {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        if Schema.requiresExistingDirectoryOnRead {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                storage.cache.invalidate(fileURL: fileURL)
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            storage.cache.invalidate(fileURL: fileURL)
            let empty = EditRegistryEnvelope(records: [:])
            remember(empty)
            return empty
        }
        let initialPath = FileDigestCache.canonicalPath(for: fileURL)
        if allowCache,
           let initialFingerprint = FileStatFingerprint(resolvedPath: initialPath),
           let cached = storage.cache.cachedStore(forPath: initialPath, fingerprint: initialFingerprint) {
            remember(cached)
            return cached
        }

        switch try readUnderStripe(initialPath: initialPath, allowCache: allowCache) {
        case .ok(let envelope):
            return envelope
        case .rootCorrupt(let error):
            if holdingWriteLock {
                return try quarantineCorruptStore(error: error)
            }
            return try withWriteLock {
                try readEnvelope(allowCache: false, holdingWriteLock: true)
            }
        }
    }

    private func readUnderStripe(initialPath: String, allowCache: Bool) throws -> StoreReadOutcome {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        let stripe = storage.cache.stripeLock(for: initialPath)
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                storage.cache.invalidate(fileURL: fileURL)
                let empty = EditRegistryEnvelope(records: [:])
                remember(empty)
                return .ok(empty)
            }
            let beforePath = FileDigestCache.canonicalPath(for: fileURL)
            let before = FileStatFingerprint(resolvedPath: beforePath)
            if allowCache,
               let before,
               let cached = storage.cache.cachedStore(forPath: beforePath, fingerprint: before) {
                remember(cached)
                return .ok(cached)
            }
            let startEpoch = storage.cache.epoch(for: beforePath)
            Self.recordDiskRead(forDirectory: directory)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                storage.cache.invalidate(fileURL: fileURL)
                var dirExists: ObjCBool = false
                if Self.isNoSuchFileError(error),
                   (!Schema.requiresExistingDirectoryOnRead ||
                    (FileManager.default.fileExists(atPath: directory.path, isDirectory: &dirExists) && dirExists.boolValue)) {
                    let empty = EditRegistryEnvelope(records: [:])
                    remember(empty)
                    return .ok(empty)
                }
                throw error
            }
            let normalized: EditRegistryEnvelope
            do {
                normalized = try Self.decodeEnvelope(from: data)
            } catch is FutureStoreVersionError {
                storage.cache.invalidate(fileURL: fileURL)
                throw Schema.futureVersionError()
            } catch {
                let afterPath = FileDigestCache.canonicalPath(for: fileURL)
                let after = FileStatFingerprint(resolvedPath: afterPath)
                if attempt < 2, (after != before || afterPath != beforePath) {
                    continue
                }
                storage.cache.invalidate(fileURL: fileURL)
                return .rootCorrupt(error)
            }
            let afterPath = FileDigestCache.canonicalPath(for: fileURL)
            let after = FileStatFingerprint(resolvedPath: afterPath)
            let endEpoch = storage.cache.epoch(for: beforePath)
            if let before, afterPath == beforePath, after == before, endEpoch == startEpoch {
                storage.cache.store(normalized, fingerprint: before, forPath: beforePath, expectedEpoch: startEpoch)
                remember(normalized)
                return .ok(normalized)
            }
            if attempt == 2 {
                remember(normalized)
                return .ok(normalized)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    public func writeEnvelope(_ envelope: inout EditRegistryEnvelope) throws {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        envelope.version = 1
        if !Schema.supportsDeletedTombstones || envelope.deleted?.isEmpty == true {
            envelope.deleted = nil
        }
        if envelope.processingMigrations?.isEmpty == true {
            envelope.processingMigrations = nil
        }
        let data = try Self.encodeEnvelope(envelope)
        storage.cache.invalidate(fileURL: fileURL)
        do {
            try writeData(data, fileURL)
        } catch {
            storage.cache.invalidate(fileURL: fileURL)
            throw error
        }
        let postWritePath = FileDigestCache.canonicalPath(for: fileURL)
        let writtenFingerprint = FileStatFingerprint(resolvedPath: postWritePath)
        snapshotLock.lock()
        _lastWriteFingerprint = writtenFingerprint
        snapshotLock.unlock()
        storage.cache.updateAfterWrite(fileURL: fileURL, store: envelope)
        remember(envelope)
    }

    private func quarantineCorruptStore(error: Error, now: Date = Date()) throws -> EditRegistryEnvelope {
        let storage = EditRegistryStorageTable.storage(for: Schema.self)
        let resolvedFile = FileDigestCache.canonicalURL(for: fileURL)
        guard FileManager.default.fileExists(atPath: resolvedFile.path) else {
            storage.cache.invalidate(fileURL: fileURL)
            let empty = EditRegistryEnvelope(records: [:])
            remember(empty)
            return empty
        }
        let parent = resolvedFile.deletingLastPathComponent()
        let baseName = "\(resolvedFile.lastPathComponent).corrupt-\(Self.corruptTimestamp(now))"
        var suffix = 0
        let candidate: URL
        while true {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let proposed = parent.appendingPathComponent(name)
            if try Self.itemType(atPath: proposed.path) == nil {
                try FileManager.default.moveItem(at: resolvedFile, to: proposed)
                candidate = proposed
                break
            }
            suffix += 1
        }
        storage.cache.invalidate(fileURL: fileURL)
        snapshotLock.lock()
        _lastQuarantinedURL = candidate
        _quarantinedError = error
        _lastReadableEnvelope = EditRegistryEnvelope(records: [:])
        snapshotLock.unlock()
        NSLog("Quarantined corrupt edit store %@ to %@ (%@)", resolvedFile.lastPathComponent, candidate.lastPathComponent, String(describing: error))
        Schema.didQuarantine(at: candidate, error: error)
        return EditRegistryEnvelope(records: [:])
    }

    @discardableResult
    public static func removeStaleAtomicTempFiles(in directory: URL) -> Int {
        guard let dirAttrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
              (dirAttrs[.type] as? FileAttributeType) == .typeDirectory else {
            return 0
        }
        return (try? EditStoreFileLock.withExclusiveLock(directory: directory, lockFileName: ".edits.lock", createDirectory: false) {
            guard let lockedAttrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  (lockedAttrs[.type] as? FileAttributeType) == .typeDirectory,
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: nil,
                      options: []
                  ) else {
                return 0
            }
            var removed = 0
            for entry in entries {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
                      let fileType = attrs[.type] as? FileAttributeType,
                      fileType != .typeSymbolicLink else {
                    continue
                }
                let name = entry.lastPathComponent
                let isAtomicTempFile = fileType == .typeRegular && (
                    name.hasPrefix("edits.json.sb-") ||
                    name.hasPrefix(".dat.nosync") ||
                    (name.hasSuffix(".tmp") && (name.hasPrefix("edits.json.") || name.hasPrefix(".edits")))
                )
                let isAtomicStagingDir = fileType == .typeDirectory &&
                    name.hasPrefix("(A Document Being Saved By ") && name.hasSuffix(")")
                guard isAtomicTempFile || isAtomicStagingDir else { continue }
                if (try? FileManager.default.removeItem(at: entry)) != nil {
                    removed += 1
                }
            }
            return removed
        }) ?? 0
    }

    // MARK: - Ordered Async Commit Queue

    public var hasPendingCommits: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingCommits.contains { !$0.delivered }
    }

    public var pendingCommitCount: Int {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingCommits.reduce(into: 0) { count, entry in
            if !entry.delivered { count += 1 }
        }
    }

    public func waitForPendingIO() {
        ioQueue.sync {}
    }

    @discardableResult
    public func deliverReadyCompletedCommits() -> Bool {
        pendingLock.lock()
        let hasReady = pendingCommits.first?.ioCompleted == true
        pendingLock.unlock()
        guard hasReady else { return true }
        if Thread.isMainThread {
            return deliverCompletedCommits()
        }
        var succeeded = true
        DispatchQueue.main.sync {
            succeeded = deliverCompletedCommits()
        }
        return succeeded
    }

    @discardableResult
    public func flushPendingCommits() -> Bool {
        var allSucceeded = true
        while true {
            ioQueue.sync {}
            pendingLock.lock()
            let hasReadyOrPending = !pendingCommits.isEmpty
            pendingLock.unlock()
            guard hasReadyOrPending else { return allSucceeded }
            let batchSucceeded: Bool
            if Thread.isMainThread {
                batchSucceeded = deliverCompletedCommits()
            } else {
                var succeeded = true
                DispatchQueue.main.sync {
                    succeeded = deliverCompletedCommits()
                }
                batchSucceeded = succeeded
            }
            if !batchSucceeded {
                allSucceeded = false
            }
        }
    }

    @discardableResult
    private func deliverCompletedCommits() -> Bool {
        let depthIndex = activeDeliveryFailureStates.count
        activeDeliveryFailureStates.append(false)
        defer { activeDeliveryFailureStates.removeLast() }

        while true {
            pendingLock.lock()
            guard let first = pendingCommits.first, first.ioCompleted else {
                pendingLock.unlock()
                break
            }
            pendingCommits.removeFirst()
            let shouldDeliver = !first.delivered
            if shouldDeliver {
                first.delivered = true
            }
            pendingLock.unlock()

            guard shouldDeliver else { continue }
            if case .failure = first.result {
                for idx in activeDeliveryFailureStates.indices {
                    activeDeliveryFailureStates[idx] = true
                }
            }
            if let result = first.result {
                first.completion?(result)
            }
            if first.postDelivery {
                first.didDeliver?()
            }
        }
        return !activeDeliveryFailureStates[depthIndex]
    }

    public func performSync<T>(clearingFailedKeys: (T) -> [String] = { _ in [] }, _ work: () throws -> T) throws -> T {
        try ioQueue.sync {
            let value = try work()
            let keys = clearingFailedKeys(value)
            if !keys.isEmpty {
                pendingLock.lock()
                for key in keys {
                    failedPathsInQueue.removeValue(forKey: key)
                }
                pendingLock.unlock()
            }
            return value
        }
    }

    public func enqueueCommit(
        key: String,
        postDelivery: Bool = true,
        chainIfUndeliveredFailure: Bool = false,
        operation: @escaping () throws -> (record: Schema.Record, didDeliver: (() -> Void)?),
        completion: ((Result<Schema.Record, Error>) -> Void)? = nil
    ) {
        pendingLock.lock()
        nextCommitSequence &+= 1
        let seq = nextCommitSequence
        if chainIfUndeliveredFailure {
            if let existing = failedPathsInQueue[key],
               pendingCommits.contains(where: { $0.sequence == existing.sequence && !$0.delivered }) {
                if seq > existing.blockThroughSequence {
                    failedPathsInQueue[key] = QueuedPathFailure(
                        sequence: existing.sequence,
                        blockThroughSequence: seq,
                        error: existing.error
                    )
                }
            } else if let latestCompletedForPath = pendingCommits.last(where: { $0.key == key && $0.ioCompleted && !$0.delivered }),
                      case .failure(let error) = latestCompletedForPath.result {
                failedPathsInQueue[key] = QueuedPathFailure(
                    sequence: latestCompletedForPath.sequence,
                    blockThroughSequence: seq,
                    error: error
                )
            }
        }
        let entry = PendingCommitEntry(sequence: seq, key: key, postDelivery: postDelivery, completion: completion)
        pendingCommits.append(entry)
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let chainedFailure: Error?
            if let recorded = self.failedPathsInQueue[key], entry.sequence <= recorded.blockThroughSequence {
                chainedFailure = recorded.error
            } else {
                chainedFailure = nil
            }
            self.pendingLock.unlock()

            let outcome: Result<(record: Schema.Record, didDeliver: (() -> Void)?), Error>
            if let chainedFailure {
                outcome = .failure(chainedFailure)
            } else {
                outcome = Result { try operation() }
            }

            self.pendingLock.lock()
            switch outcome {
            case .success(let pair):
                entry.result = .success(pair.record)
                entry.didDeliver = pair.didDeliver
                if let recorded = self.failedPathsInQueue[entry.key], entry.sequence >= recorded.sequence {
                    self.failedPathsInQueue.removeValue(forKey: entry.key)
                }
            case .failure(let error):
                entry.result = .failure(error)
                let maxPendingSeq = self.pendingCommits.lazy
                    .filter { $0.key == entry.key }
                    .map(\.sequence)
                    .max() ?? entry.sequence
                if let existing = self.failedPathsInQueue[entry.key] {
                    if entry.sequence > existing.blockThroughSequence {
                        if maxPendingSeq > entry.sequence {
                            self.failedPathsInQueue[entry.key] = QueuedPathFailure(
                                sequence: entry.sequence,
                                blockThroughSequence: maxPendingSeq,
                                error: error
                            )
                        } else {
                            self.failedPathsInQueue.removeValue(forKey: entry.key)
                        }
                    } else if entry.sequence >= existing.blockThroughSequence {
                        self.failedPathsInQueue.removeValue(forKey: entry.key)
                    }
                } else if maxPendingSeq > entry.sequence {
                    self.failedPathsInQueue[entry.key] = QueuedPathFailure(
                        sequence: entry.sequence,
                        blockThroughSequence: maxPendingSeq,
                        error: error
                    )
                }
            }
            entry.ioCompleted = true
            self.pendingLock.unlock()

            DispatchQueue.main.async { [weak self] in
                _ = self?.deliverCompletedCommits()
            }
        }
        pendingLock.unlock()
    }

    // MARK: - Envelope Codec & Filesystem Helpers

    private static func decodeEnvelope(from data: Data) throws -> EditRegistryEnvelope {
        let fail = { Schema.rootCorruptError(underlying: CocoaError(.fileReadCorruptFile)) }
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw fail()
        }
        let root = try EditStoreJSONCodec.scanJSONObjectSlices(
            data,
            allowUTF8BOM: Schema.allowUTF8BOM,
            error: fail()
        )
        let version: Int?
        if let versionSlice = root["version"], String(data: versionSlice, encoding: .utf8) != "null" {
            if let parsedVersion = EditStoreJSONCodec.parseIntegerVersion(versionSlice), parsedVersion > 1 {
                throw FutureStoreVersionError()
            }
            guard EditStoreJSONCodec.isVersionOne(versionSlice) else { throw fail() }
            version = 1
        } else if Schema.requiresVersionOnDecode {
            throw fail()
        } else {
            version = nil
        }

        guard let recordsSlice = root["records"] else { throw fail() }
        let records = try EditStoreJSONCodec.scanJSONObjectSlices(
            recordsSlice,
            allowUTF8BOM: false,
            error: fail()
        )

        var deleted: Set<String>?
        if Schema.supportsDeletedTombstones {
            if let deletedSlice = root["deleted"], String(data: deletedSlice, encoding: .utf8) != "null" {
                deleted = Set(try JSONDecoder().decode([String].self, from: deletedSlice))
            }
            if let revisionsSlice = root["revisions"], String(data: revisionsSlice, encoding: .utf8) != "null" {
                _ = try EditStoreJSONCodec.scanJSONObjectSlices(revisionsSlice, allowUTF8BOM: false, error: fail())
                let revisions = try JSONDecoder().decode([String: String].self, from: revisionsSlice)
                guard revisions.values.allSatisfy({ !$0.isEmpty }) else { throw fail() }
                let tombstones = Set(revisions.keys.filter { records[$0] == nil })
                deleted = (deleted ?? []).union(tombstones)
            }
        }

        let migrations: [String: Data]?
        if let migrationsSlice = root["processingMigrations"],
           String(data: migrationsSlice, encoding: .utf8) != "null" {
            migrations = try EditStoreJSONCodec.scanJSONObjectSlices(
                migrationsSlice,
                allowUTF8BOM: false,
                error: fail()
            )
        } else {
            migrations = nil
        }

        return EditRegistryEnvelope(
            version: version,
            records: records,
            deleted: deleted?.isEmpty == true ? nil : deleted,
            processingMigrations: migrations
        )
    }

    private static func encodeEnvelope(_ envelope: EditRegistryEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data("{".utf8)
        var hasField = false
        func appendComma() {
            if hasField { out.append(UInt8(ascii: ",")) }
            hasField = true
        }
        if Schema.supportsDeletedTombstones, let deleted = envelope.deleted, !deleted.isEmpty {
            appendComma()
            out.append(contentsOf: "\"deleted\":".utf8)
            out.append(try encoder.encode(deleted.sorted()))
        }
        if let migrations = envelope.processingMigrations, !migrations.isEmpty {
            appendComma()
            out.append(contentsOf: "\"processingMigrations\":".utf8)
            try EditStoreJSONCodec.appendRawMap(migrations, encoder: encoder, to: &out)
        }
        appendComma()
        out.append(contentsOf: "\"records\":".utf8)
        try EditStoreJSONCodec.appendRawMap(envelope.records, encoder: encoder, to: &out)
        appendComma()
        out.append(contentsOf: "\"version\":1}".utf8)
        return out
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

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return underlying.code == ENOENT
            }
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }
}
