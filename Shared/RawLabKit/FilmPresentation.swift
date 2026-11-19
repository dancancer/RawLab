import Foundation

public enum EditorLayoutPolicy {
    public static func usesSidePanel(width: Double, height: Double, accessibility: Bool) -> Bool {
        !accessibility && width >= 600 && width > height
    }
}

public struct FilmPresentation {
    public static let artworkNames = [
        "ACROS": "acros", "ASTIA": "astia", "CLASSIC-CHROME": "classic-chrome",
        "CLASSIC-NEG.": "classic-neg", "ETERNA": "eterna", "ETERNA-BB": "eterna-bb",
        "PRO-NEG.STD": "pro-neg-std", "PROVIA": "provia", "REALA-ACE": "reala-ace",
        "VELVIA": "velvia"
    ].merging(Dictionary(uniqueKeysWithValues: BundledLook.all.map { ($0.id.uppercased(), $0.artworkName) })) { _, new in new }
    public let name: String
    public let artworkName: String?
    public let group: FilmGroup

    public init(fileName: String) {
        group = FilmGroup.builtIn(fileName)
        if let look = BundledLook.find(fileName) {
            name = look.name
            artworkName = look.artworkName
            return
        }
        guard let start = fileName.range(of: "_to_", options: .caseInsensitive),
              let end = fileName.range(of: "_BT.709", options: .caseInsensitive)
                ?? fileName.range(of: "_65grid", options: .caseInsensitive),
              start.upperBound < end.lowerBound else {
            name = fileName
            artworkName = nil
            return
        }
        let film = String(fileName[start.upperBound..<end.lowerBound])
        name = film.replacingOccurrences(of: "-", with: " ")
        artworkName = Self.artworkNames[film.uppercased()]
    }
}

public struct Film: Identifiable, Hashable, Sendable {
    public var id: String { managedID ?? url.path }
    public var browserID: String { managedID ?? "builtin:\(url.lastPathComponent)" }
    public let name: String
    public let url: URL
    public var managedID: String?
    public var colorNotice: String?
    public var isCompatibility: Bool
    public var isIndependentRecipe: Bool { id.hasPrefix("recipe-lut:") }

    public init(name: String, url: URL, managedID: String? = nil, colorNotice: String? = nil, isCompatibility: Bool = false) {
        self.name = name
        self.url = url
        self.managedID = managedID
        self.colorNotice = colorNotice
        self.isCompatibility = isCompatibility
    }

    public static func independentRecipe(_ id: String) -> Film? {
        guard id.hasPrefix("recipe-lut:"), let recipe = MasterRecipe.recipe(for: String(id.dropFirst(11))),
              let url = recipe.lutURL() else { return nil }
        return Film(name: L10n.format("%@ · 独立外观", recipe.title), url: url, managedID: id)
    }
    public var group: FilmGroup {
        managedID == nil ? FilmGroup.builtIn(url.lastPathComponent) : .other
    }
    public static func bundled() -> [Film] {
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
