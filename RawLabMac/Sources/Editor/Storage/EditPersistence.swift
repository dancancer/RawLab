import CryptoKit
import Foundation
import Darwin
import UniformTypeIdentifiers

struct FileStatFingerprint: Hashable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mtimeSec: Int
    let mtimeNsec: Int
    let ctimeSec: Int
    let ctimeNsec: Int

    init?(path: String) {
        var st = Darwin.stat()
        guard stat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
        mtimeSec = st.st_mtimespec.tv_sec
        mtimeNsec = st.st_mtimespec.tv_nsec
        ctimeSec = st.st_ctimespec.tv_sec
        ctimeNsec = st.st_ctimespec.tv_nsec
    }
}

final class BoundedLRUCache<Key: Hashable, Value> {
    let maximumEntries: Int
    private var entries: [Key: Value] = [:]
    private var order: [Key] = []

    init(maximumEntries: Int) {
        self.maximumEntries = max(1, maximumEntries)
    }

    var count: Int { entries.count }

    func get(_ key: Key) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: Value, for key: Key) {
        if entries[key] != nil {
            entries[key] = value
            touch(key)
            return
        }
        while entries.count >= maximumEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[key] = value
        order.append(key)
    }

    func removeValue(for key: Key) {
        guard entries.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Key) {
        if let idx = order.firstIndex(of: key) {
            if idx != order.count - 1 {
                order.remove(at: idx)
                order.append(key)
            }
        } else {
            order.append(key)
        }
    }
}

struct OriginalFileIdentity: Codable, Equatable {
    let path: String
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64

    init(_ url: URL) throws {
        path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.size = size.uint64Value
        self.modified = modified
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func requireCurrent() throws {
        guard try OriginalFileIdentity(URL(fileURLWithPath: path)) == self else { throw AdjustmentCommitError.photoChanged }
    }
}

struct PhotoEditRecord: Equatable {
    let identity: OriginalFileIdentity
    let state: PhotoEditState?
}

enum AdjustmentCommitError: Error { case photoChanged, expired, historyOrder }

struct UnusableEditRecordError: LocalizedError {
    let message: String
    let underlying: Error?

    init(_ message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }

    var errorDescription: String? { message }
}

final class EditPersistence {
    static let didChangeRecordsNotification = Notification.Name("RawLab.EditPersistence.didChangeRecords")
    static let didInvalidateEditedNotification = Notification.Name("RawLab.EditPersistence.didInvalidateEdited")
    static let directoryPathUserInfoKey = "directoryPath"
    static let changedRecordsUserInfoKey = "changedRecords"
    static let invalidatedPathsUserInfoKey = "invalidatedPaths"
    static let editedRevisionsUserInfoKey = "editedRevisions"
    static let fileIdentitiesUserInfoKey = "fileIdentities"

    private struct Record: Codable {
        let identity: OriginalFileIdentity
        let state: PhotoEditState
    }
    private struct Registry {
        var records: [String: Data] = [:]
        var processingMigrations: [String: Data]? = nil
    }
    private struct StoredMigration: Codable {
        let identity: OriginalFileIdentity
        var receipt: ProcessingMigrationReceipt<PhotoEditState>
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    static let registryCacheCapacity = 32

    private final class RegistryCache {
        private struct Entry {
            let fingerprint: FileStatFingerprint
            let registry: Registry
        }

        private let stateLock = NSLock()
        private let stripeLocks = (0..<16).map { _ in NSLock() }
        private var cache: BoundedLRUCache<String, Entry>
        private var invalidationEpoch: UInt64 = 0

        init(maximumEntries: Int) {
            cache = BoundedLRUCache(maximumEntries: maximumEntries)
        }

        private func stripeLock(for path: String) -> NSLock {
            let hash = UInt(bitPattern: path.hashValue)
            return stripeLocks[Int(hash % UInt(stripeLocks.count))]
        }

        func invalidate(path: String) {
            stateLock.lock()
            invalidationEpoch &+= 1
            cache.removeValue(for: path)
            stateLock.unlock()
        }

        func load(path: String, loader: () throws -> Registry) throws -> Registry {
            let stripe = stripeLock(for: path)
            stripe.lock()
            defer { stripe.unlock() }

            stateLock.lock()
            let epochBefore = invalidationEpoch
            let s1 = FileStatFingerprint(path: path)
            if let s1, let hit = cache.get(path), hit.fingerprint == s1 {
                stateLock.unlock()
                return hit.registry
            }
            stateLock.unlock()

            let registry = try loader()
            let s2 = FileStatFingerprint(path: path)
            if let s1, s2 == s1 {
                stateLock.lock()
                if invalidationEpoch == epochBefore, FileStatFingerprint(path: path) == s1 {
                    cache.set(Entry(fingerprint: s1, registry: registry), for: path)
                }
                stateLock.unlock()
            } else {
                invalidate(path: path)
            }
            return registry
        }
    }

    private let directory: URL
    private let canonicalFilePath: String
    private let writeData: (Data, URL) throws -> Void
    private var file: URL { directory.appendingPathComponent("edits.json") }

    private static let statsLock = NSLock()
    private static var _registryDiskReadCount = 0
    private static var _registryDiskReadCountsByPath: [String: Int] = [:]
    private static let registryCache = RegistryCache(maximumEntries: registryCacheCapacity)

    static var registryDiskReadCount: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _registryDiskReadCount
    }

    static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        let path = Self.canonicalRegistryFilePath(forDirectory: directory)
        statsLock.lock()
        defer { statsLock.unlock() }
        return _registryDiskReadCountsByPath[path, default: 0]
    }

    private static func canonicalRegistryFilePath(forDirectory directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("edits.json")
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func recordRegistryDiskRead(forFilePath path: String) {
        statsLock.lock()
        _registryDiskReadCount += 1
        _registryDiskReadCountsByPath[path, default: 0] += 1
        statsLock.unlock()
    }

    init(directory: URL = EditPersistence.defaultDirectory,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.canonicalFilePath = Self.canonicalRegistryFilePath(forDirectory: directory)
        self.writeData = writeData
        _ = try readRegistry()
    }

    private func readRegistry(allowCache: Bool = true) throws -> Registry {
        guard FileManager.default.fileExists(atPath: file.path) else {
            Self.registryCache.invalidate(path: canonicalFilePath)
            return Registry()
        }
        if allowCache {
            return try Self.registryCache.load(path: canonicalFilePath) {
                try parseRegistryFromDisk()
            }
        }
        return try parseRegistryFromDisk()
    }

    private func parseRegistryFromDisk() throws -> Registry {
        Self.recordRegistryDiskRead(forFilePath: canonicalFilePath)
        let data = try Data(contentsOf: file)
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = try Self.scanJSONObjectSlices(data)
        guard let versionSlice = root["version"], Self.isVersionOne(versionSlice),
              let recordsSlice = root["records"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let records = try Self.scanJSONObjectSlices(recordsSlice)
        let migrations: [String: Data]?
        if let migrationsSlice = root["processingMigrations"],
           String(data: migrationsSlice, encoding: .utf8) != "null" {
            migrations = try Self.scanJSONObjectSlices(migrationsSlice)
        } else {
            migrations = nil
        }
        return Registry(records: records, processingMigrations: migrations)
    }

    private func writeRegistry(_ updated: Registry) throws {
        let data = try Self.encodeRegistry(updated)
        Self.registryCache.invalidate(path: canonicalFilePath)
        do {
            try writeData(data, file)
        } catch {
            Self.registryCache.invalidate(path: canonicalFilePath)
            throw error
        }
        Self.registryCache.invalidate(path: canonicalFilePath)
    }

    private static func isVersionOne(_ slice: Data) -> Bool {
        guard !slice.contains(UInt8(ascii: ".")),
              !slice.contains(UInt8(ascii: "e")),
              !slice.contains(UInt8(ascii: "E")),
              let value = try? JSONDecoder().decode(Int.self, from: slice) else { return false }
        return value == 1
    }

    private static func encodeRegistry(_ registry: Registry) throws -> Data {
        var out = Data("{\"records\":".utf8)
        try appendRawMap(registry.records, to: &out)
        if let migrations = registry.processingMigrations {
            out.append(contentsOf: ",\"processingMigrations\":".utf8)
            try appendRawMap(migrations, to: &out)
        }
        out.append(contentsOf: ",\"version\":1}".utf8)
        return out
    }

    private static func appendRawMap(_ map: [String: Data], to out: inout Data) throws {
        let encoder = JSONEncoder()
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
            guard index < end, bytes[index] == 0x22 else { throw CocoaError(.fileReadCorruptFile) }
            index += 1
            while index < end {
                let b = bytes[index]
                if b == 0x5C {
                    index += 2
                    if index > end { throw CocoaError(.fileReadCorruptFile) }
                } else if b == 0x22 {
                    index += 1
                    return
                } else {
                    index += 1
                }
            }
            throw CocoaError(.fileReadCorruptFile)
        }

        func scanValue() throws -> Data {
            skipWhitespace()
            guard index < end else { throw CocoaError(.fileReadCorruptFile) }
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
                guard depth == 0 else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                while index < end {
                    let b = bytes[index]
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x2C || b == 0x7D || b == 0x5D { break }
                    index += 1
                }
                guard index > start else { throw CocoaError(.fileReadCorruptFile) }
            }
            return Data(bytes[start..<index])
        }

        skipWhitespace()
        guard index < end, bytes[index] == 0x7B else { throw CocoaError(.fileReadCorruptFile) }
        index += 1
        skipWhitespace()
        var result: [String: Data] = [:]
        if index < end, bytes[index] == 0x7D {
            index += 1
            skipWhitespace()
            guard index == end else { throw CocoaError(.fileReadCorruptFile) }
            return result
        }
        while true {
            skipWhitespace()
            let keyStart = index
            try skipString()
            let key = try decoder.decode(String.self, from: Data(bytes[keyStart..<index]))
            guard result[key] == nil else { throw CocoaError(.fileReadCorruptFile) }
            skipWhitespace()
            guard index < end, bytes[index] == 0x3A else { throw CocoaError(.fileReadCorruptFile) }
            index += 1
            result[key] = try scanValue()
            skipWhitespace()
            guard index < end else { throw CocoaError(.fileReadCorruptFile) }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                index += 1
                skipWhitespace()
                guard index == end else { throw CocoaError(.fileReadCorruptFile) }
                return result
            } else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private static func validateState(_ state: PhotoEditState) throws {
        try state.settings.validateResetValues()
        if state.settings.isHDREditing {
            var sdr = state.settings
            sdr.hdr?.mode = .sdr
            try sdr.validateResetValues()
        } else if state.settings.hdr?.isValid == false {
            throw EditorResetBlockedReason.invalidSnapshot("hdr")
        }
        guard state.masterRecipeID == state.settings.masterRecipeID else {
            throw EditorResetBlockedReason.invalidSnapshot("metadata")
        }
    }

    private static func parseRecord(_ data: Data) throws -> Record {
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            try validateState(record.state)
            return record
        } catch let error as UnusableEditRecordError {
            throw error
        } catch {
            let detail = String(describing: error)
            let message = detail.localizedCaseInsensitiveContains("processing identity")
                ? L10n.text("不支持此处理版本，原有记录未被覆盖。")
                : L10n.format("无法读取调整记录：%@", error.localizedDescription)
            throw UnusableEditRecordError(message, underlying: error)
        }
    }

    private static func tryParseMigration(_ data: Data?, identity: OriginalFileIdentity) -> StoredMigration? {
        guard let data, let stored = try? JSONDecoder().decode(StoredMigration.self, from: data),
              stored.identity == identity, (try? validateState(stored.receipt.original)) != nil else { return nil }
        return stored
    }

    func state(for url: URL) throws -> PhotoEditState? {
        try readState(for: url).state
    }

    func readState(for url: URL) throws -> PhotoEditRecord {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return try snapshot(identity: identity, registry: registry)
    }

    func processingMigration(for url: URL) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return Self.tryParseMigration(registry.processingMigrations?[identity.path], identity: identity)?.receipt
    }

    var canonicalDirectoryPath: String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func pathsReferencingFilms(_ identifiers: Set<String>) -> Set<String> {
        guard !identifiers.isEmpty, let registry = try? readRegistry() else { return [] }
        var matched = Set<String>()
        for (path, raw) in registry.records {
            guard let record = try? Self.parseRecord(raw), record.identity.path == path else { continue }
            if identifiers.contains(record.state.filmID) {
                matched.insert(path)
            }
        }
        return matched
    }

    func notifyEditedInvalidation(forPaths paths: Set<String>) {
        guard !paths.isEmpty else { return }
        NotificationCenter.default.post(
            name: Self.didInvalidateEditedNotification,
            object: nil,
            userInfo: [
                Self.directoryPathUserInfoKey: canonicalDirectoryPath,
                Self.invalidatedPathsUserInfoKey: paths
            ]
        )
    }

    static func stateRevisionDigest(for state: PhotoEditState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(state)) ?? Data(String(describing: state).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func editedRevision(for state: PhotoEditState?, atPath path: String) -> String? {
        guard let state else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let isRaster = UTType(filenameExtension: ext).map { $0.conforms(to: .image) && !$0.conforms(to: .rawImage) } ?? false
        let raw = !isRaster
        let context = EditorAdjustmentContext(
            isRaw: raw,
            defaultExposureMode: raw ? Adjustments().exposureMode : .sensor,
            neutralFilmID: ""
        )
        guard EditorAdjustmentRules.isModified(scope: .all, snapshot: state, context: context) else { return nil }
        return stateRevisionDigest(for: state)
    }

    private func postRecordsChanged(_ changes: [String: PhotoEditRecord]) {
        guard !changes.isEmpty else { return }
        var editedRevisions: [String: String] = [:]
        var fileIdentities: [String: (UInt64, Date, UInt64)] = [:]
        for (path, record) in changes {
            fileIdentities[path] = (record.identity.size, record.identity.modified, record.identity.fileNumber)
            if let revision = Self.editedRevision(for: record.state, atPath: path) {
                editedRevisions[path] = revision
            }
        }
        NotificationCenter.default.post(
            name: Self.didChangeRecordsNotification,
            object: nil,
            userInfo: [
                Self.directoryPathUserInfoKey: canonicalDirectoryPath,
                Self.changedRecordsUserInfoKey: changes,
                Self.invalidatedPathsUserInfoKey: Set(changes.keys),
                Self.editedRevisionsUserInfoKey: editedRevisions,
                Self.fileIdentitiesUserInfoKey: fileIdentities
            ]
        )
    }

    func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?,
                                   quality: ProcessingMigrationQuality) throws -> PhotoEditRecord {
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false)
            try expected.identity.requireCurrent()
            guard try snapshot(identity: expected.identity, registry: updated) == expected,
                  let original = expected.state, original.settings.processing.version < 3,
                  quality.isValid else { throw AdjustmentCommitError.expired }
            if let previous = Self.tryParseMigration(updated.processingMigrations?[expected.identity.path], identity: expected.identity),
               !previous.receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) {
                throw AdjustmentCommitError.expired
            }
            if let candidate {
                try Self.validateState(candidate)
                guard candidate.settings.processing == .current, quality.passes else { throw AdjustmentCommitError.expired }
                updated.records[expected.identity.path] = try JSONEncoder().encode(Record(identity: expected.identity, state: candidate))
            }
            let receipt = ProcessingMigrationReceipt(status: candidate == nil ? .kept : .migrated,
                original: original, quality: quality)
            var migrations = updated.processingMigrations ?? [:]
            migrations[expected.identity.path] = try JSONEncoder().encode(StoredMigration(identity: expected.identity, receipt: receipt))
            updated.processingMigrations = migrations
            try writeRegistry(updated)
            return try snapshot(identity: expected.identity, registry: updated)
        }
        if let candidate, expected.state != candidate {
            postRecordsChanged([expected.identity.path: result])
        }
        return result
    }

    func rollbackProcessingMigration(expected: PhotoEditRecord) throws -> PhotoEditRecord {
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false)
            try expected.identity.requireCurrent()
            guard try snapshot(identity: expected.identity, registry: updated) == expected,
                  var stored = Self.tryParseMigration(updated.processingMigrations?[expected.identity.path], identity: expected.identity),
                  stored.receipt.status == .migrated else {
                throw AdjustmentCommitError.expired
            }
            try Self.validateState(stored.receipt.original)
            updated.records[expected.identity.path] = try JSONEncoder().encode(Record(identity: expected.identity, state: stored.receipt.original))
            stored.receipt.status = .rolledBack
            updated.processingMigrations?[expected.identity.path] = try JSONEncoder().encode(stored)
            try writeRegistry(updated)
            return try snapshot(identity: expected.identity, registry: updated)
        }
        if expected.state != result.state {
            postRecordsChanged([expected.identity.path: result])
        }
        return result
    }

    private func snapshot(identity: OriginalFileIdentity, registry: Registry) throws -> PhotoEditRecord {
        guard let raw = registry.records[identity.path] else {
            return PhotoEditRecord(identity: identity, state: nil)
        }
        let record = try Self.parseRecord(raw)
        return PhotoEditRecord(identity: identity, state: record.identity == identity ? record.state : nil)
    }

    func save(_ url: URL, state: PhotoEditState) throws {
        try save([url], state: state)
    }

    func save(_ urls: [URL], state: PhotoEditState) throws {
        var changedPaths: [String: PhotoEditRecord] = [:]
        try withWriteLock {
            try Self.validateState(state)
            var updated = try readRegistry(allowCache: false)
            for url in urls {
                let identity = try OriginalFileIdentity(url)
                if try snapshot(identity: identity, registry: updated).state == state { continue }
                updated.records[identity.path] = try JSONEncoder().encode(Record(identity: identity, state: state))
                changedPaths[identity.path] = PhotoEditRecord(identity: identity, state: state)
            }
            if !changedPaths.isEmpty { try writeRegistry(updated) }
        }
        postRecordsChanged(changedPaths)
    }

    @discardableResult func saveState(identity: OriginalFileIdentity, state: PhotoEditState?,
                                      clearsProcessingMigration: Bool = false) throws -> PhotoEditRecord {
        var stateChanged = false
        let result = try withWriteLock {
            if let state { try Self.validateState(state) }
            var updated = try readRegistry(allowCache: false)
            try identity.requireCurrent()
            let current = try snapshot(identity: identity, registry: updated)
            stateChanged = current.state != state
            let clearsMigration = clearsProcessingMigration && updated.processingMigrations?[identity.path] != nil
            guard stateChanged || clearsMigration else { return current }
            if let state { updated.records[identity.path] = try JSONEncoder().encode(Record(identity: identity, state: state)) }
            else { updated.records.removeValue(forKey: identity.path) }
            if clearsMigration {
                updated.processingMigrations?.removeValue(forKey: identity.path)
                if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            }
            try writeRegistry(updated)
            return PhotoEditRecord(identity: identity, state: state)
        }
        if stateChanged {
            postRecordsChanged([identity.path: result])
        }
        return result
    }

    @discardableResult func resetToUnmodified(_ url: URL) throws -> PhotoEditRecord {
        var clearedPath: String?
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false)
            let identity = try OriginalFileIdentity(url)
            let hadRecord = updated.records.removeValue(forKey: identity.path) != nil
            let hadMigration = updated.processingMigrations?.removeValue(forKey: identity.path) != nil
            if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            if hadRecord || hadMigration {
                try writeRegistry(updated)
            }
            if hadRecord { clearedPath = identity.path }
            return PhotoEditRecord(identity: identity, state: nil)
        }
        if let clearedPath {
            postRecordsChanged([clearedPath: result])
        }
        return result
    }

    private func withWriteLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".edits.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action()
    }
}
