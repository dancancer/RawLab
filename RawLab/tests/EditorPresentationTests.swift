import Foundation

@main
struct EditorPresentationTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() {
        var settings = RawSettings.default
        check(!settings.denoise.enabled && settings.denoise.luma == 0 && settings.denoise.chroma == 46 && settings.denoise.coarse == 50,
              "Denoise defaults off and retains luminance texture")
        settings.denoise.apply(.clean)
        check(settings.denoise.enabled && settings.denoise.luma == 10 && settings.denoise.chroma == 72 && settings.denoise.coarse == 100,
              "Clean preset adds light luminance smoothing")
        settings.denoise.luma = 23
        settings.denoise.enabled = false
        check(settings.denoise.luma == 23 && settings.denoise.preset == .custom, "Off preserves custom strengths")
        AdjustmentKind.noiseReduction.reset(in: &settings)
        check(settings.denoise == RawDenoiseSettings(), "Denoise group reset restores disabled defaults")
        check(!RawDenoiseSettings(enabled: true, luma: .nan).isValid &&
              !RawDenoiseSettings(enabled: true, chroma: 101).isValid, "Nonfinite and out-of-range denoise values rejected")
        check(settings.photoEffects == PhotoEffectsSettings(vignetteAmount: 0, vignetteMidpoint: 50,
                                                               vignetteRoundness: 0, vignetteFeather: 50,
                                                               vignetteHighlights: 0, grainAmount: 0,
                                                               grainSize: 25, grainRoughness: 50),
              "Photo effects use the canonical disabled defaults")
        var effects = settings.photoEffects
        effects.vignetteAmount = 125
        effects.vignetteRoundness = -125
        effects.vignetteMidpoint = 125
        effects.grainSize = -1
        effects.grainRoughness = 125
        check(effects.vignetteAmount == 100 && effects.vignetteRoundness == -100 &&
              effects.vignetteMidpoint == 100 && effects.grainSize == 0 && effects.grainRoughness == 100,
              "Photo effect controls clamp each parameter to its canonical range")
        effects.vignetteAmount = 0.5
        effects.vignetteRoundness = -0.5
        check(effects.vignetteAmount == 1 && effects.vignetteRoundness == -1,
              "Photo effect values use the shared nearest-integer rounding contract")
        effects.vignetteAmount = 0
        effects.vignetteMidpoint = 62
        settings.photoEffects = effects
        check(settings.photoEffects.vignetteAmount == 0 && settings.photoEffects.vignetteMidpoint == 62,
              "Vignette auxiliary values survive while amount is zero")
        AdjustmentKind.vignette.reset(in: &settings)
        check(settings.photoEffects.vignetteAmount == 0 && settings.photoEffects.vignetteMidpoint == 50 &&
              settings.photoEffects.vignetteRoundness == 0 && settings.photoEffects.vignetteFeather == 50 &&
              settings.photoEffects.vignetteHighlights == 0,
              "Vignette group reset restores all vignette defaults")
        settings.photoEffects.grainAmount = 70
        settings.photoEffects.grainSize = 60
        AdjustmentKind.grain.reset(in: &settings)
        check(settings.photoEffects == PhotoEffectsSettings(), "Grain group reset restores all defaults")
        settings.displayChromaDenoise = 3
        check(settings.displayChromaDenoise == 2, "Display chroma mode clamps to the supported range")
        settings.displayChromaDenoise = -1
        check(settings.displayChromaDenoise == 0, "Display chroma mode clamps negative values to off")
        check(AdjustmentKind.strength.range == 0...2, "Film strength range reaches 200 percent")
        AdjustmentKind.strength.setValue(2, in: &settings)
        check(settings.lutStrength == 2 && AdjustmentKind.strength.progress(in: settings) == 1,
              "200 percent is selectable and fills the positive strength ring")
        check(settings.clampedLUTStrength == 2, "Processing receives 200 percent without clipping to 100")
        settings.lutStrength = 3
        check(settings.clampedLUTStrength == 2, "Processing clamps strength above 200 percent")
        settings.lutStrength = -1
        check(settings.clampedLUTStrength == 0, "Processing clamps negative strength to zero")
        AdjustmentKind.strength.reset(in: &settings)
        check(settings.lutStrength == 1, "Default and reset film strength remain 100 percent")
        check(AdjustmentKind.temperature.progress(in: settings) == 0,
              "Unchanged white balance has no progress ring")
        check(AdjustmentKind.temperature.range == 2000...50000,
              "RAW temperature range reaches 50000 K")
        check(abs(RawSettings.reciprocalSliderValue(for: 2000)) < 0.0001 &&
              abs(RawSettings.reciprocalSliderValue(for: 50000) - 1) < 0.0001 &&
              RawSettings.temperature(forReciprocalSliderValue: 0.5) > 2000,
              "Temperature slider uses reciprocal Kelvin while the field stays Kelvin")
        settings.temperature = 4250
        check(AdjustmentKind.temperature.progress(in: settings) == -0.5,
              "Negative progress uses the lower half of an asymmetric range")
        settings.temperature = 8250
        check(AdjustmentKind.temperature.progress(in: settings) > 0 &&
              AdjustmentKind.temperature.progress(in: settings) < 0.1,
              "Positive progress uses the upper half of the expanded temperature range")
        settings.exposure = -1
        check(AdjustmentKind.exposure.progress(in: settings) == -0.5,
              "Negative exposure travels counterclockwise")
        settings.lutStrength = 0
        check(AdjustmentKind.strength.progress(in: settings) == -1,
              "Strength is anchored at its existing 100 percent default")
        settings.lutID = "existing-film"
        AdjustmentKind.temperature.reset(in: &settings)
        check(settings.temperature == 6500 && settings.exposure == -1 && settings.lutID == "existing-film",
              "Single-tool reset preserves other adjustments and film selection")
        AdjustmentKind.strength.reset(in: &settings)
        check(settings.lutStrength == 1 && settings.lutID == "existing-film",
              "Resetting strength does not deselect the film")
        settings.whiteBalanceMode = .custom
        let encoded = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(RawSettings.self, from: encoded)
        check(decoded.whiteBalanceMode == .custom, "White balance mode round-trips in the edit record")
        var legacy = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "photoEffects")
        legacy.removeValue(forKey: "displayChromaDenoise")
        let oldDecoded = try! JSONDecoder().decode(RawSettings.self,
                                                     from: JSONSerialization.data(withJSONObject: legacy))
        check(oldDecoded.photoEffects == PhotoEffectsSettings() && oldDecoded.displayChromaDenoise == 0,
              "Older edit records default effects and display chroma to off")
        for kind in AdjustmentKind.allCases {
            kind.setValue(kind.range.upperBound, in: &settings)
            kind.reset(in: &settings)
            check(kind.progress(in: settings) == 0, "Reset clears the \(kind.rawValue) ring")
        }
        let film = FilmPresentation(fileName: "X100VI_FLog2_FGamut_to_ETERNA-BB_BT.709_33grid_V.1.00")
        check(film.name == "ETERNA BB" && film.artworkName == "eterna-bb",
              "A bundled film resolves to its short name and matching artwork")
        let wdr = FilmPresentation(fileName: "X100VI_FLog2_FGamut_to_WDR_BT.709_33grid_V.1.00")
        check(wdr.name == "WDR" && wdr.artworkName == nil,
              "WDR does not impersonate a film package")
        let custom = FilmPresentation(fileName: "My_Custom_Look")
        check(custom.name == "My_Custom_Look" && custom.artworkName == nil,
              "Unknown names remain intact and do not borrow film artwork")
        let modernFilms: [(String, String, String?)] = [
            ("ACROS", "ACROS", "acros"), ("ASTIA", "ASTIA", "astia"),
            ("CLASSIC-CHROME", "CLASSIC CHROME", "classic-chrome"),
            ("CLASSIC-Neg.", "CLASSIC Neg.", "classic-neg"),
            ("ETERNA", "ETERNA", "eterna"), ("ETERNA-BB", "ETERNA BB", "eterna-bb"),
            ("PRO-Neg.Std", "PRO Neg.Std", "pro-neg-std"), ("PROVIA", "PROVIA", "provia"),
            ("REALA-ACE", "REALA ACE", "reala-ace"), ("Velvia", "Velvia", "velvia"),
            ("WDR", "WDR", nil)
        ]
        for (token, name, artwork) in modernFilms {
            let film = FilmPresentation(fileName: "FLog2_to_\(token)_65grid_V.1.00")
            check(film.name == name && film.artworkName == artwork,
                  "65-grid \(token) resolves to its display name and matching artwork")
        }
    }
}
