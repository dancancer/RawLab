@_exported import CSony2Fuji
@_exported import RawLabInspectionNative
@_exported import RawLabNativeTypes
import RawLabKit
import Darwin
import Foundation

public extension LUTCompatibility {
    static func inspect(_ source: URL) throws -> LUTCompatibility? {
        guard ["cube", "vlt"].contains(source.pathExtension.lowercased()) else { return nil }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var blob = sony2fuji_blob()
        defer { sony2fuji_release_blob(&blob) }
        let status = source.path.withCString { sony2fuji_inspect_lut_compatibility($0, &blob) }
        guard status == SONY2FUJI_STATUS_OK, let bytes = blob.data else { return nil }
        let data = Data(bytes: bytes, count: blob.size_bytes)
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["eligible"] as? Bool == true else { return nil }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func prepare(_ source: URL) throws -> Data {
        guard canImport else { throw LookLibraryError.missingColor }
        struct Request: Encodable {
            let source_sha256: String
            let confirmed = true
            let confirmed_extreme_values: Bool
            let contract: LUTCompatibilityContract
        }
        let request = Request(source_sha256: sourceSHA256, confirmed_extreme_values: confirmedExtremeValues, contract: contract)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var blob = sony2fuji_blob()
        defer { sony2fuji_release_blob(&blob) }
        let status = source.path.withCString { path in
            json.withCString { sony2fuji_prepare_lut_compatibility(path, $0, &blob) }
        }
        guard status == SONY2FUJI_STATUS_OK, let bytes = blob.data else { throw LookLibraryError.compatibilityChanged }
        return Data(bytes: bytes, count: blob.size_bytes)
    }
}

public final class LookLibrary {
    public typealias UnreadableLook = LookLibraryUnreadableLook

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Looks", isDirectory: true)
    }

    private enum ReadabilityProbe: Equatable {
        case missing
        case present(FileStatFingerprint)
    }

    private let directory: URL
    private let manager = FileManager.default
    private var registryURL: URL { directory.appendingPathComponent("registry.json") }
    private let readabilityLock = NSLock()
    private var cachedReadability: (probe: ReadabilityProbe, readable: Bool)?
    public private(set) var diskReadCount = 0
    public private(set) var looks: [UserLook] = []
    public private(set) var unreadableLooks: [UnreadableLook] = []

    public init(directory: URL = LookLibrary.defaultDirectory) throws {
        self.directory = directory
        let resolvedPath = registryURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard manager.fileExists(atPath: registryURL.path) else {
            if Self.probeReadability(for: resolvedPath) == .missing {
                cachedReadability = (.missing, true)
            }
            return
        }
        let probeBefore = Self.probeReadability(for: resolvedPath)
        do {
            diskReadCount += 1
            let state = try LookRegistryCodec.readRegistry(at: registryURL)
            looks = state.looks
            unreadableLooks = state.unreadable
            let probeAfter = Self.probeReadability(for: resolvedPath)
            if let probeBefore, let probeAfter, probeBefore == probeAfter {
                cachedReadability = (probeBefore, true)
            }
        } catch { throw LookLibraryError.invalidRegistry }
        do { try recoverRemovals() } catch { throw LookLibraryError.invalidRegistry }
    }

    public var isReadable: Bool {
        let resolvedPath = registryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let probe = Self.probeReadability(for: resolvedPath)
        readabilityLock.lock()
        if let probe, let cached = cachedReadability, cached.probe == probe {
            readabilityLock.unlock()
            return cached.readable
        }
        readabilityLock.unlock()

        let readable: Bool
        if !manager.fileExists(atPath: registryURL.path) {
            readable = probe == .missing
        } else {
            readabilityLock.lock()
            diskReadCount += 1
            readabilityLock.unlock()
            readable = (try? LookRegistryCodec.readRegistry(at: registryURL)) != nil
        }

        let probeAfter = Self.probeReadability(for: resolvedPath)
        readabilityLock.lock()
        if let probe, let probeAfter, probe == probeAfter {
            if case .present(let fp) = probe, !fp.isRegularFile {
                cachedReadability = nil
            } else {
                cachedReadability = (probe, readable)
            }
        } else {
            cachedReadability = nil
        }
        readabilityLock.unlock()
        return readable
    }

    private static func probeReadability(for resolvedPath: String) -> ReadabilityProbe? {
        var st = POSIXStat()
        if stat(resolvedPath, &st) == 0 {
            return .present(FileStatFingerprint(statBuffer: st))
        }
        return errno == ENOENT ? .missing : nil
    }

    public func url(for look: UserLook) -> URL { directory.appendingPathComponent(look.fileName) }

    public func importLook(from source: URL, compatibility: LUTCompatibility? = nil,
                           dcpOptions: DCPImportOptions? = nil) throws -> UserLook {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let suffix = source.pathExtension.lowercased()
        guard ["cube", "vlt", "rlook", "dcp"].contains(suffix) else { throw LookLibraryError.invalidLook }
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw LookLibraryError.unreadableSource
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let preparedSuffix = suffix == "dcp" ? "rlook" : suffix
        let staging = directory.appendingPathComponent(".import-\(id).\(preparedSuffix)")
        defer { try? manager.removeItem(at: staging) }
        if let compatibility {
            guard ["cube", "vlt"].contains(suffix) else { throw LookLibraryError.invalidLook }
            try compatibility.prepare(source).write(to: staging, options: .withoutOverwriting)
        } else if suffix == "dcp" {
            try DCPCompiler.compile(source: source, options: dcpOptions ?? .init())
                .write(to: staging, options: .withoutOverwriting)
        } else {
            try manager.copyItem(at: source, to: staging)
        }
        var format = SONY2FUJI_LOOK_UNKNOWN
        var version: UInt32 = 0
        let status = staging.path.withCString { sony2fuji_validate_look($0, &format, &version) }
        let color = staging.path.withCString { sony2fuji_inspect_lut_color($0) }
        if compatibility == nil && (color == SONY2FUJI_LUT_COMPATIBILITY || color == SONY2FUJI_LUT_APPROXIMATE_BASE) {
            throw LookLibraryError.missingReference
        }
        guard status == SONY2FUJI_STATUS_OK else {
            if status == SONY2FUJI_STATUS_UNSUPPORTED {
                switch color {
                case SONY2FUJI_LUT_MISSING_COLOR: throw LookLibraryError.missingColor
                case SONY2FUJI_LUT_MISSING_REFERENCE: throw LookLibraryError.missingReference
                case SONY2FUJI_LUT_UNSUPPORTED_CONTRACT: throw LookLibraryError.unsupportedColor
                case SONY2FUJI_LUT_INVALID_CONTRACT: throw LookLibraryError.conflictingColor
                default: break
                }
            }
            throw status == SONY2FUJI_STATUS_IO_ERROR ? LookLibraryError.unreadableSource : LookLibraryError.invalidLook
        }
        let look = UserLook(id: id, name: source.deletingPathExtension().lastPathComponent,
                            fileName: "\(id).\(preparedSuffix)", sourceName: source.lastPathComponent,
                            format: format == SONY2FUJI_LOOK_RLOOK ? "rlook" : format == SONY2FUJI_LOOK_VLT ? "vlt" : "cube", formatVersion: version,
                            colorState: color == SONY2FUJI_LUT_APPROXIMATE_BASE ? "approximate-base" :
                                color == SONY2FUJI_LUT_COMPATIBILITY ? "compatibility" :
                                color == SONY2FUJI_LUT_DECLARED_UNVERIFIED ? "declared-unverified" : nil)
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

    public func rename(id: String, to proposed: String) throws {
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

    public func remove(id: String) throws {
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

    // 坏条目按原文精确删除；仅当文件名安全（无路径分隔与扩展名白名单）、前缀是 UUID
    // 且不被任何存活条目引用时才清理实体文件，防止误删有效外观的文件。
    // APFS 默认大小写不敏感：归属判重必须折叠大小写（Windows #314 同用 OrdinalIgnoreCase），
    // `X.CUBE` 与 `x.cube` 是同一个实体文件；且只清理普通文件，同名目录不得整树搬走
    //（对齐 Android isFile / Windows File.Exists）。
    public func remove(_ look: UnreadableLook) throws {
        guard let index = unreadableLooks.firstIndex(of: look) else { throw LookLibraryError.missingLook }
        var changed = unreadableLooks
        changed.remove(at: index)
        var file: URL?
        if let name = look.fileName, !name.contains("/"), !name.contains("\\"), !name.contains(".."),
           ["cube", "vlt", "rlook"].contains((name as NSString).pathExtension.lowercased()),
           UUID(uuidString: (name as NSString).deletingPathExtension) != nil,
           !looks.contains(where: { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }),
           !changed.contains(where: { $0.fileName.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false }) {
            file = directory.appendingPathComponent(name)
        }
        let staging = file.map { directory.appendingPathComponent(".remove-\($0.lastPathComponent)") }
        let exists = file.map { isRegularFile(at: $0) } ?? false
        if exists, let file, let staging { try manager.moveItem(at: file, to: staging) }
        do {
            try persist(looks, unreadable: changed)
        } catch {
            if exists, let file, let staging { try? manager.moveItem(at: staging, to: file) }
            throw error
        }
        unreadableLooks = changed
        if exists, let staging { try? manager.removeItem(at: staging) }
    }

    // 大小写不敏感卷上文件属性查询失败按「不可动」处理：只认真正的普通文件。
    private func isRegularFile(at url: URL) -> Bool {
        guard let type = (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    private func recoverRemovals() throws {
        // 归属判重与扩展名白名单同 remove(_:)：大小写不敏感卷上必须折叠大小写，
        // 否则 `.remove-<小写id>.cube` 会被判「无主」直接删掉，而它属于存活条目 `<大写id>.cube`。
        let activeFiles = Set((looks.map(\.fileName) + unreadableLooks.compactMap(\.fileName)).map { $0.lowercased() })
        let prefix = ".remove-"
        for staged in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = staged.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let fileName = String(name.dropFirst(prefix.count))
            let file = URL(fileURLWithPath: fileName)
            guard ["cube", "vlt", "rlook"].contains(file.pathExtension.lowercased()),
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  isRegularFile(at: staged) else { continue }
            let original = directory.appendingPathComponent(fileName)
            // registry 的原子写入是提交点：提交前恢复文件，提交后完成清理。
            if activeFiles.contains(fileName.lowercased()) {
                if !manager.fileExists(atPath: original.path) { try manager.moveItem(at: staged, to: original) }
            } else {
                try manager.removeItem(at: staged)
            }
        }
    }

    private func persist(_ values: [UserLook], unreadable: [UnreadableLook]? = nil) throws {
        readabilityLock.lock()
        cachedReadability = nil
        readabilityLock.unlock()
        let bad = unreadable ?? unreadableLooks
        let out = try LookRegistryCodec.encodeRegistry(looks: values, unreadable: bad)
        try out.write(to: registryURL, options: .atomic)
    }
}
