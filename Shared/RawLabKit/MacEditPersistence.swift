import CryptoKit
import Foundation

public struct MacPhotoEditRecord: Equatable {
    public let identity: OriginalFileIdentity
    public let state: MacPhotoEditState?

    public init(identity: OriginalFileIdentity, state: MacPhotoEditState?) {
        self.identity = identity
        self.state = state
    }
}

public final class MacEditPersistence: @unchecked Sendable {
    public static let didChangeRecordsNotification = Notification.Name("RawLab.EditPersistence.didChangeRecords")
    public static let didInvalidateEditedNotification = Notification.Name("RawLab.EditPersistence.didInvalidateEdited")
    public static let directoryPathUserInfoKey = "directoryPath"
    public static let changedRecordsUserInfoKey = "changedRecords"
    public static let invalidatedPathsUserInfoKey = "invalidatedPaths"
    public static let editedRevisionsUserInfoKey = "editedRevisions"
    public static let fileIdentitiesUserInfoKey = "fileIdentities"

    private struct Record: Codable {
        let identity: OriginalFileIdentity
        let state: MacPhotoEditState
    }
    private struct Registry {
        var records: [String: Data] = [:]
        var processingMigrations: [String: Data]? = nil
    }
    private struct StoredMigration: Codable {
        let identity: OriginalFileIdentity
        var receipt: ProcessingMigrationReceipt<MacPhotoEditState>
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    public static let registryCacheCapacity = 32

    private final class RegistryCache: @unchecked Sendable {
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
            cache.removeValue(forKey: path)
            stateLock.unlock()
        }

        func load(path: String, loader: () throws -> Registry) throws -> Registry {
            let stripe = stripeLock(for: path)
            stripe.lock()
            defer { stripe.unlock() }

            stateLock.lock()
            let epochBefore = invalidationEpoch
            let s1 = FileStatFingerprint(resolvedPath: path)
            if let s1, s1.isRegularFile, let hit = cache.peek(forKey: path), hit.fingerprint == s1 {
                _ = cache.value(forKey: path)
                stateLock.unlock()
                return hit.registry
            }
            cache.removeValue(forKey: path)
            stateLock.unlock()

            let registry: Registry
            do {
                registry = try loader()
            } catch {
                invalidate(path: path)
                throw error
            }
            let s2 = FileStatFingerprint(resolvedPath: path)
            if let s1, s1.isRegularFile, s2 == s1 {
                stateLock.lock()
                if invalidationEpoch == epochBefore, FileStatFingerprint(resolvedPath: path) == s1 {
                    cache.setValue(Entry(fingerprint: s1, registry: registry), forKey: path)
                }
                stateLock.unlock()
            } else {
                invalidate(path: path)
            }
            return registry
        }

        func updateAfterWrite(path: String, registry: Registry) {
            let stripe = stripeLock(for: path)
            stripe.lock()
            defer { stripe.unlock() }
            guard let fingerprint = FileStatFingerprint(resolvedPath: path), fingerprint.isRegularFile else {
                invalidate(path: path)
                return
            }
            stateLock.lock()
            cache.setValue(Entry(fingerprint: fingerprint, registry: registry), forKey: path)
            stateLock.unlock()
        }
    }

    private let directory: URL
    private let writeData: (Data, URL) throws -> Void
    private var file: URL { directory.appendingPathComponent("edits.json") }
    private let quarantineLock = NSLock()
    private var _lastQuarantinedURL: URL?
    private var quarantinedError: Error?
    internal static var onQuarantine: ((URL, Error) -> Void)?

    public var lastQuarantinedURL: URL? {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        return _lastQuarantinedURL
    }

    public func consumeQuarantinedError() -> Error? {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        defer { quarantinedError = nil }
        return quarantinedError
    }

    private struct RootCorruptionError: Error {
        let underlying: Error
    }

    private struct FutureVersionError: Error {}

    private static let statsLock = NSLock()
    private static var _registryDiskReadCount = 0
    private static var _registryDiskReadCountsByPath: [String: Int] = [:]
    private static let registryCache = RegistryCache(maximumEntries: registryCacheCapacity)

    public static var registryDiskReadCount: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _registryDiskReadCount
    }

    public static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        let path = Self.resolvedRegistryFileURL(forDirectory: directory).path
        statsLock.lock()
        defer { statsLock.unlock() }
        return _registryDiskReadCountsByPath[path, default: 0]
    }

    private static func resolvedRegistryFileURL(forDirectory directory: URL) -> URL {
        directory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("edits.json")
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private static func recordRegistryDiskRead(forFilePath path: String) {
        statsLock.lock()
        _registryDiskReadCount += 1
        _registryDiskReadCountsByPath[path, default: 0] += 1
        statsLock.unlock()
    }

    public init(directory: URL = MacEditPersistence.defaultDirectory,
                writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.writeData = writeData
        _ = try readRegistry()
    }

    private func readRegistry(allowCache: Bool = true, holdingWriteLock: Bool = false) throws -> Registry {
        let resolvedFile = Self.resolvedRegistryFileURL(forDirectory: directory)
        let resolvedPath = resolvedFile.path
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            Self.registryCache.invalidate(path: resolvedPath)
            return Registry()
        }
        do {
            if allowCache {
                return try Self.registryCache.load(path: resolvedPath) {
                    try parseRegistryFromDisk(fileURL: resolvedFile, resolvedPath: resolvedPath)
                }
            }
            return try parseRegistryFromDisk(fileURL: resolvedFile, resolvedPath: resolvedPath)
        } catch let corruption as RootCorruptionError {
            Self.registryCache.invalidate(path: resolvedPath)
            if file.path != resolvedPath {
                Self.registryCache.invalidate(path: file.path)
            }
            if holdingWriteLock {
                return try quarantineCorruptStore(at: resolvedFile, resolvedPath: resolvedPath, error: corruption.underlying)
            }
            return try withWriteLock {
                try readRegistry(allowCache: false, holdingWriteLock: true)
            }
        } catch {
            Self.registryCache.invalidate(path: resolvedPath)
            throw error
        }
    }

    private func parseRegistryFromDisk(fileURL: URL, resolvedPath: String) throws -> Registry {
        Self.recordRegistryDiskRead(forFilePath: resolvedPath)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch where Self.isNoSuchFileError(error) {
            Self.registryCache.invalidate(path: resolvedPath)
            return Registry()
        }
        do {
            guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let root = try EditStoreJSONCodec.scanJSONObjectSlices(data, error: CocoaError(.fileReadCorruptFile))
            guard let versionSlice = root["version"] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let version = EditStoreJSONCodec.parseIntegerVersion(versionSlice), version > 1 {
                throw FutureVersionError()
            }
            guard EditStoreJSONCodec.isVersionOne(versionSlice),
                  let recordsSlice = root["records"] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let records = try EditStoreJSONCodec.scanJSONObjectSlices(recordsSlice, allowUTF8BOM: false, error: CocoaError(.fileReadCorruptFile))
            let migrations: [String: Data]?
            if let migrationsSlice = root["processingMigrations"],
               String(data: migrationsSlice, encoding: .utf8) != "null" {
                migrations = try EditStoreJSONCodec.scanJSONObjectSlices(migrationsSlice, allowUTF8BOM: false, error: CocoaError(.fileReadCorruptFile))
            } else {
                migrations = nil
            }
            return Registry(records: records, processingMigrations: migrations)
        } catch is FutureVersionError {
            throw CocoaError(.fileReadCorruptFile)
        } catch {
            throw RootCorruptionError(underlying: error)
        }
    }

    private func quarantineCorruptStore(at resolvedFile: URL, resolvedPath: String, error: Error, now: Date = Date()) throws -> Registry {
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
        Self.registryCache.invalidate(path: resolvedPath)
        if file.path != resolvedPath {
            Self.registryCache.invalidate(path: file.path)
        }
        quarantineLock.lock()
        _lastQuarantinedURL = candidate
        quarantinedError = error
        quarantineLock.unlock()
        NSLog("Quarantined corrupt edit store %@ to %@ (%@)", resolvedFile.lastPathComponent, candidate.lastPathComponent, String(describing: error))
        Self.onQuarantine?(candidate, error)
        return Registry()
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

    private func writeRegistry(_ updated: Registry) throws {
        let preWritePath = Self.resolvedRegistryFileURL(forDirectory: directory).path
        // `.atomic` 替换窗口内读者不得再命中旧条目。
        Self.registryCache.invalidate(path: preWritePath)
        let data = try Self.encodeRegistry(updated)
        do {
            try writeData(data, file)
        } catch {
            Self.registryCache.invalidate(path: preWritePath)
            let failedWritePath = Self.resolvedRegistryFileURL(forDirectory: directory).path
            if failedWritePath != preWritePath {
                Self.registryCache.invalidate(path: failedWritePath)
            }
            throw error
        }
        let postWritePath = Self.resolvedRegistryFileURL(forDirectory: directory).path
        Self.registryCache.updateAfterWrite(path: postWritePath, registry: updated)
        if postWritePath != preWritePath {
            Self.registryCache.invalidate(path: preWritePath)
        }
    }

    private static func encodeRegistry(_ registry: Registry) throws -> Data {
        let encoder = JSONEncoder()
        var out = Data("{\"records\":".utf8)
        try EditStoreJSONCodec.appendRawMap(registry.records, encoder: encoder, to: &out)
        if let migrations = registry.processingMigrations {
            out.append(contentsOf: ",\"processingMigrations\":".utf8)
            try EditStoreJSONCodec.appendRawMap(migrations, encoder: encoder, to: &out)
        }
        out.append(contentsOf: ",\"version\":1}".utf8)
        return out
    }

    private static func validateState(_ state: MacPhotoEditState) throws {
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

    public func state(for url: URL) throws -> MacPhotoEditState? {
        try readState(for: url).state
    }

    public func readState(for url: URL) throws -> MacPhotoEditRecord {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return try snapshot(identity: identity, registry: registry)
    }

    public func processingMigration(for url: URL) throws -> ProcessingMigrationReceipt<MacPhotoEditState>? {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return Self.tryParseMigration(registry.processingMigrations?[identity.path], identity: identity)?.receipt
    }

    public var canonicalDirectoryPath: String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func pathsReferencingFilms(_ identifiers: Set<String>) -> Set<String> {
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

    public func notifyEditedInvalidation(forPaths paths: Set<String>) {
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

    public static func stateRevisionDigest(for state: MacPhotoEditState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(state)) ?? Data(String(describing: state).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func editedRevision(for state: MacPhotoEditState?, atPath path: String) -> String? {
        guard let state else { return nil }
        let raw = !PhotoInputClassification.isRasterInput(URL(fileURLWithPath: path))
        let context = MacEditorAdjustmentContext(
            isRaw: raw,
            defaultExposureMode: raw ? Adjustments().exposureMode : .sensor,
            neutralFilmID: ""
        )
        guard MacEditorAdjustmentRules.isModified(scope: .all, snapshot: state, context: context) else { return nil }
        return stateRevisionDigest(for: state)
    }

    private func postRecordsChanged(_ changes: [String: MacPhotoEditRecord]) {
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

    public func commitProcessingMigration(expected: MacPhotoEditRecord, candidate: MacPhotoEditState?,
                                          quality: ProcessingMigrationQuality) throws -> MacPhotoEditRecord {
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false, holdingWriteLock: true)
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

    public func rollbackProcessingMigration(expected: MacPhotoEditRecord) throws -> MacPhotoEditRecord {
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false, holdingWriteLock: true)
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

    private func snapshot(identity: OriginalFileIdentity, registry: Registry) throws -> MacPhotoEditRecord {
        guard let raw = registry.records[identity.path] else {
            return MacPhotoEditRecord(identity: identity, state: nil)
        }
        let record = try Self.parseRecord(raw)
        return MacPhotoEditRecord(identity: identity, state: record.identity == identity ? record.state : nil)
    }

    public func save(_ url: URL, state: MacPhotoEditState) throws {
        try save([url], state: state)
    }

    public func save(_ urls: [URL], state: MacPhotoEditState) throws {
        var changedPaths: [String: MacPhotoEditRecord] = [:]
        try withWriteLock {
            try Self.validateState(state)
            var updated = try readRegistry(allowCache: false, holdingWriteLock: true)
            for url in urls {
                let identity = try OriginalFileIdentity(url)
                if try snapshot(identity: identity, registry: updated).state == state { continue }
                updated.records[identity.path] = try JSONEncoder().encode(Record(identity: identity, state: state))
                changedPaths[identity.path] = MacPhotoEditRecord(identity: identity, state: state)
            }
            if !changedPaths.isEmpty { try writeRegistry(updated) }
        }
        postRecordsChanged(changedPaths)
    }

    @discardableResult public func saveState(identity: OriginalFileIdentity, state: MacPhotoEditState?,
                                             clearsProcessingMigration: Bool = false) throws -> MacPhotoEditRecord {
        var stateChanged = false
        let result = try withWriteLock {
            if let state { try Self.validateState(state) }
            var updated = try readRegistry(allowCache: false, holdingWriteLock: true)
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
            return MacPhotoEditRecord(identity: identity, state: state)
        }
        if stateChanged {
            postRecordsChanged([identity.path: result])
        }
        return result
    }

    @discardableResult public func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord {
        var clearedPath: String?
        let result = try withWriteLock {
            var updated = try readRegistry(allowCache: false, holdingWriteLock: true)
            let identity = try OriginalFileIdentity(url)
            let hadRecord = updated.records.removeValue(forKey: identity.path) != nil
            let hadMigration = updated.processingMigrations?.removeValue(forKey: identity.path) != nil
            if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            if hadRecord || hadMigration {
                try writeRegistry(updated)
            }
            if hadRecord { clearedPath = identity.path }
            return MacPhotoEditRecord(identity: identity, state: nil)
        }
        if let clearedPath {
            postRecordsChanged([clearedPath: result])
        }
        return result
    }

    private func withWriteLock<T>(_ action: () throws -> T) throws -> T {
        try EditStoreFileLock.withExclusiveLock(directory: directory, lockFileName: ".edits.lock", createDirectory: true, body: action)
    }
}

public final class MacResourceDigestCache: @unchecked Sendable {
    public static let defaultMaximumEntries = 128
    public static let shared = MacResourceDigestCache()

    public struct Result {
        public let identity: OriginalFileIdentity
        public let digest: Data

        public init(identity: OriginalFileIdentity, digest: Data) {
            self.identity = identity
            self.digest = digest
        }
    }

    private struct Entry {
        let fingerprint: FileStatFingerprint
        let identity: OriginalFileIdentity
        let digest: Data
    }

    private let stateLock = NSLock()
    private let stripeLocks = (0..<16).map { _ in NSLock() }
    private var cache: BoundedLRUCache<String, Entry>
    private var invalidationEpoch: UInt64 = 0
    private var _sha256Count = 0

    public let maximumEntries: Int

    public init(maximumEntries: Int = MacResourceDigestCache.defaultMaximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
        self.cache = BoundedLRUCache(maximumEntries: self.maximumEntries)
    }

    public var entryCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.count
    }

    public var sha256Count: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _sha256Count
    }

    private func stripeLock(for path: String) -> NSLock {
        let hash = UInt(bitPattern: path.hashValue)
        return stripeLocks[Int(hash % UInt(stripeLocks.count))]
    }

    public func invalidate(url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        invalidate(path: path)
    }

    private func invalidate(path: String) {
        stateLock.lock()
        invalidationEpoch &+= 1
        cache.removeValue(forKey: path)
        stateLock.unlock()
    }

    public func fingerprintDigest(
        for url: URL,
        maxBytes: Int? = nil,
        onHash: (() -> Void)? = nil,
        readData: ((URL) throws -> Data)? = nil
    ) throws -> Result {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path

        if let cached = lookup(path: path) {
            if let maxBytes, !(1...maxBytes).contains(Int(cached.fingerprint.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Result(identity: cached.identity, digest: cached.digest)
        }

        let stripe = stripeLock(for: path)
        stripe.lock()
        defer { stripe.unlock() }

        if let cached = lookup(path: path) {
            if let maxBytes, !(1...maxBytes).contains(Int(cached.fingerprint.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Result(identity: cached.identity, digest: cached.digest)
        }

        for attempt in 0..<3 {
            stateLock.lock()
            let epochBefore = invalidationEpoch
            stateLock.unlock()

            guard let statBefore = FileStatFingerprint(resolvedPath: path), statBefore.isRegularFile else {
                invalidate(path: path)
                _ = try OriginalFileIdentity(url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            if let maxBytes, !(1...maxBytes).contains(Int(statBefore.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }

            let identity = try OriginalFileIdentity(resolvedURL)
            let data = try (readData?(resolvedURL) ?? Data(contentsOf: resolvedURL))
            if let maxBytes, data.isEmpty || data.count > maxBytes {
                throw CocoaError(.fileReadCorruptFile)
            }

            stateLock.lock()
            _sha256Count += 1
            stateLock.unlock()
            onHash?()
            let digest = Data(SHA256.hash(data: data))

            let statAfter = FileStatFingerprint(resolvedPath: path)
            if statAfter == statBefore,
               Int64(data.count) == statBefore.size,
               identity.size == UInt64(statBefore.size) {
                stateLock.lock()
                if invalidationEpoch == epochBefore, FileStatFingerprint(resolvedPath: path) == statBefore {
                    cache.setValue(Entry(fingerprint: statBefore, identity: identity, digest: digest), forKey: path)
                }
                stateLock.unlock()
                return Result(identity: identity, digest: digest)
            }

            invalidate(path: path)
            if attempt == 2 {
                return Result(identity: identity, digest: digest)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func lookup(path: String) -> Entry? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let statNow = FileStatFingerprint(resolvedPath: path), statNow.isRegularFile else {
            cache.removeValue(forKey: path)
            return nil
        }
        guard let hit = cache.value(forKey: path), hit.fingerprint == statNow else {
            cache.removeValue(forKey: path)
            return nil
        }
        return hit
    }
}
