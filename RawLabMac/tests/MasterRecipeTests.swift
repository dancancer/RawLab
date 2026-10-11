import Foundation

@main
struct MasterRecipeTests {
    private static var failures = 0
    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS: \(name)")
        } else {
            fputs("FAIL: \(name)\n", stderr)
        }
    }

    static func main() throws {
        // 1. Definition and parameter verification for all 14 recipes
        check(MasterRecipe.allRecipes.count == 14, "MasterRecipe defines exactly 14 recipes")

        for r in MasterRecipe.allRecipes {
            check(!r.id.isEmpty, "Recipe \(r.name) has non-empty ID")
            check(!r.name.isEmpty, "Recipe \(r.id) has non-empty name")
            check(!r.subtitle.isEmpty, "Recipe \(r.name) has subtitle")
            check(!r.lutFileName.isEmpty, "Recipe \(r.name) has CUBE filename")
            check(r.lutURL() != nil, "Recipe \(r.name) CUBE URL resolves successfully (\(r.lutFileName))")
            check(MasterRecipe.recipe(for: r.id)?.name == r.name, "Lookup for \(r.id) returns \(r.name)")
        }

        check(MasterRecipe.recipe(for: nil) == nil, "Lookup nil returns nil")
        check(MasterRecipe.recipe(for: "") == nil, "Lookup empty returns nil")

        // 2. Specific master parameter verification
        let hamada = MasterRecipe.hamadaDaylightV2
        check(hamada.exposureDelta == 0.40, "Hamada exposure delta is +0.40 EV")
        check(hamada.shadowsDelta == 20.0, "Hamada shadows delta is +20.0")
        check(hamada.highlightsDelta == -15.0, "Hamada highlights delta is -15.0")
        check(hamada.contrastDelta == -15.0, "Hamada contrast delta is -15.0")
        check(hamada.saturationDelta == -8.0, "Hamada saturation delta is -8.0")
        check(hamada.tintDelta == 5.0, "Hamada tint delta is +5.0")

        let takashi = MasterRecipe.takashiYasuiZen
        check(takashi.contrastDelta == 30.0, "Takashi Yasui contrast delta is +30.0")
        check(takashi.shadowsDelta == -25.0, "Takashi Yasui shadows delta is -25.0")

        let sakai = MasterRecipe.takahiroSakaiBlue
        check(sakai.exposureDelta == 0.35, "Takahiro Sakai exposure delta is +0.35 EV")
        check(sakai.shadowsDelta == 35.0, "Takahiro Sakai shadows delta is +35.0")

        let luke = MasterRecipe.withlukeEpic
        check(luke.saturationDelta == -12.0, "withluke saturation delta is -12.0")

        let rk = MasterRecipe.rkrkrkCyberpunk
        check(rk.saturationDelta == 15.0, "rkrkrk saturation delta is +15.0")
        check(rk.highlightsDelta == -40.0, "rkrkrk highlights delta is -40.0")

        // 3. Adjustments and strength scaling verification
        var settings = Adjustments()
        check(settings.masterRecipeID == nil, "Default adjustments have no master recipe")
        check(settings.masterRecipe == nil, "Default adjustments masterRecipe property is nil")
        check(settings.isDefault(.film), "Default adjustments report film group default")

        // Set master recipe
        settings.masterRecipeID = hamada.id
        check(settings.masterRecipe?.id == hamada.id, "Master recipe resolved on adjustments")
        check(!settings.isDefault(.film), "Active master recipe marks film group non-default")

        var request = sony2fuji_request()

        // Test at default strength 1.0 (100%)
        settings.strength = 1.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.40) < 1e-4, "Strength 1.0 applies +0.40 EV exposure")
        check(abs(request.shadows - 0.20) < 1e-4, "Strength 1.0 applies +0.20 shadows (+20)")
        check(abs(request.highlights - 0.15) < 1e-4, "Strength 1.0 applies +0.15 core highlights (-15 UI)")
        check(abs(request.contrast - 0.85) < 1e-4, "Strength 1.0 applies 0.85 contrast (-15)")
        check(abs(request.saturation - 0.92) < 1e-4, "Strength 1.0 applies 0.92 saturation (-8)")
        check(abs(request.tint - 5.0) < 1e-4, "Strength 1.0 applies +5.0 tint")

        // Test at strength 0.5 (50%)
        settings.strength = 0.5
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.20) < 1e-4, "Strength 0.5 scales exposure to +0.20 EV")
        check(abs(request.shadows - 0.10) < 1e-4, "Strength 0.5 scales shadows to +0.10")
        check(abs(request.highlights - 0.075) < 1e-4, "Strength 0.5 scales highlights to +0.075")
        check(abs(request.contrast - 0.925) < 1e-4, "Strength 0.5 scales contrast to 0.925")
        check(abs(request.saturation - 0.96) < 1e-4, "Strength 0.5 scales saturation to 0.96")
        check(abs(request.tint - 2.5) < 1e-4, "Strength 0.5 scales tint to +2.5")

        // Test at strength 0.0 (0% - neutral)
        settings.strength = 0.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.0) < 1e-4, "Strength 0.0 reverts exposure to 0")
        check(abs(request.shadows - 0.0) < 1e-4, "Strength 0.0 reverts shadows to 0")
        check(abs(request.highlights - 0.0) < 1e-4, "Strength 0.0 reverts highlights to 0")
        check(abs(request.contrast - 1.0) < 1e-4, "Strength 0.0 reverts contrast to 1.0")
        check(abs(request.saturation - 1.0) < 1e-4, "Strength 0.0 reverts saturation to 1.0")
        check(abs(request.tint - 0.0) < 1e-4, "Strength 0.0 reverts tint to 0")

        // Test at strength 1.5 (150% - amplified)
        settings.strength = 1.5
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.60) < 1e-4, "Strength 1.5 scales exposure to +0.60 EV")
        check(abs(request.shadows - 0.30) < 1e-4, "Strength 1.5 scales shadows to +0.30")
        check(abs(request.highlights - 0.225) < 1e-4, "Strength 1.5 scales highlights to +0.225")

        // Test with user manual trimming on top
        settings.exposure = 0.25
        settings.shadows = 10.0
        settings.strength = 1.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.65) < 1e-4, "User exposure +0.25 combines with recipe +0.40 to +0.65 EV")
        check(abs(request.shadows - 0.30) < 1e-4, "User shadows +10 combines with recipe +20 to +0.30")

        // Reset group film
        settings.reset(.film)
        check(settings.masterRecipeID == nil, "Film group reset clears masterRecipeID")
        check(settings.strength == 1.0, "Film group reset restores 100% strength")

        settings.masterRecipeID = rk.id
        settings.resetAll()
        check(settings.masterRecipeID == nil, "Reset all clears masterRecipeID")

        // 4. Persistence verification
        let editState = PhotoEditState(settings: settings, filmID: "", masterRecipeID: rk.id)
        let data = try JSONEncoder().encode(editState)
        let decoded = try JSONDecoder().decode(PhotoEditState.self, from: data)
        check(decoded.masterRecipeID == rk.id, "PhotoEditState encodes and decodes masterRecipeID")
        check(decoded.filmID == "", "PhotoEditState preserves filmID")

        // Legacy format backward compatibility
        let legacyJSON = """
        {
            "settings": {
                "exposure": 0.0,
                "temperature": 6500.0,
                "tint": 0.0,
                "whiteBalanceMode": "拍摄时设置",
                "strength": 1.0,
                "contrast": 0.0,
                "highlights": 0.0,
                "shadows": 0.0,
                "toneCurve": 0.0,
                "saturation": 0.0,
                "sharpening": 0.0,
                "rawNoiseReduction": 0.0,
                "supportsRawNoiseReduction": false
            },
            "filmID": "provia"
        }
        """.data(using: .utf8)!
        let legacyRestored = try JSONDecoder().decode(PhotoEditState.self, from: legacyJSON)
        check(legacyRestored.masterRecipeID == nil, "Legacy JSON decodes with masterRecipeID == nil")
        check(legacyRestored.filmID == "provia", "Legacy JSON preserves filmID")

        // 5. Mutual exclusivity simulation
        var simSelectedFilmID = "PROVIA"
        var simMasterRecipeID: String? = nil

        func selectRecipe(_ r: MasterRecipe?) {
            simMasterRecipeID = r?.id
            if r != nil { simSelectedFilmID = "" }
        }
        func selectFilm(_ f: String) {
            simSelectedFilmID = f
            if !f.isEmpty { simMasterRecipeID = nil }
        }

        selectRecipe(hamada)
        check(simMasterRecipeID == hamada.id && simSelectedFilmID.isEmpty,
              "Selecting master recipe clears film ID to empty (neutral)")

        selectFilm("CLASSIC_CHROME")
        check(simSelectedFilmID == "CLASSIC_CHROME" && simMasterRecipeID == nil,
              "Selecting film simulation clears master recipe ID")

        selectRecipe(nil)
        check(simMasterRecipeID == nil, "Deselecting master recipe leaves it nil")

        if failures > 0 {
            fputs("FAILED: \(failures) tests failed\n", stderr)
            exit(1)
        }
        print("PASS: All MasterRecipe unit tests passed successfully!")
    }
}
