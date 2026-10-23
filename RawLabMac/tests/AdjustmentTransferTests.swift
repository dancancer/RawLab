import Foundation

@main
struct AdjustmentTransferTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError(message) } catch { print("PASS: \(message)") }
    }

    static func state(_ settings: Adjustments = Adjustments(), film: String = "") -> PhotoEditState {
        PhotoEditState(settings: settings, filmID: film, masterRecipeID: settings.masterRecipeID)
    }

    static var raw: MacAdjustmentTransferContext {
        MacAdjustmentTransferContext(identifier: "photo-A", isRaw: true,
            availableLookIDs: ["builtin:PROVIA.cube", "recipe:hamada_daylight_v2"])
    }

    static func request(_ state: PhotoEditState) -> sony2fuji_request {
        var request = sony2fuji_request()
        state.settings.apply(to: &request)
        return request
    }

    static func main() throws {
        try postRGBCompatibility()
        try scopesAndFreeze()
        try recipeConversions()
        try whiteBalanceAndCompatibility()
        try preservationAndLegacy()
        try whiteBalanceGuards()
        try independentRequestFields()
        try serialization()
        try sharedFixtures()
    }

    static func postRGBCompatibility() throws {
        let key = "detail.denoise.post_rgb"
        let source = AdjustmentTransferSource(identifier: "ios-photo", isRaw: true, processingVersion: 2, recipe: nil)
        let zero = try AdjustmentTransferPayload(source: source, values: [key: .number(0)])
        let before = state()
        check(try MacAdjustmentTransfer.prepare(payload: zero, target: before, context: raw) == before,
            "Post-RGB zero is representable without changing Mac denoise")
        let legacy = try AdjustmentTransferPayload(source: source, values: [key: .number(0.25)])
        rejects("Post-RGB denoise never maps to Mac RAW FBDD") {
            _ = try MacAdjustmentTransfer.prepare(payload: legacy, target: before, context: raw)
        }
        let all = try MacAdjustmentTransfer.capture(scope: .all, snapshot: before, context: raw)
        check(all.values[key] == .number(0), "Mac all scope explicitly captures supported post-RGB zero")
        rejects("Out-of-range post-RGB requests are rejected") {
            _ = try AdjustmentTransferPayload(source: source, values: [key: .number(1.1)])
        }
        rejects("Raster cannot claim an active post-RGB request") {
            _ = try AdjustmentTransferPayload(source: .init(identifier: "png", isRaw: false, processingVersion: 2, recipe: nil),
                values: [key: .number(0.25)])
        }
    }

    static func scopesAndFreeze() throws {
        var source = Adjustments()
        source.exposure = 1.25
        source.contrast = 20
        source.geometry = GeometrySettings()
        source.geometry?.straightenDegrees = 3
        source.resolveWhiteBalance(WhiteBalance(temperature: 5123, tint: 17))
        var hsl = HSLSettings()
        check(hsl.setExact(.hue, channel: 0, value: 12.375), "Exact HSL accepts valid fractional values")
        source.hsl = hsl
        let standard = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(!standard.fields.contains(.cropX) && standard.fields.isDisjoint(with: AdjustmentTransferField.lensFields), "Default excludes geometry and lens")
        let all = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        check(all.fields == Set(AdjustmentTransferField.allCases), "Explicit all contains every supported field")
        let modified = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == [.exposure, .contrast, .hslHueRed], "Modified uses logical defaults and excludes geometry")
        var target = Adjustments()
        target.exposure = -2; target.contrast = -10; target.sharpening = 47
        target.processing = .legacy
        target.resolveWhiteBalance(WhiteBalance(temperature: 6001, tint: -8))
        let before = state(target, film: "builtin:PROVIA.cube")
        let payload = try MacAdjustmentTransfer.capture(scope: .custom([.exposure, .hslHueRed]), snapshot: state(source), context: raw)
        source.exposure = 3
        source.hsl = nil
        let result = try MacAdjustmentTransfer.prepare(payload: payload, target: before, context: raw)
        var expected = before
        expected.settings.exposure = 1.25
        expected.settings.hsl = hsl
        check(result == expected, "Custom paste freezes source and preserves all unselected fields and target metadata")
        check(try MacAdjustmentTransfer.prepare(payload: payload, target: result, context: raw) == result,
              "Repeated paste is idempotent")
        rejects("Empty modified source is not a usable clipboard") {
            _ = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(), context: raw)
        }
        var draft = raw; draft.hasUncommittedDraft = true
        rejects("Source draft requires preflight") {
            _ = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: draft)
        }
        rejects("Target draft requires preflight") {
            _ = try MacAdjustmentTransfer.prepare(payload: payload, target: before, context: draft)
        }
    }

    static func recipeConversions() throws {
        var source = Adjustments()
        source.applyMasterRecipe(.hamadaDaylightV2)
        source.exposure = 1.4; source.contrast = 40; source.strength = 0.5
        let selected: Set<AdjustmentTransferField> = [.exposure, .contrast]
        let payload = try MacAdjustmentTransfer.capture(scope: .custom(selected), snapshot: state(source), context: raw)
        let plain = try MacAdjustmentTransfer.prepare(payload: payload, target: state(), context: raw)
        check(request(plain).exposure_ev == 0.7 && request(plain).contrast == 1.2,
              "Partial recipe paste materializes source strength exactly once")
        check(plain.settings.masterRecipeID == nil && plain.filmID.isEmpty, "Partial paste does not select source look")
        var target = Adjustments()
        target.applyMasterRecipe(.hamadaDaylightV2)
        target.strength = 0.5; target.saturation = 13; target.tint = 0
        let before = state(target)
        let merged = try MacAdjustmentTransfer.prepare(payload: payload, target: before, context: raw)
        check(request(merged).exposure_ev == request(plain).exposure_ev && request(merged).contrast == request(plain).contrast,
              "Representable recipe target inversely maps selected contributions")
        check(merged.settings.saturation == target.saturation && merged.settings.strength == target.strength
            && merged.masterRecipeID == before.masterRecipeID, "Recipe target keeps unselected context")
        source.contrast = 80; source.strength = 1
        let wide = try MacAdjustmentTransfer.capture(scope: .custom([.contrast]), snapshot: state(source), context: raw)
        rejects("Unrepresentable recipe target is blocked without clamping") {
            _ = try MacAdjustmentTransfer.prepare(payload: wide, target: before, context: raw)
        }
        source.strength = 0
        let zero = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(zero.fields.contains(.contrast) && zero.fields.contains(.exposure), "Zero strength does not hide logical changes")
        let full = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        let restored = try MacAdjustmentTransfer.prepare(payload: full, target: state(), context: raw)
        check(restored.settings.masterRecipeID == source.masterRecipeID && restored.settings.contrast == source.contrast
            && restored.settings.strength == 0, "Full recipe retains zero-strength logical values")
    }

    static func whiteBalanceAndCompatibility() throws {
        var source = Adjustments()
        source.resolveWhiteBalance(WhiteBalance(temperature: 4000, tint: 20))
        var target = Adjustments()
        target.resolveWhiteBalance(WhiteBalance(temperature: 6200, tint: -9))
        let payload = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(source), context: raw)
        let result = try MacAdjustmentTransfer.prepare(payload: payload, target: state(target), context: raw)
        check(result.settings.usesAsShotWhiteBalance && result.settings.asShotWhiteBalance == target.asShotWhiteBalance,
              "Camera WB resolves against target rather than copying source calibration")
        source.whiteBalanceMode = .custom; source.temperature = 5400; source.tint = 3.5
        let fixed = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(source), context: raw)
        let custom = try MacAdjustmentTransfer.prepare(payload: fixed, target: state(target), context: raw)
        check(custom.settings.temperature == 5400 && custom.settings.tint == 3.5 && custom.settings.whiteBalanceMode == .custom,
              "Fixed white balance keeps absolute values")
        var raster = raw; raster.isRaw = false
        let rasterMode = try MacAdjustmentTransfer.capture(scope: .custom([.exposureMode]), snapshot: state(), context: raster)
        check(try MacAdjustmentTransfer.prepare(payload: rasterMode, target: state(), context: raw).settings.exposureMode == .sensor,
              "Explicit sensor mode from raster remains sensor on RAW instead of using a native default")
        rejects("RAW white balance is explicitly incompatible with raster target") {
            _ = try MacAdjustmentTransfer.prepare(payload: fixed, target: state(), context: raster)
        }
        let look = try MacAdjustmentTransfer.capture(scope: .custom([.look]), snapshot: state(source, film: "builtin:PROVIA.cube"), context: raw)
        var missing = raw; missing.availableLookIDs = []
        rejects("Missing selected look blocks preparation") {
            _ = try MacAdjustmentTransfer.prepare(payload: look, target: state(), context: missing)
        }
    }

    static func serialization() throws {
        var source = Adjustments(); source.exposure = 1
        let payload = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(source), context: raw)
        let bytes = try JSONEncoder().encode(payload)
        check(try JSONDecoder().decode(AdjustmentTransferPayload.self, from: bytes) == payload, "Logical payload round-trips")
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        json["payload_version"] = 99
        rejects("Future payload version rejected") {
            _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: json))
        }
        json["payload_version"] = 1; json["unexpected"] = true
        rejects("Unknown root payload field rejected") {
            _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: json))
        }
        json.removeValue(forKey: "unexpected")
        json["values"] = ["future.parameter": 1]
        rejects("Unknown selected field rejected") {
            _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: json))
        }
        for bad: Any in [true, "1", 21, ["unexpected": 1]] {
            json["values"] = ["light.exposure": bad]
            rejects("Malformed or out-of-range selected scalar rejected") {
                _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: json))
            }
        }
    }

    static func whiteBalanceGuards() throws {
        var recipe = Adjustments(); recipe.applyMasterRecipe(.hamadaDaylightV2)
        recipe.tint = 5; recipe.strength = 1
        let look = try MacAdjustmentTransfer.capture(scope: .custom([.look]),
            snapshot: state(film: "builtin:PROVIA.cube"), context: raw)
        rejects("Detaching target recipe cannot materialize missing camera calibration") {
            _ = try MacAdjustmentTransfer.prepare(payload: look, target: state(recipe), context: raw)
        }
        let balance = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(recipe), context: raw)
        var extreme = Adjustments(); extreme.resolveWhiteBalance(WhiteBalance(temperature: 6000, tint: 149))
        rejects("Relative WB beyond target's representable tint range is blocked") {
            _ = try MacAdjustmentTransfer.prepare(payload: balance, target: state(extreme), context: raw)
        }
        let full = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(recipe), context: raw)
        rejects("Full recipe requiring target WB calibration blocks until metadata is available") {
            _ = try MacAdjustmentTransfer.prepare(payload: full, target: state(), context: raw)
        }
        rejects("Full recipe WB checks target range before retaining identity") {
            _ = try MacAdjustmentTransfer.prepare(payload: full, target: state(extreme), context: raw)
        }
        rejects("RAW payload cannot declare unsupported none white balance") {
            _ = try AdjustmentTransferPayload(source: .init(identifier: "bad", isRaw: true, processingVersion: 2, recipe: nil),
                values: [AdjustmentTransferField.whiteBalanceMode.rawValue: .string("none"),
                    AdjustmentTransferField.temperature.rawValue: .null, AdjustmentTransferField.tint.rawValue: .null])
        }
        rejects("Raster payload cannot smuggle fixed camera WB that would be silently discarded") {
            _ = try AdjustmentTransferPayload(source: .init(identifier: "bad", isRaw: false, processingVersion: 2, recipe: nil),
                values: [AdjustmentTransferField.temperature.rawValue: .number(5000)])
        }
        check(AdjustmentTransferField.whiteBalanceFields.isSubset(of: AdjustmentTransferField.recipeDependencies), "Full recipe dependency set includes WB")
    }

    static func independentRequestFields() throws {
        let all = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(), context: raw)
        let required = ["color.white_balance.mode", "color.white_balance.temperature_kelvin", "color.white_balance.tint",
            "geometry.crop.x", "geometry.crop.y", "geometry.crop.width", "geometry.crop.height",
            "geometry.lens.distortion", "geometry.lens.tca", "geometry.lens.auto_crop", "geometry.lens.profile_id",
            "detail.denoise.raw_level", "detail.denoise.chroma_mode", "detail.denoise.wavelet"]
        check(required.allSatisfy { all.values[$0] != nil }, "Request fields follow the independent stable field catalog")
        var source = Adjustments(); source.whiteBalanceMode = .custom; source.temperature = 4100; source.tint = 12
        var target = Adjustments(); target.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 8))
        target.whiteBalanceMode = .custom; target.temperature = 6200; target.tint = -9
        let temperature = try MacAdjustmentTransfer.capture(scope: .custom([.temperature]), snapshot: state(source), context: raw)
        let changedTemperature = try MacAdjustmentTransfer.prepare(payload: temperature, target: state(target), context: raw)
        var expected = target; expected.temperature = 4100
        check(changedTemperature == state(expected), "Temperature-only paste preserves custom tint and mode")
        let tint = try MacAdjustmentTransfer.capture(scope: .custom([.tint]), snapshot: state(source), context: raw)
        let changedTint = try MacAdjustmentTransfer.prepare(payload: tint, target: state(target), context: raw)
        expected = target; expected.tint = 12
        check(changedTint == state(expected), "Tint-only paste preserves custom Kelvin and mode")
        let mode = try MacAdjustmentTransfer.capture(scope: .custom([.whiteBalanceMode]), snapshot: state(), context: raw)
        rejects("Mode-only change cannot silently replace unselected fixed Kelvin") {
            _ = try MacAdjustmentTransfer.prepare(payload: mode, target: state(target), context: raw)
        }
        rejects("Fixed Kelvin requires an explicitly compatible target mode") {
            _ = try MacAdjustmentTransfer.prepare(payload: temperature, target: state(), context: raw)
        }
        source.applyMasterRecipe(.hamadaDaylightV2); source.tint = 5; source.strength = 0.5
        let relative = try MacAdjustmentTransfer.capture(scope: .custom([.tint]), snapshot: state(source), context: raw)
        let relativeApplied = try MacAdjustmentTransfer.prepare(payload: relative, target: state(target), context: raw)
        check(request(relativeApplied).temperature == 6200 && request(relativeApplied).tint == 10.5,
              "Relative tint-only paste resolves target calibration while preserving fixed Kelvin")
        var recipeTarget = Adjustments(); recipeTarget.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 8))
        recipeTarget.applyMasterRecipe(.hamadaDaylightV2); recipeTarget.strength = 0.5
        rejects("Fixed tint-only payload is rejected before relative math on a camera-mode recipe target") {
            _ = try MacAdjustmentTransfer.prepare(payload: tint, target: state(recipeTarget), context: raw)
        }
        let fixedModeTint = try AdjustmentTransferPayload(source: tint.source,
            values: [AdjustmentTransferField.whiteBalanceMode.rawValue: .string("temperature"),
                AdjustmentTransferField.tint.rawValue: tint[.tint]!])
        let fixedTintResult = try MacAdjustmentTransfer.prepare(payload: fixedModeTint, target: state(recipeTarget), context: raw)
        check(request(fixedTintResult).tint == 12 && fixedTintResult.settings.temperature == recipeTarget.temperature,
              "Selecting mode with fixed tint preserves target Kelvin and does not add camera tint twice")
        let recipeApplied = try MacAdjustmentTransfer.prepare(payload: relative, target: state(recipeTarget), context: raw)
        check(recipeApplied.settings.whiteBalanceMode == .asShot && request(recipeApplied).tint == 10.5,
              "Relative tint-only recipe target retains camera mode")
        recipeTarget.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 149))
        recipeTarget.whiteBalanceMode = .custom; recipeTarget.temperature = 6200; recipeTarget.strength = 1
        let clipped = try MacAdjustmentTransfer.prepare(payload: temperature, target: state(recipeTarget), context: raw)
        check(clipped.settings.tint == recipeTarget.tint && request(clipped).tint == 150,
              "Changing Kelvin preserves unselected native tint even when existing recipe rendering clips it")
        let sameClipped = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(recipeTarget), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: sameClipped, target: state(recipeTarget), context: raw) == state(recipeTarget),
              "Identical existing clipped recipe is unchanged instead of introducing a new clamp")

        source = Adjustments(); source.geometry = GeometrySettings()
        source.geometry?.cropWidth = 0.6
        target = Adjustments(); target.geometry = GeometrySettings()
        target.geometry?.cropX = 0.2; target.geometry?.cropY = 0.1
        target.geometry?.cropWidth = 0.3; target.geometry?.cropHeight = 0.5
        let cropWidth = try MacAdjustmentTransfer.capture(scope: .custom([.cropWidth]), snapshot: state(source), context: raw)
        let cropped = try MacAdjustmentTransfer.prepare(payload: cropWidth, target: state(target), context: raw)
        expected = target; expected.geometry?.cropWidth = 0.6
        check(cropped == state(expected), "Crop width is independently selected and keeps position and height")
        source.geometry?.cropX = 0.8; source.geometry?.cropWidth = 0.2
        let cropX = try MacAdjustmentTransfer.capture(scope: .custom([.cropX]), snapshot: state(source), context: raw)
        rejects("Independently valid crop X is blocked when merged rectangle would exceed canvas") {
            _ = try MacAdjustmentTransfer.prepare(payload: cropX, target: state(target), context: raw)
        }
        var rasterContext = raw; rasterContext.isRaw = false
        for request: [String: AdjustmentTransferValue] in [
            ["geometry.lens.profile_id": .string("fixture-profile")],
            ["geometry.lens.auto_crop": .boolean(false)]
        ] {
            let unsupported = try AdjustmentTransferPayload(source: .init(identifier: "source", isRaw: true,
                processingVersion: 2, recipe: nil), values: request)
            rejects("Raster rejects selected inactive lens request instead of dropping it") {
                _ = try MacAdjustmentTransfer.prepare(payload: unsupported, target: state(), context: rasterContext)
            }
        }
        source = Adjustments(); source.lensCorrection = LensCorrectionSettings(distortion: true)
        target.lensCorrection = LensCorrectionSettings(tca: true, autoCrop: false, mode: .manual, profileID: "target-profile")
        let distortion = try MacAdjustmentTransfer.capture(scope: .custom([.lensDistortion]), snapshot: state(source), context: raw)
        rejects("Enabled lens request requires target calibration preflight") {
            _ = try MacAdjustmentTransfer.prepare(payload: distortion, target: state(target), context: raw)
        }
        var lensContext = raw
        lensContext.validateLensRequest = { request in
            guard request.profileID == "target-profile" else { throw AdjustmentTransferError.incompatible("missing lens profile") }
        }
        let corrected = try MacAdjustmentTransfer.prepare(payload: distortion, target: state(target), context: lensContext)
        expected = target; expected.lensCorrection?.distortion = true
        check(corrected == state(expected), "Lens distortion selection preserves TCA, auto crop and target profile request")
        source.rawNoiseReduction = 1
        target.resolveRawNoiseReductionSupport(true); target.rawNoiseReduction = 2; target.chromaNoiseReduction = 2
        let rawDenoise = try MacAdjustmentTransfer.capture(scope: .custom([.rawDenoise]), snapshot: state(source), context: raw)
        let denoised = try MacAdjustmentTransfer.prepare(payload: rawDenoise, target: state(target), context: raw)
        expected = target; expected.rawNoiseReduction = 1
        check(denoised == state(expected), "RAW denoise selection preserves the separate chroma request")
    }

    static func sharedFixtures() throws {
        let url = URL(fileURLWithPath: "Shared/fixtures/adjustment-transfer-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let vectors = root["vectors"] as! [[String: Any]]
        for vector in vectors {
            let id = vector["id"] as! String
            let bytes = try JSONSerialization.data(withJSONObject: vector["payload"]!)
            if vector["valid"] as! Bool {
                let payload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: bytes)
                if let expected = vector["neutral_effective"] as? [String: Double] {
                    let candidate = try MacAdjustmentTransfer.prepare(payload: payload, target: state(), context: raw)
                    let actual = MacAdjustmentTransfer.effectiveNumbers(candidate.settings)
                    check(expected.allSatisfy { Float(actual[AdjustmentTransferField(rawValue: $0.key)!]!) == Float($0.value) },
                          "Shared effective vector: \(id)")
                }
                check(try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(payload)) == payload,
                      "Shared accepted vector: \(id)")
            } else {
                rejects("Shared rejected vector: \(id)") { _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: bytes) }
            }
        }
    }

    static func preservationAndLegacy() throws {
        var source = Adjustments(); source.strength = 0.7
        let strength = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: state(source), context: raw)
        var target = Adjustments()
        target.contrast = 13.37; target.saturation = -16.29
        target.photoEffects = PhotoEffectsSettings()
        target.hsl = HSLSettings()
        target.geometry = GeometrySettings()
        let before = state(target, film: "builtin:PROVIA.cube")
        var expected = before; expected.settings.strength = 0.7
        check(try MacAdjustmentTransfer.prepare(payload: strength, target: before, context: raw) == expected,
              "Independent look strength preserves exact unselected native values")
        let all = try MacAdjustmentTransfer.capture(scope: .all, snapshot: before, context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: all, target: before, context: raw) == before,
              "Same-content all paste does not normalize optional identity objects into a change")

        source.applyMasterRecipe(.hamadaDaylightV2); source.strength = 0.5; source.tint = 5
        source.hsl = HSLSettings()
        source.hsl?.setExact(.hue, channel: 0, value: 37.25)
        source.setTransferRecipe(source.masterRecipeID, settingsVersion: 2)
        let legacy = try MacAdjustmentTransfer.capture(scope: .custom([.hslHueRed]), snapshot: state(source), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: legacy, target: state(), context: raw).settings.hslSettings.hue[0] == 37.25,
              "Legacy recipe HSL is not multiplied by strength")
        let partialLook = try MacAdjustmentTransfer.capture(scope: .custom([.look, .contrast]), snapshot: state(source), context: raw)
        let independent = try MacAdjustmentTransfer.prepare(payload: partialLook, target: before, context: raw)
        check(independent.masterRecipeID == nil && independent.filmID == "recipe-lut:hamada_daylight_v2"
            && independent.settings.saturation == target.saturation, "Partial recipe look becomes an independent LUT reference")

        var raster = raw; raster.isRaw = false
        let style = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(source), context: raster)
        var cameraTarget = Adjustments(); cameraTarget.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 8))
        let applied = try MacAdjustmentTransfer.prepare(payload: style, target: state(cameraTarget), context: raw)
        check(request(applied).temperature == 5200 && request(applied).tint == 10.5,
              "Raster recipe tint remains a relative style resolved against the RAW target")
        let bytes = try JSONEncoder().encode(style)
        check(!String(decoding: bytes, as: UTF8.self).contains("asShot"), "Payload never serializes source camera metadata")

        var recipeTarget = cameraTarget; recipeTarget.applyMasterRecipe(.hamadaDaylightV2)
        recipeTarget.strength = 0.5
        var fixed = Adjustments(); fixed.whiteBalanceMode = .custom; fixed.temperature = 5000; fixed.tint = 0
        let balance = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(fixed), context: raw)
        let resolved = try MacAdjustmentTransfer.prepare(payload: balance, target: state(recipeTarget), context: raw)
        check(request(resolved).temperature == 5000 && request(resolved).tint == 0,
              "Fixed WB inversely maps target recipe tint instead of adding it twice")
        var invalid = raw; invalid.availableLookIDs = []
        rejects("Full recipe with missing target LUT is blocked") {
            _ = try MacAdjustmentTransfer.prepare(payload: MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw),
                target: state(), context: invalid)
        }
    }
}
