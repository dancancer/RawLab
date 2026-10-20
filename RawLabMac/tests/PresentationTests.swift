import AppKit

@main
struct PresentationTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func main() throws {
        check(AdjustmentParameter.photoTools.contains { $0.rawValue == "vignetteAmount" },
              "Photo tools include vignette controls")
        check(AdjustmentParameter.photoTools.contains { $0.rawValue == "grainAmount" },
              "Photo tools include film grain controls")
        var effects = Adjustments()
        check(effects.effectSettings == PhotoEffectsSettings() && effects.isDefault(.effects),
              "Photo effects start disabled with canonical defaults")
        effects.setEffect(.vignetteAmount, to: -40)
        effects.setEffect(.vignetteMidpoint, to: 20)
        effects.setEffect(.grainAmount, to: 65)
        effects.setEffect(.grainSize, to: 70)
        let persistedEffects = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(effects))
        check(persistedEffects == effects, "Effect settings persist")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as! [String: Any]
        legacy.removeValue(forKey: "photoEffects")
        let migrated = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated.effectSettings == PhotoEffectsSettings(), "Old edits decode with effects off")
        effects.setEffect(.grainAmount, to: 1000)
        check(effects.grainAmount == 100, "Effect values clamp to slider range")
        effects.setEffect(.grainAmount, to: .nan)
        check(effects.grainAmount == 100, "Nonfinite effects are ignored")
        let config = effects.photoEffectsConfig
        check(config.vignette_amount == -40 && config.vignette_midpoint == 20 &&
              config.grain_amount == 100 && config.grain_size == 70, "All effect fields reach the native config")
        effects.resetEffect(.vignetteAmount)
        check(effects.vignetteAmount == 0 && effects.effectSettings.vignetteMidpoint == 50 && effects.grainAmount == 100,
              "Vignette reset clears its auxiliary controls without touching grain")
        effects.reset(.effects)
        check(effects == Adjustments(), "Effects group reset restores canonical defaults")
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
        check(panel.height(available: 800) == 252, "Adjustment panel starts at its default height")
        panel.selectHeight(288)
        check(panel.height(available: 800) == 288, "Grouped tools request their readable editor height")
        check(AdjustmentPanelLayout.effectsHeight(rows: 1) == 252, "A single effect row keeps the default height")
        check(AdjustmentPanelLayout.effectsHeight(rows: 3) > 252, "Grain rows and their hint get more than the default height")
        panel.selectHeight(AdjustmentPanelLayout.effectsHeight(rows: 5))
        check(panel.height(available: 700) == AdjustmentPanelLayout.effectsHeight(rows: 5),
              "Advanced vignette and its hint fit in a default-size window")
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
        check(tools.filter(\.isWhiteBalance) == [.temperature],
              "White balance has one tool while retaining separate temperature and tint parameters")
        wb.resetWhiteBalance()
        check(wb.isWhiteBalanceDefault, "Unified white balance starts unchanged at the camera baseline")
        wb.set(.tint, to: 35)
        check(!wb.isWhiteBalanceDefault && wb.temperature == 5274,
              "Tint-only edits mark the unified white-balance tool changed")
        wb.resetWhiteBalance()
        check(wb.isWhiteBalanceDefault && wb.tint == 12 && wb.whiteBalanceMode == .asShot,
              "Unified white-balance reset restores both parameters and as-shot mode")
        wb.applyMasterRecipe(.hamadaDaylightV2)
        let recipeID = wb.masterRecipeID
        let recipeExposure = wb.exposure
        wb.set(.temperature, to: 8000)
        wb.set(.tint, to: 35)
        wb.resetWhiteBalance()
        check(wb.isWhiteBalanceDefault && wb.temperature == 5274 && wb.tint == 0 &&
              wb.masterRecipeID == recipeID && wb.exposure == recipeExposure,
              "White-balance group reset keeps the recipe and restores its zero tint offset")
        check(Set(tools) == Set(AdjustmentParameter.allCases.filter { $0 != .strength && $0 != .rawNoiseReduction && $0 != .tint }),
              "Photo tools expose each adjustment group exactly once")
        check(tools.count == 11 && tools.contains(.denoiseMode) && !tools.contains(.rawNoiseReduction),
              "Photo tools replace legacy FBDD with chroma denoising")
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
        let canvas = CGSize(width: 824, height: 624)
        let source = CGSize(width: 6000, height: 4000)
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 1, source: source) == 832,
              "Fit preview uses the image footprint, rounded to stable 64-pixel steps")
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 2, source: source) == 1600,
              "Retina preview requests physical pixels, not points")
        check(viewport.previewLongEdge(canvas: CGSize(width: 424, height: 624), displayScale: 2, source: source) == 832,
              "Split comparison reduces work to the smaller photo pane")
        viewport.zoom(by: 2)
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 2, source: source) == 3200,
              "Zoom requests enough pixels for the enlarged image")
        viewport.actualPixels()
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 2, source: source) == 1600,
              "Pixel-mode dragging stays bounded by the visible canvas")
        viewport.fit()
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 20, source: source) == 6000,
              "Preview never requests more than the source resolution")
        check(viewport.factor(fit: 0.2, displayScale: 2) == 0.2, "Initial canvas fits the image")
        viewport.zoom(by: 1.25)
        check(abs(viewport.factor(fit: 0.2, displayScale: 2) - 0.25) < 0.00001,
              "Zoom starts from the current fit instead of a hard-coded scale")
        check(abs(viewport.factor(fit: 0.05, displayScale: 2) * 8000 - 0.25 * 2000) < 0.001,
              "Loading a full-resolution image preserves the displayed size")
        viewport.actualPixels()
        check(viewport.factor(fit: 0.2, displayScale: 2) == 0.5, "100 percent matches physical pixels on Retina")
        let proxyFactor = viewport.factor(fit: 0.4, displayScale: 2, sourceWidth: 6000, renderedWidth: 1000)
        check(proxyFactor * 1000 == 3000, "Interactive proxy preserves the native 100 percent canvas width")
        viewport.zoom(by: 1.25)
        check(viewport.factor(fit: 0.4, displayScale: 2, sourceWidth: 6000, renderedWidth: 1000) * 1000 == 3750,
              "Interactive proxy preserves manual magnification within pixel mode")
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
        try Data().write(to: folder.appendingPathComponent("sigma.X3F"))
        try Data().write(to: folder.appendingPathComponent("photo.dng"))
        try Data().write(to: folder.appendingPathComponent("photo.ARQ"))
        try Data().write(to: folder.appendingPathComponent("photo.JPG"))
        try Data().write(to: folder.appendingPathComponent("photo.png"))
        try Data().write(to: folder.appendingPathComponent("animation.gif"))
        try Data().write(to: folder.appendingPathComponent("style.cube"))
        try Data().write(to: folder.appendingPathComponent(".hidden.ARW"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let listing = try DirectoryContents.read(folder)
        check(listing.photos.count == 6 && listing.folders.count == 1 &&
              DirectoryContents.rawExtensions.contains("x3f"),
              "Directory browsing exposes RAW/X3F/JPEG/PNG, not hidden files, GIF or LUTs")
        check(listing.folders[0].lastPathComponent == "nested", "Subfolders remain lazy tree nodes")
        let artworkFolder = URL(fileURLWithPath: CommandLine.arguments[1])
        check(FilmArtwork.resourceNames.count == 39, "Every bundled film has packaging artwork")
        let bundledFilms = BundledLook.all.map {
            Film(name: $0.name, url: URL(fileURLWithPath: "/LUTs/" + $0.fileName))
        }
        check(FilmGroup.allCases == [.fuji, .kodak, .other], "Film groups retain Fuji, Kodak, Other order")
        check(bundledFilms.filter { $0.group == .kodak }.count == 24,
              "Kodak contains all 23 G'MIC looks and the separate Ektar v2")
        check(bundledFilms.filter { $0.group == .other }.count == 5,
              "Camera looks stay in Other, separate from Kodak and Fuji")
        for path in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "lutools/flog-2-new"),
                                                               includingPropertiesForKeys: nil)
            where path.pathExtension == "cube" {
            check(Film(name: path.lastPathComponent, url: path).group == .fuji,
                  "Legacy Fuji LUT remains in Fuji: \(path.lastPathComponent)")
        }
        let customFuji = Film(name: "PROVIA", url: URL(fileURLWithPath: "/custom/FLog2_to_PROVIA.cube"), managedID: "custom:fuji")
        let customKodak = Film(name: bundledFilms[0].name, url: bundledFilms[0].url, managedID: "custom:kodak")
        check(customFuji.group == .other && customKodak.group == .other,
              "Imported looks remain in Other even when names or filenames match built-ins")
        check(Film(name: "Unknown", url: URL(fileURLWithPath: "/LUTs/unknown.cube")).group == .other,
              "Unknown looks have a predictable Other fallback")
        let groupedFilms = FilmGroup.allCases.flatMap { group in bundledFilms.filter { $0.group == group } }
        check(groupedFilms.count == bundledFilms.count && Set(groupedFilms.map(\.id)) == Set(bundledFilms.map(\.id)),
              "Flat grouping retains every LUT and its stable identity")
        for name in FilmArtwork.resourceNames.keys.sorted() {
            let directory = FileManager.default.fileExists(atPath: artworkFolder.appendingPathComponent(FilmArtwork.resourceNames[name]! + ".png").path)
                ? artworkFolder : URL(fileURLWithPath: "Shared/BundledLooks/Artwork")
            guard let url = FilmArtwork.url(for: name, in: directory),
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
