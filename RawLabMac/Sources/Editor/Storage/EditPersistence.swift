import Foundation
import Darwin

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

final class EditPersistence {
    private struct Record: Codable {
        let identity: OriginalFileIdentity
        let state: PhotoEditState
    }
    private struct Registry: Codable {
        var version = 1
        var records: [String: Record] = [:]
        var processingMigrations: [String: StoredMigration]? = nil
    }
    private struct StoredMigration: Codable {
        let identity: OriginalFileIdentity
        var receipt: ProcessingMigrationReceipt<PhotoEditState>
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    private let directory: URL
    private let writeData: (Data, URL) throws -> Void
    private var file: URL { directory.appendingPathComponent("edits.json") }

    init(directory: URL = EditPersistence.defaultDirectory,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.writeData = writeData
        _ = try readRegistry()
    }

    private func readRegistry() throws -> Registry {
        guard FileManager.default.fileExists(atPath: file.path) else { return Registry() }
        let stored = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        guard stored.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }

    func state(for url: URL) throws -> PhotoEditState? {
        try readState(for: url).state
    }

    func readState(for url: URL) throws -> PhotoEditRecord {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return snapshot(identity: identity, registry: registry)
    }

    func processingMigration(for url: URL) throws -> ProcessingMigrationReceipt<PhotoEditState>? {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        guard let stored = registry.processingMigrations?[identity.path], stored.identity == identity else { return nil }
        return stored.receipt
    }

    func commitProcessingMigration(expected: PhotoEditRecord, candidate: PhotoEditState?,
                                   quality: ProcessingMigrationQuality) throws -> PhotoEditRecord {
        try withWriteLock {
            var updated = try readRegistry()
            try expected.identity.requireCurrent()
            guard snapshot(identity: expected.identity, registry: updated) == expected,
                  let original = expected.state, original.settings.processing.version < 3,
                  quality.isValid else { throw AdjustmentCommitError.expired }
            if let previous = updated.processingMigrations?[expected.identity.path], previous.identity == expected.identity,
               !previous.receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) {
                throw AdjustmentCommitError.expired
            }
            if let candidate {
                try candidate.settings.validateResetValues()
                guard candidate.settings.processing == .current, quality.passes else { throw AdjustmentCommitError.expired }
                updated.records[expected.identity.path] = Record(identity: expected.identity, state: candidate)
            }
            let receipt = ProcessingMigrationReceipt(status: candidate == nil ? .kept : .migrated,
                original: original, quality: quality)
            var migrations = updated.processingMigrations ?? [:]
            migrations[expected.identity.path] = StoredMigration(identity: expected.identity, receipt: receipt)
            updated.processingMigrations = migrations
            try writeData(JSONEncoder().encode(updated), file)
            return snapshot(identity: expected.identity, registry: updated)
        }
    }

    func rollbackProcessingMigration(expected: PhotoEditRecord) throws -> PhotoEditRecord {
        try withWriteLock {
            var updated = try readRegistry()
            try expected.identity.requireCurrent()
            guard snapshot(identity: expected.identity, registry: updated) == expected,
                  var stored = updated.processingMigrations?[expected.identity.path],
                  stored.identity == expected.identity, stored.receipt.status == .migrated else {
                throw AdjustmentCommitError.expired
            }
            try stored.receipt.original.settings.validateResetValues()
            updated.records[expected.identity.path] = Record(identity: expected.identity, state: stored.receipt.original)
            stored.receipt.status = .rolledBack
            updated.processingMigrations?[expected.identity.path] = stored
            try writeData(JSONEncoder().encode(updated), file)
            return snapshot(identity: expected.identity, registry: updated)
        }
    }

    private func snapshot(identity: OriginalFileIdentity, registry: Registry) -> PhotoEditRecord {
        let record = registry.records[identity.path]
        return PhotoEditRecord(identity: identity, state: record?.identity == identity ? record?.state : nil)
    }

    func save(_ url: URL, state: PhotoEditState) throws {
        try save([url], state: state)
    }

    func save(_ urls: [URL], state: PhotoEditState) throws {
        try withWriteLock {
            var updated = try readRegistry()
            var changed = false
            for url in urls {
                let identity = try OriginalFileIdentity(url)
                if snapshot(identity: identity, registry: updated).state == state { continue }
                updated.records[identity.path] = Record(identity: identity, state: state)
                changed = true
            }
            if changed { try writeData(JSONEncoder().encode(updated), file) }
        }
    }

    @discardableResult func saveState(identity: OriginalFileIdentity, state: PhotoEditState?) throws -> PhotoEditRecord {
        try withWriteLock {
            var updated = try readRegistry()
            try identity.requireCurrent()
            let current = snapshot(identity: identity, registry: updated)
            guard current.state != state else { return current }
            if let state { updated.records[identity.path] = Record(identity: identity, state: state) }
            else { updated.records.removeValue(forKey: identity.path) }
            try writeData(JSONEncoder().encode(updated), file)
            return PhotoEditRecord(identity: identity, state: state)
        }
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
