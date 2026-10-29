import Foundation

struct Film: Identifiable, Hashable {
    var id: String { managedID ?? url.path }
    let name: String
    let url: URL
    var managedID: String? = nil
    var colorNotice: String? = nil
    var isCompatibility = false
    var isIndependentRecipe: Bool { id.hasPrefix("recipe-lut:") }
    static func independentRecipe(_ id: String) -> Film? {
        guard id.hasPrefix("recipe-lut:"), let recipe = MasterRecipe.recipe(for: String(id.dropFirst(11))),
              let url = recipe.lutURL() else { return nil }
        return Film(name: L10n.format("%@ · 独立外观", recipe.title), url: url, managedID: id)
    }
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
