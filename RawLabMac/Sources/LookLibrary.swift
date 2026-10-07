import Foundation

struct UserLook: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let fileName: String
    let sourceName: String
    let format: String
    let formatVersion: UInt32
}

enum LookLibraryError: LocalizedError {
    case invalidLook, unreadableSource, invalidRegistry, invalidName, missingLook

    var errorDescription: String? {
        switch self {
        case .invalidLook: return "外观文件损坏或不兼容；需要兼容的 CUBE 或 RLOOK 文件。"
        case .unreadableSource: return "无法读取外观文件。"
        case .invalidRegistry: return "无法读取已保存的外观库，原有记录未被覆盖。"
        case .invalidName: return "外观名称不能为空或包含控制字符。"
        case .missingLook: return "此外观已不在外观库中。"
        }
    }
}

final class LookLibrary {
    private struct Registry: Codable {
        let version: Int
        let looks: [UserLook]
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Looks", isDirectory: true)
    }

    private let directory: URL
    private let manager = FileManager.default
    private var registryURL: URL { directory.appendingPathComponent("registry.json") }
    private(set) var looks: [UserLook] = []

    init(directory: URL = LookLibrary.defaultDirectory) throws {
        self.directory = directory
        guard manager.fileExists(atPath: registryURL.path) else { return }
        do {
            let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
            guard registry.version == 1,
                  Set(registry.looks.map(\.id)).count == registry.looks.count,
                  registry.looks.allSatisfy({ look in
                      UUID(uuidString: look.id) != nil &&
                      look.fileName == "\(look.id).\(look.format)" &&
                      ((look.format == "cube" && look.formatVersion == 0) ||
                       (look.format == "rlook" && (1...2).contains(look.formatVersion)))
                  }) else { throw LookLibraryError.invalidRegistry }
            looks = registry.looks
            try recoverRemovals()
        } catch {
            throw LookLibraryError.invalidRegistry
        }
    }

    func url(for look: UserLook) -> URL { directory.appendingPathComponent(look.fileName) }

    func importLook(from source: URL) throws -> UserLook {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let suffix = source.pathExtension.lowercased()
        guard ["cube", "rlook"].contains(suffix) else { throw LookLibraryError.invalidLook }
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw LookLibraryError.unreadableSource
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = directory.appendingPathComponent(".import-\(id).\(suffix)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        var format = SONY2FUJI_LOOK_UNKNOWN
        var version: UInt32 = 0
        let status = staging.path.withCString { sony2fuji_validate_look($0, &format, &version) }
        guard status == SONY2FUJI_STATUS_OK else {
            throw status == SONY2FUJI_STATUS_IO_ERROR ? LookLibraryError.unreadableSource : LookLibraryError.invalidLook
        }
        let look = UserLook(id: id, name: source.deletingPathExtension().lastPathComponent,
                            fileName: "\(id).\(suffix)", sourceName: source.lastPathComponent,
                            format: format == SONY2FUJI_LOOK_RLOOK ? "rlook" : "cube", formatVersion: version)
        let installed = url(for: look)
        try manager.moveItem(at: staging, to: installed)
        do {
            try persist(looks + [look])
        } catch {
            try? manager.removeItem(at: installed)
            throw error
        }
        looks.append(look)
        return look
    }

    func rename(id: String, to proposed: String) throws {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LookLibraryError.invalidName
        }
        guard let index = looks.firstIndex(where: { $0.id == id }) else { throw LookLibraryError.missingLook }
        var changed = looks
        changed[index].name = name
        try persist(changed)
        looks = changed
    }

    func remove(id: String) throws {
        guard let look = looks.first(where: { $0.id == id }) else { throw LookLibraryError.missingLook }
        let original = url(for: look)
        let staging = directory.appendingPathComponent(".remove-\(look.fileName)")
        let exists = manager.fileExists(atPath: original.path)
        if exists { try manager.moveItem(at: original, to: staging) }
        let changed = looks.filter { $0.id != id }
        do {
            try persist(changed)
        } catch {
            if exists { try manager.moveItem(at: staging, to: original) }
            throw error
        }
        looks = changed
        if exists { try? manager.removeItem(at: staging) }
    }

    private func recoverRemovals() throws {
        let activeFiles = Set(looks.map(\.fileName))
        let prefix = ".remove-"
        for staged in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = staged.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let fileName = String(name.dropFirst(prefix.count))
            let file = URL(fileURLWithPath: fileName)
            guard ["cube", "rlook"].contains(file.pathExtension),
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            let original = directory.appendingPathComponent(fileName)
            // registry 的原子写入是提交点：提交前恢复文件，提交后完成清理。
            if activeFiles.contains(fileName) {
                if !manager.fileExists(atPath: original.path) { try manager.moveItem(at: staged, to: original) }
            } else {
                try manager.removeItem(at: staged)
            }
        }
    }

    private func persist(_ values: [UserLook]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Registry(version: 1, looks: values)).write(to: registryURL, options: .atomic)
    }
}
