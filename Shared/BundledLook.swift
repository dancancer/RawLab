import Foundation

enum FilmGroup: String, CaseIterable {
    case fuji, kodak, other

    static func builtIn(_ fileName: String) -> Self {
        let id = fileName.hasSuffix(".cube") ? String(fileName.dropLast(5)) : fileName
        if let look = BundledLook.find(id) {
            return look.id.hasPrefix("RawLab_look_") || look.id == "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65"
                ? .kodak : .other
        }
        return id.hasPrefix("FLog2_to_") || id.hasPrefix("X100VI_FLog2_FGamut_to_") ? .fuji : .other
    }

    static func sections<T>(_ values: [T], group: (T) -> Self) -> [[T]] {
        allCases.map { category in values.filter { group($0) == category } }.filter { !$0.isEmpty }
    }
}

struct BundledLook: Decodable {
    let id: String
    let name: String
    let fileName: String
    let artworkName: String

    static let all: [BundledLook] = {
        let candidates = [
            Bundle.main.url(forResource: "bundled-looks", withExtension: "json"),
            Bundle.main.url(forResource: "catalog", withExtension: "json"),
            Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "BundledLooks"),
            URL(fileURLWithPath: "Shared/BundledLooks/catalog.json")
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: path),
              let entries = try? JSONDecoder().decode([BundledLook].self, from: data),
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.fileName)).count == entries.count else {
            preconditionFailure("Missing or invalid bundled look catalog")
        }
        return entries
    }()

    static func find(_ id: String) -> BundledLook? { all.first { $0.id == id } }
    static func file(_ fileName: String) -> BundledLook? { all.first { $0.fileName == fileName } }
}
