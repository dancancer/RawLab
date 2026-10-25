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
}

struct VersionedPhotoEdit: Equatable {
    let identity: OriginalFileIdentity
    let state: PhotoEditState?
    let revision: UUID?
}

enum EditPersistenceConflict: Error { case changed }

final class EditPersistence {
    private struct Record: Codable {
        let identity: OriginalFileIdentity
        let state: PhotoEditState
    }
    private struct Registry: Codable {
        var version = 1
        var records: [String: Record] = [:]
        // 删除记录也保留新的 token，避免“修改后又恢复”绕过 prepared/history 守卫。
        var revisions: [String: UUID]?
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
        try versionedState(for: url).state
    }

    func versionedState(for url: URL) throws -> VersionedPhotoEdit {
        let registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        return snapshot(identity: identity, registry: registry)
    }

    private func snapshot(identity: OriginalFileIdentity, registry: Registry) -> VersionedPhotoEdit {
        let record = registry.records[identity.path]
        return VersionedPhotoEdit(identity: identity, state: record?.identity == identity ? record?.state : nil,
            revision: registry.revisions?[identity.path])
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
                if updated.revisions == nil { updated.revisions = [:] }
                updated.revisions?[identity.path] = UUID()
                changed = true
            }
            if changed { try writeData(JSONEncoder().encode(updated), file) }
        }
    }

    @discardableResult func compareAndSave(expected: VersionedPhotoEdit, state: PhotoEditState?) throws -> VersionedPhotoEdit {
        try withWriteLock {
            var updated = try readRegistry()
            let identity = try OriginalFileIdentity(URL(fileURLWithPath: expected.identity.path))
            guard snapshot(identity: identity, registry: updated) == expected else { throw EditPersistenceConflict.changed }
            if state == expected.state { return expected }
            if let state { updated.records[identity.path] = Record(identity: identity, state: state) }
            else { updated.records.removeValue(forKey: identity.path) }
            let revision = UUID()
            if updated.revisions == nil { updated.revisions = [:] }
            updated.revisions?[identity.path] = revision
            try writeData(JSONEncoder().encode(updated), file)
            return VersionedPhotoEdit(identity: identity, state: state, revision: revision)
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
