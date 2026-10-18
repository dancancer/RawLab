import Foundation

struct Film: Identifiable, Hashable {
    var id: String { managedID ?? url.path }
    let name: String
    let url: URL
    var managedID: String? = nil
    var group: FilmGroup {
        managedID == nil ? FilmGroup.builtIn(url.lastPathComponent) : .other
    }
    static func bundled() -> [Film] {
        let root = Bundle.main.resourceURL!.appendingPathComponent("LUTs")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "cube" }
            .map { Film(name: BundledLook.file($0.lastPathComponent)?.name ?? $0.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "FLog2_to_", with: "")
                .replacingOccurrences(of: "_65grid_V.1.00", with: "")
                .replacingOccurrences(of: "-", with: " "), url: $0) }
            .sorted { $0.name < $1.name }
    }
}
