@_exported import CSony2Fuji
import RawLabKit
import Foundation

public struct UserLook: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let fileName: String
    public let sourceName: String
    public let format: String
    public let formatVersion: UInt32
    public var colorState: String?

    public init(id: String, name: String, fileName: String, sourceName: String,
                format: String, formatVersion: UInt32, colorState: String? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sourceName = sourceName
        self.format = format
        self.formatVersion = formatVersion
        self.colorState = colorState
    }

    public var isCompatibility: Bool { colorState == "compatibility" || colorState == "approximate-base" }

    public var colorNotice: String? {
        switch colorState {
        case "compatibility": return L10n.text("兼容导入 · 未验证")
        case "approximate-base": return L10n.text("近似基础 · 未验证")
        case "declared-unverified": return L10n.text("效果未验证")
        default: return nil
        }
    }
}

public struct LUTCompatibilitySignal: Codable, Equatable, Sendable {
    public var space: String
    public var reference: String
    public var range: String

    public init(space: String, reference: String, range: String) {
        self.space = space
        self.reference = reference
        self.range = range
    }
}

public struct LUTCompatibilityContract: Codable, Equatable, Sendable {
    public var version: Int
    public var input: LUTCompatibilitySignal
    public var output: LUTCompatibilitySignal
    public var interpolation: String
    public var baseRendering: String

    public enum CodingKeys: String, CodingKey {
        case version, input, output, interpolation
        case baseRendering = "base_rendering"
    }

    public init(version: Int, input: LUTCompatibilitySignal, output: LUTCompatibilitySignal,
                interpolation: String, baseRendering: String) {
        self.version = version
        self.input = input
        self.output = output
        self.interpolation = interpolation
        self.baseRendering = baseRendering
    }

    public mutating func selectInput(_ space: String) {
        input.space = space
        input.reference = Self.reference(for: space)
        baseRendering = input.reference == "scene" ? "none" : "rawlab-neutral-v1"
    }

    public mutating func selectOutput(_ space: String) {
        output.space = space
        output.reference = Self.reference(for: space)
    }

    public static func reference(for space: String) -> String {
        ["srgb", "rec709-gamma24"].contains(space) ? "display" : "scene"
    }
}

public struct LUTCompatibility: Decodable, Equatable, Sendable {
    public let sourceSHA256: String
    public var contract: LUTCompatibilityContract
    public let fixedContract: Bool
    public let photoStyle: String
    public let extremeValues: Bool
    public let hints: [String]
    public var candidates: [LUTCompatibilityCandidate]? = nil
    public var confirmedExtremeValues = false

    public enum CodingKeys: String, CodingKey {
        case sourceSHA256 = "source_sha256", contract, fixedContract = "fixed_contract"
        case photoStyle = "photo_style", extremeValues = "extreme_values", hints, candidates
    }

    public init(sourceSHA256: String,
                contract: LUTCompatibilityContract,
                fixedContract: Bool = false,
                photoStyle: String = "none",
                extremeValues: Bool = false,
                hints: [String] = [],
                candidates: [LUTCompatibilityCandidate]? = nil,
                confirmedExtremeValues: Bool = false) {
        self.sourceSHA256 = sourceSHA256
        self.contract = contract
        self.fixedContract = fixedContract
        self.photoStyle = photoStyle
        self.extremeValues = extremeValues
        self.hints = hints
        self.candidates = candidates
        self.confirmedExtremeValues = confirmedExtremeValues
    }

    public var canImport: Bool {
        hasCompleteContract && (!extremeValues || confirmedExtremeValues)
    }

    public var hasCompleteContract: Bool {
        !contract.input.space.isEmpty && !contract.output.space.isEmpty &&
        !(contract.input.reference == "display" && contract.output.reference == "scene") &&
        (photoStyle != "std" || contract.input.reference == "display") &&
        (photoStyle != "vlog" || contract.input.space == "vlog-vgamut")
    }

    public func applying(_ candidate: LUTCompatibilityCandidate, displayInput: Bool) -> Self? {
        var copy = self
        copy.contract = candidate.contract
        if displayInput {
            guard copy.contract.input.reference == "display" else { return nil }
            if fixedContract && copy.contract.baseRendering != "source-display" { return nil }
            copy.contract.baseRendering = "source-display"
        } else if copy.contract.baseRendering == "source-display" { return nil }
        return copy
    }

    public func supportsPreview(displayInput: Bool) -> Bool {
        hasCompleteContract && (displayInput ? contract.input.reference == "display" && contract.baseRendering == "source-display" : contract.baseRendering != "source-display")
    }

    public func previewRequest() throws -> String {
        struct Request: Encodable { let source_sha256: String; let contract: LUTCompatibilityContract }
        return String(decoding: try JSONEncoder().encode(Request(source_sha256: sourceSHA256, contract: contract)), as: UTF8.self)
    }

    public static let spaces = ["srgb", "rec709-gamma24", "vlog-vgamut", "slog3-sgamut3", "slog3-sgamut3-cine", "linear-srgb"]

    public static func spaceName(_ space: String) -> String {
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
}

public struct LUTCompatibilityCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let contract: LUTCompatibilityContract
    public let basis: String
    public let assumptions: [String]

    public init(id: String, contract: LUTCompatibilityContract, basis: String, assumptions: [String]) {
        self.id = id
        self.contract = contract
        self.basis = basis
        self.assumptions = assumptions
    }

    public var basisName: String {
        L10n.text(basis == "file-parameters" ? "文件已有参数 · 效果未验证" : basis == "partial-metadata" ? "依据部分文件线索 · 仍有假设" : "试用方案 · 无颜色依据")
    }

    public func assumptionsName(baseRendering: String) -> String {
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

public struct LUTReferenceConditions: Codable, Equatable, Sendable {
    public var sameSource = false
    public var sameGeometry = false
    public var sameProcessing = false
    public var knownSRGB = false
    public var referenceSource = ""

    public enum CodingKeys: String, CodingKey {
        case sameSource = "same_source", sameGeometry = "same_geometry", sameProcessing = "same_processing"
        case knownSRGB = "known_srgb", referenceSource = "reference_source"
    }

    public init(sameSource: Bool = false, sameGeometry: Bool = false, sameProcessing: Bool = false,
                knownSRGB: Bool = false, referenceSource: String = "") {
        self.sameSource = sameSource
        self.sameGeometry = sameGeometry
        self.sameProcessing = sameProcessing
        self.knownSRGB = knownSRGB
        self.referenceSource = referenceSource
    }

    public var canCompare: Bool {
        sameSource && sameGeometry && sameProcessing && knownSRGB &&
        !referenceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && referenceSource.utf8.count <= 2048
    }
}

public struct LUTPreviewComparison: Decodable, Sendable {
    public let meanAbsoluteRGB: Double
    public let maxAbsoluteRGB: Double
    public let candidateBoundaryFraction: Double
    public let referenceBoundaryFraction: Double
    public let width: Int
    public let height: Int

    public enum CodingKeys: String, CodingKey {
        case meanAbsoluteRGB = "mean_absolute_rgb", maxAbsoluteRGB = "max_absolute_rgb", width, height
        case candidateBoundaryFraction = "candidate_boundary_fraction", referenceBoundaryFraction = "reference_boundary_fraction"
    }

    public init(meanAbsoluteRGB: Double, maxAbsoluteRGB: Double, candidateBoundaryFraction: Double,
                referenceBoundaryFraction: Double, width: Int, height: Int) {
        self.meanAbsoluteRGB = meanAbsoluteRGB
        self.maxAbsoluteRGB = maxAbsoluteRGB
        self.candidateBoundaryFraction = candidateBoundaryFraction
        self.referenceBoundaryFraction = referenceBoundaryFraction
        self.width = width
        self.height = height
    }
}

public enum LookLibraryError: LocalizedError, Equatable, Sendable {
    case invalidLook, unreadableSource, invalidRegistry, invalidName, missingLook
    case missingColor, missingReference, unsupportedColor, conflictingColor
    case compatibilityChanged

    public var needsCompatibility: Bool {
        switch self { case .missingColor, .missingReference: return true; default: return false }
    }

    public var errorDescription: String? {
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

// 读不懂的外观条目：只隔离自己，身份尽力保留，原文逐字节留到可以删除为止（P2-16）。
public struct LookLibraryUnreadableLook: Equatable, Sendable {
    public let id: String?
    public let fileName: String?
    public let json: String

    public init(id: String?, fileName: String?, json: String) {
        self.id = id
        self.fileName = fileName
        self.json = json
    }

    public var displayName: String {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        if let name = object?["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let fileName, !fileName.isEmpty { return fileName }
        return L10n.text("损坏的外观")
    }

    public var reason: String { L10n.text("此外观无法读取，可能已损坏或来自不兼容版本。") }
}

public enum LookRegistryCodec {
    private struct Registry: Codable {
        let version: Int
        let looks: [UserLook]
    }

    public static func readRegistry(at url: URL) throws -> (looks: [UserLook], unreadable: [LookLibraryUnreadableLook]) {
        let bytes = Array(try Data(contentsOf: url))
        // 文件级失败（语法、版本、有效条目重名 ID）仍让整库不可用；单条目损坏只降级这一条。
        guard let root = try? PresetJSONScanner.scan(bytes),
              case let .object(members, _) = root.value,
              case let .number(versionLiteral)? = members.first(where: { $0.key == "version" })?.value.value,
              PresetJSONScanner.isIntegerLiteral(versionLiteral), Int(versionLiteral) == 1,
              case let .array(elements)? = members.first(where: { $0.key == "looks" })?.value.value
        else { throw LookLibraryError.invalidRegistry }
        var looks: [UserLook] = []
        var unreadable: [LookLibraryUnreadableLook] = []
        for element in elements {
            if case .object = element.value,
               let look = try? JSONDecoder().decode(UserLook.self, from: Data(bytes[element.range])),
               Self.isValid(look) {
                looks.append(look)
            } else {
                var id: String?, fileName: String?
                if case let .object(lookMembers, _) = element.value {
                    if case let .string(value)? = lookMembers.first(where: { $0.key == "id" })?.value.value { id = value }
                    if case let .string(value)? = lookMembers.first(where: { $0.key == "fileName" })?.value.value {
                        fileName = value
                    } else if case let .string(value)? = lookMembers.first(where: { $0.key == "file_name" })?.value.value {
                        fileName = value
                    }
                }
                unreadable.append(LookLibraryUnreadableLook(id: id, fileName: fileName,
                    json: String(decoding: bytes[element.range], as: UTF8.self)))
            }
        }
        guard Set(looks.map(\.id)).count == looks.count else { throw LookLibraryError.invalidRegistry }
        return (looks, unreadable)
    }

    public static func isValid(_ look: UserLook) -> Bool {
        UUID(uuidString: look.id) != nil &&
        look.fileName == "\(look.id).\(look.format)" &&
        ((look.format == "cube" && look.formatVersion == 0) ||
         (look.format == "vlt" && look.formatVersion == 1) ||
         (look.format == "rlook" && (1...2).contains(look.formatVersion)))
    }

    public static func encodeRegistry(looks: [UserLook], unreadable: [LookLibraryUnreadableLook]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard !unreadable.isEmpty else {
            return try encoder.encode(Registry(version: 1, looks: looks))
        }
        // 坏条目原文拼接写回；有效条目单独 pretty 编码后按数组缩进并入，保持现行版式。
        var blocks: [Data] = []
        for look in looks { blocks.append(Self.reindent(try encoder.encode(look))) }
        for entry in unreadable { blocks.append(Data(entry.json.utf8)) }
        var out = Data("{\n  \"looks\" : [\n".utf8)
        for (index, block) in blocks.enumerated() {
            out.append(contentsOf: "    ".utf8)
            out.append(block)
            if index < blocks.count - 1 { out.append(UInt8(0x2C)) }
            out.append(UInt8(0x0A))
        }
        out.append(contentsOf: "  ],\n  \"version\" : 1\n}".utf8)
        return out
    }

    // 单条目 pretty 编码从顶层缩进挪到数组元素层级：除首行外每行补四个空格。
    private static func reindent(_ data: Data) -> Data {
        var out = Data()
        for (index, byte) in data.enumerated() {
            out.append(byte)
            if byte == 0x0A, index < data.count - 1 { out.append(contentsOf: "    ".utf8) }
        }
        return out
    }
}
