import AppKit

enum FilmArtwork {
    static let resourceNames = [
        "PROVIA": "provia", "VELVIA": "velvia", "ASTIA": "astia", "ACROS": "acros",
        "PRO NEG.STD": "pro-neg-std", "CLASSIC NEG.": "classic-neg",
        "ETERNA": "eterna", "ETERNA BB": "eterna-bb",
        "CLASSIC CHROME": "classic-chrome", "REALA ACE": "reala-ace"
    ]
    private static let cache = NSCache<NSString, NSImage>()

    private static func resourceName(for name: String, isCustom: Bool) -> String {
        isCustom ? "custom-look" : resourceNames[name.uppercased()] ?? "custom-look"
    }

    static func url(for name: String, isCustom: Bool = false, in directory: URL) -> URL? {
        let resource = resourceName(for: name, isCustom: isCustom)
        return ["png", "jpg", "jpeg"].map {
            directory.appendingPathComponent(resource).appendingPathExtension($0)
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func image(for name: String, isCustom: Bool = false) -> NSImage? {
        let key = resourceName(for: name, isCustom: isCustom) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("FilmIcons"),
              let file = url(for: name, isCustom: isCustom, in: directory),
              let image = NSImage(contentsOf: file) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
