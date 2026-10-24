import Foundation

@main
struct EditMemoryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        let defaultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RawSettings.default)) as! [String: Any]
        check((defaultObject["processing"] as? [String: Any])?["version"] as? Int == 2,
              "new settings persist current processing identity")
        check(PhotoImportFile.sourceKind(for: URL(fileURLWithPath: "/tmp/sigma.X3F"))?.isRaw == true,
              "Sigma X3F imports as RAW even without a system UTI registration")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-edit-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PhotoIdentity(resourceIdentifier: "asset-a")
        let second = PhotoIdentity(resourceIdentifier: "asset-b")
        let sameNameA = root.appendingPathComponent("one/IMG_0001.ARW")
        let sameNameB = root.appendingPathComponent("two/IMG_0001.ARW")
        try FileManager.default.createDirectory(at: sameNameA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sameNameB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: sameNameA)
        try Data("second".utf8).write(to: sameNameB)
        let store = try EditPersistence(directory: root)
        var changed = RawSettings.default
        changed.geometry.cropX = 0.125
        changed.geometry.cropY = 0.25
        changed.geometry.cropWidth = 0.75
        changed.geometry.cropHeight = 0.5
        changed.geometry.quarterTurns = 1
        changed.geometry.flipHorizontal = true
        changed.geometry.straightenDegrees = -4.2
        changed.exposure = 0.75
        changed.exposureMode = .sensor
        changed.hsl.set(.saturation, channel: 0, value: -60)
        changed.whiteBalanceMode = .custom
        changed.temperature = 4250
        changed.denoise = RawDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        changed.photoEffects.vignetteMidpoint = 62
        changed.photoEffects.grainSize = 60
        changed.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false,
                                                       mode: .manual, profileID: "Maker\n镜头 Model,|\nMount\n1.000000")
        try store.save(first, state: PhotoEditState(settings: changed, filmID: "provia"))

        let reopened = try EditPersistence(directory: root)
        check(reopened.state(for: first)?.settings.exposure == 0.75, "edit survives restart")
        check(reopened.state(for: first)?.settings.hsl == changed.hsl && reopened.state(for: first)?.settings.exposureMode == .sensor,
              "HSL and the selected exposure mode survive restart")
        check(reopened.state(for: first)?.settings.geometry == changed.geometry, "geometry survives restart")
        check(RawSettings.default.geometry.isIdentity, "new photos default to identity geometry")
        var invalidGeometry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as! [String: Any]
        invalidGeometry["geometry"] = ["cropX": 0.5, "cropWidth": 0.75]
        do {
            _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: invalidGeometry))
            fatalError("invalid crop was accepted")
        } catch is DecodingError { }
        check(true, "saved geometry rejects crop outside the canvas")
        check(reopened.state(for: first)?.settings.denoise == changed.denoise, "denoise survives restart")
        check(reopened.state(for: first)?.settings.lensCorrection == changed.lensCorrection, "lens configuration survives restart")
        check(LensCorrectionSettings(mode: .manual).coreProfileID == "__rawlab_manual_selection_required__", "manual mode never falls back to automatic")
        check(reopened.state(for: first)?.settings.photoEffects == changed.photoEffects,
              "photo effects auxiliary values survive restart even when amount is zero")
        check(reopened.state(for: first)?.settings.whiteBalanceMode == .custom, "white balance mode survives restart")
        check(reopened.state(for: second) == nil, "unseen photo uses no previous record")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as! [String: Any]
        legacy.removeValue(forKey: "processing")
        legacy.removeValue(forKey: "geometry")
        legacy.removeValue(forKey: "denoise")
        legacy.removeValue(forKey: "photoEffects")
        legacy.removeValue(forKey: "displayChromaDenoise")
        legacy.removeValue(forKey: "hsl")
        legacy.removeValue(forKey: "exposureMode")
        legacy.removeValue(forKey: "lensCorrection")
        let legacySettings = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacySettings.processing == .legacy, "missing identity preserves released processing")
        let resetLegacy = legacySettings.resettingAdjustments()
        check(resetLegacy.processing == .legacy && resetLegacy.exposure == 0 && !resetLegacy.denoise.enabled,
              "reset all preserves legacy processing while clearing adjustments")
        let resetIdentity = PhotoIdentity(resourceIdentifier: "reset-v1")
        try store.save(resetIdentity, state: PhotoEditState(settings: resetLegacy))
        let resetStore = try EditPersistence(directory: root)
        check(resetStore.state(for: resetIdentity)?.settings.processing == .legacy,
              "legacy reset remains legacy after saving and reopening")
        var scopedSource = RawSettings.default
        scopedSource.processing = .legacy
        scopedSource.exposure = 1
        let scopedContext = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .scene,
                                                     cameraTemperature: 5200, cameraTint: 8)
        guard case .candidate(let scopedReset, _) = EditorAdjustmentRules.prepareReset(.all,
            snapshot: PhotoEditState(settings: scopedSource), context: scopedContext) else {
            fatalError("expected legacy reset candidate")
        }
        check(scopedReset.settings.processing == .legacy, "scoped reset all preserves legacy identity")
        try store.save(resetIdentity, state: scopedReset)
        let scopedStore = try EditPersistence(directory: root)
        check(scopedStore.state(for: resetIdentity)?.settings.processing == .legacy,
              "scoped legacy reset survives save and reopen")
        check(reopened.state(for: first)?.settings.processing == .current, "processing identity survives restart")
        for identity: Any in [NSNull(), ["family": "other", "version": 2, "quality": "standard"],
                             ["family": "rawlab", "version": 3, "quality": "standard"],
                             ["family": "rawlab", "version": 2, "quality": "fast"],
                             ["family": "rawlab", "version": 2, "quality": "standard", "future": true]] {
            var invalid = defaultObject
            invalid["processing"] = identity
            do {
                _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: invalid))
                fatalError("invalid processing identity was accepted")
            } catch is DecodingError { }
        }
        check(true, "unknown or null processing identity rejects before rendering")
        check(legacySettings.geometry.isIdentity, "older records default to identity geometry")
        check(legacySettings.denoise == RawDenoiseSettings(), "older records default to disabled denoise")
        check(!legacySettings.lensSettings.isEnabled, "older records default to disabled lens correction")
        check(legacySettings.photoEffects == PhotoEffectsSettings(), "older records default to disabled photo effects")
        check(legacySettings.hsl.isIdentity && legacySettings.exposureMode == .scene, "legacy records preserve scene exposure and no HSL")

        try store.save(sameNameA, state: PhotoEditState(settings: changed))
        var other = RawSettings.default
        other.exposure = -1
        try store.save(sameNameB, state: PhotoEditState(settings: other))
        check(store.state(for: sameNameA)?.settings.exposure == 0.75, "same names in different locations stay separate")
        check(store.state(for: sameNameB)?.settings.exposure == -1, "second same-named input keeps its own record")

        try store.reset(first)
        check(store.state(for: first) == nil, "reset removes the persisted record")
        let failureDirectory = root.appendingPathComponent("failure-store")
        let failureStore = try EditPersistence(directory: failureDirectory)
        try failureStore.save(first, state: PhotoEditState(settings: changed))
        let backup = root.appendingPathComponent("last-good")
        try FileManager.default.moveItem(at: failureDirectory, to: backup)
        try Data("not a directory".utf8).write(to: failureDirectory)
        do {
            try failureStore.save(first, state: PhotoEditState(settings: other))
            fatalError("failed write was accepted")
        } catch { }
        check(failureStore.state(for: first)?.settings == changed, "failed save does not commit in-memory records")
        let lastGood = try EditPersistence(directory: backup)
        check(lastGood.state(for: first)?.settings == changed, "failed replacement preserves previous durable records")
        var manualTint = RawSettings.default.customWhiteBalance(cameraTemperature: 5200, cameraTint: 8)
        manualTint.tint = 12
        check(manualTint.temperature == 5200 && manualTint.whiteBalanceMode == .custom,
              "editing tint from camera WB preserves the camera temperature")
        var manualTemperature = RawSettings.default.customWhiteBalance(cameraTemperature: 5200, cameraTint: 8)
        manualTemperature.temperature = 6000
        check(manualTemperature.tint == 8, "editing temperature preserves the camera tint")
        let retained = try PhotoImportFile.retain(sameNameA)
        try FileManager.default.removeItem(at: sameNameA)
        let retainedBytes = try Data(contentsOf: retained)
        check(retainedBytes == Data("first".utf8), "picker callback owns bytes after provider file expires")
        PhotoImportFile.release(retained)
        check(!FileManager.default.fileExists(atPath: retained.path), "temporary picker ownership is released after use")
        PhotoImportFile.release(sameNameB)
        check(FileManager.default.fileExists(atPath: sameNameB.path), "temporary cleanup never removes unrelated inputs")
        try resetRules()
        print("PASS: edit memory regression suite")
    }
}


extension EditMemoryTests {
    static func resetRules() throws {
        let toolOrder: [(EditorAdjustmentGroup, [EditorToolSelection])] = [
            (.looks, [.film, .recipe, .adjustment(.strength)]),
            (.light, [.adjustment(.exposure), .adjustment(.highlights), .adjustment(.shadows),
                      .adjustment(.blackPoint), .adjustment(.whitePoint), .adjustment(.contrast), .adjustment(.toneCurve)]),
            (.color, [.adjustment(.temperature), .adjustment(.saturation), .adjustment(.vibrance), .adjustment(.hsl), .adjustment(.colorGrading)]),
            (.effects, [.adjustment(.clarity), .adjustment(.dehaze), .adjustment(.vignette), .adjustment(.grain)]),
            (.detail, [.adjustment(.noiseReduction), .adjustment(.sharpening)]),
            (.geometry, [.geometry, .lens])
        ]
        check(toolOrder.map { $0.0 } == EditorAdjustmentGroup.allCases,
              "stable groups follow looks light color effects detail geometry order")
        var visibleTools = [EditorToolSelection]()
        for (group, expectedTools) in toolOrder {
            let tools = EditorAdjustmentRules.tools(group)
            check(tools == expectedTools, "group \(group) preserves visible tool order and default first tool")
            check(tools.allSatisfy { EditorAdjustmentRules.groupFor($0) == group },
                  "visible tools map back to their owning group \(group)")
            visibleTools += tools
        }
        let expectedVisible = Set(AdjustmentKind.toolCases.map(EditorToolSelection.adjustment) + [.film, .recipe, .geometry, .lens])
        check(visibleTools.count == Set(visibleTools).count && Set(visibleTools) == expectedVisible,
              "all visible tools appear exactly once across the six groups")
        check(EditorAdjustmentRules.groupFor(.adjustment(.tint)) == .color &&
              !visibleTools.contains(.adjustment(.tint)),
              "legacy tint maps to color without becoming a second visible WB tool")
        let context = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview,
                                              cameraTemperature: 5200, cameraTint: 8)
        let noCamera = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview)
        let raster = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        let rasterDefault = PhotoEditState(settings: .default)
        for scope in [EditorAdjustmentScope.all, .group(.light), .group(.color)] {
            check(!EditorAdjustmentRules.isModified(scope, snapshot: rasterDefault, context: raster),
                  "raster default has no light color or all marker despite stored preview exposure")
            if case .unchanged = EditorAdjustmentRules.prepareReset(scope, snapshot: rasterDefault, context: raster) {
                check(true, "raster default reset is an effective no-op")
            } else { fatalError("raster default reset unexpectedly produced a candidate") }
        }
        check(!EditorAdjustmentRules.isModified(.tool(.adjustment(.exposure)), snapshot: rasterDefault, context: raster),
              "raster exposure tool ignores disabled stored RAW baseline")
        var rasterWB = RawSettings.default
        rasterWB.whiteBalanceMode = .custom; rasterWB.temperature = 4250; rasterWB.tint = 12
        let rasterCustom = PhotoEditState(settings: rasterWB)
        for scope in [EditorAdjustmentScope.all, .group(.light), .group(.color)] {
            check(!EditorAdjustmentRules.isModified(scope, snapshot: rasterCustom, context: raster),
                  "raster ignores stored custom WB and exposure mode when marking applicable values")
            if case .unchanged = EditorAdjustmentRules.prepareReset(scope, snapshot: rasterCustom, context: raster) {
                check(true, "raster custom WB effective no-op leaves stored values alone")
            } else { fatalError("raster custom WB generated a no-op candidate") }
        }
        var rasterAuxiliary = rasterWB
        rasterAuxiliary.photoEffects.grainSize = 61
        rasterAuxiliary.denoise.chroma = 72
        rasterAuxiliary.lensCorrection = LensCorrectionSettings(mode: .manual, profileID: "disabled-profile")
        for group in [EditorAdjustmentGroup.effects, .detail, .geometry] {
            check(EditorAdjustmentRules.isModified(.group(group), snapshot: PhotoEditState(settings: rasterAuxiliary), context: raster),
                  "raster still marks complete disabled auxiliary objects in \(group)")
        }
        let timestamp = Date(timeIntervalSince1970: 1234)
        func state(_ settings: RawSettings, film: String? = "external") -> PhotoEditState {
            PhotoEditState(settings: settings, filmID: film, updatedAt: timestamp)
        }
        func candidate(_ scope: EditorAdjustmentScope, _ original: PhotoEditState,
                       _ context: EditorAdjustmentContext = context) -> PhotoEditState {
            guard case .candidate(let value, _) = EditorAdjustmentRules.prepareReset(scope, snapshot: original, context: context) else {
                fatalError("expected reset candidate for \(scope)")
            }
            check(value.updatedAt == timestamp, "candidate retains snapshot timestamp")
            return value
        }
        func blocked(_ settings: RawSettings, _ scope: EditorAdjustmentScope = .group(.looks),
                     _ context: EditorAdjustmentContext = noCamera) -> Bool {
            if case .blocked = EditorAdjustmentRules.prepareReset(scope, snapshot: state(settings), context: context) { return true }
            return false
        }
        check(!EditorAdjustmentRules.isModified(.group(.color), snapshot: state(.default, film: nil), context: context),
              "RAW camera WB placeholder fields do not claim adjustment against real calibration")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: state(.default, film: nil), context: context) {
            check(true, "neutral RAW camera snapshot remains unchanged with actual calibration")
        } else { fatalError("neutral RAW produced a save candidate") }
        var settings = RawSettings.default
        settings.exposure = 1; settings.exposureMode = .scene; settings.highlights = -0.25
        settings.shadows = 0.2; settings.contrast = 1.1; settings.toneCurve = 0.3
        settings.saturation = 1.2; settings.whiteBalanceMode = .custom
        settings.temperature = 4250; settings.tint = 12
        settings.hsl = try JSONDecoder().decode(HSLSettings.self, from: Data("{\"hue\":[0.5,1.5,0,0,0,0,0,0],\"saturation\":[2.5,3.5,0,0,0,0,0,0],\"lightness\":[4.5,5.5,0,0,0,0,0,0]}".utf8))
        settings.photoEffects.vignetteMidpoint = 63; settings.photoEffects.grainSize = 61
        settings.denoise = RawDenoiseSettings(enabled: false, luma: 10, chroma: 72, coarse: 100)
        settings.noiseReduction = 0.3; settings.sharpening = 0.4; settings.displayChromaDenoise = 2
        settings.geometry.quarterTurns = 1
        settings.lensCorrection = LensCorrectionSettings(mode: .manual, profileID: "stored-disabled-profile")
        let original = state(settings)
        for group in EditorAdjustmentGroup.allCases {
            check(EditorAdjustmentRules.isModified(.group(group), snapshot: original, context: context), "stored changes mark \(group)")
        }
        let toolExpectations: [(EditorToolSelection, (inout RawSettings) -> Void)] = [
            (.adjustment(.exposure), { $0.exposure = 0; $0.exposureMode = .preview }),
            (.adjustment(.highlights), { $0.highlights = 0 }),
            (.adjustment(.shadows), { $0.shadows = 0 }),
            (.adjustment(.contrast), { $0.contrast = 1 }),
            (.adjustment(.toneCurve), { $0.toneCurve = 0 }),
            (.adjustment(.temperature), { $0.whiteBalanceMode = .camera; $0.temperature = 5200; $0.tint = 8 }),
            (.adjustment(.tint), { $0.whiteBalanceMode = .camera; $0.temperature = 5200; $0.tint = 8 }),
            (.adjustment(.saturation), { $0.saturation = 1 }),
            (.adjustment(.hsl), { $0.hsl = HSLSettings() }),
            (.adjustment(.vignette), { $0.photoEffects.resetVignette() }),
            (.adjustment(.grain), { $0.photoEffects.resetGrain() }),
            (.adjustment(.noiseReduction), { $0.noiseReduction = 0; $0.denoise = RawDenoiseSettings(); $0.displayChromaDenoise = 0 }),
            (.adjustment(.sharpening), { $0.sharpening = 0 }),
            (.geometry, { $0.geometry = GeometrySettings() }),
            (.lens, { $0.lensCorrection = nil })
        ]
        for (tool, resetOwnedFields) in toolExpectations {
            var expected = settings; resetOwnedFields(&expected)
            let reset = candidate(.tool(tool), original)
            check(reset.settings == expected && reset.filmID == original.filmID,
                  "current tool \(tool) resets complete owned fields and preserves every unrelated field")
        }
        for identity in [RawSettings.default.processing, try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8)).processing] {
            var versioned = settings; versioned.processing = identity
            for tool in toolExpectations.map({ $0.0 }) {
                check(candidate(.tool(tool), state(versioned)).settings.processing == identity,
                      "tool reset preserves processing identity")
            }
        }
        check(blocked(settings, .tool(.adjustment(.temperature)), noCamera),
              "WB reset requires actual calibration instead of inventing a camera default")
        var filmOnly = settings; filmOnly.lutID = "provia"; filmOnly.lutStrength = 0.5
        let clearedFilm = candidate(.tool(.film), state(filmOnly))
        var expectedFilm = filmOnly; expectedFilm.lutID = nil
        check(clearedFilm.settings == expectedFilm && clearedFilm.filmID == nil,
              "film-only reset preserves strength and every adjustment")
        let strengthOnly = candidate(.tool(.adjustment(.strength)), state(filmOnly))
        expectedFilm = filmOnly; expectedFilm.lutStrength = 1
        check(strengthOnly.settings == expectedFilm && strengthOnly.filmID == "external",
              "strength-only reset keeps film identity and edits")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.tool(.recipe), snapshot: original, context: context) {
            check(true, "unselected recipe reset is NoChange even when other appearance fields differ")
        } else { fatalError("recipe reset without recipe changed unrelated identity") }
        let light = candidate(.group(.light), original)
        check(light.settings.exposure == 0 && light.settings.exposureMode == .preview && light.settings.contrast == 1 && light.settings.toneCurve == 0 && light.settings.highlights == 0 && light.settings.shadows == 0,
              "light reset restores every owned value and effective exposure default")
        var expected = settings
        expected.exposure = 0; expected.exposureMode = .preview; expected.highlights = 0
        expected.shadows = 0; expected.contrast = 1; expected.toneCurve = 0
        check(light.settings == expected && light.filmID == "external", "light reset preserves all unselected values and identity")
        let color = candidate(.group(.color), original)
        check(color.settings.whiteBalanceMode == .camera && color.settings.temperature == 5200 && color.settings.tint == 8 && color.settings.saturation == 1 && color.settings.hsl.isIdentity, "color reset uses actual camera WB and clears HSL")
        check(color.settings.photoEffects == settings.photoEffects && color.settings.exposureMode == .scene, "color reset preserves effects and legacy exposure mode")
        let effects = candidate(.group(.effects), original)
        check(effects.settings.photoEffects == PhotoEffectsSettings() && effects.settings.denoise == settings.denoise, "effects reset includes disabled auxiliary values")
        let detail = candidate(.group(.detail), original)
        check(detail.settings.denoise == RawDenoiseSettings() && detail.settings.noiseReduction == 0 && detail.settings.displayChromaDenoise == 0 && detail.settings.sharpening == 0, "detail reset clears modern and legacy complete noise settings")
        let geometry = candidate(.group(.geometry), original)
        check(geometry.settings.geometry.isIdentity && geometry.settings.lensCorrection == nil && geometry.settings.hsl == settings.hsl, "geometry reset includes complete disabled lens configuration")
        let channel = candidate(.hslChannel(0), original)
        check(channel.settings.hsl.hue[0] == 0 && channel.settings.hsl.saturation[0] == 0 && channel.settings.hsl.lightness[0] == 0 && channel.settings.hsl.hue[1] == 1.5 && channel.settings.hsl.saturation[1] == 3.5 && channel.settings.hsl.lightness[1] == 5.5,
              "HSL channel reset isolates three axes and preserves other fractional channels")
        check(candidate(.allHSL, original).settings.hsl.isIdentity, "all HSL reset clears 24 values")
        let all = candidate(.all, original)
        var defaults = RawSettings.default; defaults.temperature = 5200; defaults.tint = 8
        check(all.settings == defaults && all.filmID == nil, "all reset restores effective defaults and clears identities")
        let roundTrip = try JSONDecoder().decode(PhotoEditState.self, from: JSONEncoder().encode(channel))
        check(roundTrip == channel, "candidate JSON round trip preserves fractional HSL and timestamp")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: all, context: context) { check(true, "default reset is unchanged") } else { fatalError("default reset changed") }
        var nilFilmJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var lutSettings = settings; lutSettings.lutID = "provia"
        nilFilmJSON["settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lutSettings))
        nilFilmJSON.removeValue(forKey: "filmID")
        let nilFilm = try JSONDecoder().decode(PhotoEditState.self, from: JSONSerialization.data(withJSONObject: nilFilmJSON))
        check(candidate(.allHSL, nilFilm).filmID == nil, "non-look reset preserves explicit nil filmID even with LUT")
        let look = candidate(.group(.looks), nilFilm)
        check(look.filmID == nil && look.settings.lutID == nil && look.settings.masterRecipeID == nil && look.settings.lutStrength == 1 && look.settings.hsl == settings.hsl, "looks clears all identities without touching independent adjustments")
        let recipe = MasterRecipe.allRecipes[0]
        for strength in [0.0, 0.5, 1, 2] {
            var recipeSettings = settings
            recipeSettings.masterRecipeID = recipe.id; recipeSettings.lutID = "also-lut"
            recipeSettings.whiteBalanceMode = .camera; recipeSettings.tint = 3
            recipeSettings.lutStrength = strength
            let result = candidate(.group(.looks), state(recipeSettings), context)
            check(result.settings.exposure == strength && Float(result.settings.contrast) == Float(1 + 0.1 * strength) && result.settings.hsl.hue[0] == 0.5 * strength && result.settings.tint == (strength == 0 ? 0 : 8 + 3 * strength),
                  "looks materializes recipe strength \(strength) with fractional HSL and real WB")
            check(result.settings.masterRecipeID == nil && result.settings.lutID == nil && result.filmID == nil && result.settings.exposureMode == .scene && result.settings.geometry == settings.geometry,
                  "recipe removal clears all look identities and retains other groups")
            check(EditorAdjustmentRules.isModified(.group(.light), snapshot: state(recipeSettings), context: context), "recipe storage remains modified at strength \(strength)")
        }
        var activeRecipe = settings
        activeRecipe.masterRecipeID = recipe.id; activeRecipe.lutStrength = 0.5
        for scope in [EditorAdjustmentScope.tool(.film), .tool(.recipe)] {
            guard case .candidate(let detached, let confirmation) = EditorAdjustmentRules.prepareReset(scope, snapshot: state(activeRecipe), context: context) else {
                fatalError("current look tool must use recipe detach")
            }
            check(confirmation && detached.settings.masterRecipeID == nil && detached.settings.lutID == nil && detached.filmID == nil,
                  "current film and recipe share lossless detach and conversion confirmation")
        }
        var recipeSettings = settings; recipeSettings.masterRecipeID = recipe.id
        check(blocked(recipeSettings), "RAW custom recipe requires real calibration")
        recipeSettings.whiteBalanceMode = .camera; recipeSettings.tint = 1
        check(blocked(recipeSettings), "RAW relative tint recipe requires real calibration")
        check(candidate(.allHSL, state(recipeSettings), noCamera).settings.tint == 1, "unrelated HSL reset does not require camera calibration")
        recipeSettings.tint = 0
        check(candidate(.group(.looks), state(recipeSettings), noCamera).settings.whiteBalanceMode == .camera, "RAW camera zero tint remains calibration-free")
        recipeSettings.whiteBalanceMode = .custom; recipeSettings.tint = 10
        let rasterLook = candidate(.group(.looks), state(recipeSettings), raster)
        check(rasterLook.settings.whiteBalanceMode == recipeSettings.whiteBalanceMode && rasterLook.settings.temperature == recipeSettings.temperature && rasterLook.settings.tint == recipeSettings.tint && rasterLook.settings.noiseReduction == recipeSettings.noiseReduction && rasterLook.settings.lensCorrection == recipeSettings.lensCorrection, "raster materialization retains disabled RAW fields under processor effective constraints")
        recipeSettings.exposure = 4; recipeSettings.lutStrength = 2
        check(blocked(recipeSettings, .group(.looks), context), "unrepresentable scaled exposure blocks without clamping")
        recipeSettings = RawSettings.default; recipeSettings.masterRecipeID = "unknown-recipe"
        check(blocked(recipeSettings, .all), "unknown recipe blocks even all reset")
        for invalid in [Double.nan, Double.infinity, 4.01] {
            var invalidSettings = settings; invalidSettings.exposure = invalid
            check(blocked(invalidSettings, .allHSL), "complete input validation rejects invalid unselected exposure")
        }
        var invalidSettings = settings; invalidSettings.denoise.chroma = 101
        check(blocked(invalidSettings, .group(.light)), "complete validation includes disabled denoise auxiliary values")
        check(blocked(settings, .hslChannel(8)), "invalid channel blocks")
        check(original.settings == settings && original.filmID == "external" && original.updatedAt == timestamp,
              "preparing, discarding and blocking candidates never mutate original snapshot")
        let legacy = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        var legacyNeutral = RawSettings.default
        legacyNeutral.processing = legacy.processing
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: state(legacyNeutral, film: nil), context: context) {
            check(true, "legacy neutral all reset is unchanged")
        } else { fatalError("legacy neutral all reset must preserve identity and avoid save/preview") }
        check(EditorAdjustmentRules.isModified(.group(.light), snapshot: state(legacy, film: nil), context: context),
              "legacy scene differs from the caller's explicit preview default")
        let legacyExposureReset = candidate(.all, state(legacy, film: nil))
        check(legacyExposureReset.settings.exposureMode == .preview && legacyExposureReset.settings.processing == .legacy,
              "all restores explicit preview default while preserving legacy processing")
        var legacyChanged = legacy; legacyChanged.hsl.set(.hue, channel: 1, value: 5)
        check(candidate(.allHSL, state(legacyChanged), noCamera).settings.exposureMode == .scene,
              "legacy missing exposure mode stays scene for unrelated reset")
        var storedRecipe = settings; storedRecipe.masterRecipeID = recipe.id; storedRecipe.lutStrength = 0
        let lightRecipe = candidate(.group(.light), state(storedRecipe), noCamera)
        check(lightRecipe.settings.masterRecipeID == recipe.id && lightRecipe.settings.hsl == settings.hsl &&
              lightRecipe.settings.tint == settings.tint && lightRecipe.settings.lutStrength == 0,
              "light reset at recipe strength zero preserves color and recipe without replay")
        let colorRecipe = candidate(.group(.color), state(storedRecipe), context)
        check(colorRecipe.settings.tint == 0 && colorRecipe.settings.masterRecipeID == recipe.id && colorRecipe.settings.exposure == 1,
              "recipe color reset clears relative tint and leaves light contribution stored")
        storedRecipe.tint = 90; storedRecipe.lutStrength = 2
        storedRecipe.hsl.set(.saturation, channel: 4, value: 75)
        let clamped = candidate(.group(.looks), state(storedRecipe), context)
        check(clamped.settings.tint == 150 && clamped.settings.hsl.saturation[4] == 100,
              "materialization preserves existing native tint and HSL clamp")
        for (key, invalid) in [(\RawSettings.temperature, 1999.0), (\RawSettings.tint, 151.0),
                               (\RawSettings.contrast, 2.01), (\RawSettings.sharpening, -0.01),
                               (\RawSettings.lutStrength, 2.01)] {
            var invalidSettings = settings; invalidSettings[keyPath: key] = invalid
            check(blocked(invalidSettings, .all), "full reset rejects out-of-range input before discarding it")
        }
    }
}
