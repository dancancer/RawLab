import CryptoKit
import Foundation

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
}

enum EditPersistenceError: LocalizedError {
    case invalidIdentity
    case corruptStore

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "无法识别原始照片，调整尚未保存。"
        case .corruptStore:
            return "无法读取已保存的调整，原有记录未被覆盖。"
        }
    }
}

final class EditPersistence {
    private struct StoreFile: Codable {
        var records: [String: PhotoEditState]
    }

    let directory: URL
    private let fileURL: URL
    private var records: [String: PhotoEditState]
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("edits.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                records = try JSONDecoder().decode(StoreFile.self, from: data).records
            } catch {
                throw EditPersistenceError.corruptStore
            }
        } else {
            records = [:]
        }
    }

    static func appStore() throws -> EditPersistence {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        return try EditPersistence(directory: root.appendingPathComponent("RawLab/Edits", isDirectory: true))
    }

    func state(for identity: PhotoIdentity) -> PhotoEditState? {
        lock.lock(); defer { lock.unlock() }
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else { return nil }
        return records[identity.key]
    }

    func state(for url: URL) -> PhotoEditState? {
        guard let identity = try? PhotoIdentity.fallback(for: url) else { return nil }
        return state(for: identity)
    }

    func save(_ identity: PhotoIdentity, state: PhotoEditState) throws {
        lock.lock(); defer { lock.unlock() }
        guard identity.resourceIdentifier != nil || identity.contentIdentifier != nil else {
            throw EditPersistenceError.invalidIdentity
        }
        var updated = records
        updated[identity.key] = state
        try writeStore(updated)
        records = updated
    }

    func save(_ url: URL, state: PhotoEditState) throws {
        try save(try PhotoIdentity.fallback(for: url), state: state)
    }

    func reset(_ identity: PhotoIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        var updated = records
        updated.removeValue(forKey: identity.key)
        try writeStore(updated)
        records = updated
    }

    func reset(_ url: URL) throws {
        try reset(try PhotoIdentity.fallback(for: url))
    }

    private func writeStore(_ updated: [String: PhotoEditState]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(StoreFile(records: updated)).write(to: fileURL, options: .atomic)
    }
}
