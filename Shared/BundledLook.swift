import Foundation

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
