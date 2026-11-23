import CryptoKit
import Foundation
import os

public struct MacPhotoEditRecord: Equatable {
    public let identity: OriginalFileIdentity
    public let state: MacPhotoEditState?

    public init(identity: OriginalFileIdentity, state: MacPhotoEditState?) {
        self.identity = identity
        self.state = state
    }
}

private enum MacEditSchema: EditRegistrySchema {
    typealias IdentityKey = OriginalFileIdentity
    typealias State = MacPhotoEditState
    typealias Record = MacPhotoEditRecord

    static var requiresExistingDirectoryOnRead: Bool { false }
    static var createDirectoryOnLock: Bool { true }
    static var requiresVersionOnDecode: Bool { true }
    static var supportsDeletedTombstones: Bool { false }
    static var allowUTF8BOM: Bool { true }

    static func futureVersionError() -> Error { CocoaError(.fileReadCorruptFile) }
    static func rootCorruptError(underlying: Error) -> Error { CocoaError(.fileReadCorruptFile) }
    static func didQuarantine(at url: URL, error: Error) { MacEditPersistence.onQuarantine?(url, error) }
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
    private struct StoredMigration: Codable {
        let identity: OriginalFileIdentity
        var receipt: ProcessingMigrationReceipt<MacPhotoEditState>
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    public static let registryCacheCapacity = EditStoreRegistryCache<EditRegistryEnvelope>.maximumEntriesDefault

    public struct FilmReferenceScanResult: Equatable, Sendable {
        public let matchedPaths: Set<String>
        public let corruptPaths: Set<String>
        public let registryUnreadable: Bool
        public let diagnostics: [String]

        public init(matchedPaths: Set<String>, corruptPaths: Set<String>, registryUnreadable: Bool, diagnostics: [String]) {
            self.matchedPaths = matchedPaths
            self.corruptPaths = corruptPaths
            self.registryUnreadable = registryUnreadable
            self.diagnostics = diagnostics
        }

        public var pathsToInvalidate: Set<String> {
            matchedPaths.union(corruptPaths)
        }
    }

    private struct PreparedRecordsChange {
        let changes: [String: MacPhotoEditRecord]
        let editedRevisions: [String: String]
        let fileIdentities: [String: (UInt64, Date, UInt64)]
    }

    private let directory: URL
    private let core: EditRegistryStore<MacEditSchema>
    private let diagnostics: ErrorDiagnostics?
    private let onDiagnostic: ((String) -> Void)?
    internal static var onQuarantine: ((URL, Error) -> Void)?

    private static let logger = Logger(subsystem: "com.rawlab.mac", category: "MacEditPersistence")

    public var lastWriteFingerprint: FileStatFingerprint? { core.lastWriteFingerprint }
    public var lastQuarantinedURL: URL? { core.lastQuarantinedURL }
    public func consumeQuarantinedError() -> Error? { core.consumeQuarantinedError() }

    public static var registryDiskReadCount: Int {
        EditRegistryStore<MacEditSchema>.registryDiskReadCount
    }

    public static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        EditRegistryStore<MacEditSchema>.registryDiskReadCount(forDirectory: directory)
    }

    public init(directory: URL = MacEditPersistence.defaultDirectory,
                writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                diagnostics: ErrorDiagnostics? = nil,
                onDiagnostic: ((String) -> Void)? = nil) throws {
        self.directory = directory
        self.core = EditRegistryStore<MacEditSchema>(directory: directory, writeData: writeData)
        self.diagnostics = diagnostics
        self.onDiagnostic = onDiagnostic
        _ = try core.readEnvelope()
    }

    private static func makeLegacyV1Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[Adjustments.legacyV1EncodingKey] = true
        return encoder
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
        let registry = try core.readEnvelope()
        let identity = try OriginalFileIdentity(url)
        return try snapshot(identity: identity, registry: registry)
    }

    public func processingMigration(for url: URL) throws -> ProcessingMigrationReceipt<MacPhotoEditState>? {
        let registry = try core.readEnvelope()
        let identity = try OriginalFileIdentity(url)
        return Self.tryParseMigration(registry.processingMigrations?[identity.path], identity: identity)?.receipt
    }

    public var canonicalDirectoryPath: String {
        core.canonicalDirectoryPath
    }

    public func scanPathsReferencingFilms(_ identifiers: Set<String>) -> FilmReferenceScanResult {
        guard !identifiers.isEmpty else {
            return FilmReferenceScanResult(matchedPaths: [], corruptPaths: [], registryUnreadable: false, diagnostics: [])
        }
        let registry: EditRegistryEnvelope
        do {
            registry = try core.readEnvelope()
        } catch {
            let message = "Failed to read edit registry during film invalidation: \(error.localizedDescription)"
            Self.logger.error("\(message, privacy: .public)")
            diagnostics?.record(error as NSError, operation: .editPersistence, stage: "scanPathsReferencingFilms.readRegistry")
            onDiagnostic?(message)
            return FilmReferenceScanResult(matchedPaths: [], corruptPaths: [], registryUnreadable: true, diagnostics: [message])
        }
        var matched = Set<String>()
        var corrupt = Set<String>()
        var recordedDiagnostics: [String] = []
        for (path, raw) in registry.records {
            do {
                let record = try Self.parseRecord(raw)
                guard record.identity.path == path else {
                    let message = "Mismatched record path during film invalidation for \(path)"
                    Self.logger.error("\(message, privacy: .public)")
                    diagnostics?.record(CocoaError(.fileReadCorruptFile) as NSError, operation: .editPersistence, stage: "scanPathsReferencingFilms.pathMismatch")
                    onDiagnostic?(message)
                    recordedDiagnostics.append(message)
                    corrupt.insert(path)
                    continue
                }
                if identifiers.contains(record.state.filmID) {
                    matched.insert(path)
                }
            } catch {
                let message = "Corrupt or unreadable edit record during film invalidation for \(path): \(error.localizedDescription)"
                Self.logger.error("\(message, privacy: .public)")
                diagnostics?.record(error as NSError, operation: .editPersistence, stage: "scanPathsReferencingFilms.parseRecord")
                onDiagnostic?(message)
                recordedDiagnostics.append(message)
                corrupt.insert(path)
            }
        }
        return FilmReferenceScanResult(
            matchedPaths: matched,
            corruptPaths: corrupt,
            registryUnreadable: false,
            diagnostics: recordedDiagnostics
        )
    }

    public func pathsReferencingFilms(_ identifiers: Set<String>) -> Set<String> {
        scanPathsReferencingFilms(identifiers).pathsToInvalidate
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

    private static func prepareRecordsChanged(_ changes: [String: MacPhotoEditRecord]) -> PreparedRecordsChange? {
        guard !changes.isEmpty else { return nil }
        var editedRevisions: [String: String] = [:]
        var fileIdentities: [String: (UInt64, Date, UInt64)] = [:]
        for (path, record) in changes {
            fileIdentities[path] = (record.identity.size, record.identity.modified, record.identity.fileNumber)
            if let revision = Self.editedRevision(for: record.state, atPath: path) {
                editedRevisions[path] = revision
            }
        }
        return PreparedRecordsChange(changes: changes, editedRevisions: editedRevisions, fileIdentities: fileIdentities)
    }

    private func postPreparedRecordsChanged(_ prepared: PreparedRecordsChange?) {
        guard let prepared else { return }
        NotificationCenter.default.post(
            name: Self.didChangeRecordsNotification,
            object: nil,
            userInfo: [
                Self.directoryPathUserInfoKey: canonicalDirectoryPath,
                Self.changedRecordsUserInfoKey: prepared.changes,
                Self.invalidatedPathsUserInfoKey: Set(prepared.changes.keys),
                Self.editedRevisionsUserInfoKey: prepared.editedRevisions,
                Self.fileIdentitiesUserInfoKey: prepared.fileIdentities
            ]
        )
    }

    private func postRecordsChanged(_ changes: [String: MacPhotoEditRecord]) {
        postPreparedRecordsChanged(Self.prepareRecordsChanged(changes))
    }

    public var hasPendingCommits: Bool { core.hasPendingCommits }
    public var pendingCommitCount: Int { core.pendingCommitCount }
    public func waitForPendingIO() { core.waitForPendingIO() }

    @discardableResult
    public func deliverReadyCompletedCommits() -> Bool {
        core.deliverReadyCompletedCommits()
    }

    @discardableResult
    public func flushPendingCommits() -> Bool {
        core.flushPendingCommits()
    }

    public func enqueueSaveState(identity: OriginalFileIdentity,
                               state: MacPhotoEditState?,
                               clearsProcessingMigration: Bool = false,
                               postNotification: Bool = true,
                               chainIfUndeliveredFailure: Bool = false,
                               completion: ((Result<MacPhotoEditRecord, Error>) -> Void)? = nil) throws {
        if let state { try Self.validateState(state) }
        core.enqueueCommit(
            key: identity.path,
            postDelivery: postNotification,
            chainIfUndeliveredFailure: chainIfUndeliveredFailure,
            operation: { [weak self] in
                guard let self else { throw AdjustmentCommitError.expired }
                let pair = try self.performSaveStateCore(
                    identity: identity,
                    state: state,
                    clearsProcessingMigration: clearsProcessingMigration
                )
                let didDeliver: (() -> Void)? = pair.notification.map { notification in
                    { [weak self] in self?.postPreparedRecordsChanged(notification) }
                }
                return (pair.record, didDeliver)
            },
            completion: completion
        )
    }

    public func commitProcessingMigration(expected: MacPhotoEditRecord, candidate: MacPhotoEditState?,
                                          quality: ProcessingMigrationQuality) throws -> MacPhotoEditRecord {
        let result = try core.performSync {
            try core.withWriteLock {
                var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
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
                    updated.records[expected.identity.path] = try Self.makeLegacyV1Encoder().encode(Record(identity: expected.identity, state: candidate))
                }
                let receipt = ProcessingMigrationReceipt(status: candidate == nil ? .kept : .migrated,
                    original: original, quality: quality)
                var migrations = updated.processingMigrations ?? [:]
                migrations[expected.identity.path] = try Self.makeLegacyV1Encoder().encode(StoredMigration(identity: expected.identity, receipt: receipt))
                updated.processingMigrations = migrations
                try core.writeEnvelope(&updated)
                return try snapshot(identity: expected.identity, registry: updated)
            }
        }
        if let candidate, expected.state != candidate {
            postRecordsChanged([expected.identity.path: result])
        }
        return result
    }

    public func rollbackProcessingMigration(expected: MacPhotoEditRecord) throws -> MacPhotoEditRecord {
        let result = try core.performSync {
            try core.withWriteLock {
                var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
                try expected.identity.requireCurrent()
                guard try snapshot(identity: expected.identity, registry: updated) == expected,
                      var stored = Self.tryParseMigration(updated.processingMigrations?[expected.identity.path], identity: expected.identity),
                      stored.receipt.status == .migrated else {
                    throw AdjustmentCommitError.expired
                }
                try Self.validateState(stored.receipt.original)
                updated.records[expected.identity.path] = try Self.makeLegacyV1Encoder().encode(Record(identity: expected.identity, state: stored.receipt.original))
                stored.receipt.status = .rolledBack
                updated.processingMigrations?[expected.identity.path] = try Self.makeLegacyV1Encoder().encode(stored)
                try core.writeEnvelope(&updated)
                return try snapshot(identity: expected.identity, registry: updated)
            }
        }
        if expected.state != result.state {
            postRecordsChanged([expected.identity.path: result])
        }
        return result
    }

    private func snapshot(identity: OriginalFileIdentity, registry: EditRegistryEnvelope) throws -> MacPhotoEditRecord {
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
        let prepared = try core.performSync(clearingFailedKeys: { Array($0?.changes.keys ?? [:].keys) }) { () -> PreparedRecordsChange? in
            var changedPaths: [String: MacPhotoEditRecord] = [:]
            try core.withWriteLock {
                try Self.validateState(state)
                var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
                for url in urls {
                    let identity = try OriginalFileIdentity(url)
                    if try snapshot(identity: identity, registry: updated).state == state { continue }
                    updated.records[identity.path] = try Self.makeLegacyV1Encoder().encode(Record(identity: identity, state: state))
                    changedPaths[identity.path] = MacPhotoEditRecord(identity: identity, state: state)
                }
                if !changedPaths.isEmpty { try core.writeEnvelope(&updated) }
            }
            return Self.prepareRecordsChanged(changedPaths)
        }
        postPreparedRecordsChanged(prepared)
    }

    private func performSaveStateCore(identity: OriginalFileIdentity, state: MacPhotoEditState?,
                                      clearsProcessingMigration: Bool) throws -> (record: MacPhotoEditRecord, notification: PreparedRecordsChange?) {
        var stateChanged = false
        let result = try core.withWriteLock {
            if let state { try Self.validateState(state) }
            var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
            try identity.requireCurrent()
            let current = try snapshot(identity: identity, registry: updated)
            stateChanged = current.state != state
            let clearsMigration = clearsProcessingMigration && updated.processingMigrations?[identity.path] != nil
            guard stateChanged || clearsMigration else { return current }
            if let state { updated.records[identity.path] = try Self.makeLegacyV1Encoder().encode(Record(identity: identity, state: state)) }
            else { updated.records.removeValue(forKey: identity.path) }
            if clearsMigration {
                updated.processingMigrations?.removeValue(forKey: identity.path)
                if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            }
            try core.writeEnvelope(&updated)
            return MacPhotoEditRecord(identity: identity, state: state)
        }
        let notification = stateChanged ? Self.prepareRecordsChanged([identity.path: result]) : nil
        return (result, notification)
    }

    @discardableResult public func saveState(identity: OriginalFileIdentity, state: MacPhotoEditState?,
                                             clearsProcessingMigration: Bool = false) throws -> MacPhotoEditRecord {
        let pair = try core.performSync(clearingFailedKeys: { _ in [identity.path] }) {
            try performSaveStateCore(identity: identity, state: state, clearsProcessingMigration: clearsProcessingMigration)
        }
        postPreparedRecordsChanged(pair.notification)
        return pair.record
    }

    @discardableResult public func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord {
        let (result, prepared) = try core.performSync(clearingFailedKeys: { [$0.0.identity.path] }) {
            var clearedPath: String?
            let record = try core.withWriteLock {
                var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
                let identity = try OriginalFileIdentity(url)
                let hadRecord = updated.records.removeValue(forKey: identity.path) != nil
                let hadMigration = updated.processingMigrations?.removeValue(forKey: identity.path) != nil
                if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
                if hadRecord || hadMigration {
                    try core.writeEnvelope(&updated)
                }
                if hadRecord { clearedPath = identity.path }
                return MacPhotoEditRecord(identity: identity, state: nil)
            }
            let prepared = clearedPath.flatMap { Self.prepareRecordsChanged([$0: record]) }
            return (record, prepared)
        }
        postPreparedRecordsChanged(prepared)
        return result
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

    private let backingCache: FileDigestCache
    public var rawDigestCache: FileDigestCache { backingCache }
    public var maximumEntries: Int { backingCache.maximumEntries }

    public init(maximumEntries: Int = MacResourceDigestCache.defaultMaximumEntries) {
        self.backingCache = FileDigestCache(maximumEntries: max(1, maximumEntries))
    }

    public var entryCount: Int { backingCache.entryCount }
    public var sha256Count: Int { backingCache.digestComputeCount }

    public func invalidate(url: URL) {
        backingCache.invalidate(for: url)
    }

    public func fingerprintDigest(
        for url: URL,
        maxBytes: Int? = nil,
        onHash: (() -> Void)? = nil,
        readData: ((URL) throws -> Data)? = nil
    ) throws -> Result {
        let result = try backingCache.digestAndFingerprint(
            for: url,
            maximumBytes: maxBytes,
            returnOnUnstableThirdAttempt: true,
            onHash: onHash,
            readData: readData
        )
        return Result(identity: result.identity, digest: result.digest)
    }
}
