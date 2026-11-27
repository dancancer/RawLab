import Foundation
import XCTest
@testable import RawLabKit
@testable import RawLabNativeTypes

final class MacControlGroupTests: XCTestCase {
    private let rawContext = MacEditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, neutralFilmID: "neutral")

    private func state(_ settings: Adjustments = Adjustments()) -> MacPhotoEditState {
        MacPhotoEditState(settings: settings, filmID: "neutral", masterRecipeID: settings.masterRecipeID)
    }

    private func candidate(
        _ scope: EditorResetScope,
        _ snapshot: MacPhotoEditState,
        context: MacEditorAdjustmentContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MacPhotoEditState {
        guard case .candidate(let result) = MacEditorAdjustmentRules.prepareReset(
            scope: scope,
            snapshot: snapshot,
            context: context ?? rawContext
        ) else {
            XCTFail("Expected reset candidate for \(scope)", file: file, line: line)
            throw NSError(domain: "MacControlGroupTests", code: 1)
        }
        return result
    }

    private func coreValues(_ settings: Adjustments) -> [Float] {
        var request = sony2fuji_request()
        settings.apply(to: &request)
        return [Float(request.wb_mode.rawValue), request.exposure_ev, request.brightness, request.temperature,
                request.tint, request.contrast, request.highlights, request.shadows, request.saturation,
                request.tone_curve, request.sharpening] +
            (settings.renderHSLSettings.hue + settings.renderHSLSettings.saturation + settings.renderHSLSettings.lightness).map(Float.init)
    }

    func testAIDenoise() throws {
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        XCTAssertTrue(!old.aiDenoiseEnabled && !Adjustments().aiDenoiseEnabled, "Missing AI state preserves ordinary rendering")
        var source = Adjustments()
        source.waveletNoiseReduction = WaveletDenoiseSettings(luma: 23, preset: .custom)
        let ordinary = source.waveletNoiseReduction
        source.aiDenoiseEnabled = true
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(source))
        XCTAssertTrue(restored == source && restored.isDenoiseEnabled, "AI enabled state persists with ordinary settings retained")
        XCTAssertTrue(!source.neutralSettings.aiDenoiseEnabled, "Original comparison excludes AI")
        var exposure = source; exposure.exposure = 2; exposure.contrast = 1.2
        XCTAssertTrue(exposure.aiWhiteBalanceSignature == source.aiWhiteBalanceSignature, "Exposure and tone reuse AI results")
        exposure.whiteBalanceMode = .custom; exposure.temperature = 4500
        XCTAssertTrue(exposure.aiWhiteBalanceSignature != source.aiWhiteBalanceSignature, "Effective WB invalidates RGB results")
        source.aiDenoiseEnabled = false
        XCTAssertTrue(source.waveletNoiseReduction == ordinary, "Disabling AI restores retained ordinary settings")
        source.aiDenoiseEnabled = true
        let reset = try candidate(.tool(.denoise), state(source))
        XCTAssertTrue(!reset.settings.aiDenoiseEnabled, "Denoise reset clears AI")
        let detail = try candidate(.group(.detail), state(source))
        XCTAssertTrue(!detail.settings.aiDenoiseEnabled, "Detail reset clears AI")
        source.reset(.detail)
        XCTAssertTrue(!source.aiDenoiseEnabled, "Legacy detail reset clears AI")
    }

    func testCurrentTools() throws {
        XCTAssertTrue(EditorAdjustmentGroup.allCases.map(\.rawValue) == ["looks", "light", "color", "effects", "detail", "geometry", "hdrRendition"], "Seven stable group IDs keep their order")
        XCTAssertTrue(EditorAdjustmentGroup.allCases.map(\.defaultTool) == [.film, .exposure, .whiteBalance, .clarity, .denoise, .geometry, .hdrPeakLimit], "Each group opens its declared default tool")
        XCTAssertTrue(EditorAdjustmentGroup.allCases.flatMap(\.tools).count == 32 && EditorAdjustmentTool.allCases.allSatisfy { $0.group.tools.contains($0) }, "One descriptor owns all thirty-two tools")
        var navigation = EditorAdjustmentNavigation()
        navigation.selectedHSLChannel = 6
        navigation.selectGroup(.color)
        XCTAssertTrue(navigation.tool == .whiteBalance && navigation.expandedGroup == .color, "Switching groups selects the default tool")
        navigation.selectTool(.hsl); navigation.selectGroup(.light); navigation.selectGroup(.color); navigation.selectTool(.hsl)
        XCTAssertTrue(navigation.selectedHSLChannel == 6, "HSL session channel survives group and tool changes")
        navigation.selectGroup(.color)
        XCTAssertTrue(navigation.expandedGroup == nil && navigation.tool == .hsl, "Repeated group click collapses without clearing tool")
        XCTAssertTrue(EditorAdjustmentGroup.visibleGroups(isHDREditing: false) == [.looks, .light, .color, .effects, .detail, .geometry] &&
              !EditorAdjustmentGroup.visibleGroups(isHDREditing: false).contains(.hdrRendition),
              "SDR mode exposes six visible groups and excludes hdrRendition")
        XCTAssertTrue(EditorAdjustmentGroup.visibleGroups(isHDREditing: true) == EditorAdjustmentGroup.allCases,
              "HDR mode exposes all seven groups including hdrRendition")
        navigation.selectedGradingZone = .highlights
        for hdrTool in EditorAdjustmentGroup.hdrRendition.tools {
            navigation.selectTool(hdrTool)
            XCTAssertTrue(navigation.normalized(isHDREditing: true) == navigation,
                  "HDR mode retains \(hdrTool.rawValue) navigation")
            let sdrNormalized = navigation.normalized(isHDREditing: false)
            XCTAssertTrue(sdrNormalized.tool.group != .hdrRendition &&
                  sdrNormalized.expandedGroup != .hdrRendition &&
                  sdrNormalized.tool == .exposure &&
                  sdrNormalized.expandedGroup == .light &&
                  sdrNormalized.selectedHSLChannel == 6 &&
                  sdrNormalized.selectedGradingZone == .highlights,
                  "SDR normalization exits hdrRendition from \(hdrTool.rawValue) while preserving session channels")
        }
        navigation.selectTool(.hdrPeakLimit)
        navigation.selectGroup(.hdrRendition)
        let collapsedNormalized = navigation.normalized(isHDREditing: false)
        XCTAssertTrue(collapsedNormalized.expandedGroup == nil &&
              collapsedNormalized.tool == .exposure &&
              collapsedNormalized.tool.group != .hdrRendition,
              "SDR normalization clears collapsed hdrRendition tool without forcing expansion")
        navigation.selectTool(.hsl)
        XCTAssertTrue(navigation.normalized(isHDREditing: false) == navigation,
              "SDR normalization leaves visible SDR tools untouched")
        var source = Adjustments()
        source.exposure = 1; source.highlights = -0.22; source.sharpening = 0.15
        source.photoEffects = PhotoEffectsSettings(vignetteMidpoint: 12, grainSize: 62)
        source.waveletNoiseReduction = WaveletDenoiseSettings(luma: 23, preset: .custom)
        let exposure = try candidate(.tool(.exposure), state(source))
        var expected = source; expected.exposure = 0
        XCTAssertTrue(exposure.settings == expected, "Current exposure reset preserves the rest of light and other groups")
        let vignette = try candidate(.tool(.vignette), state(source))
        expected = source; expected.resetEffect(.vignetteAmount)
        XCTAssertTrue(vignette.settings == expected, "Vignette tool resets auxiliary fields while retaining grain")
        let denoise = try candidate(.tool(.denoise), state(source))
        expected = source; expected.rawNoiseReduction = 0; expected.chromaNoiseReduction = 0; expected.waveletNoiseReduction = WaveletDenoiseSettings()
        XCTAssertTrue(denoise.settings == expected && denoise.settings.sharpening == 0.15, "Disabled denoise tool reset clears the complete object and preserves sharpening")
        XCTAssertTrue(MacEditorAdjustmentRules.prepareReset(scope: .tool(.recipe), snapshot: state(source), context: rawContext) == .unchanged, "Unselected recipe reset is NoChange")
        source.strength = 0.2
        var selected = state(source); selected.filmID = "film"
        let film = try candidate(.tool(.film), selected)
        XCTAssertTrue(film.filmID == "neutral" && film.settings == source, "Film tool reset preserves independent strength and parameters")
        source.resolveWhiteBalance(WhiteBalance(temperature: 5230, tint: 7))
        source.set(.temperature, to: 7000); source.set(.tint, to: 20)
        let wb = try candidate(.tool(.whiteBalance), state(source))
        expected = source; expected.resetWhiteBalance()
        XCTAssertTrue(wb.settings == expected, "Current WB reset restores mode and both camera parameters while preserving color peers")
        source.processing = .legacy
        let legacy = try candidate(.all, state(source))
        XCTAssertTrue(legacy.settings.processing == .legacy && MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: legacy, context: rawContext) == .unchanged, "All reset retains legacy processing identity and is idempotent")
    }

    func testHSL() throws {
        var settings = HSLSettings()
        for (axisIndex, axis) in HSLAxis.allCases.enumerated() {
            for channel in 0..<8 {
                let value = Double(axisIndex * 8 + channel + 1) / 10
                settings = MacHSLPrecision.setting(value, axis: axis, channel: channel, in: settings)
            }
        }
        let saved = settings
        let edited = MacHSLPrecision.setting(-12.36, axis: .saturation, channel: 3, in: settings)
        XCTAssertTrue(edited.saturation[3] == -12.4 && edited.hue == saved.hue && edited.lightness == saved.lightness &&
              edited.saturation.enumerated().allSatisfy { $0.offset == 3 || $0.element == saved.saturation[$0.offset] },
              "Desktop HSL changes one axis and color while retaining all other tenths")
        let restored = try JSONDecoder().decode(HSLSettings.self, from: JSONEncoder().encode(edited))
        XCTAssertTrue(restored == edited && restored.isValid, "Fractional desktop HSL round-trips in the existing payload")
        XCTAssertTrue(MacHSLPrecision.setting(1000, axis: .hue, channel: 0, in: saved).hue[0] == 100 &&
              MacHSLPrecision.setting(-1000, axis: .hue, channel: 0, in: saved).hue[0] == -100,
              "Desktop HSL clamps to both bounds")
        XCTAssertTrue(MacHSLPrecision.setting(.nan, axis: .hue, channel: 0, in: saved) == saved &&
              MacHSLPrecision.setting(.infinity, axis: .hue, channel: 0, in: saved) == saved &&
              MacHSLPrecision.setting(1, axis: .hue, channel: 8, in: saved) == saved,
              "Desktop HSL rejects invalid edits")
        settings.reset(channel: 3)
        XCTAssertTrue(HSLAxis.allCases.allSatisfy { axis in
            (0..<8).allSatisfy { channel in
                settings.value(axis, channel: channel) == (channel == 3 ? 0 : saved.value(axis, channel: channel))
            }
        }, "Current-color reset preserves fractional edits in other colors")
        settings.reset()
        XCTAssertTrue(settings.isIdentity, "Whole HSL reset restores identity")
        settings.set(.hue, channel: 0, value: 12.4)
        XCTAssertTrue(settings.hue[0] == 12, "Shared HSL setter keeps its mobile integer contract")
        var adjustments = Adjustments()
        adjustments.hsl = edited
        let savedAdjustments = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(adjustments))
        XCTAssertTrue(savedAdjustments.hslSettings == edited, "Photo edit serialization retains fractional desktop HSL")
    }

    func testDenoise() throws {
        var settings = Adjustments()
        settings.applyDenoisePreset(.clean)
        settings.setDenoiseParameter(.luma, to: 11.2)
        settings.setDenoiseParameter(.chroma, to: 48.3)
        settings.setDenoiseParameter(.coarse, to: 50.4)
        let active = settings.waveletSettings
        XCTAssertTrue(active.luma == 11.2 && active.chroma == 48.3 && active.coarse == 50.4 && active.preset == .custom,
              "All desktop denoise parameters retain tenths and mark the preset custom")
        settings.setDenoiseEnabled(false)
        XCTAssertTrue(!settings.waveletSettings.enabled && settings.waveletSettings.luma == active.luma &&
              settings.waveletSettings.chroma == active.chroma && settings.waveletSettings.coarse == active.coarse &&
              settings.waveletSettings.preset == .custom, "Disabling denoise retains all custom values")
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored == settings, "Disabled fractional denoise round-trips in photo edits")
        settings.setDenoiseEnabled(true)
        XCTAssertTrue(settings.waveletSettings == active, "Re-enabling denoise restores the same custom strengths")
        settings.setDenoiseParameter(.chroma, to: DenoiseParameter.chroma.defaultValue)
        XCTAssertTrue(settings.waveletSettings.chroma == 46 && settings.waveletSettings.luma == 11.2 &&
              settings.waveletSettings.coarse == 50.4 && settings.waveletSettings.enabled,
              "One denoise parameter reset preserves the others and enable state")
        settings.setEffect(.grainAmount, to: 15.6)
        settings.set(.denoiseMode, to: 0)
        XCTAssertTrue(settings.waveletNoiseReduction == WaveletDenoiseSettings() && settings.denoiseMode == 0 && settings.grainAmount == 15.6,
              "Denoise group reset preserves unrelated effects")
        settings.rawNoiseReduction = 2
        XCTAssertTrue(settings.hasLegacyDenoise && settings.denoiseMode == 3, "Legacy FBDD remains selected until migration")
        settings.applyDenoisePreset(.detail)
        XCTAssertTrue(!settings.hasLegacyDenoise && settings.rawNoiseReduction == 0 && settings.waveletSettings.enabled,
              "Explicit preset migrates the legacy algorithm")
    }

    func testEffects() throws {
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
        XCTAssertTrue(active.vignetteAmount == -24.3 && active.vignetteMidpoint == 51.2 &&
              active.vignetteRoundness == -8.7 && active.vignetteFeather == 48.1 && active.vignetteHighlights == 12.6 &&
              active.grainAmount == 15.7 && active.grainSize == 28.9 && active.grainRoughness == 53.4,
              "All desktop effect parameters retain tenths")
        settings.setEffect(.vignetteAmount, to: 0)
        settings.setEffect(.grainAmount, to: 0)
        XCTAssertTrue(settings.effectSettings.vignetteMidpoint == active.vignetteMidpoint &&
              settings.effectSettings.vignetteHighlights == active.vignetteHighlights &&
              settings.effectSettings.grainSize == active.grainSize && settings.effectSettings.grainRoughness == active.grainRoughness,
              "Zero intensity retains auxiliary effect values")
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored == settings, "Zero intensity and fractional auxiliary values round-trip")
        settings.setEffect(.vignetteMidpoint, to: PhotoEffectParameter.vignetteMidpoint.defaultValue)
        XCTAssertTrue(settings.effectSettings.vignetteMidpoint == 50 && settings.effectSettings.vignetteRoundness == -8.7 &&
              settings.effectSettings.grainSize == 28.9, "One effect parameter reset preserves the others")
        settings.resetEffect(.vignetteAmount)
        XCTAssertTrue(settings.isEffectDefault(.vignetteAmount) && settings.effectSettings.grainSize == 28.9 &&
              settings.effectSettings.grainRoughness == 53.4, "Whole vignette reset preserves grain settings")
        settings.resetEffect(.grainAmount)
        XCTAssertTrue(settings.photoEffects == nil && settings.isEffectDefault(.grainAmount), "Whole grain reset restores canonical effect defaults")
    }

    func testEditorGroups() throws {
        XCTAssertTrue(EditorAdjustmentGroup.allCases.map(\.rawValue) == ["looks", "light", "color", "effects", "detail", "geometry", "hdrRendition"],
              "Editor group IDs are stable and independent of the old eight groups")
        let neutral = state()
        XCTAssertTrue(EditorAdjustmentGroup.allCases.allSatisfy {
            !MacEditorAdjustmentRules.isModified(scope: .group($0), snapshot: neutral, context: rawContext)
        }, "Neutral RAW settings have no group markers")
        if case .unchanged = MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: neutral, context: rawContext) {
            XCTAssertTrue(true, "No-op reset creates no candidate")
        } else { XCTFail("No-op reset creates no candidate") }
        var source = neutral
        source.settings.exposure = 1.25; source.settings.saturation = 1.234
        source.settings.photoEffects = PhotoEffectsSettings(vignetteMidpoint: 68.2, grainSize: 42.1)
        source.settings.waveletNoiseReduction = WaveletDenoiseSettings(luma: 12.3, preset: .custom)
        source.settings.lensCorrection = LensCorrectionSettings(autoCrop: false, mode: .manual, profileID: "lens")
        source.settings.geometry = GeometrySettings()
        source.settings.geometry?.flipHorizontal = true
        source.settings.hsl = MacHSLPrecision.setting(12.4, axis: .hue, channel: 0, in: HSLSettings())
        source.settings.hsl = MacHSLPrecision.setting(-8.7, axis: .saturation, channel: 1, in: source.settings.hslSettings)
        for group in [EditorAdjustmentGroup.light, .color, .effects, .detail, .geometry] {
            XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .group(group), snapshot: source, context: rawContext),
                  "\(group) includes stored auxiliary values even when disabled")
        }
        let light = try candidate(.group(.light), source)
        var expected = source; expected.settings.exposure = 0
        XCTAssertTrue(light == expected, "Light reset preserves every unrelated object")
        let geometry = try candidate(.group(.geometry), source)
        expected = source; expected.settings.geometry = nil; expected.settings.lensCorrection = nil
        XCTAssertTrue(geometry == expected, "Geometry reset includes the complete lens object")
        let detail = try candidate(.group(.detail), source)
        expected = source; expected.settings.waveletNoiseReduction = WaveletDenoiseSettings()
        XCTAssertTrue(detail == expected, "Detail reset removes disabled custom denoise without touching other groups")
        let effects = try candidate(.group(.effects), source)
        expected = source; expected.settings.photoEffects = nil
        XCTAssertTrue(effects == expected, "Effects reset restores all auxiliary values")
        let channel = try candidate(.hslColor(0), source)
        expected = source; expected.settings.hsl?.reset(channel: 0)
        XCTAssertTrue(channel == expected && channel.settings.hslSettings.saturation[1] == -8.7,
              "Current HSL color reset preserves other fractional channels")
        let hsl = try candidate(.hslAll, source)
        expected = source; expected.settings.hsl = nil
        XCTAssertTrue(hsl == expected, "Whole HSL reset preserves white balance and saturation")

        var colorSci = source
        colorSci.settings.calibrationSettings.shadowTint = -25
        colorSci.settings.calibrationSettings.redHue = 18
        colorSci.settings.pointColorSettings = PointColorSettings(swatches: [PointColorSwatch(srcHue: 25, srcSaturation: 0.4, srcLuminance: 0.6, hueShift: 10, variance: -40)])
        colorSci.settings.selectiveColorSettings.bands.reds.cyan = 15
        colorSci.settings.bwMixerSettings.enabled = true
        colorSci.settings.bwMixerSettings.mixer.red = 30
        for tool in [EditorAdjustmentTool.cameraCalibration, .pointColor, .selectiveColor, .bwMixer] {
            XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .tool(tool), snapshot: colorSci, context: rawContext), "\(tool) marks modified")
            let cleared = try candidate(.tool(tool), colorSci)
            XCTAssertTrue(!MacEditorAdjustmentRules.isModified(scope: .tool(tool), snapshot: cleared, context: rawContext), "\(tool) tool reset clears owned state")
        }
        let clearedColor = try candidate(.group(.color), colorSci)
        XCTAssertTrue(clearedColor.settings.calibrationSettings.isDefault &&
              clearedColor.settings.pointColorSettings.isDefault &&
              clearedColor.settings.selectiveColorSettings.isDefault &&
              clearedColor.settings.bwMixerSettings.isDefault,
              "Color group reset clears all Track A color science controls")
        var legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.exposureMode == .scene && MacEditorAdjustmentRules.isModified(scope: .group(.light), snapshot: state(legacy), context: rawContext),
              "Legacy missing exposure mode keeps scene instead of silently adopting the new-photo default")
        legacy.rawNoiseReduction = 2
        let resetLegacy = try candidate(.group(.detail), state(legacy))
        XCTAssertTrue(resetLegacy.settings.rawNoiseReduction == 0 && resetLegacy.settings.waveletNoiseReduction == WaveletDenoiseSettings(),
              "Reset legacy denoise does not enable a different algorithm")
        let raster = MacEditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "neutral")
        let resetRaster = try candidate(.all, source, context: raster)
        XCTAssertTrue(resetRaster.settings.exposureMode == .sensor && resetRaster.filmID == "neutral",
              "Full raster reset uses the existing sensor default")
        XCTAssertTrue(source.settings.exposure == 1.25 && source.settings.hslSettings.hue[0] == 12.4,
              "Preparing candidates never changes the caller snapshot")
    }

    func testRecipeReset() throws {
        for strength in [0.0, 0.5, 1.0, 2.0] {
            var settings = Adjustments()
            settings.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
            settings.applyMasterRecipe(.hamadaDaylightV2)
            settings.hsl = MacHSLPrecision.setting(65.3, axis: .hue, channel: 0, in: settings.hslSettings)
            settings.strength = strength
            var source = state(settings); source.filmID = "recipe-film"
            XCTAssertTrue(MacEditorAdjustmentRules.isModified(scope: .group(.light), snapshot: source, context: rawContext) &&
                  MacEditorAdjustmentRules.isModified(scope: .group(.color), snapshot: source, context: rawContext),
                  "Recipe logical light/color markers remain visible at strength \(strength)")
            let result = try candidate(.group(.looks), source)
            XCTAssertTrue(coreValues(result.settings) == coreValues(source.settings) && result.settings.exposureMode == source.settings.exposureMode,
                  "Appearance reset preserves every non-look core Float and HSL at strength \(strength)")
            XCTAssertTrue(result.filmID == "neutral" && result.masterRecipeID == nil && result.settings.masterRecipeID == nil && result.settings.strength == 1,
                  "Appearance reset clears all appearance identities together")
            XCTAssertTrue(try JSONDecoder().decode(MacPhotoEditState.self, from: JSONEncoder().encode(result)) == result,
                  "Detached recipe candidate survives existing persistence")
            var versionTwo = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
            versionTwo["masterRecipeSettingsVersion"] = 2
            let old = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: versionTwo))
            let detached = try candidate(.group(.looks), state(old))
            XCTAssertTrue(coreValues(detached.settings) == coreValues(old), "Version two HSL is not scaled a second time at \(strength)")
        }
        var settings = Adjustments()
        settings.applyMasterRecipe(.hamadaDaylightV2)
        if case .blocked(.missingAsShotWhiteBalance) = MacEditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            XCTAssertTrue(true, "Missing RAW as-shot calibration blocks relative-tint materialization")
        } else { XCTFail("Missing RAW as-shot calibration blocks relative-tint materialization") }
        settings.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
        settings.exposure = 4; settings.strength = 2
        if case .blocked = MacEditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            XCTAssertTrue(true, "Unrepresentable 8 EV materialization is blocked instead of clamped")
        } else { XCTFail("Unrepresentable 8 EV materialization is blocked instead of clamped") }
        settings.exposure = .nan
        if case .blocked = MacEditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(settings), context: rawContext) {
            XCTAssertTrue(true, "Nonfinite source values are rejected before conversion")
        } else { XCTFail("Nonfinite source values are rejected before conversion") }

        let raster = MacEditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "neutral")
        XCTAssertTrue(!MacEditorAdjustmentRules.isModified(scope: .group(.light), snapshot: state(), context: raster),
              "Raster effective sensor mode does not mark untouched stored preview mode")
        var rgb = Adjustments()
        rgb.exposureMode = .scene
        rgb.applyMasterRecipe(.hamadaDaylightV2)
        rgb.strength = 0.5
        let rgbResult = try candidate(.group(.looks), state(rgb), context: raster)
        XCTAssertTrue(coreValues(rgbResult.settings.resolvedForRaster) == coreValues(rgb.resolvedForRaster) &&
              rgbResult.settings.exposureMode == .scene && rgbResult.settings.whiteBalanceMode == .asShot,
              "Raster recipe reset preserves actual core values and stored exposure mode without inventing camera WB")
        rgb.tint = 0
        let noCamera = try candidate(.group(.looks), state(rgb))
        XCTAssertTrue(coreValues(noCamera.settings) == coreValues(rgb), "Zero relative tint needs no invented RAW calibration")

        var customWithoutCamera = Adjustments()
        customWithoutCamera.applyMasterRecipe(.hamadaDaylightV2)
        customWithoutCamera.whiteBalanceMode = .custom
        customWithoutCamera.tint = 0
        if case .blocked(.missingAsShotWhiteBalance) = MacEditorAdjustmentRules.prepareReset(
            scope: .group(.looks), snapshot: state(customWithoutCamera), context: rawContext) {
            XCTAssertTrue(true, "Custom RAW white balance with zero relative tint blocks without as-shot calibration")
        } else {
            XCTFail("Custom RAW white balance with zero relative tint blocks without as-shot calibration")
        }

        customWithoutCamera.strength = 0
        if case .blocked(.missingAsShotWhiteBalance) = MacEditorAdjustmentRules.prepareReset(
            scope: .group(.looks), snapshot: state(customWithoutCamera), context: rawContext) {
            XCTAssertTrue(true, "Custom RAW white balance with zero strength blocks without as-shot calibration")
        } else {
            XCTFail("Custom RAW white balance with zero strength blocks without as-shot calibration")
        }

        var customWithCamera = customWithoutCamera
        customWithCamera.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
        let customWithCameraResult = try candidate(.group(.looks), state(customWithCamera))
        XCTAssertTrue(coreValues(customWithCameraResult.settings) == coreValues(customWithCamera),
              "Custom RAW white balance with camera calibration preserves non-look core values")

        var asShotWithoutCamera = Adjustments()
        asShotWithoutCamera.applyMasterRecipe(.hamadaDaylightV2)
        asShotWithoutCamera.tint = 0
        let asShotResult = try candidate(.group(.looks), state(asShotWithoutCamera))
        XCTAssertTrue(coreValues(asShotResult.settings) == coreValues(asShotWithoutCamera),
              "As-shot RAW white balance with zero relative tint needs no calibration")

        var futureSettings = rgb
        futureSettings.setTransferRecipe(rgb.masterRecipeID, settingsVersion: 5)
        if case .blocked(.invalidSnapshot("masterRecipe")) = MacEditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(futureSettings), context: rawContext) {
            XCTAssertTrue(true, "Unknown recipe settings versions are blocked without migration")
        } else { XCTFail("Unknown recipe settings versions are blocked without migration") }
        let fixtureURL = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/fixtures/master-recipe-v4.json")
        let refinedRecipe = try JSONDecoder().decode(MasterRecipe.self, from: Data(contentsOf: fixtureURL))
        var refined = Adjustments()
        refined.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8.2))
        refined.applyMasterRecipe(refinedRecipe); refined.strength = 0.5
        let refinedDetached = try candidate(.group(.looks), state(refined)).settings
        XCTAssertTrue(refinedDetached.masterRecipeID == nil && refinedDetached.toneSettings == refined.renderToneSettings &&
              refinedDetached.atmosphereSettings == refined.renderAtmosphereSettings &&
              refinedDetached.gradingSettings == refined.renderGradingSettings && refinedDetached.curveSettings == refined.renderCurveSettings,
              "Looks reset bakes v4 refinements once while preserving their rendered effect")
        rgb.masterRecipeID = "missing-recipe"
        if case .blocked = MacEditorAdjustmentRules.prepareReset(scope: .group(.looks), snapshot: state(rgb), context: rawContext) {
            XCTAssertTrue(true, "Unknown recipe identity is not guessed")
        } else { XCTFail("Unknown recipe identity is not guessed") }

        var coupled = Adjustments()
        coupled.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 4))
        coupled.applyMasterRecipe(.hamadaDaylightV2)
        coupled.strength = 0.5
        coupled.photoEffects = PhotoEffectsSettings(grainSize: 31)
        coupled.geometry = GeometrySettings()
        coupled.geometry?.flipVertical = true
        coupled.lensCorrection = LensCorrectionSettings(distortion: true)
        coupled.waveletNoiseReduction = WaveletDenoiseSettings(luma: 15, preset: .custom)
        let detached = try candidate(.group(.looks), state(coupled))
        let detachedTool = try candidate(.tool(.recipe), state(coupled))
        XCTAssertTrue(detachedTool == detached, "Current recipe reset uses the exact same lossless detach as the looks group")
        XCTAssertTrue(detached.settings.photoEffects == coupled.photoEffects && detached.settings.geometry == coupled.geometry &&
              detached.settings.lensCorrection == coupled.lensCorrection && detached.settings.waveletNoiseReduction == coupled.waveletNoiseReduction,
              "Recipe detachment preserves exact effect, geometry, lens and denoise snapshots")
        let color = try candidate(.group(.color), state(coupled))
        var expected = coupled
        expected.resetWhiteBalance(); expected.saturation = 1; expected.hsl = nil
        expected.vibrance = 0; expected.gradingSettings = ColorGradingSettings()
        XCTAssertTrue(color.settings == expected && color.settings.strength == 0.5 && color.masterRecipeID == coupled.masterRecipeID,
              "Color reset clears only logical color fields and does not replay the recipe")
        let light = try candidate(.group(.light), state(coupled))
        expected = coupled
        expected.exposure = 0; expected.contrast = 1; expected.highlights = 0; expected.shadows = 0; expected.toneCurve = 0
        expected.blackPoint = 0; expected.whitePoint = 0; expected.curveSettings = ToneCurveSettings()
        XCTAssertTrue(light.settings == expected, "Light reset preserves color values and the recipe scale")
        var selected = state(coupled); selected.filmID = "film"
        let all = try candidate(.all, selected)
        XCTAssertTrue(all.filmID == "neutral" && all.masterRecipeID == nil && all.settings.masterRecipeID == nil &&
              all.settings.asShotWhiteBalance == coupled.asShotWhiteBalance &&
              !MacEditorAdjustmentRules.isModified(scope: .all, snapshot: all, context: rawContext),
              "Full reset clears external and internal identities while retaining genuine input metadata")
    }

    func testInvalidResetSources() throws {
        var invalid = Adjustments()
        invalid.exposure = 9
        for scope in [EditorResetScope.group(.light), .all] {
            if case .blocked(.invalidSnapshot("exposure")) = MacEditorAdjustmentRules.prepareReset(scope: scope, snapshot: state(invalid), context: rawContext) {
                XCTAssertTrue(true, "\(scope) rejects an invalid source instead of silently repairing it")
            } else { XCTFail("\(scope) rejects an invalid source instead of silently repairing it") }
        }
        invalid = Adjustments()
        invalid.hsl = try JSONDecoder().decode(HSLSettings.self, from: Data("{\"hue\":[1],\"saturation\":[0],\"lightness\":[0]}".utf8))
        if case .blocked = MacEditorAdjustmentRules.prepareReset(scope: .hslColor(7), snapshot: state(invalid), context: rawContext) {
            XCTAssertTrue(true, "Malformed HSL source is blocked before indexing a color")
        } else { XCTFail("Malformed HSL source is blocked before indexing a color") }
    }

    func testFilmPhysicsControlsAndResets() throws {
        var s = Adjustments()
        s.applyGrainToneCurve(.negativeAsymmetric)
        s.applyGrainFormatPreset(.film135)
        XCTAssertTrue(s.effectSettings.grainToneCurve == .negativeAsymmetric && s.effectSettings.grainFormatPreset == .film135 &&
              s.effectSettings.grainSize == 18 && s.effectSettings.grainRoughness == 65,
              "135 grain format preset applies canonical grain scale and roughness")
        s.applyGrainFormatPreset(.film120)
        XCTAssertTrue(s.effectSettings.grainFormatPreset == .film120 && s.effectSettings.grainSize == 34 && s.effectSettings.grainRoughness == 22,
              "120 grain format preset applies medium-format scale and roughness")
        s.setGrainEffect(.grainSize, to: 41)
        XCTAssertTrue(s.effectSettings.grainFormatPreset == .custom && s.effectSettings.grainSize == 41 && s.effectSettings.grainRoughness == 22,
              "Manual grain size edit transitions preset to Custom while preserving tuning")
        s.setFilmOptics(.halationAmount, to: 65)
        s.setFilmOptics(.bloomAmount, to: 40)
        XCTAssertTrue(!s.filmOpticsSettings.isHalationDefault && !s.filmOpticsSettings.isBloomDefault &&
              MacEditorAdjustmentRules.isModified(scope: .group(.effects), snapshot: state(s), context: rawContext),
              "Film optics changes mark Effects group modified")
        s.filmOpticsSettings.resetHalation()
        XCTAssertTrue(s.filmOpticsSettings.isHalationDefault && !s.filmOpticsSettings.isBloomDefault,
              "Halation reset preserves Bloom parameters")
        let effectsReset = try candidate(.group(.effects), state(s))
        XCTAssertTrue(effectsReset.settings.filmOpticsSettings.isDefault &&
              effectsReset.settings.effectSettings.grainToneCurve == .legacy &&
              effectsReset.settings.effectSettings.grainFormatPreset == .custom,
              "Effects group reset clears Halation, Bloom, and Grain curve/preset")
    }
}
