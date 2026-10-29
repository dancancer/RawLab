import Foundation
import Darwin

enum AdjustmentPresetError: Error, Equatable {
    case emptyName, corruptLibrary, unsupportedVersion, changed, identityCollision
    case duplicateName(AdjustmentPreset)
}

struct AdjustmentPreset: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let createdAt: Int64
    let updatedAt: Int64
    let payload: AdjustmentTransferPayload

    enum CodingKeys: String, CodingKey {
        case id, name, payload
        case createdAt = "created_at", updatedAt = "updated_at"
    }
    init(id: String, name: String, createdAt: Int64, updatedAt: Int64, payload: AdjustmentTransferPayload) {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.payload = payload
    }
    init(from decoder: Decoder) throws {
        try PresetCodingKey.requireKeys(decoder, ["id", "name", "created_at", "updated_at", "payload"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        payload = try values.decode(AdjustmentTransferPayload.self, forKey: .payload)
        try validate()
    }
    func validate() throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              !name.isEmpty, name.utf8.elementsEqual(Self.normalizedName(name).utf8), createdAt >= 0, updatedAt >= createdAt,
              payload.source.identifier == "preset:\(id)" else { throw AdjustmentPresetError.corruptLibrary }
        try payload.validate()
    }
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: nameWhitespace).precomposedStringWithCanonicalMapping
    }
    // 固定跨端 trim 集合，不依赖 Foundation、JVM、.NET 各自的默认空白定义。
    private static let nameWhitespace = CharacterSet(charactersIn:
        "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{85}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}" +
        "\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{200B}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
}

final class AdjustmentPresetStore {
    private struct Registry: Codable {
        var version = 1
        var presets: [AdjustmentPreset] = []
        var retiredIDs: [String] = []
        enum CodingKeys: String, CodingKey { case version = "registry_version", presets; case retiredIDs = "retired_ids" }
        init() {}
        init(from decoder: Decoder) throws {
            try PresetCodingKey.requireKeys(decoder, ["registry_version", "presets"], optional: ["retired_ids"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            guard version == 1 else { throw AdjustmentPresetError.unsupportedVersion }
            presets = try values.decode([AdjustmentPreset].self, forKey: .presets)
            retiredIDs = values.contains(.retiredIDs) ? try values.decode([String].self, forKey: .retiredIDs) : []
            guard Set(presets.map(\.id)).count == presets.count,
                  Set(presets.map(\.name)).count == presets.count,
                  Set(retiredIDs).count == retiredIDs.count,
                  retiredIDs.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
                  Set(retiredIDs).isDisjoint(with: presets.map(\.id)) else { throw AdjustmentPresetError.corruptLibrary }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/Presets", isDirectory: true)
    }
    let directory: URL
    private let writeData: (Data, URL) throws -> Void
    private let makeID: () -> String
    private let clock: () -> Int64
    private var file: URL { directory.appendingPathComponent("presets.json") }

    init(directory: URL = AdjustmentPresetStore.defaultDirectory,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.directory = directory; self.writeData = writeData; self.makeID = makeID; self.clock = clock
    }

    func list() throws -> [AdjustmentPreset] { try read().presets }

    func create(name: String, payload: AdjustmentTransferPayload) throws -> AdjustmentPreset {
        let name = try validatedName(name)
        try payload.validate()
        return try withWriteLock {
            var registry = try read()
            try requireAvailableName(name, in: registry)
            var id: String?
            for _ in 0..<8 {
                let candidate = makeID()
                if UUID(uuidString: candidate)?.uuidString.lowercased() == candidate,
                   !registry.retiredIDs.contains(candidate),
                   !registry.presets.contains(where: { $0.id == candidate }) { id = candidate; break }
            }
            guard let id else { throw AdjustmentPresetError.identityCollision }
            let now = max(0, clock())
            let preset = AdjustmentPreset(id: id, name: name, createdAt: now, updatedAt: now,
                payload: try independentPayload(payload, id: id))
            registry.presets.append(preset)
            try write(registry)
            return preset
        }
    }

    func overwrite(_ expected: AdjustmentPreset, payload: AdjustmentTransferPayload) throws -> AdjustmentPreset {
        try update(expected, name: expected.name, payload: payload)
    }

    func rename(_ expected: AdjustmentPreset, name: String) throws -> AdjustmentPreset {
        try update(expected, name: validatedName(name), payload: expected.payload)
    }

    func delete(_ expected: AdjustmentPreset) throws {
        try withWriteLock {
            var registry = try read()
            let index = try matchingIndex(expected, in: registry)
            registry.presets.remove(at: index)
            registry.retiredIDs.append(expected.id)
            try write(registry)
        }
    }

    private func update(_ expected: AdjustmentPreset, name: String, payload: AdjustmentTransferPayload) throws -> AdjustmentPreset {
        let payload = try independentPayload(payload, id: expected.id)
        return try withWriteLock {
            var registry = try read()
            let index = try matchingIndex(expected, in: registry)
            try requireAvailableName(name, in: registry, excluding: expected.id)
            if expected.name == name && expected.payload == payload { return expected }
            guard expected.updatedAt < Int64.max else { throw AdjustmentPresetError.corruptLibrary }
            // 单调时间同时区分短时间内“改名后改回”等旧确认，系统时钟回退也不能复用回执。
            let modified = max(clock(), expected.updatedAt + 1)
            let updated = AdjustmentPreset(id: expected.id, name: name, createdAt: expected.createdAt,
                updatedAt: modified, payload: payload)
            registry.presets[index] = updated
            try write(registry)
            return updated
        }
    }

    private func independentPayload(_ payload: AdjustmentTransferPayload, id: String) throws -> AdjustmentTransferPayload {
        try payload.validate()
        return try .init(source: .init(identifier: "preset:\(id)", isRaw: payload.source.isRaw,
            processingVersion: payload.source.processingVersion, recipe: payload.source.recipe,
            hdrProcessingVersion: payload.source.hdrProcessingVersion), values: payload.values)
    }
    private func matchingIndex(_ expected: AdjustmentPreset, in registry: Registry) throws -> Int {
        guard let index = registry.presets.firstIndex(where: { $0.id == expected.id }),
              registry.presets[index] == expected else { throw AdjustmentPresetError.changed }
        return index
    }
    private func validatedName(_ name: String) throws -> String {
        let value = AdjustmentPreset.normalizedName(name)
        guard !value.isEmpty else { throw AdjustmentPresetError.emptyName }
        return value
    }
    private func requireAvailableName(_ name: String, in registry: Registry, excluding id: String? = nil) throws {
        if let existing = registry.presets.first(where: { $0.id != id && $0.name == name }) {
            throw AdjustmentPresetError.duplicateName(existing)
        }
    }
    private func read() throws -> Registry {
        guard FileManager.default.fileExists(atPath: file.path) else { return Registry() }
        let data = try Data(contentsOf: file)
        do {
            try PresetCodingKey.requireIntegerMetadata(data)
            return try JSONDecoder().decode(Registry.self, from: data)
        }
        catch let error as AdjustmentPresetError { throw error }
        catch AdjustmentTransferError.unsupportedVersion { throw AdjustmentPresetError.unsupportedVersion }
        catch { throw AdjustmentPresetError.corruptLibrary }
    }
    private func write(_ registry: Registry) throws {
        for preset in registry.presets { try preset.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(registry), file)
    }
    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".presets.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

private struct PresetCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func requireKeys(_ decoder: Decoder, _ required: Set<String>, optional: Set<String> = []) throws {
        let values = try decoder.container(keyedBy: Self.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        guard keys.isSuperset(of: required), keys.isSubset(of: required.union(optional)) else { throw AdjustmentPresetError.corruptLibrary }
    }

    static func requireIntegerMetadata(_ data: Data) throws {
        // JSONDecoder 会把部分高精度小数舍入为 Int64；时间和版本只接受整数字面量。
        let bytes = Array(data), keys: Set<String> = ["registry_version", "created_at", "updated_at"]
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        let delimiters = whitespace.union([44, 93, 125])
        var index = 0
        var objectKeys: [Set<String>] = []
        while index < bytes.count {
            // Foundation 也接受尾逗号；持久化合同只接受标准 JSON。
            if bytes[index] == 44 {
                var next = index + 1
                while next < bytes.count && whitespace.contains(bytes[next]) { next += 1 }
                guard next < bytes.count, bytes[next] != 93, bytes[next] != 125 else { throw AdjustmentPresetError.corruptLibrary }
            }
            if bytes[index] == 123 { objectKeys.append([]) }
            if bytes[index] == 125, !objectKeys.isEmpty { objectKeys.removeLast() }
            guard bytes[index] == 34 else { index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count && bytes[index] != 34 {
                index += bytes[index] == 92 ? 2 : 1
            }
            guard index < bytes.count else { throw AdjustmentPresetError.corruptLibrary }
            index += 1
            let end = index
            while index < bytes.count && whitespace.contains(bytes[index]) { index += 1 }
            guard index < bytes.count && bytes[index] == 58 else { continue }
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<end]))
            guard !objectKeys.isEmpty, objectKeys[objectKeys.count - 1].insert(key).inserted else {
                throw AdjustmentPresetError.corruptLibrary
            }
            guard keys.contains(key) else { continue }
            index += 1
            while index < bytes.count && whitespace.contains(bytes[index]) { index += 1 }
            let valueStart = index
            while index < bytes.count && !delimiters.contains(bytes[index]) { index += 1 }
            let token = bytes[valueStart..<index]
            let digits = token.first == 45 ? token.dropFirst() : token[...]
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                  Int64(String(decoding: token, as: UTF8.self)) != nil else { throw AdjustmentPresetError.corruptLibrary }
        }
    }
}
