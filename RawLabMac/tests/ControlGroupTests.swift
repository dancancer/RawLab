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
}
