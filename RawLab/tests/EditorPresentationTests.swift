import Foundation

@main
struct EditorPresentationTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() {
        var settings = RawSettings.default
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
        settings.temperature = 4250
        check(AdjustmentKind.temperature.progress(in: settings) == -0.5,
              "Negative progress uses the lower half of an asymmetric range")
        settings.temperature = 8250
        check(AdjustmentKind.temperature.progress(in: settings) == 0.5,
              "Positive progress uses the upper half of an asymmetric range")
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
