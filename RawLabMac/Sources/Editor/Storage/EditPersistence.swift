import Foundation

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

final class EditPersistence {
    private struct Record: Codable {
        let identity: OriginalFileIdentity
        let state: PhotoEditState
    }
    private struct Registry: Codable {
        var version = 1
        var records: [String: Record] = [:]
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Edits", isDirectory: true)
    }

    private let directory: URL
    private var registry = Registry()
    private var file: URL { directory.appendingPathComponent("edits.json") }

    init(directory: URL = EditPersistence.defaultDirectory) throws {
        self.directory = directory
        registry = try readRegistry()
    }

    private func readRegistry() throws -> Registry {
        guard FileManager.default.fileExists(atPath: file.path) else { return Registry() }
        let stored = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        guard stored.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }

    func state(for url: URL) throws -> PhotoEditState? {
        registry = try readRegistry()
        let identity = try OriginalFileIdentity(url)
        guard let record = registry.records[identity.path], record.identity == identity else { return nil }
        return record.state
    }

    func save(_ url: URL, state: PhotoEditState) throws {
        try save([url], state: state)
    }

    func save(_ urls: [URL], state: PhotoEditState) throws {
        var updated = try readRegistry()
        for url in urls {
            let identity = try OriginalFileIdentity(url)
            updated.records[identity.path] = Record(identity: identity, state: state)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        registry = updated
    }
}
