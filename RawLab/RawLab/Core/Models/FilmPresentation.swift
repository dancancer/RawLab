import Foundation

enum EditorLayoutPolicy {
    static func usesSidePanel(width: Double, height: Double, accessibility: Bool) -> Bool {
        !accessibility && width >= 600 && width > height
    }
}

struct FilmPresentation {
    static let artworkNames = [
        "ACROS": "acros", "ASTIA": "astia", "CLASSIC-CHROME": "classic-chrome",
        "CLASSIC-NEG.": "classic-neg", "ETERNA": "eterna", "ETERNA-BB": "eterna-bb",
        "PRO-NEG.STD": "pro-neg-std", "PROVIA": "provia", "REALA-ACE": "reala-ace",
        "VELVIA": "velvia"
    ].merging(Dictionary(uniqueKeysWithValues: BundledLook.all.map { ($0.id.uppercased(), $0.artworkName) })) { _, new in new }
    let name: String
    let artworkName: String?
    let group: FilmGroup

    init(fileName: String) {
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
