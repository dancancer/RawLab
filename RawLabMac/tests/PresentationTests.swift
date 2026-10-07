import AppKit

@main
struct PresentationTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func main() throws {
        let strength = AdjustmentParameter.strength.spec
        check(strength.parse("200") == 2 && strength.parse("250") == 2,
              "Film strength accepts 200 percent and clamps larger input")
        check(strength.value(at: 0) == 0 && strength.value(at: 0.5) == 1 && strength.value(at: 1) == 2,
              "Film strength slider spans zero to 200 percent with 100 at the midpoint")
        check(Adjustments().strength == 1 && strength.defaultValue == 1 && strength.text(1) == "100",
              "Film strength still defaults to 100 percent")
        var filmSettings = Adjustments()
        filmSettings.strength = 2; filmSettings.exposure = 1.25
        filmSettings.reset(.film)
        check(filmSettings.strength == 1 && filmSettings.exposure == 1.25,
              "Film reset restores 100 percent without changing exposure")
        var wb = Adjustments()
        wb.resolveWhiteBalance(WhiteBalance(temperature: 5274, tint: 12))
        check(wb.temperature == 5274 && wb.tint == 12 && wb.whiteBalanceMode == .asShot,
              "RAW controls start at the camera's own white balance")
        wb.set(.temperature, to: 8000)
        check(wb.whiteBalanceMode == .custom && wb.tint == 12, "Kelvin edits enter custom WB without resetting tint")
        wb.resetWhiteBalance()
        check(wb.temperature == 5274 && wb.tint == 12 && wb.whiteBalanceMode == .asShot,
              "White balance reset restores as-shot instead of fixed 6500")
        check(AdjustmentParameter.temperature.spec(for: wb).progress(for: 5274) == 0,
              "Temperature change ring is anchored at as-shot")
        let temperatureSpec = AdjustmentParameter.temperature.spec(for: wb)
        check(abs(temperatureSpec.position(for: temperatureSpec.value(at: 0.5)) - 0.5) < 0.001,
              "Kelvin slider uses a reversible reciprocal-temperature scale")
        wb.whiteBalanceMode = .custom
        var sameWhiteBalance = sony2fuji_request()
        wb.apply(to: &sameWhiteBalance)
        check(sameWhiteBalance.wb_mode == SONY2FUJI_WB_CAMERA,
              "Choosing Custom at the displayed as-shot values does not shift the image")
        var panel = AdjustmentPanelLayout()
        check(panel.height(available: 800) == 260, "Adjustment panel starts at its default height")
        panel.resize(to: 340, available: 800)
        check(panel.height(available: 800) == 340, "Adjustment panel accepts a dragged height")
        panel.collapsed = true
        check(panel.height(available: 800) == 0, "Collapsed adjustments return all space to the canvas")
        panel.collapsed = false
        check(panel.height(available: 800) == 340, "Reopening restores the previous panel height")
        panel.resize(to: 10, available: 620)
        check(panel.height(available: 620) == 220, "Minimum panel size keeps controls usable")
        panel.resize(to: 1000, available: 620)
        check(panel.height(available: 620) <= 310, "Panel resizing preserves half the small window for the canvas")
        let tools = AdjustmentParameter.photoTools
        check(Set(tools) == Set(AdjustmentParameter.allCases.filter { $0 != .strength }),
              "Photo tools expose every image adjustment exactly once")
        check(tools.count == 9, "Nine tonal and color tools, alongside film strength")
        for tool in tools {
            check(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil,
                  "Native symbol exists for \(tool.rawValue)")
        }
        check(AdjustmentParameter.exposure.spec.progress(for: -2) == -0.5,
              "Negative adjustments use counterclockwise signed progress")
        check(AdjustmentParameter.exposure.spec.progress(for: 2) == 0.5,
              "Positive adjustments use clockwise signed progress")
        check(AdjustmentParameter.temperature.spec.progress(for: 2000) == -1 &&
              AdjustmentParameter.temperature.spec.progress(for: 50000) == 1,
              "Asymmetric ranges fill each direction relative to its default")
        var viewport = PhotoViewport()
        check(viewport.factor(fit: 0.2, displayScale: 2) == 0.2, "Initial canvas fits the image")
        viewport.zoom(by: 1.25)
        check(abs(viewport.factor(fit: 0.2, displayScale: 2) - 0.25) < 0.00001,
              "Zoom starts from the current fit instead of a hard-coded scale")
        check(abs(viewport.factor(fit: 0.05, displayScale: 2) * 8000 - 0.25 * 2000) < 0.001,
              "Loading a full-resolution image preserves the displayed size")
        viewport.actualPixels()
        check(viewport.factor(fit: 0.2, displayScale: 2) == 0.5, "100 percent matches physical pixels on Retina")
        viewport.fit()
        check(viewport == PhotoViewport(), "Fit clears manual zoom and pixel mode")
        viewport.toggleActualPixels()
        check(viewport.pixelMode && viewport.magnification == 1 && viewport.factor(fit: 0.1, displayScale: 2) == 0.5,
              "Double click enters 100 percent physical pixels, not a fixed multiple of fit")
        viewport.zoom(by: 1.25)
        viewport.toggleActualPixels()
        check(viewport == PhotoViewport(), "Double click leaves pixel mode and clears manual zoom")
        viewport.zoom(by: 2)
        viewport.toggleActualPixels()
        check(viewport == PhotoViewport(), "Double click returns a manually magnified fit view to fit")
        viewport.zoom(by: 1000)
        check(viewport.magnification == 16, "Zoom has a stable upper bound")
        viewport.zoom(by: 0.00001)
        check(viewport.magnification == 0.1, "Zoom has a stable lower bound")
        var session = PhotoEditSession()
        let first = URL(fileURLWithPath: "/tmp/one.ARW"), second = URL(fileURLWithPath: "/tmp/two.ARW")
        var edited = Adjustments(); edited.exposure = 1.25
        session.save(first, settings: edited, filmID: "ASTIA")
        check(session.state(for: first, defaultFilmID: "PROVIA").settings == edited,
              "Each photo retains its own adjustments while browsing")
        check(session.state(for: second, defaultFilmID: "PROVIA").settings == Adjustments(),
              "A newly selected photo does not inherit another photo's exposure")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("photo.ARW"))
        try Data().write(to: folder.appendingPathComponent("photo.dng"))
        try Data().write(to: folder.appendingPathComponent("photo.ARQ"))
        try Data().write(to: folder.appendingPathComponent("style.cube"))
        try Data().write(to: folder.appendingPathComponent(".hidden.ARW"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let listing = try DirectoryContents.read(folder)
        check(listing.photos.count == 3 && listing.folders.count == 1,
              "Directory browsing exposes RAW files and folders, not hidden files or LUTs")
        check(listing.folders[0].lastPathComponent == "nested", "Subfolders remain lazy tree nodes")
        let artworkFolder = URL(fileURLWithPath: CommandLine.arguments[1])
        check(FilmArtwork.resourceNames.count == 10, "Every bundled film has packaging artwork")
        for name in FilmArtwork.resourceNames.keys.sorted() {
            guard let url = FilmArtwork.url(for: name, in: artworkFolder),
                  let image = NSImage(contentsOf: url) else { fatalError("Missing or invalid artwork: \(name)") }
            check(image.size.width >= 128 && image.size.height >= 128, "Packaging image decodes: \(name)")
            check(url.deletingPathExtension().lastPathComponent == FilmArtwork.resourceNames[name],
                  "Built-in film retains its own package: \(name)")
        }
        let customArtwork = FilmArtwork.url(for: "Panasonic-Vivid", in: artworkFolder)
        check(customArtwork?.lastPathComponent == "custom-look.png",
              "Imported looks receive the default package instead of an empty icon")
        if let customArtwork, let image = NSImage(contentsOf: customArtwork) {
            check(image.size.width >= 128 && image.size.width == image.size.height,
                  "Default imported-look artwork is a decodable square")
        } else {
            check(false, "Default imported-look artwork must decode")
        }
        check(FilmArtwork.url(for: "PROVIA", isCustom: true, in: artworkFolder) == customArtwork,
              "An imported look named after a built-in still uses the custom package")
    }
}
