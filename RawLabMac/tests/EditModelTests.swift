import AppKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

private func rasterFixtureImage() -> CGImage {
    let width = 4, height = 3
    let bytes: [UInt8] = [
        255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255,
        32, 64, 96, 160, 128, 96, 16, 48, 80, 224, 192, 160,
        12, 34, 56, 78, 90, 123, 145, 167, 189, 210, 231, 252
    ]
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                   bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

private func writeRasterFixture(_ image: CGImage, to url: URL, type: CFString) throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: UInt32(6),
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "RawLab Editor Fixture",
            kCGImagePropertyTIFFImageDescription: "editor-raster"
        ]
    ]
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw Failure(message: "cannot create " + url.pathExtension + " ImageIO destination")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure(message: "cannot write " + url.pathExtension + " editor fixture")
    }
}

private func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

@main struct EditModelTests {
    static func waitForRender(_ model: EditorModel, _ label: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try check(!model.busy && model.error == nil && model.result != nil && model.neutral != nil,
                  label + ": EditorModel raster render completes")
    }

    static func waitForFailure(_ model: EditorModel, _ label: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try check(!model.busy && model.result == nil && model.neutral == nil && model.error != nil,
                  label + ": invalid raster clears result and publishes an error")
    }

    static func makeRasterModel(root: URL, lut: URL) -> EditorModel {
        let result = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                                 editDirectory: root.appendingPathComponent("edits"),
                                 batchDirectory: root.appendingPathComponent("batch"))
        result.films = [Film(name: "PROVIA", url: lut)]
        result.selectedFilmID = lut.path
        return result
    }

    static func checkRasterMetadata(_ model: EditorModel, _ label: String) throws {
        guard let neutral = model.neutral, let result = model.result else {
            throw Failure(message: label + ": raster result is missing")
        }
        for (name, frame) in [("neutral", neutral), ("result", result)] {
            try check(frame.image.width == 3 && frame.image.height == 4 &&
                      frame.nativeWidth == 3 && frame.nativeHeight == 4,
                      label + " " + name + ": ImageIO orientation is applied to final dimensions")
            try check(frame.baselineEV == 0 && frame.metadataEV == 0 &&
                      frame.asShotWhiteBalance == nil && !frame.supportsRawNoiseReduction &&
                      frame.lensInfo == nil,
                      label + " " + name + ": raster has zero RAW metadata, no WB/RAW NR/lens state")
        }
    }

    static func rasterEditorChecks(root: URL, lut: URL) throws {
        let fixtureRoot = root.appendingPathComponent("editor-raster")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let image = rasterFixtureImage()
        let jpeg = fixtureRoot.appendingPathComponent("oriented.jpg")
        let png = fixtureRoot.appendingPathComponent("oriented.png")
        try writeRasterFixture(image, to: jpeg, type: "public.jpeg" as CFString)
        try writeRasterFixture(image, to: png, type: "public.png" as CFString)

        let first = makeRasterModel(root: fixtureRoot, lut: lut)
        first.open(jpeg)
        try waitForRender(first, "JPEG open")
        try check(first.selectedFilmID.isEmpty && first.settings.masterRecipeID == nil,
                  "JPEG unseen photo opens with no film or master recipe")
        first.selectFilm(lut.path)
        try checkRasterMetadata(first, "JPEG open")
        let originalPixels = pixels(first.result!.image)

        first.settings.exposure = 0.4
        first.settings.contrast = 36
        first.settings.saturation = -24
        first.settings.setHSL(.hue, channel: 0, value: 31)
        first.settings.setHSL(.lightness, channel: 4, value: -19)
        first.settings.setEffect(.vignetteAmount, to: -42)
        first.settings.setEffect(.grainAmount, to: 37)
        try waitForRender(first, "JPEG tone/HSL/effects edit")
        try check(pixels(first.result!.image) != originalPixels,
                  "JPEG tone/HSL/effects edit changes the actual raster render")
        try check(first.saveEdits(), "JPEG raster edit history saves")
        let saved = first.settings

        let second = makeRasterModel(root: fixtureRoot, lut: lut)
        second.open(png)
        try waitForRender(second, "PNG open in a new EditorModel")
        try check(second.settings.contrast == 0 && second.settings.saturation == 0 &&
                  second.settings.hslSettings.isIdentity && second.settings.effectSettings == PhotoEffectsSettings(),
                  "PNG open does not inherit another raster's edit history")
        try check(second.selectedFilmID.isEmpty && second.settings.masterRecipeID == nil,
                  "PNG unseen photo opens with no film or master recipe")
        try checkRasterMetadata(second, "PNG open")
        second.open(jpeg)
        try waitForRender(second, "JPEG history restore")
        try check(second.settings.exposure == saved.exposure && second.settings.contrast == saved.contrast &&
                  second.settings.saturation == saved.saturation && second.settings.hslSettings == saved.hslSettings &&
                  second.settings.effectSettings == saved.effectSettings && second.selectedFilmID == lut.path &&
                  second.settings.masterRecipeID == nil,
                  "JPEG history restores tone/HSL/effects and the saved film in a new EditorModel")
        try checkRasterMetadata(second, "JPEG history restore")

        let broken = fixtureRoot.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken, options: .atomic)
        let failing = makeRasterModel(root: fixtureRoot, lut: lut)
        failing.open(broken)
        try waitForFailure(failing, "broken PNG open")
        print("PASS: EditorModel raster open, oriented dimensions, metadata isolation, persistence and rejection")
    }

    static func resetTransactionChecks(root: URL, source: URL, otherSource: URL) throws {
        let model = EditorModel(lookDirectory: root.appendingPathComponent("reset-looks"),
                                editDirectory: root.appendingPathComponent("reset-edits"),
                                batchDirectory: root.appendingPathComponent("reset-batch"))
        model.file = source
        // 禁用定时启动，检查真实 scheduler 入队和同步保存，不让占位 RAW 的解码干扰事务。
        model.debounceTimer?.cancel(); model.debounceTimer = nil
        func prepared(_ scope: EditorResetScope) throws -> EditorModel.PreparedReset {
            guard case .prepared(let value) = model.prepareReset(scope: scope) else {
                throw Failure(message: "reset must prepare: \(scope)")
            }
            return value
        }
        try check(model.prepareReset(scope: .group(.light)) == .unchanged &&
                  model.scheduler.latest == nil && model.saveWork == nil && !model.dirty,
                  "unchanged reset creates no render or save request")
        model.updatingMetadata = true
        var invalidEffects = PhotoEffectsSettings(); invalidEffects.grainSize = .nan
        model.settings.photoEffects = invalidEffects
        model.updatingMetadata = false
        guard case .blocked(.adjustment(.invalidSnapshot)) = model.prepareReset(scope: .group(.light)) else {
            throw Failure(message: "invalid disabled effect must block an unrelated reset")
        }
        try check(model.scheduler.latest == nil && model.saveWork == nil && !model.dirty,
                  "invalid complete snapshot cannot enqueue partial reset")
        model.updatingMetadata = true; model.settings.photoEffects = nil; model.updatingMetadata = false
        model.settings.exposure = 1.25
        let snapshot = model.editState(settings: model.settings), revision = model.editRevision
        let request = model.scheduler.latest!.id, save = model.saveWork
        let light = try prepared(.group(.light))
        try check(model.editState(settings: model.settings) == snapshot && model.editRevision == revision &&
                  model.scheduler.latest!.id == request && model.saveWork === save,
                  "preparing a candidate is pure")
        try check(model.commitReset(light) && model.settings.exposure == 0 &&
                  model.scheduler.latest!.id == request + 1 && model.dirty,
                  "reset commits once through the normal edit scheduler")
        try check(!model.commitReset(light), "a consumed revision cannot overwrite a new edit")
        model.settings.exposure = 2
        let stale = try prepared(.group(.light))
        model.settings.saturation = 11
        try check(!model.commitReset(stale) && model.settings.exposure == 2,
                  "old revision is rejected")
        let switched = try prepared(.group(.light))
        model.file = otherSource
        try check(!model.commitReset(switched), "changed source is rejected")
        model.file = source
        let metadata = try prepared(.group(.light)), metadataRevision = model.editRevision
        model.updatingMetadata = true
        model.settings.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 7))
        model.updatingMetadata = false
        try check(model.editRevision == metadataRevision && !model.commitReset(metadata),
                  "same-revision WB metadata change requires preparation again")
        let identity = try prepared(.group(.light))
        try Data("source changed".utf8).write(to: source)
        try check(!model.commitReset(identity), "replaced source file identity is rejected")

        let lut = root.appendingPathComponent("reset.cube")
        try Data("fixture".utf8).write(to: lut)
        model.films = [Film(name: "Reset fixture", url: lut)]
        model.selectFilm(lut.path)
        let keepFilm = try prepared(.group(.light))
        try check(model.commitReset(keepFilm) && model.selectedFilmID == lut.path &&
                  model.editState(settings: model.settings).filmID == "builtin:reset.cube",
                  "ordinary reset preserves UI film ID while persistence keeps storage ID")
        model.selectMasterRecipe(.hamadaDaylightV2)
        let looks = try prepared(.group(.looks))
        let beforeLooks = model.scheduler.latest!.id
        try check(model.commitReset(looks) && model.selectedFilmID.isEmpty &&
                  model.settings.masterRecipeID == nil && model.editState(settings: model.settings).masterRecipeID == nil &&
                  model.scheduler.latest!.id == beforeLooks + 1,
                  "looks reset clears recipe and film together with one request")
        model.selectFilm(lut.path)
        try check(model.commitReset(try prepared(.all)) && model.selectedFilmID.isEmpty &&
                  model.settings.masterRecipeID == nil && model.settings.exposure == 0,
                  "all reset clears every look identity")
        try check(model.saveEdits(), "reset state persists")
        model.settings.setHSL(.hue, channel: 2, value: 25)
        model.settings.setHSL(.hue, channel: 3, value: 30)
        try check(model.commitReset(try prepared(.hslColor(2))) &&
                  model.settings.hslSettings.value(.hue, channel: 2) == 0 &&
                  model.settings.hslSettings.value(.hue, channel: 3) == 30,
                  "HSL color reset preserves other channels")
        try check(model.commitReset(try prepared(.hslAll)) && model.settings.hslSettings.isIdentity,
                  "all HSL reset uses the same transaction")

        var geometry = GeometrySettings(); geometry.cropWidth = 0.75
        var lens = LensCorrectionSettings(); lens.mode = .manual; lens.profileID = "saved-disabled-profile"
        model.geometryDraft = MacGeometryDraft(geometry: geometry, lens: lens)
        try check(model.prepareReset(scope: .all) == .blocked(.geometryDraftActive) &&
                  model.prepareReset(scope: .group(.light)) == .blocked(.geometryDraftActive),
                  "active geometry draft blocks committed and all resets")
        let staleDraftReset = try prepared(.group(.geometry))
        model.geometryDraft!.geometry.cropWidth = 0.5
        try check(!model.commitReset(staleDraftReset) && model.geometryDraftSettings.cropWidth == 0.5,
                  "changed draft requires preparation again even without a committed revision change")
        let draftReset = try prepared(.group(.geometry))
        let committed = model.settings, draftRequest = model.scheduler.latest!.id, oldSave = model.saveWork
        try check(model.commitReset(draftReset) && model.settings == committed &&
                  model.geometryDraftSettings.isIdentity && model.lensDraftSettings == LensCorrectionSettings() &&
                  model.saveWork === oldSave && model.scheduler.latest!.id == draftRequest + 1,
                  "geometry reset updates geometry and disabled lens metadata only in the draft")
        let unchangedRequest = model.scheduler.latest!.id
        try check(model.prepareReset(scope: .group(.geometry)) == .unchanged &&
                  model.scheduler.latest!.id == unchangedRequest && model.saveWork === oldSave,
                  "unchanged draft reset produces no request")
        model.geometryDraft = nil
        model.settings.exposure = 1
        let failed = try prepared(.group(.light))
        let oldSaveWork = model.saveWork
        let directory = root.appendingPathComponent("reset-edits")
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        try check(model.commitReset(failed) && !model.saveEdits() && model.dirty && model.saveError != nil &&
                  model.settings.exposure == 0,
                  "failed reset autosave retains candidate, dirty and visible error")
        oldSaveWork?.perform()
        try check(model.settings.exposure == 0 && model.dirty,
                  "older queued save cannot restore pre-reset state")
        try FileManager.default.removeItem(at: directory)
        try check(model.saveEdits() && !model.dirty && model.saveError == nil &&
                  EditPersistence(directory: directory).state(for: source)?.settings.exposure == 0,
                  "failed reset save can retry the candidate")
        print("PASS: EditorModel reset preparation, stale guards, single commit, draft boundary and retry")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.ARW"), b = root.appendingPathComponent("b.ARW")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        func model() -> EditorModel {
            EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                        editDirectory: root.appendingPathComponent("edits"),
                        batchDirectory: root.appendingPathComponent("batch"))
        }
        try resetTransactionChecks(root: root, source: a, otherSource: b)
        let selection = model()
        selection.settings.exposure = 2
        selection.settings.shadows = -60
        selection.settings.highlights = 80
        selection.settings.contrast = 75
        selection.settings.saturation = 50
        selection.settings.set(.temperature, to: 8000)
        selection.settings.set(.tint, to: 100)
        selection.settings.sharpening = 75
        selection.settings.setEffect(.grainAmount, to: 40)
        selection.selectedFilmID = "PROVIA"
        selection.selectMasterRecipe(.hamadaDaylightV2)
        try check(selection.settings.masterRecipeID == MasterRecipe.hamadaDaylightV2.id && selection.selectedFilmID.isEmpty,
                  "selecting a recipe clears film selection without clearing the recipe")
        try check(selection.settings.exposure == 0.4 && selection.settings.shadows == 20 &&
                  selection.settings.highlights == -15 && selection.settings.contrast == -15 &&
                  selection.settings.saturation == -8 && selection.settings.tint == 5,
                  "applying a recipe overwrites its six adjustment fields")
        try check(selection.settings.temperature == 8000 && selection.settings.sharpening == 75 &&
                  selection.settings.grainAmount == 40, "applying a recipe preserves unrelated adjustments")
        selection.settings.exposure = 1
        selection.selectMasterRecipe(.hamadaDaylightV2)
        try check(selection.settings.exposure == 0.4, "explicitly reapplying the same recipe overwrites manual changes")
        selection.selectedFilmID = ""
        try check(selection.settings.masterRecipeID == nil, "selecting neutral clears an active recipe")
        selection.selectMasterRecipe(.hamadaDaylightV2)
        selection.selectedFilmID = "PROVIA"
        try check(selection.settings.masterRecipeID == nil, "selecting a film clears an active recipe")
        fputs("[EXPECTED RAW FAILURE] EditModelTests.persistence: a.ARW and b.ARW in \(root.path) contain one-byte placeholders, not RAW photos. Their asynchronous decoder rejections are expected; assertion failures are not.\n", stderr)
        let first = model()
        first.open(a)
        first.settings.exposure = 0.75
        try check(first.saveEdits(), "save must succeed")
        first.open(b)
        try check(first.settings.exposure == 0, "unseen photo does not inherit adjustments")
        let second = model()
        second.open(a)
        try check(second.settings.exposure == 0.75, "editor must restore from disk")
        let legacyDirectory = root.appendingPathComponent("legacy-edits")
        let legacyStore = try EditPersistence(directory: legacyDirectory)
        var legacySettings = Adjustments()
        legacySettings.masterRecipeID = MasterRecipe.hamadaDaylightV2.id
        try legacyStore.save(a, state: PhotoEditState(settings: legacySettings, filmID: "",
                                                     masterRecipeID: legacySettings.masterRecipeID))
        let legacyFile = legacyDirectory.appendingPathComponent("edits.json")
        var legacyRegistry = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        var records = legacyRegistry["records"] as! [String: [String: Any]]
        let recordKey = try OriginalFileIdentity(a).path
        var record = records[recordKey]!
        var state = record["state"] as! [String: Any]
        var oldSettings = state["settings"] as! [String: Any]
        oldSettings.removeValue(forKey: "masterRecipeSettingsVersion")
        state["settings"] = oldSettings; record["state"] = state
        records[recordKey] = record; legacyRegistry["records"] = records
        try JSONSerialization.data(withJSONObject: legacyRegistry).write(to: legacyFile)
        func legacyModel() -> EditorModel {
            EditorModel(lookDirectory: root.appendingPathComponent("looks"), editDirectory: legacyDirectory,
                        batchDirectory: root.appendingPathComponent("legacy-batch"))
        }
        let migratedEditor = legacyModel()
        migratedEditor.open(a)
        try check(migratedEditor.settings.exposure == 0.4 && migratedEditor.settings.shadows == 20 &&
                  migratedEditor.settings.tint == 5 && migratedEditor.selectedFilmID.isEmpty,
                  "actual EditorModel restoration migrates an old recipe record")
        migratedEditor.settings.exposure = 0.71
        try check(migratedEditor.saveEdits(), "migrated editor state saves")
        let migratedRestart = legacyModel(); migratedRestart.open(a)
        try check(migratedRestart.settings.exposure == 0.71 && migratedRestart.settings.tint == 5,
                  "editor restart retains migrated manual changes without applying preset deltas twice")
        second.settings.resetAll()
        try check(second.saveEdits(), "reset must save")
        let third = model(); third.open(a)
        try check(third.settings.exposure == 0, "editor restart restores reset")
        third.settings.exposure = 1.25
        let originalB = try Data(contentsOf: b)
        try check(third.applyCurrentSettings(to: [b, b]) == 1, "apply current settings deduplicates targets")
        let applied = model(); applied.open(b)
        try check(applied.settings.exposure == 1.25 && third.file == a && third.settings.exposure == 1.25,
                  "context action persists target settings without opening the target or changing the source")
        try check(try Data(contentsOf: b) == originalB, "apply settings leaves RAW bytes intact")
        let preset = model()
        preset.open(a)
        preset.selectMasterRecipe(.hamadaDaylightV2)
        preset.settings.exposure = 0.6
        preset.settings.setHSL(.hue, channel: 0, value: 37)
        preset.settings.strength = 0.5
        try check(preset.saveEdits(), "preset adjustments save successfully")
        let restoredPreset = model()
        restoredPreset.open(a)
        try check(restoredPreset.settings.masterRecipeID == MasterRecipe.hamadaDaylightV2.id &&
                  restoredPreset.settings.exposure == 0.6 && restoredPreset.settings.shadows == 20 &&
                  restoredPreset.settings.tint == 5 && restoredPreset.settings.hslSettings.value(.hue, channel: 0) == 37 &&
                  restoredPreset.settings.renderHSLSettings.value(.hue, channel: 0) == 18.5 &&
                  restoredPreset.selectedFilmID.isEmpty,
                  "restoring a preset keeps later manual edits instead of reapplying preset defaults")
        let blocked = root.appendingPathComponent("blocked")
        for recipe in MasterRecipe.allRecipes {
            let catalogModel = model()
            catalogModel.open(a)
            catalogModel.selectMasterRecipe(recipe)
            try check(catalogModel.settings.masterRecipeID == recipe.id && catalogModel.selectedFilmID.isEmpty &&
                      catalogModel.settings.tint == recipe.tintDelta && catalogModel.settings.contrast == recipe.contrastDelta &&
                      catalogModel.settings.hslSettings == recipe.hsl,
                      "\(recipe.id): EditorModel applies the catalog entry and clears film")
            catalogModel.settings.exposure = 0.63
            catalogModel.settings.setHSL(.saturation, channel: 4, value: -37)
            try check(catalogModel.saveEdits(), "\(recipe.id): recipe saves")
            let restored = model()
            restored.open(a)
            try check(restored.settings.masterRecipeID == recipe.id && restored.settings.exposure == 0.63 &&
                      restored.settings.saturation == recipe.saturationDelta &&
                      restored.settings.hslSettings.value(.saturation, channel: 4) == -37,
                      "\(recipe.id): editor restoration preserves the recipe and manual change")
        }
        try Data().write(to: blocked)
        let failing = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                                  editDirectory: blocked, batchDirectory: root.appendingPathComponent("batch2"))
        failing.open(a); failing.settings.exposure = 1
        try check(!failing.saveEdits() && failing.saveError != nil, "save failure must be visible")
        failing.open(b)
        try check(failing.file == a && failing.settings.exposure == 1, "failed save must not discard edits on photo switch")
        let repository = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWLAB_TEST_ROOT"] ??
                             FileManager.default.currentDirectoryPath)
        let rasterLUT = repository.appendingPathComponent("lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        try check(FileManager.default.isReadableFile(atPath: rasterLUT.path),
                  "raster EditorModel integration has a real PROVIA LUT")
        try rasterEditorChecks(root: root, lut: rasterLUT)
        print("PASS: EditorModel persistent restore, unseen defaults, reset and failed-save protection")
        if CommandLine.arguments.count > 1 {
            fputs("[RAW SUCCESS REQUIRED] EditModelTests.realRAW: \(CommandLine.arguments[1]) must render successfully; decoder failures for this input are not expected.\n", stderr)
            let live = model()
            live.open(URL(fileURLWithPath: CommandLine.arguments[1]))
            func waitForRender() throws {
                let deadline = Date().addingTimeInterval(120)
                while live.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                try check(!live.busy && live.error == nil && live.result != nil, "real RAW render must complete")
            }
            try waitForRender()
            let original = live.neutral!.image
            try check(live.neutral!.isFullResolution, "original baseline provides native source geometry")
            live.settings.exposure = 1
            try waitForRender()
            try check(live.neutral!.image === original, "exposure must not replace the original image")
            live.settings.set(.temperature, to: 8000)
            try waitForRender()
            try check(live.neutral!.image === original, "white balance must not replace the original image")
            live.updatePreviewLongEdge(1000)
            live.setInteracting(true)
            live.settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 65, chroma: 72, coarse: 100)
            let deadline = Date().addingTimeInterval(60)
            while live.result.map({ max($0.image.width, $0.image.height) }) != 1000 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try check(live.result.map { max($0.image.width, $0.image.height) } == 1000, "interactive proxy long edge must publish while dragging")
            try check(live.neutral!.image === original && !live.result!.isFullResolution,
                      "interactive denoise must retain the same native original")
            live.setInteracting(false)
            try waitForRender()
            try check(live.neutral!.image === original, "exact denoise must retain the same original")
            print("PASS: Original is native and unchanged across exposure, WB and interactive/exact denoise")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            var fieldAppeared = false
            var changedSize = false
            func hasPixelField(_ view: NSView) -> Bool {
                if let field = view as? NSTextField, field.isEditable { return true }
                return view.subviews.contains { hasPixelField($0) }
            }
            let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
                MainActor.assumeIsolated {
                guard let panel = app.modalWindow as? NSSavePanel else { return }
                if !changedSize {
                    live.exportLongEdge = 2048
                    changedSize = true
                } else {
                    fieldAppeared = panel.accessoryView.map { hasPixelField($0) } ?? false
                    panel.cancel(nil)
                    timer.invalidate()
                }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            live.export(png: false)
            timer.invalidate()
            try check(fieldAppeared, "save-panel size accessory must update when the chosen long edge changes")
            print("PASS: Save-panel size accessory updates its numeric input")
        }
    }
}
