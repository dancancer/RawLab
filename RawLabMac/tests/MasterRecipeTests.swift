import Foundation
import ImageIO

@main
struct MasterRecipeTests {
    private static var failures = 0
    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS: \(name)")
        } else {
            fputs("FAIL: \(name)\n", stderr)
            failures += 1
        }
    }

    static func directRecipeRemoval() throws {
        let recipe = try JSONDecoder().decode(MasterRecipe.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json")))
        for strength in [0.0, 0.5, 2.0] {
            var source = Adjustments(); source.applyMasterRecipe(recipe)
            source.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8)); source.strength = strength
            var before = sony2fuji_request(); source.apply(to: &before)
            let tone = source.renderToneSettings, curve = source.renderCurveSettings
            let grading = source.renderGradingSettings, atmosphere = source.renderAtmosphereSettings
            var removed = source; removed.clearMasterRecipe()
            var after = sony2fuji_request(); removed.apply(to: &after)
            check(removed.masterRecipeID == nil && removed.toneSettings == tone && removed.curveSettings == curve &&
                  removed.gradingSettings == grading && removed.atmosphereSettings == atmosphere &&
                  removed.renderHSLSettings == source.renderHSLSettings && before.exposure_ev == after.exposure_ev &&
                  before.contrast == after.contrast && before.tint == after.tint && before.wb_mode == after.wb_mode,
                  "Direct recipe removal preserves effective controls at \(strength)")
        }
        var extreme = Adjustments(); extreme.applyMasterRecipe(recipe)
        extreme.resolveWhiteBalance(WhiteBalance(temperature: 5300, tint: 8)); extreme.exposure = 4; extreme.strength = 2
        let unchanged = extreme
        check(!extreme.clearMasterRecipe() && extreme == unchanged,
              "Unrepresentable direct removal keeps the original edit unchanged")
    }

    static func main() throws {
        try refinedRecipeApplication()
        try directRecipeRemoval()
        // 1. Definition and parameter verification
        let recipe = MasterRecipe.hamadaDaylightV2
        check(recipe.id == "hamada_daylight_v2", "Recipe has expected ID")
        check(recipe.name == "滨田英明", "Recipe name is 滨田英明")
        check(recipe.exposureDelta == 0.40, "Sony exposure delta is +0.40 EV")
        check(recipe.shadowsDelta == 20.0, "Sony shadows delta is +20.0")
        check(recipe.highlightsDelta == -15.0, "Sony highlights delta is -15.0")
        check(recipe.contrastDelta == -5.0, "Refined recipe reduces the uniform contrast offset")
        check(recipe.saturationDelta == -8.0, "Sony saturation delta is -8.0")
        check(recipe.tintDelta == 5.0, "Sony tint delta is +5.0")
        check(recipe.lutURL() != nil, "Recipe CUBE URL resolves successfully")

        let expectedIDs = ["hamada_daylight_v2", "takashi_yasui_zen", "takahiro_sakai_blue", "withluke_epic",
                           "daniel_casson_autumn", "billy_dinh_cinema", "rkrkrk_cyberpunk", "samalive_vintage",
                           "iwona_fairy_tale", "cinestill_800t", "wilson_lee_golden", "luizclas_portrait",
                           "ivan_ivanchenko_twilight", "jungraphy_neon"]
        check(MasterRecipe.allRecipes.map(\.id) == expectedIDs, "All fourteen recipe IDs are registered in stable order")
        let catalogURL = URL(fileURLWithPath: "Shared/master-recipes.json")
        if let data = try? Data(contentsOf: catalogURL),
           let shared = try? JSONDecoder().decode([MasterRecipe].self, from: data) {
            check(shared == MasterRecipe.allRecipes, "All platforms share the exact fourteen recipe definitions")
        } else {
            check(false, "Shared master recipe catalog exists and decodes")
        }
        for entry in MasterRecipe.allRecipes {
            check(entry.lutURL() != nil, "\(entry.id): LUT resolves")
            if let artwork = entry.artworkURL(),
               let source = CGImageSourceCreateWithURL(artwork as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                check(image.width == 256 && image.height == 256, "\(entry.id): dedicated 256px artwork decodes")
            } else {
                check(false, "\(entry.id): dedicated artwork resolves and decodes")
            }
            var applied = Adjustments()
            applied.exposure = 2; applied.shadows = -60; applied.highlights = 80
            applied.contrast = 75; applied.saturation = 50; applied.tint = 100
            applied.temperature = 8000; applied.sharpening = 75
            applied.setHSL(.saturation, channel: 5, value: -35)
            let originalHSL = applied.hslSettings
            applied.applyMasterRecipe(entry)
            check(applied.exposure == entry.exposureDelta && applied.shadows == entry.shadowsDelta &&
                  applied.highlights == entry.highlightsDelta && applied.contrast == entry.contrastDelta &&
                  applied.saturation == entry.saturationDelta && applied.tint == entry.tintDelta,
                  "\(entry.id): preset overwrites all six corresponding controls")
            check(applied.temperature == 8000 && applied.sharpening == 75,
                  "\(entry.id): unrelated controls are preserved")
            check(applied.hslSettings != originalHSL,
                  "\(entry.id): preset replaces corresponding HSL controls")
            check(entry.hsl.isValid && applied.hslSettings == entry.hsl,
                  "\(entry.id): all three HSL axes use the visible preset values")
            applied.setHSL(.hue, channel: 7, value: 37)
            applied.setHSL(.saturation, channel: 5, value: -61)
            applied.setHSL(.lightness, channel: 3, value: 19)
            let editedHSL = applied.hslSettings
            for strength in [0.0, 0.5, 1.0, 2.0] {
                applied.strength = strength
                var scaled = sony2fuji_request()
                applied.apply(to: &scaled)
                check(abs(Double(scaled.exposure_ev) - entry.exposureDelta * strength) < 1e-5 &&
                      abs(Double(scaled.shadows) - entry.shadowsDelta * strength / 100) < 1e-5 &&
                      abs(Double(scaled.highlights) + entry.highlightsDelta * strength / 100) < 1e-5 &&
                      abs(Double(scaled.contrast) - (1 + entry.contrastDelta * strength / 100)) < 1e-5 &&
                      abs(Double(scaled.saturation) - (1 + entry.saturationDelta * strength / 100)) < 1e-5 &&
                      abs(Double(scaled.tint) - entry.tintDelta * strength) < 1e-5,
                      "\(entry.id): \(Int(strength * 100))% scales all six parameters")
                let renderedHSL = applied.renderHSLSettings
                for axis in HSLAxis.allCases {
                    for channel in 0..<8 {
                        let expected = min(100, max(-100, editedHSL.value(axis, channel: channel) * strength))
                        check(renderedHSL.value(axis, channel: channel) == expected,
                              "\(entry.id): \(Int(strength * 100))% scales \(axis.rawValue) channel \(channel) without rounding")
                    }
                }
                check(applied.hslSettings == editedHSL, "\(entry.id): rendering does not rewrite visible HSL")
            }
            applied.exposure = 0.63
            let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(applied))
            check(restored == applied && restored.masterRecipe?.id == entry.id,
                  "\(entry.id): persisted manual adjustments survive restoration")
        }

        check(MasterRecipe.recipe(for: "hamada_daylight_v2")?.name == "滨田英明", "Recipe lookup by ID succeeds")
        check(MasterRecipe.recipe(for: nil) == nil, "Lookup nil returns nil")
        check(MasterRecipe.recipe(for: "") == nil, "Lookup empty returns nil")

        var legacyBase = Adjustments()
        legacyBase.masterRecipeID = recipe.id
        legacyBase.exposure = 0.25; legacyBase.shadows = 10; legacyBase.highlights = 5
        legacyBase.contrast = 10; legacyBase.saturation = 3
        legacyBase.setHSL(.hue, channel: 0, value: 25)
        legacyBase.resolveWhiteBalance(WhiteBalance(temperature: 6500, tint: 10))
        var legacyPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyBase)) as! [String: Any]
        legacyPayload.removeValue(forKey: "masterRecipeSettingsVersion")
        legacyPayload["tint"] = 10
        let migrated = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        check(abs(migrated.exposure - 0.65) < 1e-6 && migrated.shadows == 30 && migrated.highlights == -10 &&
              migrated.contrast == -5 && migrated.saturation == -5 && migrated.tint == 5,
              "Legacy additive recipe records fold all six preset controls without double-counting camera tint")
        check(migrated.masterRecipeID == recipe.id && migrated.strength == 1,
              "Legacy migration preserves recipe selection and strength")
        check(migrated.hslSettings == legacyBase.hslSettings,
              "Legacy recipe migration preserves independently saved HSL")
        let migratedAgain = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(migrated))
        check(migratedAgain == migrated, "Migrated recipe records are not migrated a second time")
        legacyPayload["whiteBalanceMode"] = WhiteBalanceMode.custom.rawValue
        legacyPayload["temperature"] = 8000
        legacyPayload["tint"] = 50
        let customLegacy = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        var customRequest = sony2fuji_request()
        customLegacy.apply(to: &customRequest)
        check(customRequest.temperature == 8000 && customRequest.tint == 55 && customLegacy.tint == 45,
              "Legacy custom WB is converted from absolute tint to a camera-relative recipe offset")

        var oldHSL = Adjustments()
        oldHSL.applyMasterRecipe(recipe)
        oldHSL.setHSL(.saturation, channel: 5, value: -80)
        oldHSL.strength = 0.5
        var versionTwo = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldHSL)) as! [String: Any]
        versionTwo["masterRecipeSettingsVersion"] = 2
        let legacyHSL = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: versionTwo))
        check(legacyHSL.hslSettings == oldHSL.hslSettings && legacyHSL.renderHSLSettings == oldHSL.hslSettings,
              "Version two records retain their independent HSL pixels and visible values")
        let legacyHSLAgain = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(legacyHSL))
        check(legacyHSLAgain == legacyHSL, "Version two HSL compatibility survives save and reload")
        var legacyZero = legacyHSL
        legacyZero.strength = 0
        check(legacyZero.renderHSLSettings == oldHSL.hslSettings,
              "Old zero-strength records retain formerly independent HSL")
        legacyZero.applyMasterRecipe(recipe)
        check(legacyZero.hslSettings == recipe.hsl && legacyZero.strength == 1,
              "Explicit reapplication adopts the new HSL preset semantics")
        legacyZero.setHSL(.lightness, channel: 3, value: 80)
        legacyZero.strength = 2
        check(legacyZero.renderHSLSettings.value(.lightness, channel: 3) == 100,
              "Two hundred percent clamps HSL at the native range")
        legacyZero.resolveWhiteBalance(WhiteBalance(temperature: 6500, tint: 0))
        legacyZero.clearMasterRecipe()
        check(legacyZero.renderHSLSettings == legacyZero.hslSettings,
              "Clearing the recipe leaves visible HSL unscaled")

        // 2. Adjustments and strength scaling verification
        var settings = Adjustments()
        check(settings.masterRecipeID == nil, "Default adjustments have no master recipe")
        check(settings.masterRecipe == nil, "Default adjustments masterRecipe property is nil")
        check(settings.isDefault(.film), "Default adjustments report film group default")

        // Set master recipe
        settings.applyMasterRecipe(recipe)
        check(settings.masterRecipe?.id == recipe.id, "Master recipe resolved on adjustments")
        check(!settings.isDefault(.film), "Active master recipe marks film group non-default")

        var request = sony2fuji_request()

        // Test at default strength 1.0 (100%)
        settings.strength = 1.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.40) < 1e-4, "Strength 1.0 applies +0.40 EV exposure")
        check(abs(request.shadows - 0.20) < 1e-4, "Strength 1.0 applies +0.20 shadows (+20)")
        check(abs(request.highlights - 0.15) < 1e-4, "Strength 1.0 applies +0.15 core highlights (-15 UI)")
        check(abs(request.contrast - 0.95) < 1e-4, "Strength 1.0 applies the refined contrast")
        check(abs(request.saturation - 0.92) < 1e-4, "Strength 1.0 applies 0.92 saturation (-8)")
        check(abs(request.tint - 5.0) < 1e-4, "Strength 1.0 applies +5.0 tint")

        // Test at strength 0.5 (50%)
        settings.strength = 0.5
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.20) < 1e-4, "Strength 0.5 scales exposure to +0.20 EV")
        check(abs(request.shadows - 0.10) < 1e-4, "Strength 0.5 scales shadows to +0.10")
        check(abs(request.highlights - 0.075) < 1e-4, "Strength 0.5 scales highlights to +0.075")
        check(abs(request.contrast - 0.975) < 1e-4, "Strength 0.5 scales the refined contrast")
        check(abs(request.saturation - 0.92 - 0.04) < 1e-4, "Strength 0.5 scales saturation to 0.96")
        check(abs(request.tint - 2.5) < 1e-4, "Strength 0.5 scales tint to +2.5")

        // Test at strength 0.0 (0%) - neutral reversion
        settings.strength = 0.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.0) < 1e-4, "Strength 0.0 reverts exposure to 0")
        check(abs(request.shadows - 0.0) < 1e-4, "Strength 0.0 reverts shadows to 0")
        check(abs(request.highlights - 0.0) < 1e-4, "Strength 0.0 reverts highlights to 0")
        check(abs(request.contrast - 1.0) < 1e-4, "Strength 0.0 reverts contrast to 1.0")
        check(abs(request.saturation - 1.0) < 1e-4, "Strength 0.0 reverts saturation to 1.0")
        check(abs(request.tint - 0.0) < 1e-4, "Strength 0.0 reverts tint to 0")

        // Test at strength 1.5 (150%) - boost
        settings.strength = 1.5
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.60) < 1e-4, "Strength 1.5 scales exposure to +0.60 EV")
        check(abs(request.shadows - 0.30) < 1e-4, "Strength 1.5 scales shadows to +0.30")
        check(abs(request.highlights - 0.225) < 1e-4, "Strength 1.5 scales highlights to +0.225")

        // Test user manual adjustments on top of recipe
        settings.strength = 1.0
        settings.exposure = 0.25
        settings.shadows = 10.0
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.25) < 1e-4, "Manual exposure replaces the preset exposure without a hidden delta")
        check(abs(request.shadows - 0.10) < 1e-4, "Manual shadows replace the preset shadows without a hidden delta")
        settings.strength = 2
        settings.apply(to: &request)
        check(abs(request.exposure_ev - 0.50) < 1e-4 && abs(request.shadows - 0.20) < 1e-4,
              "Strength scales the current preset adjustment values as a whole")

        settings.resolveWhiteBalance(WhiteBalance(temperature: 6500, tint: 0))
        settings.set(.tint, to: 150)
        for strength in [1.0, 2.0] {
            settings.strength = strength
            settings.apply(to: &request)
            check(request.tint == 150, "Recipe keeps maximum user tint within the RAW request range at strength \(strength)")
        }
        settings.resolveWhiteBalance(WhiteBalance(temperature: 6500, tint: 149))
        settings.apply(to: &request)
        check(request.tint == 150, "Recipe keeps as-shot tint within the RAW request range")
        settings.resolveWhiteBalance(WhiteBalance(temperature: 3200, tint: 10))
        settings.strength = 0
        settings.apply(to: &request)
        check(request.wb_mode == SONY2FUJI_WB_CAMERA && request.temperature == 6500 && request.tint == 0,
              "Zero-strength recipe preserves camera WB without a second relative RGB adjustment")
        settings.masterRecipeID = nil
        settings.apply(to: &request)
        check(request.wb_mode == SONY2FUJI_WB_CAMERA && request.temperature == 6500 && request.tint == 0,
              "No recipe preserves camera WB without a second relative RGB adjustment")
        settings.masterRecipeID = recipe.id

        // 3. Reset behavior
        settings.reset(.film)
        check(settings.masterRecipeID == nil, "Film group reset clears masterRecipeID")
        check(settings.strength == 1.0, "Film group reset restores 100% strength")

        settings.masterRecipeID = recipe.id
        settings.resetAll()
        check(settings.masterRecipeID == nil, "Reset all clears masterRecipeID")

        // 4. Persistence & Serialization
        let state = PhotoEditState(settings: settings, filmID: "some_film", masterRecipeID: recipe.id)
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PhotoEditState.self, from: data)
        check(restored.masterRecipeID == recipe.id, "PhotoEditState encodes and decodes masterRecipeID")
        check(restored.filmID == "some_film", "PhotoEditState preserves filmID")

        // Backwards compatibility with legacy JSON lacking masterRecipeID
        let legacyJSON = """
        {
            "settings": {
                "exposure": 0.5,
                "exposureMode": "标准显影",
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

        selectRecipe(recipe)
        check(simMasterRecipeID == recipe.id && simSelectedFilmID.isEmpty,
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

    private static func refinedRecipeApplication() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json"))
        let recipe = try JSONDecoder().decode(MasterRecipe.self, from: data)
        var state = Adjustments()
        state.blackPoint = -20; state.whitePoint = 30; state.vibrance = -25
        state.clarity = -40; state.dehaze = 20; state.toneCurve = 35
        state.temperature = 8000; state.sharpening = 75
        state.applyMasterRecipe(recipe)
        check(state.recipeSettingsVersion == 4, "Refined recipe stores version four only on explicit application")
        check(state.blackPoint == 50 && state.whitePoint == -60 && state.vibrance == 15,
              "Refined recipe replaces all visible tone controls")
        check(state.clarity == 12 && state.dehaze == -6,
              "Refined recipe replaces visible atmosphere controls")
        check(state.gradingSettings.shadows == ColorGradingWheel(hue: 210, saturation: 8) &&
              state.gradingSettings.highlights == ColorGradingWheel(hue: 50, saturation: 12),
              "Refined recipe replaces visible grading controls")
        check(state.curveSettings.mode == .custom && state.curveSettings.points.count == 5 && state.toneCurve == 0,
              "Refined recipe selects its custom curve and clears inactive legacy S curve")
        check(state.temperature == 8000 && state.sharpening == 75,
              "Refinement preserves independent temperature and sharpening")
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(state))
        check(restored == state && restored.recipeSettingsVersion == 4,
              "Refined recipe settings round-trip without catalog reinjection")
        for strength in [0.0, 0.5, 1.0, 2.0] {
            state.strength = strength
            check(state.renderToneSettings.blackPoint == min(100, 50 * strength) &&
                  state.renderToneSettings.whitePoint == max(-100, -60 * strength) &&
                  state.renderToneSettings.vibrance == 15 * strength &&
                  state.renderAtmosphereSettings.clarity == 12 * strength && state.renderAtmosphereSettings.dehaze == -6 * strength,
                  "V4 \(strength): current tone and atmosphere values scale with native limits")
            check(state.renderGradingSettings.shadows.hue == 210 && state.renderGradingSettings.shadows.saturation == 8 * strength,
                  "V4 \(strength): grading amount scales but hue stays fixed")
            let curve = state.renderCurveSettings
            check(curve.isValid && (strength != 0 || curve.isIdentity), "V4 \(strength): effective curve remains valid")
            check(state.blackPoint == 50 && state.curveSettings.points.count == 5,
                  "V4 \(strength): rendering does not rewrite visible controls")
        }
        state.blackPoint = 13.5; state.gradingSettings.shadows.saturation = 17.5
        let edited = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(state))
        check(edited.blackPoint == 13.5 && edited.renderToneSettings.blackPoint == 27 &&
              edited.renderGradingSettings.shadows.saturation == 35,
              "Saved manual refinements are rendered without reinjecting catalog defaults")
        for version in [2, 3] {
            var legacy = state
            legacy.setTransferRecipe(recipe.id, settingsVersion: version)
            legacy.strength = 0
            check(legacy.renderToneSettings == legacy.toneSettings && legacy.renderCurveSettings == legacy.curveSettings &&
                  legacy.renderGradingSettings == legacy.gradingSettings && legacy.renderAtmosphereSettings == legacy.atmosphereSettings,
                  "Version \(version) preserves independent refinements even at zero recipe strength")
        }
        state.curveSettings = ToneCurveSettings()
        state.toneCurve = 30; state.strength = 0.5
        var request = sony2fuji_request()
        state.apply(to: &request)
        check(abs(request.tone_curve - 0.15) < 1e-6, "V4 manually selected legacy curve participates in strength")
    }
}
