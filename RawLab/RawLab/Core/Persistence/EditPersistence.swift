import CryptoKit
import Foundation
import Darwin

struct PhotoIdentity: Codable, Equatable, Hashable, Sendable {
    let resourceIdentifier: String?
    let contentIdentifier: String?

    init(resourceIdentifier: String) {
        self.resourceIdentifier = resourceIdentifier.isEmpty ? nil : resourceIdentifier
        self.contentIdentifier = nil
    }

    init(contentIdentifier: String) {
        self.resourceIdentifier = nil
        self.contentIdentifier = contentIdentifier.isEmpty ? nil : contentIdentifier
    }

    init(resourceIdentifier: String?, contentIdentifier: String?) {
        self.resourceIdentifier = resourceIdentifier?.isEmpty == true ? nil : resourceIdentifier
        self.contentIdentifier = contentIdentifier?.isEmpty == true ? nil : contentIdentifier
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

    static func fallback(for url: URL) throws -> PhotoIdentity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return PhotoIdentity(contentIdentifier: hasher.finalize().map { String(format: "%02x", $0) }.joined())
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

struct VersionedPhotoEdit: Equatable {
    let identity: PhotoIdentity
    let state: PhotoEditState?
    let revision: String?
}

enum EditPersistenceConflict: Error { case changed }

enum EditPersistenceError: LocalizedError {
    case invalidIdentity
    case corruptStore

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return L10n.text("无法识别原始照片，调整尚未保存。")
        case .corruptStore:
            return L10n.text("无法读取已保存的调整，原有记录未被覆盖。")
        }
    }
}

final class EditPersistence {
    private struct StoreFile: Codable {
        var version: Int?
        var records: [String: PhotoEditState]
        var revisions: [String: String]?
    }

    let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let writeData: (Data, URL) throws -> Void
    private let snapshotLock = NSLock()
    private var lastReadableRecords: [String: PhotoEditState] = [:]

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
        do { return try versionedState(for: identity).state }
        catch {
            // 旧读取接口在 I/O 失败时保留已载入值；事务读取始终抛错，不能用缓存提交。
            snapshotLock.lock(); defer { snapshotLock.unlock() }
            return lastReadableRecords[identity.key]
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
            _ = try write(nil, identity: identity, store: &store)
        }
    }

    func reset(_ url: URL) throws {
        try reset(try PhotoIdentity.fallback(for: url))
    }

    func versionedState(for identity: PhotoIdentity) throws -> VersionedPhotoEdit {
        try validate(identity)
        let store = try readStore()
        return record(identity, from: store)
    }

    func compareAndSave(expected: VersionedPhotoEdit, state: PhotoEditState?) throws -> VersionedPhotoEdit {
        try validate(expected.identity)
        return try withWriteLock {
            var store = try readStore()
            guard record(expected.identity, from: store) == expected else { throw EditPersistenceConflict.changed }
            return try write(state, identity: expected.identity, store: &store)
        }
    }

    private func validate(_ identity: PhotoIdentity) throws {
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else { throw EditPersistenceError.invalidIdentity }
    }

    private func record(_ identity: PhotoIdentity, from store: StoreFile) -> VersionedPhotoEdit {
        .init(identity: identity, state: store.records[identity.key], revision: store.revisions?[identity.key])
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
            remember(store)
            return store
        } catch { throw EditPersistenceError.corruptStore }
    }

    private func write(_ state: PhotoEditState?, identity: PhotoIdentity, store: inout StoreFile) throws -> VersionedPhotoEdit {
        let current = record(identity, from: store)
        if let previous = current.state, let state, previous.hasSameAdjustments(as: state) { return current }
        if current.state == nil && state == nil { return current }
        store.version = 1
        store.records[identity.key] = state
        var revisions = store.revisions ?? [:]
        revisions[identity.key] = UUID().uuidString
        store.revisions = revisions
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(store), fileURL)
        remember(store)
        return record(identity, from: store)
    }

    private func remember(_ store: StoreFile) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        lastReadableRecords = store.records
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
