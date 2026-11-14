import Foundation
import Darwin

enum AdjustmentPresetError: Error, Equatable {
    case emptyName, corruptLibrary, unsupportedVersion, changed, identityCollision
    // 同名预设可能只是读不懂的坏条目（拿不到可覆盖对象），因此允许 nil。
    case duplicateName(AdjustmentPreset?)
}

// 读不懂的条目：只隔离自己，身份尽力保留，原文逐字节留到可以删除为止。
struct UnreadablePreset: Equatable {
    let id: String?
    let name: String?
    let json: String
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
    private struct Registry {
        var presets: [AdjustmentPreset] = []
        var retiredIDs: [String] = []
        var unreadable: [UnreadablePreset] = []
        init() {}
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
    func listUnreadable() throws -> [UnreadablePreset] { try read().unreadable }

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
                   !registry.presets.contains(where: { $0.id == candidate }),
                   !registry.unreadable.contains(where: { $0.id == candidate }) { id = candidate; break }
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
            // 坏条目仍占用的 ID 不登记 retired：retired ∩ 条目 ID 会让整库下次读取失效。
            if !registry.unreadable.contains(where: { $0.id == expected.id }) { registry.retiredIDs.append(expected.id) }
            try write(registry)
        }
    }

    // 删除读不懂的条目：按 ID + 原文精确匹配，防止误删同名或同 ID 的另一条。
    func delete(_ expected: UnreadablePreset) throws {
        try withWriteLock {
            var registry = try read()
            guard let index = registry.unreadable.firstIndex(where: { $0.id == expected.id && $0.json == expected.json })
            else { throw AdjustmentPresetError.changed }
            let removed = registry.unreadable.remove(at: index)
            // 与 Windows 同守：ID 仍被占用或已在 retired_ids 中都不再追加，重复退休 ID 会废掉整库。
            let stillUsed = registry.presets.contains { $0.id == removed.id } || registry.unreadable.contains { $0.id == removed.id }
            if let id = removed.id, UUID(uuidString: id)?.uuidString.lowercased() == id,
               !stillUsed, !registry.retiredIDs.contains(id) { registry.retiredIDs.append(id) }
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
        // 坏条目的名字保留：宁可提示重名，也不悄悄造出两条同名预设。
        if registry.unreadable.contains(where: { $0.name == name }) { throw AdjustmentPresetError.duplicateName(nil) }
    }
    private func read() throws -> Registry {
        guard FileManager.default.fileExists(atPath: file.path) else { return Registry() }
        let bytes = Array(try Data(contentsOf: file))
        let root: PresetJSONNode
        do { root = try PresetJSONScanner.scan(bytes) }
        catch let error as AdjustmentPresetError { throw error }
        catch { throw AdjustmentPresetError.corruptLibrary }
        // 文件级失败（语法、根结构、版本、retired_ids、有效条目身份冲突）仍让整库不可用。
        guard case let .object(members, ownDuplicate) = root.value, !ownDuplicate else { throw AdjustmentPresetError.corruptLibrary }
        let keys = Set(members.map(\.key))
        guard keys.isSuperset(of: ["registry_version", "presets"]),
              keys.isSubset(of: ["registry_version", "presets", "retired_ids"]) else { throw AdjustmentPresetError.corruptLibrary }
        guard case let .number(versionLiteral)? = members.first(where: { $0.key == "registry_version" })?.value.value,
              PresetJSONScanner.isIntegerLiteral(versionLiteral) else { throw AdjustmentPresetError.corruptLibrary }
        guard Int64(versionLiteral) != nil else { throw AdjustmentPresetError.corruptLibrary }
        guard Int64(versionLiteral) == 1 else { throw AdjustmentPresetError.unsupportedVersion }
        guard case let .array(elements)? = members.first(where: { $0.key == "presets" })?.value.value else { throw AdjustmentPresetError.corruptLibrary }
        var registry = Registry()
        if let retiredNode = members.first(where: { $0.key == "retired_ids" }) {
            guard case let .array(items) = retiredNode.value.value else { throw AdjustmentPresetError.corruptLibrary }
            var ids: [String] = []
            for item in items {
                guard case let .string(value) = item.value, UUID(uuidString: value)?.uuidString.lowercased() == value else { throw AdjustmentPresetError.corruptLibrary }
                ids.append(value)
            }
            guard Set(ids).count == ids.count else { throw AdjustmentPresetError.corruptLibrary }
            registry.retiredIDs = ids
        }
        // 单条目损坏只降级这一条：跳过并计入 unreadable，其余照常可用。
        for element in elements {
            switch decodeEntry(element, bytes) {
            case let .valid(preset): registry.presets.append(preset)
            case let .unreadable(bad): registry.unreadable.append(bad)
            }
        }
        guard Set(registry.presets.map(\.id)).count == registry.presets.count,
              Set(registry.presets.map(\.name)).count == registry.presets.count,
              !registry.presets.contains(where: { registry.retiredIDs.contains($0.id) }) else { throw AdjustmentPresetError.corruptLibrary }
        return registry
    }
    private enum EntryOutcome { case valid(AdjustmentPreset), unreadable(UnreadablePreset) }
    private func decodeEntry(_ element: PresetJSONNode, _ bytes: [UInt8]) -> EntryOutcome {
        var id: String?, name: String?
        if case let .object(members, _) = element.value {
            if case let .string(value)? = members.first(where: { $0.key == "id" })?.value.value { id = value }
            if case let .string(value)? = members.first(where: { $0.key == "name" })?.value.value { name = value }
        }
        if case .object = element.value, !element.hasDuplicateKey, timestampsAreIntegers(element),
           let preset = try? JSONDecoder().decode(AdjustmentPreset.self, from: Data(bytes[element.range])) {
            return .valid(preset)
        }
        return .unreadable(UnreadablePreset(id: id, name: name, json: String(decoding: bytes[element.range], as: UTF8.self)))
    }
    // JSONDecoder 会把高精度小数舍入为 Int64；条目时间只接受整数字面量（Windows 同语义）。
    private func timestampsAreIntegers(_ node: PresetJSONNode) -> Bool {
        switch node.value {
        case let .object(members, _):
            for member in members {
                if member.key == "created_at" || member.key == "updated_at" {
                    guard case let .number(literal) = member.value.value, PresetJSONScanner.isIntegerLiteral(literal) else { return false }
                }
                guard timestampsAreIntegers(member.value) else { return false }
            }
        case let .array(items):
            for item in items { guard timestampsAreIntegers(item) else { return false } }
        case .string, .number, .boolean, .null: break
        }
        return true
    }
    private func write(_ registry: Registry) throws {
        for preset in registry.presets { try preset.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // 有效条目按现行紧凑格式编码；坏条目以原文拼接在末尾，键序与空白逐字节保留。
        var pieces: [Data] = []
        for preset in registry.presets { pieces.append(try encoder.encode(preset)) }
        for bad in registry.unreadable { pieces.append(Data(bad.json.utf8)) }
        var out = Data("{\"presets\":[".utf8)
        for (index, piece) in pieces.enumerated() { if index > 0 { out.append(UInt8(0x2C)) }; out.append(piece) }
        out.append(Data("],\"registry_version\":1,\"retired_ids\":".utf8))
        out.append(try encoder.encode(registry.retiredIDs))
        out.append(UInt8(0x7D))
        try writeData(out, file)
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
}
