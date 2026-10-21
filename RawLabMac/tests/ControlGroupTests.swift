import Foundation

@main
struct ControlGroupTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        try hsl()
        try denoise()
        try effects()
        try editorGroups()
        try recipeReset()
        try invalidResetSources()
    }

    private static func hsl() throws {
        var settings = HSLSettings()
        for (axisIndex, axis) in HSLAxis.allCases.enumerated() {
            for channel in 0..<8 {
                let value = Double(axisIndex * 8 + channel + 1) / 10
                settings = MacHSLPrecision.setting(value, axis: axis, channel: channel, in: settings)
            }
        }
        let saved = settings
        let edited = MacHSLPrecision.setting(-12.36, axis: .saturation, channel: 3, in: settings)
        check(edited.saturation[3] == -12.4 && edited.hue == saved.hue && edited.lightness == saved.lightness &&
              edited.saturation.enumerated().allSatisfy { $0.offset == 3 || $0.element == saved.saturation[$0.offset] },
              "Desktop HSL changes one axis and color while retaining all other tenths")
        let restored = try JSONDecoder().decode(HSLSettings.self, from: JSONEncoder().encode(edited))
        check(restored == edited && restored.isValid, "Fractional desktop HSL round-trips in the existing payload")
        check(MacHSLPrecision.setting(1000, axis: .hue, channel: 0, in: saved).hue[0] == 100 &&
              MacHSLPrecision.setting(-1000, axis: .hue, channel: 0, in: saved).hue[0] == -100,
              "Desktop HSL clamps to both bounds")
        check(MacHSLPrecision.setting(.nan, axis: .hue, channel: 0, in: saved) == saved &&
              MacHSLPrecision.setting(.infinity, axis: .hue, channel: 0, in: saved) == saved &&
              MacHSLPrecision.setting(1, axis: .hue, channel: 8, in: saved) == saved,
              "Desktop HSL rejects invalid edits")
        settings.reset(channel: 3)
        check(HSLAxis.allCases.allSatisfy { axis in
            (0..<8).allSatisfy { channel in
                settings.value(axis, channel: channel) == (channel == 3 ? 0 : saved.value(axis, channel: channel))
            }
        }, "Current-color reset preserves fractional edits in other colors")
        settings.reset()
        check(settings.isIdentity, "Whole HSL reset restores identity")
        settings.set(.hue, channel: 0, value: 12.4)
        check(settings.hue[0] == 12, "Shared HSL setter keeps its mobile integer contract")
        var adjustments = Adjustments()
        adjustments.hsl = edited
        let savedAdjustments = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(adjustments))
        check(savedAdjustments.hslSettings == edited, "Photo edit serialization retains fractional desktop HSL")
    }

    private static func denoise() throws {
        var settings = Adjustments()
        settings.applyDenoisePreset(.clean)
        settings.setDenoiseParameter(.luma, to: 11.2)
        settings.setDenoiseParameter(.chroma, to: 48.3)
        settings.setDenoiseParameter(.coarse, to: 50.4)
        let active = settings.waveletSettings
        check(active.luma == 11.2 && active.chroma == 48.3 && active.coarse == 50.4 && active.preset == .custom,
              "All desktop denoise parameters retain tenths and mark the preset custom")
        settings.setDenoiseEnabled(false)
        check(!settings.waveletSettings.enabled && settings.waveletSettings.luma == active.luma &&
              settings.waveletSettings.chroma == active.chroma && settings.waveletSettings.coarse == active.coarse &&
              settings.waveletSettings.preset == .custom, "Disabling denoise retains all custom values")
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        check(restored == settings, "Disabled fractional denoise round-trips in photo edits")
        settings.setDenoiseEnabled(true)
        check(settings.waveletSettings == active, "Re-enabling denoise restores the same custom strengths")
        settings.setDenoiseParameter(.chroma, to: DenoiseParameter.chroma.defaultValue)
        check(settings.waveletSettings.chroma == 46 && settings.waveletSettings.luma == 11.2 &&
              settings.waveletSettings.coarse == 50.4 && settings.waveletSettings.enabled,
              "One denoise parameter reset preserves the others and enable state")
        settings.setEffect(.grainAmount, to: 15.6)
        settings.set(.denoiseMode, to: 0)
        check(settings.waveletNoiseReduction == nil && settings.denoiseMode == 0 && settings.grainAmount == 15.6,
              "Denoise group reset preserves unrelated effects")
        settings.rawNoiseReduction = 2
        check(settings.hasLegacyDenoise && settings.denoiseMode == 3, "Legacy FBDD remains selected until migration")
        settings.applyDenoisePreset(.detail)
        check(!settings.hasLegacyDenoise && settings.rawNoiseReduction == 0 && settings.waveletSettings.enabled,
              "Explicit preset migrates the legacy algorithm")
    }

    private static func effects() throws {
        var settings = Adjustments()
        settings.setEffect(.vignetteAmount, to: -24.3)
        settings.setEffect(.vignetteMidpoint, to: 51.2)
        settings.setEffect(.vignetteRoundness, to: -8.7)
        settings.setEffect(.vignetteFeather, to: 48.1)
        settings.setEffect(.vignetteHighlights, to: 12.6)
        settings.setEffect(.grainAmount, to: 15.7)
        settings.setEffect(.grainSize, to: 28.9)
        settings.setEffect(.grainRoughness, to: 53.4)
        let active = settings.effectSettings
        check(active.vignetteAmount == -24.3 && active.vignetteMidpoint == 51.2 &&
              active.vignetteRoundness == -8.7 && active.vignetteFeather == 48.1 && active.vignetteHighlights == 12.6 &&
              active.grainAmount == 15.7 && active.grainSize == 28.9 && active.grainRoughness == 53.4,
              "All desktop effect parameters retain tenths")
        settings.setEffect(.vignetteAmount, to: 0)
        settings.setEffect(.grainAmount, to: 0)
        check(settings.effectSettings.vignetteMidpoint == active.vignetteMidpoint &&
              settings.effectSettings.vignetteHighlights == active.vignetteHighlights &&
              settings.effectSettings.grainSize == active.grainSize && settings.effectSettings.grainRoughness == active.grainRoughness,
              "Zero intensity retains auxiliary effect values")
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        check(restored == settings, "Zero intensity and fractional auxiliary values round-trip")
        settings.setEffect(.vignetteMidpoint, to: PhotoEffectParameter.vignetteMidpoint.defaultValue)
        check(settings.effectSettings.vignetteMidpoint == 50 && settings.effectSettings.vignetteRoundness == -8.7 &&
              settings.effectSettings.grainSize == 28.9, "One effect parameter reset preserves the others")
        settings.resetEffect(.vignetteAmount)
        check(settings.isEffectDefault(.vignetteAmount) && settings.effectSettings.grainSize == 28.9 &&
              settings.effectSettings.grainRoughness == 53.4, "Whole vignette reset preserves grain settings")
        settings.resetEffect(.grainAmount)
        check(settings.photoEffects == nil && settings.isEffectDefault(.grainAmount), "Whole grain reset restores canonical effect defaults")
    }

    private static let rawContext = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, neutralFilmID: "neutral")

    private static func state(_ settings: Adjustments = Adjustments()) -> PhotoEditState {
        PhotoEditState(settings: settings, filmID: "neutral", masterRecipeID: settings.masterRecipeID)
    }

    private static func candidate(_ scope: EditorResetScope, _ snapshot: PhotoEditState,
                                  context: EditorAdjustmentContext = rawContext) -> PhotoEditState {
        guard case .candidate(let result) = EditorAdjustmentRules.prepareReset(scope: scope, snapshot: snapshot, context: context) else {
            fatalError("Expected reset candidate for \(scope)")
        }
        return result
    }

    private static func coreValues(_ settings: Adjustments) -> [Float] {
        var request = sony2fuji_request()
        settings.apply(to: &request)
        return [Float(request.wb_mode.rawValue), request.exposure_ev, request.brightness, request.temperature,
                request.tint, request.contrast, request.highlights, request.shadows, request.saturation,
                request.tone_curve, request.sharpening] +
            (settings.renderHSLSettings.hue + settings.renderHSLSettings.saturation + settings.renderHSLSettings.lightness).map(Float.init)
    }

    private static func editorGroups() throws {
        check(EditorAdjustmentGroup.allCases.map(\.rawValue) == ["looks", "light", "color", "effects", "detail", "geometry"],
              "Editor group IDs are stable and independent of the old eight groups")
        let neutral = state()
        check(EditorAdjustmentGroup.allCases.allSatisfy {
            !EditorAdjustmentRules.isModified(scope: .group($0), snapshot: neutral, context: rawContext)
        }, "Neutral RAW settings have no group markers")
        if case .unchanged = EditorAdjustmentRules.prepareReset(scope: .all, snapshot: neutral, context: rawContext) {
            check(true, "No-op reset creates no candidate")
        } else { check(false, "No-op reset creates no candidate") }
        var source = neutral
        source.settings.exposure = 1.25; source.settings.saturation = 23.4
        source.settings.photoEffects = PhotoEffectsSettings(vignetteMidpoint: 68.2, grainSize: 42.1)
        source.settings.waveletNoiseReduction = WaveletDenoiseSettings(luma: 12.3, preset: .custom)
        source.settings.lensCorrection = LensCorrectionSettings(autoCrop: false, mode: .manual, profileID: "lens")
        source.settings.geometry = GeometrySettings()
        source.settings.geometry?.flipHorizontal = true
        source.settings.hsl = MacHSLPrecision.setting(12.4, axis: .hue, channel: 0, in: HSLSettings())
        source.settings.hsl = MacHSLPrecision.setting(-8.7, axis: .saturation, channel: 1, in: source.settings.hslSettings)
        for group in [EditorAdjustmentGroup.light, .color, .effects, .detail, .geometry] {
            check(EditorAdjustmentRules.isModified(scope: .group(group), snapshot: source, context: rawContext),
                  "\(group) includes stored auxiliary values even when disabled")
        }
        let light = candidate(.group(.light), source)
        var expected = source; expected.settings.exposure = 0
        check(light == expected, "Light reset preserves every unrelated object")
        let geometry = candidate(.group(.geometry), source)
        expected = source; expected.settings.geometry = nil; expected.settings.lensCorrection = nil
        check(geometry == expected, "Geometry reset includes the complete lens object")
        let detail = candidate(.group(.detail), source)
        expected = source; expected.settings.waveletNoiseReduction = nil
        check(detail == expected, "Detail reset removes disabled custom denoise without touching other groups")
        let effects = candidate(.group(.effects), source)
        expected = source; expected.settings.photoEffects = nil
        check(effects == expected, "Effects reset restores all auxiliary values")
        let channel = candidate(.hslColor(0), source)
        expected = source; expected.settings.hsl?.reset(channel: 0)
        check(channel == expected && channel.settings.hslSettings.saturation[1] == -8.7,
              "Current HSL color reset preserves other fractional channels")
        let hsl = candidate(.hslAll, source)
        expected = source; expected.settings.hsl = nil
        check(hsl == expected, "Whole HSL reset preserves white balance and saturation")
        var legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(legacy.exposureMode == .scene && EditorAdjustmentRules.isModified(scope: .group(.light), snapshot: state(legacy), context: rawContext),
              "Legacy missing exposure mode keeps scene instead of silently adopting the new-photo default")
        legacy.rawNoiseReduction = 2
        let resetLegacy = candidate(.group(.detail), state(legacy))
        check(resetLegacy.settings.rawNoiseReduction == 0 && resetLegacy.settings.waveletNoiseReduction == nil,
              "Reset legacy denoise does not enable a different algorithm")
        let raster = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "neutral")
        let resetRaster = candidate(.all, source, context: raster)
        check(resetRaster.settings.exposureMode == .sensor && resetRaster.filmID == "neutral",
              "Full raster reset uses the existing sensor default")
        check(source.settings.exposure == 1.25 && source.settings.hslSettings.hue[0] == 12.4,
              "Preparing candidates never changes the caller snapshot")
    }

    private static func recipeReset() throws {
        for strength in [0.0, 0.5, 1.0, 2.0] {
            var settings = Adjustments()
            settings.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
            settings.applyMasterRecipe(.hamadaDaylightV2)
            settings.hsl = MacHSLPrecision.setting(65.3, axis: .hue, channel: 0, in: settings.hslSettings)
            settings.strength = strength
            var source = state(settings); source.filmID = "recipe-film"
            check(EditorAdjustmentRules.isModified(scope: .group(.light), snapshot: source, context: rawContext) &&
                  EditorAdjustmentRules.isModified(scope: .group(.color), snapshot: source, context: rawContext),
                  "Recipe logical light/color markers remain visible at strength \(strength)")
            let result = candidate(.group(.looks), source)
            check(coreValues(result.settings) == coreValues(source.settings) && result.settings.exposureMode == source.settings.exposureMode,
                  "Appearance reset preserves every non-look core Float and HSL at strength \(strength)")
            check(result.filmID == "neutral" && result.masterRecipeID == nil && result.settings.masterRecipeID == nil && result.settings.strength == 1,
                  "Appearance reset clears all appearance identities together")
            check(try JSONDecoder().decode(PhotoEditState.self, from: JSONEncoder().encode(result)) == result,
                  "Detached recipe candidate survives existing persistence")
            var versionTwo = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
            versionTwo["masterRecipeSettingsVersion"] = 2
            let old = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: versionTwo))
            let detached = candidate(.group(.looks), state(old))
            check(coreValues(detached.settings) == coreValues(old), "Version two HSL is not scaled a second time at \(strength)")
        }
        var settings = Adjustments()
        settings.applyMasterRecipe(.hamadaDaylightV2)
        if case .blocked(.missingAsShotWhiteBalance) = EditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            check(true, "Missing RAW as-shot calibration blocks relative-tint materialization")
        } else { check(false, "Missing RAW as-shot calibration blocks relative-tint materialization") }
        settings.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
        settings.exposure = 4; settings.strength = 2
        if case .blocked = EditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            check(true, "Unrepresentable 8 EV materialization is blocked instead of clamped")
        } else { check(false, "Unrepresentable 8 EV materialization is blocked instead of clamped") }
        settings.exposure = .nan
        if case .blocked = EditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            check(true, "Nonfinite source values are rejected before conversion")
        } else { check(false, "Nonfinite source values are rejected before conversion") }

        let raster = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "neutral")
        check(!EditorAdjustmentRules.isModified(scope: .group(.light), snapshot: state(), context: raster),
              "Raster effective sensor mode does not mark untouched stored preview mode")
        var rgb = Adjustments()
        rgb.exposureMode = .scene
        rgb.applyMasterRecipe(.hamadaDaylightV2)
        rgb.strength = 0.5
        let rgbResult = candidate(.group(.looks), state(rgb), context: raster)
        check(coreValues(rgbResult.settings.resolvedForRaster) == coreValues(rgb.resolvedForRaster) &&
              rgbResult.settings.exposureMode == .scene && rgbResult.settings.whiteBalanceMode == .asShot,
              "Raster recipe reset preserves actual core values and stored exposure mode without inventing camera WB")
        rgb.tint = 0
        let noCamera = candidate(.group(.looks), state(rgb))
        check(coreValues(noCamera.settings) == coreValues(rgb), "Zero relative tint needs no invented RAW calibration")

        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rgb)) as! [String: Any]
        future["masterRecipeSettingsVersion"] = 4
        let futureSettings = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: future))
        if case .blocked(.invalidSnapshot("masterRecipe")) = EditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(futureSettings), context: rawContext) {
            check(true, "Unknown recipe settings versions are blocked without migration")
        } else { check(false, "Unknown recipe settings versions are blocked without migration") }
        rgb.masterRecipeID = "missing-recipe"
        if case .blocked = EditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(rgb), context: rawContext) {
            check(true, "Unknown recipe identity is not guessed")
        } else { check(false, "Unknown recipe identity is not guessed") }

        var coupled = Adjustments()
        coupled.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 4))
        coupled.applyMasterRecipe(.hamadaDaylightV2)
        coupled.strength = 0.5
        coupled.photoEffects = PhotoEffectsSettings(grainSize: 31)
        coupled.geometry = GeometrySettings()
        coupled.geometry?.flipVertical = true
        coupled.lensCorrection = LensCorrectionSettings(distortion: true)
        coupled.waveletNoiseReduction = WaveletDenoiseSettings(luma: 15, preset: .custom)
        let detached = candidate(.group(.looks), state(coupled))
        check(detached.settings.photoEffects == coupled.photoEffects && detached.settings.geometry == coupled.geometry &&
              detached.settings.lensCorrection == coupled.lensCorrection && detached.settings.waveletNoiseReduction == coupled.waveletNoiseReduction,
              "Recipe detachment preserves exact effect, geometry, lens and denoise snapshots")
        let color = candidate(.group(.color), state(coupled))
        var expected = coupled
        expected.resetWhiteBalance(); expected.saturation = 0; expected.hsl = nil
        check(color.settings == expected && color.settings.strength == 0.5 && color.masterRecipeID == coupled.masterRecipeID,
              "Color reset clears only logical color fields and does not replay the recipe")
        let light = candidate(.group(.light), state(coupled))
        expected = coupled
        expected.exposure = 0; expected.contrast = 0; expected.highlights = 0; expected.shadows = 0; expected.toneCurve = 0
        check(light.settings == expected, "Light reset preserves color values and the recipe scale")
        var selected = state(coupled); selected.filmID = "film"
        let all = candidate(.all, selected)
        check(all.filmID == "neutral" && all.masterRecipeID == nil && all.settings.masterRecipeID == nil &&
              all.settings.asShotWhiteBalance == coupled.asShotWhiteBalance &&
              !EditorAdjustmentRules.isModified(scope: .all, snapshot: all, context: rawContext),
              "Full reset clears external and internal identities while retaining genuine input metadata")
    }

    private static func invalidResetSources() throws {
        var invalid = Adjustments()
        invalid.exposure = 9
        for scope in [EditorResetScope.group(.light), .all] {
            if case .blocked(.invalidSnapshot("exposure")) = EditorAdjustmentRules.prepareReset(scope: scope, snapshot: state(invalid), context: rawContext) {
                check(true, "\(scope) rejects an invalid source instead of silently repairing it")
            } else { check(false, "\(scope) rejects an invalid source instead of silently repairing it") }
        }
        invalid = Adjustments()
        invalid.hsl = try JSONDecoder().decode(HSLSettings.self, from: Data("{\"hue\":[1],\"saturation\":[0],\"lightness\":[0]}".utf8))
        if case .blocked = EditorAdjustmentRules.prepareReset(scope: .hslColor(7), snapshot: state(invalid), context: rawContext) {
            check(true, "Malformed HSL source is blocked before indexing a color")
        } else { check(false, "Malformed HSL source is blocked before indexing a color") }
    }
}
