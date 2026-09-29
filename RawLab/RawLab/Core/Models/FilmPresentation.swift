import Foundation

struct FilmPresentation {
    static let artworkNames = [
        "ACROS": "acros", "ASTIA": "astia", "CLASSIC-CHROME": "classic-chrome",
        "CLASSIC-NEG.": "classic-neg", "ETERNA": "eterna", "ETERNA-BB": "eterna-bb",
        "PRO-NEG.STD": "pro-neg-std", "PROVIA": "provia", "REALA-ACE": "reala-ace",
        "VELVIA": "velvia"
    ]
    let name: String
    let artworkName: String?

    init(fileName: String) {
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
