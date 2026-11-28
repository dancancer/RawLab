import CryptoKit
import Foundation
import os

public enum EditPersistenceError: LocalizedError, Sendable {
    case invalidIdentity, corruptStore, legacyAssetEditNeedsDecision
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: return L10n.text("无法识别原始照片，调整尚未保存。")
        case .corruptStore: return L10n.text("无法读取已保存的调整，原有记录未被覆盖。")
        case .legacyAssetEditNeedsDecision: return L10n.text("请先打开这张照片，确认是否恢复旧调整。")
        }
    }
}

public extension UnusableEditRecordError {
    init(underlying: Error? = nil) {
        self.init(L10n.text("无法读取已保存的调整，原有记录未被覆盖。"), underlying: underlying)
    }
}

public struct OpenX3fRepairResult<Record> {
    public let record: Record
    public let repaired: Bool
    public let writeError: Error?
    public init(record: Record, repaired: Bool, writeError: Error? = nil) {
        self.record = record
        self.repaired = repaired
        self.writeError = writeError
    }
}

public extension PhotoEditState {
    func repairingLegacyNormalX3f(isX3f: Bool) -> (state: PhotoEditState, changed: Bool) {
        var updated = self
        let changed = updated.settings.repairLegacyNormalX3f(isX3f: isX3f)
        return (updated, changed)
    }
}

public struct PhotoEditRecord: Equatable {
    public let identity: PhotoIdentity
    public let state: PhotoEditState?
    public init(identity: PhotoIdentity, state: PhotoEditState?) { self.identity = identity; self.state = state }
    public func hasSameAdjustments(as other: PhotoEditRecord?) -> Bool {
        guard let other, identity == other.identity else { return false }
        switch (state, other.state) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameAdjustments(as: rhs)
        default: return false
        }
    }
    public func repairingLegacyNormalX3f(isX3f: Bool) -> (record: PhotoEditRecord, changed: Bool) {
        guard let state else { return (self, false) }
        let repaired = state.repairingLegacyNormalX3f(isX3f: isX3f)
        guard repaired.changed else { return (self, false) }
        return (PhotoEditRecord(identity: identity, state: repaired.state), true)
    }
}

public struct MacPhotoEditRecord: Equatable {
    public let identity: OriginalFileIdentity
    public let state: PhotoEditState?
    public init(identity: OriginalFileIdentity, state: PhotoEditState?) { self.identity = identity; self.state = state }
    public func repairingLegacyNormalX3f() -> (record: MacPhotoEditRecord, changed: Bool) {
        guard let state else { return (self, false) }
        let isX3f = URL(fileURLWithPath: identity.path).pathExtension.lowercased() == "x3f"
        let repaired = state.repairingLegacyNormalX3f(isX3f: isX3f)
        guard repaired.changed else { return (self, false) }
        return (MacPhotoEditRecord(identity: identity, state: repaired.state), true)
    }
}

internal enum EditRecordCodec {
    struct StoredMigration<Identity: Codable>: Codable {
        let identity: Identity
        var receipt: ProcessingMigrationReceipt<PhotoEditState>
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    static func decoder(flavor: Adjustments.LegacyWireFlavor) -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.userInfo[Adjustments.legacyFormatHintKey] = flavor; return decoder
    }

    static func encoder(legacyV1: Bool) -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if legacyV1 { encoder.userInfo[Adjustments.legacyV1EncodingKey] = true }
        return encoder
    }

    static func validateState(_ state: PhotoEditState, isMac: Bool, rawData: Data? = nil) throws {
        guard state.updatedAt.timeIntervalSince1970.isFinite else {
            throw isMac ? EditorResetBlockedReason.invalidSnapshot("updatedAt") : EditPersistenceError.corruptStore
        }
        do {
            try state.settings.validateResetValues()
            if state.settings.isHDREditing {
                var sdr = state.settings; sdr.hdr?.mode = .sdr; try sdr.validateResetValues()
            } else if state.settings.hdr?.isValid == false {
                throw EditorResetBlockedReason.invalidSnapshot("hdr")
            }
        } catch {
            throw isMac ? error : EditPersistenceError.corruptStore
        }
        if isMac {
            guard state.masterRecipeID == state.settings.masterRecipeID else {
                throw EditorResetBlockedReason.invalidSnapshot("metadata")
            }
        } else if let rawData,
                  let root = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
                  let settingsDict = root["settings"] as? [String: Any] {
            if let mode = settingsDict["exposureMode"] as? Int, !(0...2).contains(mode) { throw EditPersistenceError.corruptStore }
            if let chroma = settingsDict["displayChromaDenoise"] as? Int, !(0...2).contains(chroma) { throw EditPersistenceError.corruptStore }
            if let effects = settingsDict["photoEffects"] as? [String: Any] {
                for p in PhotoEffectParameter.allCases where (effects[p.rawValue] as? Double).map({ !$0.isFinite || !p.range.contains($0) }) == true {
                    throw EditPersistenceError.corruptStore
                }
            }
        }
    }

    static func parseMigration<Identity: Codable>(
        _ data: Data?, flavor: Adjustments.LegacyWireFlavor, isMac: Bool, matches: (Identity) -> Bool = { _ in true }
    ) -> StoredMigration<Identity>? {
        guard let data, let stored = try? decoder(flavor: flavor).decode(StoredMigration<Identity>.self, from: data),
              matches(stored.identity), (try? validateState(stored.receipt.original, isMac: isMac)) != nil else { return nil }
        return stored
    }

    static func commitMigration<Schema: EditRegistrySchema, Identity: Codable>(
        core: EditRegistryStore<Schema>, key: String, identity: Identity, original: PhotoEditState, candidate: PhotoEditState?,
        quality: ProcessingMigrationQuality, maxSourceVersion: Int, isMac: Bool,
        existingMigration: (EditRegistryEnvelope) -> StoredMigration<Identity>?,
        encodeRecord: (PhotoEditState) throws -> Data, encodeMigration: (StoredMigration<Identity>) throws -> Data
    ) throws {
        guard original.settings.processing.version <= maxSourceVersion, quality.isValid else { throw AdjustmentCommitError.expired }
        var envelope = try core.readEnvelope(allowCache: !isMac, holdingWriteLock: true)
        if let previous = existingMigration(envelope), !previous.receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) {
            throw AdjustmentCommitError.expired
        }
        if let candidate {
            if isMac { try validateState(candidate, isMac: true) }
            guard candidate.settings.processing == .current, quality.passes else { throw AdjustmentCommitError.expired }
            envelope.records[key] = try encodeRecord(candidate)
            if !isMac { envelope.deleted?.remove(key) }
        }
        var receipts = envelope.processingMigrations ?? [:]
        receipts[key] = try encodeMigration(StoredMigration(identity: identity, receipt: .init(status: candidate == nil ? .kept : .migrated, original: original, quality: quality)))
        envelope.processingMigrations = receipts
        try core.writeEnvelope(&envelope)
    }

    static func rollbackMigration<Schema: EditRegistrySchema, Identity: Codable>(
        core: EditRegistryStore<Schema>, key: String, isMac: Bool, isX3f: Bool, envelope: inout EditRegistryEnvelope, stored: StoredMigration<Identity>,
        encodeRecord: (PhotoEditState) throws -> Data, encodeMigration: (StoredMigration<Identity>) throws -> Data
    ) throws {
        var receipt = stored.receipt
        guard receipt.status == .migrated else { throw AdjustmentCommitError.expired }
        let restored = receipt.original.repairingLegacyNormalX3f(isX3f: isX3f).state
        if isMac { try validateState(restored, isMac: true) }
        envelope.records[key] = try encodeRecord(restored)
        if !isMac { envelope.deleted?.remove(key) }
        receipt.status = .rolledBack
        var receipts = envelope.processingMigrations ?? [:]
        receipts[key] = try encodeMigration(StoredMigration(identity: stored.identity, receipt: receipt))
        envelope.processingMigrations = receipts
        try core.writeEnvelope(&envelope)
    }
}

private enum IOSEditSchema: EditRegistrySchema {
    typealias IdentityKey = PhotoIdentity; typealias State = PhotoEditState; typealias Record = PhotoEditRecord
    static var requiresExistingDirectoryOnRead: Bool { true }; static var createDirectoryOnLock: Bool { false }
    static var requiresVersionOnDecode: Bool { false }; static var supportsDeletedTombstones: Bool { true }; static var allowUTF8BOM: Bool { true }
    static func futureVersionError() -> Error { EditPersistenceError.corruptStore }
    static func rootCorruptError(underlying: Error) -> Error { EditPersistenceError.corruptStore }
    static func didQuarantine(at url: URL, error: Error) { EditPersistence.onQuarantine?(url, error) }
}

private enum MacEditSchema: EditRegistrySchema {
    typealias IdentityKey = OriginalFileIdentity; typealias State = PhotoEditState; typealias Record = MacPhotoEditRecord
    static var requiresExistingDirectoryOnRead: Bool { false }; static var createDirectoryOnLock: Bool { true }
    static var requiresVersionOnDecode: Bool { true }; static var supportsDeletedTombstones: Bool { false }; static var allowUTF8BOM: Bool { true }
    static func futureVersionError() -> Error { CocoaError(.fileReadCorruptFile) }
    static func rootCorruptError(underlying: Error) -> Error { CocoaError(.fileReadCorruptFile) }
    static func didQuarantine(at url: URL, error: Error) { MacEditPersistence.onQuarantine?(url, error) }
}

public final class EditPersistence: @unchecked Sendable {
    public static var willSaveRecord: ((PhotoIdentity, PhotoEditState?) throws -> Void)?
    public static var onSaveRecord: ((PhotoIdentity, PhotoEditState?) -> Void)?
    private typealias StoredMigration = EditRecordCodec.StoredMigration<PhotoIdentity>

    public static var registryDiskReadCount: Int { EditRegistryStore<IOSEditSchema>.registryDiskReadCount }
    public static func registryDiskReadCount(forDirectory directory: URL) -> Int {
        EditRegistryStore<IOSEditSchema>.registryDiskReadCount(forDirectory: directory)
    }

    public let directory: URL
    private let core: EditRegistryStore<IOSEditSchema>
    internal static var onQuarantine: ((URL, Error) -> Void)?

    public static var defaultDirectory: URL { EditRecordCodec.defaultDirectory }
    public var lastQuarantinedURL: URL? { core.lastQuarantinedURL }
    public func consumeQuarantinedError() -> Error? { core.consumeQuarantinedError() }
    @discardableResult public static func removeStaleAtomicTempFiles(in directory: URL = defaultDirectory) -> Int {
        EditRegistryStore<IOSEditSchema>.removeStaleAtomicTempFiles(in: directory)
    }

    public init(directory: URL, writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.core = EditRegistryStore<IOSEditSchema>(directory: directory, writeData: writeData)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try core.readEnvelope()
    }

    public static func appStore() throws -> EditPersistence {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try EditPersistence(directory: root.appendingPathComponent("RawLab/Edits", isDirectory: true))
    }

    public func state(for identity: PhotoIdentity) throws -> PhotoEditState? {
        do { return try readState(for: identity, isX3f: false).state }
        catch let error as UnusableEditRecordError { throw error }
        catch { return try record(identity, from: core.lastReadableEnvelope).state }
    }

    public func state(for url: URL) throws -> PhotoEditState? {
        guard let identity = try? PhotoIdentity.fallback(for: url) else { return nil }
        return try state(for: identity)
    }

    public func save(_ identity: PhotoIdentity, state: PhotoEditState) throws {
        try validate(identity)
        try core.withWriteLock { var s = try core.readEnvelope(holdingWriteLock: true); _ = try write(state, identity: identity, store: &s) }
    }

    public func save(_ url: URL, state: PhotoEditState) throws { try save(try PhotoIdentity.fallback(for: url), state: state) }

    public func reset(_ identity: PhotoIdentity) throws {
        try validate(identity)
        try core.withWriteLock { var s = try core.readEnvelope(holdingWriteLock: true); _ = try write(nil, identity: identity, clearsProcessingMigration: true, store: &s) }
    }

    public func reset(_ url: URL) throws { try reset(try PhotoIdentity.fallback(for: url)) }

    @discardableResult
    public func resetToUnmodified(_ identity: PhotoIdentity) throws -> PhotoEditRecord {
        try validate(identity)
        return try core.withWriteLock {
            var store = try core.readEnvelope(holdingWriteLock: true)
            let resolvedKey = recordKey(identity, from: store)
            let hadFallback = store.records[resolvedKey] != nil
            let hadOwn = store.records.removeValue(forKey: identity.editKey) != nil
            let hadUnverified = identity.editKey != identity.key && store.deleted?.contains(identity.editKey) != true && store.records[identity.key] != nil
            let cleared = clearProcessingMigration(for: identity, in: &store)
            if hadOwn || hadFallback || hadUnverified || cleared {
                store.deleted = (store.deleted ?? []).union([identity.editKey])
                try core.writeEnvelope(&store)
            }
            return PhotoEditRecord(identity: identity, state: nil)
        }
    }

    public func readState(for identity: PhotoIdentity, requiringLegacyDecision: Bool = false, isX3f: Bool) throws -> PhotoEditRecord {
        try validate(identity)
        let store = try core.readEnvelope()
        if requiringLegacyDecision, try unverifiedAssetEdit(for: identity, from: store) != nil {
            throw EditPersistenceError.legacyAssetEditNeedsDecision
        }
        return try record(identity, from: store).repairingLegacyNormalX3f(isX3f: isX3f).record
    }

    @discardableResult
    public func repairLegacyNormalX3fOnOpen(for identity: PhotoIdentity, isX3f: Bool) throws -> OpenX3fRepairResult<PhotoEditRecord> {
        try validate(identity)
        let initial = try record(identity, from: core.readEnvelope())
        let checked = initial.repairingLegacyNormalX3f(isX3f: isX3f)
        guard checked.changed else { return OpenX3fRepairResult(record: initial, repaired: false) }
        do {
            let outcome = try core.withWriteLock { () -> (record: PhotoEditRecord, repaired: Bool) in
                var store = try core.readEnvelope(holdingWriteLock: true)
                let rawCurrent = try record(identity, from: store)
                let repaired = rawCurrent.repairingLegacyNormalX3f(isX3f: true)
                guard repaired.changed, let repairedState = repaired.record.state else { return (repaired.record, false) }
                return (try write(repairedState, identity: identity, store: &store), true)
            }
            return OpenX3fRepairResult(record: outcome.record, repaired: outcome.repaired)
        } catch let error as UnusableEditRecordError {
            throw error
        } catch {
            return OpenX3fRepairResult(record: checked.record, repaired: true, writeError: error)
        }
    }

    public func readStates(for identities: [PhotoIdentity], requiringLegacyDecision: Bool = false) throws -> [PhotoIdentity: Result<PhotoEditRecord, Error>] {
        let store = try core.readEnvelope()
        var results = [PhotoIdentity: Result<PhotoEditRecord, Error>](minimumCapacity: identities.count)
        for identity in identities where results[identity] == nil {
            do {
                try validate(identity)
                if requiringLegacyDecision, try unverifiedAssetEdit(for: identity, from: store) != nil {
                    results[identity] = .failure(EditPersistenceError.legacyAssetEditNeedsDecision)
                } else {
                    results[identity] = .success(try record(identity, from: store))
                }
            } catch { results[identity] = .failure(error) }
        }
        return results
    }

    public func unverifiedAssetEdit(for identity: PhotoIdentity) throws -> PhotoEditState? {
        try unverifiedAssetEdit(for: identity, from: core.readEnvelope())
    }

    public func resolveUnverifiedAssetEdit(for identity: PhotoIdentity, expected: PhotoEditState, restore: Bool) throws {
        try core.withWriteLock {
            var store = try core.readEnvelope(holdingWriteLock: true)
            guard try unverifiedAssetEdit(for: identity, from: store) == expected else { throw AdjustmentCommitError.expired }
            if restore { _ = try write(expected, identity: identity, store: &store) }
            else { store.deleted = (store.deleted ?? []).union([identity.editKey]); try core.writeEnvelope(&store) }
        }
    }

    private func unverifiedAssetEdit(for identity: PhotoIdentity, from store: EditRegistryEnvelope) throws -> PhotoEditState? {
        guard identity.editKey != identity.key else { return nil }
        let existing = recordKey(identity, from: store)
        guard store.records[existing] == nil, store.deleted?.contains(existing) != true else { return nil }
        return try store.records[identity.key].map(Self.parseState)
    }

    public func processingMigration(for identity: PhotoIdentity) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        try validate(identity); return storedMigration(identity, from: try core.readEnvelope())?.receipt
    }

    public func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?, quality: ProcessingMigrationQuality) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try core.withWriteLock {
            let store = try core.readEnvelope(holdingWriteLock: true)
            guard try record(expected.identity, from: store) == expected, let original = expected.state else { throw AdjustmentCommitError.expired }
            try EditRecordCodec.commitMigration(
                core: core, key: expected.identity.editKey, identity: expected.identity, original: original, candidate: candidate,
                quality: quality, maxSourceVersion: 2, isMac: false,
                existingMigration: { storedMigration(expected.identity, from: $0) },
                encodeRecord: Self.encodeState, encodeMigration: { try EditRecordCodec.encoder(legacyV1: false).encode($0) }
            )
            return try record(expected.identity, from: core.readEnvelope(holdingWriteLock: true))
        }
    }

    public func rollbackProcessingMigration(expected: PhotoEditRecord, isX3f: Bool) throws -> PhotoEditRecord {
        try validate(expected.identity)
        return try core.withWriteLock {
            var store = try core.readEnvelope(holdingWriteLock: true)
            guard try record(expected.identity, from: store).repairingLegacyNormalX3f(isX3f: isX3f).record == expected,
                  let stored = storedMigration(expected.identity, from: store) else { throw AdjustmentCommitError.expired }
            try EditRecordCodec.rollbackMigration(
                core: core, key: expected.identity.editKey, isMac: false, isX3f: isX3f, envelope: &store,
                stored: StoredMigration(identity: expected.identity, receipt: stored.receipt),
                encodeRecord: Self.encodeState, encodeMigration: { try EditRecordCodec.encoder(legacyV1: false).encode($0) }
            )
            return try record(expected.identity, from: store)
        }
    }

    public func resolvingLegacyContent(for identity: PhotoIdentity, load: () async -> String?) async -> PhotoIdentity {
        guard identity.resourceIdentifier != nil, identity.legacyContentIdentifier == nil,
              let store = try? core.readEnvelope() else { return identity }
        let key = recordKey(identity, from: store)
        guard store.records[key] == nil, store.deleted?.contains(key) != true,
              store.records.keys.contains(where: { $0.hasPrefix("content:") }),
              let legacy = await load() else { return identity }
        return PhotoIdentity(resourceIdentifier: identity.resourceIdentifier, contentIdentifier: identity.contentIdentifier, legacyContentIdentifier: legacy)
    }

    @discardableResult
    public func saveState(identity: PhotoIdentity, state: PhotoEditState?, clearsProcessingMigration: Bool = false) throws -> PhotoEditRecord {
        try validate(identity)
        return try core.withWriteLock {
            var store = try core.readEnvelope(holdingWriteLock: true)
            return try write(state, identity: identity, clearsProcessingMigration: clearsProcessingMigration, store: &store)
        }
    }

    public func saveTransferredState(_ state: PhotoEditState, expected: PhotoEditRecord, isX3f: Bool) throws -> PhotoEditRecord {
        let identity = expected.identity; try validate(identity)
        return try core.withWriteLock {
            var store = try core.readEnvelope(holdingWriteLock: true)
            guard try unverifiedAssetEdit(for: identity, from: store) == nil else { throw EditPersistenceError.legacyAssetEditNeedsDecision }
            guard try record(identity, from: store).repairingLegacyNormalX3f(isX3f: isX3f).record.hasSameAdjustments(as: expected) else {
                throw AdjustmentCommitError.expired
            }
            return try write(state, identity: identity, store: &store)
        }
    }

    private func validate(_ identity: PhotoIdentity) throws {
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else { throw EditPersistenceError.invalidIdentity }
    }

    private func record(_ identity: PhotoIdentity, from store: EditRegistryEnvelope) throws -> PhotoEditRecord {
        .init(identity: identity, state: try store.records[recordKey(identity, from: store)].map(Self.parseState))
    }

    private func recordKey(_ identity: PhotoIdentity, from store: EditRegistryEnvelope) -> String {
        var key = identity.editKey
        if identity.resourceIdentifier != nil {
            if store.records[key] == nil, store.deleted?.contains(key) != true, store.deleted?.contains(identity.key) == true { return identity.key }
            for content in [identity.contentIdentifier, identity.legacyContentIdentifier].compactMap({ $0 }) {
                guard store.records[key] == nil, store.deleted?.contains(key) != true else { break }
                key = PhotoIdentity(contentIdentifier: content).key
            }
        }
        return key
    }

    private func storedMigration(_ identity: PhotoIdentity, from store: EditRegistryEnvelope) -> StoredMigration? {
        let receipts = store.processingMigrations ?? [:]
        if let primary = Self.tryParseMigration(receipts[identity.editKey]) ?? Self.tryParseMigration(receipts[identity.key]),
           matchesMigrationIdentity(primary.identity, identity) { return primary }
        let key = recordKey(identity, from: store)
        guard let stored = Self.tryParseMigration(receipts[key]), stored.identity.resourceIdentifier == nil, stored.identity.key == key else { return nil }
        return stored
    }

    private static func parseState(_ data: Data) throws -> PhotoEditState {
        do {
            let state = try EditRecordCodec.decoder(flavor: .ios).decode(PhotoEditState.self, from: data)
            try EditRecordCodec.validateState(state, isMac: false, rawData: data); return state
        } catch let error as UnusableEditRecordError { throw error }
        catch { throw UnusableEditRecordError(underlying: error) }
    }

    private static func tryParseMigration(_ data: Data?) -> StoredMigration? {
        EditRecordCodec.parseMigration(data, flavor: .ios, isMac: false)
    }

    private static func encodeState(_ state: PhotoEditState) throws -> Data {
        let encoded = try EditRecordCodec.encoder(legacyV1: false).encode(state)
        try EditRecordCodec.validateState(state, isMac: false); return encoded
    }

    private func matchesMigrationIdentity(_ stored: PhotoIdentity, _ identity: PhotoIdentity) -> Bool {
        stored.resourceIdentifier == identity.resourceIdentifier && stored.contentIdentifier == identity.contentIdentifier
    }

    private func hasClearableProcessingMigration(_ identity: PhotoIdentity, in store: EditRegistryEnvelope) -> Bool {
        let receipts = store.processingMigrations ?? [:]
        if receipts[identity.editKey] != nil { return true }
        return identity.editKey != identity.key &&
            Self.tryParseMigration(receipts[identity.key]).map { matchesMigrationIdentity($0.identity, identity) } == true
    }

    @discardableResult
    private func clearProcessingMigration(for identity: PhotoIdentity, in store: inout EditRegistryEnvelope) -> Bool {
        guard var receipts = store.processingMigrations else { return false }
        var removed = receipts.removeValue(forKey: identity.editKey) != nil
        if identity.editKey != identity.key, let stored = Self.tryParseMigration(receipts[identity.key]),
           matchesMigrationIdentity(stored.identity, identity) {
            removed = receipts.removeValue(forKey: identity.key) != nil || removed
        }
        store.processingMigrations = receipts.isEmpty ? nil : receipts; return removed
    }

    private func write(_ state: PhotoEditState?, identity: PhotoIdentity, clearsProcessingMigration: Bool = false,
                       store: inout EditRegistryEnvelope) throws -> PhotoEditRecord {
        let current = try record(identity, from: store)
        let clearsMigration = clearsProcessingMigration && hasClearableProcessingMigration(identity, in: store)
        if !clearsMigration {
            if let previous = current.state, let state, previous.hasSameAdjustments(as: state) { return current }
            if current.state == nil && state == nil { return current }
        }
        try Self.willSaveRecord?(identity, state)
        let encodedState = try state.map(Self.encodeState)
        store.version = 1
        if clearsProcessingMigration { clearProcessingMigration(for: identity, in: &store) }
        else if state != nil, store.processingMigrations?[identity.editKey] == nil, let previous = storedMigration(identity, from: store) {
            var receipts = store.processingMigrations ?? [:]
            receipts[identity.editKey] = try EditRecordCodec.encoder(legacyV1: false).encode(StoredMigration(identity: identity, receipt: previous.receipt))
            store.processingMigrations = receipts
        }
        if let encodedState {
            store.records[identity.editKey] = encodedState; Self.onSaveRecord?(identity, state); store.deleted?.remove(identity.editKey)
        } else {
            store.records.removeValue(forKey: identity.editKey); store.deleted = (store.deleted ?? []).union([identity.editKey])
        }
        try core.writeEnvelope(&store)
        return try record(identity, from: store)
    }
}

public final class MacEditPersistence: @unchecked Sendable {
    public static let didChangeRecordsNotification = Notification.Name("RawLab.EditPersistence.didChangeRecords")
    public static let didInvalidateEditedNotification = Notification.Name("RawLab.EditPersistence.didInvalidateEdited")
    public static let directoryPathUserInfoKey = "directoryPath", changedRecordsUserInfoKey = "changedRecords"
    public static let invalidatedPathsUserInfoKey = "invalidatedPaths", editedRevisionsUserInfoKey = "editedRevisions", fileIdentitiesUserInfoKey = "fileIdentities"
    private struct Record: Codable { let identity: OriginalFileIdentity; let state: PhotoEditState }
    private typealias StoredMigration = EditRecordCodec.StoredMigration<OriginalFileIdentity>
    public static var defaultDirectory: URL { EditRecordCodec.defaultDirectory }
    public static let registryCacheCapacity = EditStoreRegistryCache<EditRegistryEnvelope>.maximumEntriesDefault
    public struct FilmReferenceScanResult: Equatable, Sendable {
        public let matchedPaths: Set<String>, corruptPaths: Set<String>; public let registryUnreadable: Bool; public let diagnostics: [String]
        public init(matchedPaths: Set<String>, corruptPaths: Set<String>, registryUnreadable: Bool, diagnostics: [String]) {
            self.matchedPaths = matchedPaths; self.corruptPaths = corruptPaths; self.registryUnreadable = registryUnreadable; self.diagnostics = diagnostics
        }
        public var pathsToInvalidate: Set<String> { matchedPaths.union(corruptPaths) }
    }
    private struct PreparedRecordsChange { let changes: [String: MacPhotoEditRecord]; let editedRevisions: [String: String]; let fileIdentities: [String: (UInt64, Date, UInt64)] }
    private let directory: URL; private let core: EditRegistryStore<MacEditSchema>; private let diagnostics: ErrorDiagnostics?; private let onDiagnostic: ((String) -> Void)?
    internal static var onQuarantine: ((URL, Error) -> Void)?
    private static let logger = Logger(subsystem: "com.rawlab.mac", category: "MacEditPersistence")
    public var lastWriteFingerprint: FileStatFingerprint? { core.lastWriteFingerprint }
    public var lastQuarantinedURL: URL? { core.lastQuarantinedURL }
    public func consumeQuarantinedError() -> Error? { core.consumeQuarantinedError() }
    public static var registryDiskReadCount: Int { EditRegistryStore<MacEditSchema>.registryDiskReadCount }
    public static func registryDiskReadCount(forDirectory directory: URL) -> Int { EditRegistryStore<MacEditSchema>.registryDiskReadCount(forDirectory: directory) }

    public init(directory: URL = MacEditPersistence.defaultDirectory,
                writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                diagnostics: ErrorDiagnostics? = nil, onDiagnostic: ((String) -> Void)? = nil) throws {
        self.directory = directory
        self.core = EditRegistryStore<MacEditSchema>(directory: directory, writeData: writeData)
        self.diagnostics = diagnostics; self.onDiagnostic = onDiagnostic
        _ = try core.readEnvelope()
    }

    private static func makeLegacyV1Encoder() -> JSONEncoder { EditRecordCodec.encoder(legacyV1: true) }

    private static func encodeRecord(_ identity: OriginalFileIdentity, state: PhotoEditState) throws -> Data {
        try makeLegacyV1Encoder().encode(Record(identity: identity, state: state))
    }

    private static func parseRecord(_ data: Data) throws -> Record {
        do {
            let record = try EditRecordCodec.decoder(flavor: .mac).decode(Record.self, from: data)
            try EditRecordCodec.validateState(record.state, isMac: true); return record
        } catch let error as UnusableEditRecordError { throw error }
        catch {
            let message = String(describing: error).localizedCaseInsensitiveContains("processing identity")
                ? L10n.text("不支持此处理版本，原有记录未被覆盖。") : L10n.format("无法读取调整记录：%@", error.localizedDescription)
            throw UnusableEditRecordError(message, underlying: error)
        }
    }

    private static func tryParseMigration(_ data: Data?, identity: OriginalFileIdentity) -> StoredMigration? {
        EditRecordCodec.parseMigration(data, flavor: .mac, isMac: true) { $0 == identity }
    }

    public func state(for url: URL) throws -> PhotoEditState? { try readState(for: url).state }
    public func readState(for url: URL) throws -> MacPhotoEditRecord { try snapshot(identity: try OriginalFileIdentity(url), registry: try core.readEnvelope()) }
    @discardableResult
    public func repairLegacyNormalX3fOnOpen(for url: URL) throws -> OpenX3fRepairResult<MacPhotoEditRecord> {
        let identity = try OriginalFileIdentity(url)
        let initial = try rawSnapshot(identity: identity, registry: try core.readEnvelope())
        let checked = initial.repairingLegacyNormalX3f()
        guard checked.changed else { return OpenX3fRepairResult(record: initial, repaired: false) }
        do {
            let pair = try core.performSync(clearingFailedKeys: { _ in [identity.path] }) {
                try core.withWriteLock { () -> (record: MacPhotoEditRecord, repaired: Bool, notification: PreparedRecordsChange?) in
                    var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
                    let currentIdentity = try OriginalFileIdentity(url)
                    let rawCurrent = try rawSnapshot(identity: currentIdentity, registry: updated)
                    let repaired = rawCurrent.repairingLegacyNormalX3f()
                    guard repaired.changed, let repairedState = repaired.record.state else {
                        return (repaired.record, false, nil)
                    }
                    try EditRecordCodec.validateState(repairedState, isMac: true)
                    updated.records[currentIdentity.path] = try Self.encodeRecord(currentIdentity, state: repairedState)
                    try core.writeEnvelope(&updated)
                    return (repaired.record, true, Self.prepareRecordsChanged([currentIdentity.path: repaired.record]))
                }
            }
            postPreparedRecordsChanged(pair.notification)
            return OpenX3fRepairResult(record: pair.record, repaired: pair.repaired)
        } catch let error as UnusableEditRecordError {
            throw error
        } catch {
            return OpenX3fRepairResult(record: checked.record, repaired: true, writeError: error)
        }
    }
    public func processingMigration(for url: URL) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        let identity = try OriginalFileIdentity(url)
        return Self.tryParseMigration((try core.readEnvelope()).processingMigrations?[identity.path], identity: identity)?.receipt
    }
    public var canonicalDirectoryPath: String { core.canonicalDirectoryPath }

    public func scanPathsReferencingFilms(_ identifiers: Set<String>) -> FilmReferenceScanResult {
        guard !identifiers.isEmpty else { return .init(matchedPaths: [], corruptPaths: [], registryUnreadable: false, diagnostics: []) }
        func fail(_ error: Error, _ message: String, _ stage: String) -> String {
            Self.logger.error("\(message, privacy: .public)"); diagnostics?.record(error as NSError, operation: .editPersistence, stage: stage)
            onDiagnostic?(message); return message
        }
        let registry: EditRegistryEnvelope
        do { registry = try core.readEnvelope() } catch {
            return .init(matchedPaths: [], corruptPaths: [], registryUnreadable: true,
                         diagnostics: [fail(error, "Failed to read edit registry during film invalidation: \(error.localizedDescription)", "scanPathsReferencingFilms.readRegistry")])
        }
        var matched = Set<String>(), corrupt = Set<String>(), recorded = [String]()
        for (path, raw) in registry.records {
            do {
                let record = try Self.parseRecord(raw)
                guard record.identity.path == path else {
                    recorded.append(fail(CocoaError(.fileReadCorruptFile), "Mismatched record path during film invalidation for \(path)", "scanPathsReferencingFilms.pathMismatch"))
                    corrupt.insert(path); continue
                }
                if let filmID = record.state.filmID, identifiers.contains(filmID) { matched.insert(path) }
            } catch {
                recorded.append(fail(error, "Corrupt or unreadable edit record during film invalidation for \(path): \(error.localizedDescription)", "scanPathsReferencingFilms.parseRecord"))
                corrupt.insert(path)
            }
        }
        return .init(matchedPaths: matched, corruptPaths: corrupt, registryUnreadable: false, diagnostics: recorded)
    }

    public func pathsReferencingFilms(_ identifiers: Set<String>) -> Set<String> { scanPathsReferencingFilms(identifiers).pathsToInvalidate }
    public func notifyEditedInvalidation(forPaths paths: Set<String>) {
        guard !paths.isEmpty else { return }
        NotificationCenter.default.post(name: Self.didInvalidateEditedNotification, object: nil,
                                        userInfo: [Self.directoryPathUserInfoKey: canonicalDirectoryPath, Self.invalidatedPathsUserInfoKey: paths])
    }

    public static func stateRevisionDigest(for state: PhotoEditState) -> String {
        let data = (try? EditRecordCodec.encoder(legacyV1: false).encode(state)) ?? Data(String(describing: state).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func editedRevision(for state: PhotoEditState?, atPath path: String) -> String? {
        guard let state else { return nil }
        let url = URL(fileURLWithPath: path)
        let isX3f = url.pathExtension.lowercased() == "x3f"
        let repaired = state.repairingLegacyNormalX3f(isX3f: isX3f).state
        let raw = !PhotoInputClassification.isRasterInput(url)
        let ctx = EditorAdjustmentContext(isRaw: raw, defaultExposureMode: raw ? Adjustments().exposureMode : .sensor, neutralFilmID: "")
        return EditorAdjustmentRules.isModified(scope: .all, snapshot: repaired, context: ctx) ? stateRevisionDigest(for: repaired) : nil
    }

    private static func prepareRecordsChanged(_ changes: [String: MacPhotoEditRecord]) -> PreparedRecordsChange? {
        guard !changes.isEmpty else { return nil }
        var revisions = [String: String](), identities = [String: (UInt64, Date, UInt64)]()
        for (path, record) in changes {
            identities[path] = (record.identity.size, record.identity.modified, record.identity.fileNumber)
            if let revision = Self.editedRevision(for: record.state, atPath: path) { revisions[path] = revision }
        }
        return PreparedRecordsChange(changes: changes, editedRevisions: revisions, fileIdentities: identities)
    }

    private func postPreparedRecordsChanged(_ prepared: PreparedRecordsChange?) {
        guard let prepared else { return }
        NotificationCenter.default.post(name: Self.didChangeRecordsNotification, object: nil, userInfo: [
            Self.directoryPathUserInfoKey: canonicalDirectoryPath, Self.changedRecordsUserInfoKey: prepared.changes,
            Self.invalidatedPathsUserInfoKey: Set(prepared.changes.keys), Self.editedRevisionsUserInfoKey: prepared.editedRevisions,
            Self.fileIdentitiesUserInfoKey: prepared.fileIdentities
        ])
    }

    public var hasPendingCommits: Bool { core.hasPendingCommits }
    public var pendingCommitCount: Int { core.pendingCommitCount }
    public func waitForPendingIO() { core.waitForPendingIO() }
    @discardableResult public func deliverReadyCompletedCommits() -> Bool { core.deliverReadyCompletedCommits() }
    @discardableResult public func flushPendingCommits() -> Bool { core.flushPendingCommits() }

    public func enqueueSaveState(identity: OriginalFileIdentity, state: PhotoEditState?, clearsProcessingMigration: Bool = false,
                               postNotification: Bool = true, chainIfUndeliveredFailure: Bool = false,
                               completion: ((Result<MacPhotoEditRecord, Error>) -> Void)? = nil) throws {
        if let state { try EditRecordCodec.validateState(state, isMac: true) }
        core.enqueueCommit(key: identity.path, postDelivery: postNotification, chainIfUndeliveredFailure: chainIfUndeliveredFailure, operation: { [weak self] in
            guard let self else { throw AdjustmentCommitError.expired }
            let pair = try self.performSaveStateCore(identity: identity, state: state, clearsProcessingMigration: clearsProcessingMigration)
            return (pair.record, pair.notification.map { n in { [weak self] in self?.postPreparedRecordsChanged(n) } })
        }, completion: completion)
    }

    private func withSyncLockedEnvelope<T>(clearingKeys: @escaping (T) -> [String] = { _ in [] }, _ body: (inout EditRegistryEnvelope) throws -> T) throws -> T {
        try core.performSync(clearingFailedKeys: clearingKeys) {
            try core.withWriteLock {
                var envelope = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
                return try body(&envelope)
            }
        }
    }

    public func commitProcessingMigration(expected: MacPhotoEditRecord, candidate: PhotoEditState?, quality: ProcessingMigrationQuality) throws -> MacPhotoEditRecord {
        let result = try withSyncLockedEnvelope { updated in
            try expected.identity.requireCurrent()
            guard try snapshot(identity: expected.identity, registry: updated) == expected, let original = expected.state else { throw AdjustmentCommitError.expired }
            let enc = Self.makeLegacyV1Encoder()
            try EditRecordCodec.commitMigration(
                core: core, key: expected.identity.path, identity: expected.identity, original: original, candidate: candidate, quality: quality,
                maxSourceVersion: 2, isMac: true, existingMigration: { Self.tryParseMigration($0.processingMigrations?[expected.identity.path], identity: expected.identity) },
                encodeRecord: { try Self.encodeRecord(expected.identity, state: $0) }, encodeMigration: { try enc.encode($0) }
            )
            return try snapshot(identity: expected.identity, registry: try core.readEnvelope(allowCache: false, holdingWriteLock: true))
        }
        if let candidate, expected.state != candidate { postPreparedRecordsChanged(Self.prepareRecordsChanged([expected.identity.path: result])) }
        return result
    }

    public func rollbackProcessingMigration(expected: MacPhotoEditRecord) throws -> MacPhotoEditRecord {
        let isX3f = URL(fileURLWithPath: expected.identity.path).pathExtension.lowercased() == "x3f"
        let result = try withSyncLockedEnvelope { updated in
            try expected.identity.requireCurrent()
            guard try snapshot(identity: expected.identity, registry: updated) == expected,
                  let stored = Self.tryParseMigration(updated.processingMigrations?[expected.identity.path], identity: expected.identity) else { throw AdjustmentCommitError.expired }
            let enc = Self.makeLegacyV1Encoder()
            try EditRecordCodec.rollbackMigration(
                core: core, key: expected.identity.path, isMac: true, isX3f: isX3f, envelope: &updated, stored: stored,
                encodeRecord: { try Self.encodeRecord(expected.identity, state: $0) }, encodeMigration: { try enc.encode($0) }
            )
            return try snapshot(identity: expected.identity, registry: updated)
        }
        if expected.state != result.state { postPreparedRecordsChanged(Self.prepareRecordsChanged([expected.identity.path: result])) }
        return result
    }

    private func rawSnapshot(identity: OriginalFileIdentity, registry: EditRegistryEnvelope) throws -> MacPhotoEditRecord {
        guard let raw = registry.records[identity.path] else { return MacPhotoEditRecord(identity: identity, state: nil) }
        let record = try Self.parseRecord(raw)
        return MacPhotoEditRecord(identity: identity, state: record.identity == identity ? record.state : nil)
    }

    private func snapshot(identity: OriginalFileIdentity, registry: EditRegistryEnvelope) throws -> MacPhotoEditRecord {
        try rawSnapshot(identity: identity, registry: registry).repairingLegacyNormalX3f().record
    }

    public func save(_ url: URL, state: PhotoEditState) throws { try save([url], state: state) }
    public func save(_ urls: [URL], state: PhotoEditState) throws {
        let prepared = try withSyncLockedEnvelope(clearingKeys: { Array($0?.changes.keys ?? [:].keys) }) { updated -> PreparedRecordsChange? in
            try EditRecordCodec.validateState(state, isMac: true)
            var changed = [String: MacPhotoEditRecord]()
            for url in urls {
                let identity = try OriginalFileIdentity(url)
                if try rawSnapshot(identity: identity, registry: updated).state == state { continue }
                updated.records[identity.path] = try Self.encodeRecord(identity, state: state)
                changed[identity.path] = MacPhotoEditRecord(identity: identity, state: state)
            }
            if !changed.isEmpty { try core.writeEnvelope(&updated) }
            return Self.prepareRecordsChanged(changed)
        }
        postPreparedRecordsChanged(prepared)
    }

    private func performSaveStateCore(identity: OriginalFileIdentity, state: PhotoEditState?, clearsProcessingMigration: Bool,
                                      expected: MacPhotoEditRecord? = nil) throws -> (record: MacPhotoEditRecord, notification: PreparedRecordsChange?) {
        var stateChanged = false
        let result = try core.withWriteLock {
            if let state { try EditRecordCodec.validateState(state, isMac: true) }
            var updated = try core.readEnvelope(allowCache: false, holdingWriteLock: true)
            try identity.requireCurrent()
            let rawCurrent = try rawSnapshot(identity: identity, registry: updated)
            let current = rawCurrent.repairingLegacyNormalX3f().record
            if let expected { guard current == expected else { throw AdjustmentCommitError.expired } }
            stateChanged = rawCurrent.state != state
            let clearsMigration = clearsProcessingMigration && updated.processingMigrations?[identity.path] != nil
            guard stateChanged || clearsMigration else { return current }
            if let state { updated.records[identity.path] = try Self.encodeRecord(identity, state: state) }
            else { updated.records.removeValue(forKey: identity.path) }
            if clearsMigration {
                updated.processingMigrations?.removeValue(forKey: identity.path)
                if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            }
            try core.writeEnvelope(&updated)
            return MacPhotoEditRecord(identity: identity, state: state)
        }
        return (result, stateChanged ? Self.prepareRecordsChanged([identity.path: result]) : nil)
    }

    @discardableResult public func saveState(identity: OriginalFileIdentity, state: PhotoEditState?, clearsProcessingMigration: Bool = false) throws -> MacPhotoEditRecord {
        let pair = try core.performSync(clearingFailedKeys: { _ in [identity.path] }) {
            try performSaveStateCore(identity: identity, state: state, clearsProcessingMigration: clearsProcessingMigration)
        }
        postPreparedRecordsChanged(pair.notification); return pair.record
    }

    @discardableResult public func saveTransferredState(_ state: PhotoEditState, expected: MacPhotoEditRecord) throws -> MacPhotoEditRecord {
        let pair = try core.performSync(clearingFailedKeys: { _ in [expected.identity.path] }) {
            try performSaveStateCore(identity: expected.identity, state: state, clearsProcessingMigration: false, expected: expected)
        }
        postPreparedRecordsChanged(pair.notification); return pair.record
    }

    @discardableResult public func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord {
        let (result, prepared) = try withSyncLockedEnvelope(clearingKeys: { [$0.0.identity.path] }) { updated in
            let identity = try OriginalFileIdentity(url)
            let hadRecord = updated.records.removeValue(forKey: identity.path) != nil
            let hadMigration = updated.processingMigrations?.removeValue(forKey: identity.path) != nil
            if updated.processingMigrations?.isEmpty == true { updated.processingMigrations = nil }
            if hadRecord || hadMigration { try core.writeEnvelope(&updated) }
            let record = MacPhotoEditRecord(identity: identity, state: nil)
            return (record, hadRecord ? Self.prepareRecordsChanged([identity.path: record]) : nil)
        }
        postPreparedRecordsChanged(prepared); return result
    }
}

public final class MacResourceDigestCache: @unchecked Sendable {
    public static let defaultMaximumEntries = 128
    public static let shared = MacResourceDigestCache()
    public struct Result { public let identity: OriginalFileIdentity; public let digest: Data; public init(identity: OriginalFileIdentity, digest: Data) { self.identity = identity; self.digest = digest } }
    private let backingCache: FileDigestCache
    public var rawDigestCache: FileDigestCache { backingCache }
    public var maximumEntries: Int { backingCache.maximumEntries }
    public init(maximumEntries: Int = MacResourceDigestCache.defaultMaximumEntries) { self.backingCache = FileDigestCache(maximumEntries: max(1, maximumEntries)) }
    public var entryCount: Int { backingCache.entryCount }
    public var sha256Count: Int { backingCache.digestComputeCount }
    public func invalidate(url: URL) { backingCache.invalidate(for: url) }
    public func fingerprintDigest(for url: URL, maxBytes: Int? = nil, onHash: (() -> Void)? = nil, readData: ((URL) throws -> Data)? = nil) throws -> Result {
        let r = try backingCache.digestAndFingerprint(for: url, maximumBytes: maxBytes, returnOnUnstableThirdAttempt: true, onHash: onHash, readData: readData)
        return Result(identity: r.identity, digest: r.digest)
    }
}
