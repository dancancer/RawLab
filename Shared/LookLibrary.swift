import Foundation

struct UserLook: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let fileName: String
    let sourceName: String
    let format: String
    let formatVersion: UInt32
    var colorState: String? = nil
    var isCompatibility: Bool { colorState == "compatibility" || colorState == "approximate-base" }
    var colorNotice: String? {
        switch colorState {
        case "compatibility": return L10n.text("兼容导入 · 未验证")
        case "approximate-base": return L10n.text("近似基础 · 未验证")
        case "declared-unverified": return L10n.text("效果未验证")
        default: return nil
        }
    }
}

struct LUTCompatibilitySignal: Codable, Equatable {
    var space: String
    var reference: String
    var range: String
}

struct LUTCompatibilityContract: Codable, Equatable {
    var version: Int
    var input: LUTCompatibilitySignal
    var output: LUTCompatibilitySignal
    var interpolation: String
    var baseRendering: String
    enum CodingKeys: String, CodingKey { case version, input, output, interpolation; case baseRendering = "base_rendering" }

    mutating func selectInput(_ space: String) {
        input.space = space
        input.reference = Self.reference(for: space)
        baseRendering = input.reference == "scene" ? "none" : "rawlab-neutral-v1"
    }
    mutating func selectOutput(_ space: String) {
        output.space = space
        output.reference = Self.reference(for: space)
    }
    static func reference(for space: String) -> String {
        ["srgb", "rec709-gamma24"].contains(space) ? "display" : "scene"
    }
}

struct LUTCompatibility: Decodable, Equatable {
    let sourceSHA256: String
    var contract: LUTCompatibilityContract
    let fixedContract: Bool
    let photoStyle: String
    let extremeValues: Bool
    let hints: [String]
    var candidates: [LUTCompatibilityCandidate]? = nil
    var confirmedExtremeValues = false
    enum CodingKeys: String, CodingKey {
        case sourceSHA256 = "source_sha256", contract, fixedContract = "fixed_contract"
        case photoStyle = "photo_style", extremeValues = "extreme_values", hints, candidates
    }
    var canImport: Bool {
        hasCompleteContract && (!extremeValues || confirmedExtremeValues)
    }
    var hasCompleteContract: Bool {
        !contract.input.space.isEmpty && !contract.output.space.isEmpty &&
        !(contract.input.reference == "display" && contract.output.reference == "scene") &&
        (photoStyle != "std" || contract.input.reference == "display") &&
        (photoStyle != "vlog" || contract.input.space == "vlog-vgamut")
    }
    func applying(_ candidate: LUTCompatibilityCandidate, displayInput: Bool) -> Self? {
        var copy = self
        copy.contract = candidate.contract
        if displayInput {
            guard copy.contract.input.reference == "display" else { return nil }
            if fixedContract && copy.contract.baseRendering != "source-display" { return nil }
            copy.contract.baseRendering = "source-display"
        } else if copy.contract.baseRendering == "source-display" { return nil }
        return copy
    }
    func supportsPreview(displayInput: Bool) -> Bool {
        hasCompleteContract && (displayInput ? contract.input.reference == "display" && contract.baseRendering == "source-display" : contract.baseRendering != "source-display")
    }
    func previewRequest() throws -> String {
        struct Request: Encodable { let source_sha256: String; let contract: LUTCompatibilityContract }
        return String(decoding: try JSONEncoder().encode(Request(source_sha256: sourceSHA256, contract: contract)), as: UTF8.self)
    }
    static let spaces = ["srgb", "rec709-gamma24", "vlog-vgamut", "slog3-sgamut3", "slog3-sgamut3-cine", "linear-srgb"]
    static func spaceName(_ space: String) -> String {
        switch space {
        case "srgb": return "sRGB"
        case "rec709-gamma24": return "Rec.709 Gamma 2.4"
        case "vlog-vgamut": return "V-Log / V-Gamut"
        case "slog3-sgamut3": return "S-Log3 / S-Gamut3"
        case "slog3-sgamut3-cine": return "S-Log3 / S-Gamut3.Cine"
        case "linear-srgb": return L10n.text("线性 sRGB")
        default: return L10n.text("请选择")
        }
    }
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

struct LUTCompatibilityCandidate: Codable, Equatable, Identifiable {
    let id: String
    let contract: LUTCompatibilityContract
    let basis: String
    let assumptions: [String]
    var basisName: String {
        L10n.text(basis == "file-parameters" ? "文件已有参数 · 效果未验证" : basis == "partial-metadata" ? "依据部分文件线索 · 仍有假设" : "试用方案 · 无颜色依据")
    }
    func assumptionsName(baseRendering: String) -> String {
        let labels = assumptions.compactMap { value -> String? in
            switch value {
            case "input-space": return L10n.text("输入颜色")
            case "output-space": return L10n.text("输出颜色")
            case "ranges-and-interpolation": return L10n.text("范围与插值")
            case "neutral-base": return baseRendering == "rawlab-neutral-v1" ? L10n.text("RawLab 中性显影（近似）") : nil
            default: return nil
            }
        }
        return labels.isEmpty ? "" : L10n.format("仍需假设：%@", labels.joined(separator: " · "))
    }
}

struct LUTReferenceConditions: Codable, Equatable {
    var sameSource = false
    var sameGeometry = false
    var sameProcessing = false
    var knownSRGB = false
    var referenceSource = ""
    enum CodingKeys: String, CodingKey {
        case sameSource = "same_source", sameGeometry = "same_geometry", sameProcessing = "same_processing"
        case knownSRGB = "known_srgb", referenceSource = "reference_source"
    }
    var canCompare: Bool {
        sameSource && sameGeometry && sameProcessing && knownSRGB &&
        !referenceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && referenceSource.utf8.count <= 2048
    }
}

struct LUTPreviewComparison: Decodable {
    let meanAbsoluteRGB: Double
    let maxAbsoluteRGB: Double
    let candidateBoundaryFraction: Double
    let referenceBoundaryFraction: Double
    let width: Int
    let height: Int
    enum CodingKeys: String, CodingKey {
        case meanAbsoluteRGB = "mean_absolute_rgb", maxAbsoluteRGB = "max_absolute_rgb", width, height
        case candidateBoundaryFraction = "candidate_boundary_fraction", referenceBoundaryFraction = "reference_boundary_fraction"
    }
}

enum LookLibraryError: LocalizedError {
    case invalidLook, unreadableSource, invalidRegistry, invalidName, missingLook
    case missingColor, missingReference, unsupportedColor, conflictingColor
    case compatibilityChanged
    var needsCompatibility: Bool {
        switch self { case .missingColor, .missingReference: return true; default: return false }
    }

    var errorDescription: String? {
        switch self {
        case .invalidLook: return L10n.text("外观文件损坏或不兼容；需要兼容的 CUBE 或 RLOOK 文件。")
        case .unreadableSource: return L10n.text("无法读取外观文件。")
        case .invalidRegistry: return L10n.text("无法读取已保存的外观库，原有记录未被覆盖。")
        case .invalidName: return L10n.text("外观名称不能为空或包含控制字符。")
        case .missingLook: return L10n.text("此外观已不在外观库中。")
        case .missingColor: return L10n.text("LUT 缺少输入或输出颜色信息，未导入。请提供作者的颜色说明。")
        case .missingReference: return L10n.text("LUT 缺少颜色配置的参考依据，未导入。请提供来源和使用条件。")
        case .unsupportedColor: return L10n.text("LUT 的颜色空间或基础风格暂不支持，未导入。不会自动替换为中性显影。")
        case .conflictingColor: return L10n.text("LUT 颜色说明无效或互相冲突，未导入。请核对来源。")
        case .compatibilityChanged: return L10n.text("LUT 文件已变化或兼容配置无效，请重新导入并确认。")
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
                       (look.format == "vlt" && look.formatVersion == 1) ||
                       (look.format == "rlook" && (1...2).contains(look.formatVersion)))
                  }) else { throw LookLibraryError.invalidRegistry }
            looks = registry.looks
            try recoverRemovals()
        } catch {
            throw LookLibraryError.invalidRegistry
        }
    }

    func url(for look: UserLook) -> URL { directory.appendingPathComponent(look.fileName) }

    func importLook(from source: URL, compatibility: LUTCompatibility? = nil) throws -> UserLook {
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
            try DCPCompiler.compile(source: source).write(to: staging, options: .withoutOverwriting)
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
            guard ["cube", "vlt", "rlook"].contains(file.pathExtension),
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
