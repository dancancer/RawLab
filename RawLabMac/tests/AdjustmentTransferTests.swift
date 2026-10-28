import Foundation

@main
struct AdjustmentTransferTests {
    static var legacyRecipe: MasterRecipe {
        // 固定测试旧版本的独立控制语义，不随 bundled catalog 的版本升级。
        let data = try! JSONEncoder().encode(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        var row = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["settingsVersion", "tone", "atmosphere", "grading", "curve"] { row.removeValue(forKey: key) }
        return try! JSONDecoder().decode(MasterRecipe.self, from: JSONSerialization.data(withJSONObject: row))
    }
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


    static func atmospherePersistence() throws {
        let input = Data("{\"atmosphere\":{\"clarity\":-37.25,\"dehaze\":42.5}}".utf8)
        let settings = try JSONDecoder().decode(Adjustments.self, from: input)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        let atmosphere = json["atmosphere"] as? [String: Double]
        check(atmosphere == ["clarity": -37.25, "dehaze": 42.5], "Atmosphere values survive a persisted edit round trip")
    }

    static func atmosphereControls() throws {
        var source = Adjustments()
        source.clarity = -37.251234; source.dehaze = 42.5
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(source))
        check(restored == source, "Atmosphere precision survives persistence")
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(old.atmosphere == nil && old.atmosphereSettings.isIdentity, "Missing atmosphere extension is identity")
        let zero = try JSONDecoder().decode(Adjustments.self, from: Data("{\"atmosphere\":{\"clarity\":0,\"dehaze\":0}}".utf8))
        check(zero.atmosphere == nil, "Explicit identity atmosphere normalizes to absent storage")
        for invalid in [-100.001, 100.001] {
            for field in ["clarity", "dehaze"] {
                rejects("Out-of-range atmosphere is rejected on load") {
                    let json = try JSONSerialization.data(withJSONObject: ["atmosphere": ["clarity": field == "clarity" ? invalid : 0, "dehaze": field == "dehaze" ? invalid : 0]])
                    _ = try JSONDecoder().decode(Adjustments.self, from: json)
                }
            }
        }
        let fields: Set<AdjustmentTransferField> = [.clarity, .dehaze]
        let modified = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == fields, "Modified scope contains exactly the atmosphere changes")
        let standard = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(fields.isSubset(of: standard.fields) && fields.allSatisfy { $0.group == "effects" }, "Atmosphere belongs to standard and effects scopes")
        check(try MacAdjustmentTransfer.prepare(payload: modified, target: state(), context: raw).settings.atmosphereSettings == source.atmosphereSettings,
            "Atmosphere paste retains exact values")
        var target = Adjustments(); target.clarity = 71; target.dehaze = -29
        let partial = try MacAdjustmentTransfer.capture(scope: .custom([.dehaze]), snapshot: state(source), context: raw)
        let merged = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.clarity == 71 && merged.settings.dehaze == 42.5, "Partial paste preserves unselected clarity")
        let legacy = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.atmosphereSettings == target.atmosphereSettings,
            "Legacy payload preserves target atmosphere")
        source.applyMasterRecipe(legacyRecipe); source.strength = 0
        target.applyMasterRecipe(legacyRecipe); target.strength = 0
        let recipe = try MacAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: recipe, target: state(target), context: raw).settings.atmosphereSettings == source.atmosphereSettings,
            "Atmosphere is independent of zero recipe strength")
        var effects = Adjustments(); effects.clarity = 31; effects.dehaze = -23; effects.vibrance = 19
        let resetContext = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "")
        check(EditorAdjustmentRules.isModified(scope: .group(.effects), snapshot: state(effects), context: resetContext), "Atmosphere-only edits mark effects group modified")
        if case .candidate(let reset) = EditorAdjustmentRules.prepareReset(scope: .group(.effects), snapshot: state(effects), context: resetContext) {
            check(reset.settings.atmosphereSettings.isIdentity && reset.settings.vibrance == 19, "Effects reset clears atmosphere and preserves color")
        } else { fatalError("Atmosphere reset must prepare a candidate") }
    }

    static func toneControls() throws {
        var source = Adjustments()
        source.blackPoint = -37.25; source.whitePoint = 42.5; source.vibrance = 18.125
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(source))
        check(restored == source, "Tone controls persist as one optional object")
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(old.toneControls == nil && old.toneSettings.isIdentity, "Legacy missing tone object retains identity")
        for invalid in [-100.1, 100.1] {
            rejects("Persisted tone values outside the UI range are rejected") {
                _ = try JSONDecoder().decode(Adjustments.self, from: Data("{\"toneControls\":{\"blackPoint\":\(invalid),\"whitePoint\":0,\"vibrance\":0}}".utf8))
            }
        }
        let fields: Set<AdjustmentTransferField> = [.blackPoint, .whitePoint, .vibrance]
        let modified = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == fields, "Modified scope includes exactly the changed tone fields")
        let standard = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(fields.isSubset(of: standard.fields), "Standard copy includes all tone fields")
        let applied = try MacAdjustmentTransfer.prepare(payload: modified, target: state(), context: raw)
        check(applied.settings.toneSettings == source.toneSettings, "Tone transfer keeps exact UI units")
        var target = Adjustments()
        target.blackPoint = 71; target.whitePoint = -29; target.vibrance = -63
        let partial = try MacAdjustmentTransfer.capture(scope: .custom([.whitePoint]), snapshot: state(source), context: raw)
        let merged = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.blackPoint == 71 && merged.settings.whitePoint == 42.5 && merged.settings.vibrance == -63,
            "Partial tone paste preserves unselected target fields")
        let legacy = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.toneSettings == target.toneSettings,
            "Legacy payload omitting tone fields does not reset target tone")
        source.applyMasterRecipe(legacyRecipe)
        source.strength = 0
        target.applyMasterRecipe(legacyRecipe)
        target.strength = 0
        let recipeCopy = try MacAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        let recipeMerged = try MacAdjustmentTransfer.prepare(payload: recipeCopy, target: state(target), context: raw)
        check(recipeMerged.settings.toneSettings == source.toneSettings,
            "Tone controls remain independent of source and target recipe strength, including zero")
        var resetSource = source
        resetSource.setTransferRecipe(nil)
        let resetContext = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "")
        let snapshot = state(resetSource)
        check(EditorAdjustmentRules.isModified(scope: .group(.light), snapshot: snapshot, context: resetContext)
            && EditorAdjustmentRules.isModified(scope: .tool(.vibrance), snapshot: snapshot, context: resetContext),
            "New controls participate in group and tool modified state")
        if case .candidate(let reset) = EditorAdjustmentRules.prepareReset(scope: .group(.light), snapshot: snapshot, context: resetContext) {
            check(reset.settings.blackPoint == 0 && reset.settings.whitePoint == 0 && reset.settings.vibrance == 18.125,
                "Light reset clears black and white point while preserving vibrance")
        } else { fatalError("Tone light reset must prepare a candidate") }
        resetSource.reset(.color)
        check(resetSource.vibrance == 0 && resetSource.blackPoint == -37.25, "Color reset clears vibrance and preserves black point")
        check(AdjustmentTransferField.blackPoint.group == "light" && AdjustmentTransferField.whitePoint.group == "light"
            && AdjustmentTransferField.vibrance.group == "color", "Tone controls appear in light and color copy groups")
    }

    static func colorGrading() throws {
        var source = Adjustments()
        source.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        source.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        source.gradingSettings[.highlights] = ColorGradingWheel(hue: 359.999999, saturation: 99.5)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(source))
        check(restored == source, "All grading values persist exactly, including pending hue")
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(old.colorGrading == nil && old.gradingSettings.isDefault, "Old settings missing grading remain default")
        let zeroJSON = try JSONSerialization.data(withJSONObject: ["colorGrading": ["shadows": ["hue": 0, "saturation": 0],
            "midtones": ["hue": 0, "saturation": 0], "highlights": ["hue": 0, "saturation": 0]]])
        check(try JSONDecoder().decode(Adjustments.self, from: zeroJSON).colorGrading == nil,
            "Explicit all-zero grading normalizes to the same storage default")
        check(ColorGradingWheel.inputHue(360) == 0 && ColorGradingWheel.inputHue(-1) == nil
            && ColorGradingWheel.inputHue(361) == nil, "Only the UI hue endpoint wraps; out-of-range input is rejected")
        let pending = ColorGradingWheel(hue: 215, saturation: 0)
        check(pending.isIdentity && !pending.isDefault && pending.moving(toX: 0, y: 0) == pending,
            "Wheel center preserves pending hue without affecting pixels")
        for (x, y, expected) in [(1.0, 0.0, 0.0), (0, 1, 90), (-1, 0, 180), (0, -1, 270)] {
            let wheel = pending.moving(toX: x, y: y)
            check(wheel.hue == expected && wheel.saturation == 100, "Wheel coordinates follow the shared clockwise hue convention")
        }
        let fine = ColorGradingDrag(initial: ColorGradingWheel(hue: 0, saturation: 20), originX: 0.8, originY: 0.4, fine: true)
        check(fine.value(x: 0.8, y: 0.4) == fine.initial && abs(fine.value(x: 1.2, y: 0.4).saturation - 30) < 1e-6,
            "Fine drag starts at the existing handle and scales pointer movement by one quarter")
        check(pending.moving(toX: 1, y: -Double.leastNonzeroMagnitude).hue == 0, "Internal negative angle rounding stays canonical")
        let fields: Set<AdjustmentTransferField> = [.gradingShadows, .gradingMidtones, .gradingHighlights]
        let captured = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(captured.fields == fields, "Modified copy includes complete grading objects and pending hue")
        check(fields.isSubset(of: try MacAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw).fields),
            "Standard copy includes all three grading zones")
        let roundTrip = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(captured))
        check(roundTrip == captured, "Grading payload JSON round-trips exactly")
        var target = Adjustments()
        target.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        target.gradingSettings[.highlights] = ColorGradingWheel(hue: 50, saturation: 15.125)
        let partial = try MacAdjustmentTransfer.capture(scope: .custom([.gradingMidtones]), snapshot: state(source), context: raw)
        let merged = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.gradingSettings.midtones == source.gradingSettings.midtones
            && merged.settings.gradingSettings.shadows == target.gradingSettings.shadows
            && merged.settings.gradingSettings.highlights == target.gradingSettings.highlights,
            "Partial grading paste preserves both unselected zones")
        let legacy = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.gradingSettings == target.gradingSettings,
            "Old payloads do not reset grading")
        source.applyMasterRecipe(legacyRecipe)
        target.applyMasterRecipe(legacyRecipe)
        source.strength = 0; target.strength = 0
        let recipeCopy = try MacAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        check(try MacAdjustmentTransfer.prepare(payload: recipeCopy, target: state(target), context: raw).settings.gradingSettings == source.gradingSettings,
            "Grading is independent of recipe strength, including zero")
        let valid: [String: Any] = ["shadows": ["hue": 231.25, "saturation": 0],
            "midtones": ["hue": 0, "saturation": 0], "highlights": ["hue": 0, "saturation": 0]]
        for wheel in [["hue": -0.1, "saturation": 0], ["hue": 360, "saturation": 0], ["hue": 0, "saturation": 100.01],
                      ["hue": 0], ["hue": 0, "saturation": 0, "lightness": 0]] {
            var invalid = valid; invalid["shadows"] = wheel
            rejects("Persisted grading rejects incomplete, unknown and out-of-range wheel fields") {
                _ = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: ["colorGrading": invalid]))
            }
            rejects("Transfer rejects incomplete, unknown and out-of-range wheel fields") {
                let value = AdjustmentTransferValue.object(wheel.mapValues { .number($0) })
                _ = try AdjustmentTransferPayload(source: captured.source, values: [AdjustmentTransferField.gradingShadows.rawValue: value])
            }
        }
        var incomplete = valid; incomplete.removeValue(forKey: "midtones")
        rejects("Persisted grading requires all three zones when the object is present") {
            _ = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: ["colorGrading": incomplete]))
        }
        var resetSource = Adjustments()
        resetSource.gradingSettings = source.gradingSettings
        let context = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "")
        let snapshot = state(resetSource)
        if case .candidate(let reset) = EditorAdjustmentRules.prepareReset(scope: .gradingZone(.midtones), snapshot: snapshot, context: context) {
            check(reset.settings.gradingSettings.midtones.isDefault && reset.settings.gradingSettings.shadows == source.gradingSettings.shadows
                && reset.settings.gradingSettings.highlights == source.gradingSettings.highlights, "Zone reset preserves sibling precision")
        } else { fatalError("Expected grading zone reset") }
        for scope in [EditorResetScope.allGrading, .group(.color), .tool(.colorGrading)] {
            if case .candidate(let reset) = EditorAdjustmentRules.prepareReset(scope: scope, snapshot: snapshot, context: context) {
                check(reset.settings.gradingSettings.isDefault, "Tool and color-group resets clear every grading value")
            } else { fatalError("Expected grading reset") }
        }
    }

    static func toneCurve() throws {
        var source = Adjustments()
        source.toneCurve = 65
        source.curveSettings = ToneCurveSettings.identity.inserting(x: 0.25, y: 0.12).inserting(x: 0.75, y: 0.88)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(source))
        check(restored == source, "Curve mode, binary64 points and inactive legacy scalar persist")
        let modified = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields.contains(.curve) && modified.fields.contains(.sCurve), "Modified scope keeps curve and inactive legacy scalar")
        let partial = try MacAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: state(source), context: raw)
        var target = Adjustments()
        target.toneCurve = -25
        let merged = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.curveSettings == source.curveSettings && merged.settings.toneCurve == -25,
            "Pasting curve mode and points preserves unselected legacy scalar")
        let scalar = try MacAdjustmentTransfer.capture(scope: .custom([.sCurve]), snapshot: state(target), context: raw)
        let legacyOnly = try MacAdjustmentTransfer.prepare(payload: scalar, target: state(source), context: raw)
        check(legacyOnly.settings.curveSettings == source.curveSettings && legacyOnly.settings.toneCurve == -25,
            "Old scalar-only payload preserves unselected custom curve mode")
        let bytes = try JSONEncoder().encode(partial)
        check(try JSONDecoder().decode(AdjustmentTransferPayload.self, from: bytes) == partial, "Curve payload round trip")
        var bad = source
        bad.curveSettings.points[1].x = 0
        rejects("Invalid native curve cannot enter a transfer") {
            _ = try MacAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: state(bad), context: raw)
        }
    }

    static func main() throws {
        try refinedRecipeTransfers()
        try toneCurve()
        try colorGrading()
        let pendingHue = Data(#"{"colorGrading":{"shadows":{"hue":231.25,"saturation":0},"midtones":{"hue":0,"saturation":0},"highlights":{"hue":0,"saturation":0}}}"#.utf8)
        let gradingRestored = try JSONDecoder().decode(Adjustments.self, from: pendingHue)
        let gradingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gradingRestored)) as! [String: Any]
        check(gradingJSON["colorGrading"] != nil, "Pending grading hue survives a persisted edit even with zero saturation")
        try atmospherePersistence()
        try atmosphereControls()
        try toneControls()
        try aiDenoiseBoundary()
        try postRGBCompatibility()
        try scopesAndFreeze()
        try recipeConversions()
        try whiteBalanceAndCompatibility()
        try preservationAndLegacy()
        try whiteBalanceGuards()
        try independentRequestFields()
        try serialization()
        try manualLensSelectionTransport()
        try sharedFixtures()
    }

    static func aiDenoiseBoundary() throws {
        var source = Adjustments(); source.aiDenoiseEnabled = true; source.exposure = 0.5
        rejects("All scope cannot silently omit active AI denoising") {
            _ = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        }
        rejects("Modified scope cannot silently omit active AI denoising") {
            _ = try MacAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        }
        let exposure = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(source), context: raw)
        var target = Adjustments(); target.aiDenoiseEnabled = true
        let result = try MacAdjustmentTransfer.prepare(payload: exposure, target: state(target), context: raw)
        check(result.settings.aiDenoiseEnabled && result.settings.exposure == 0.5,
              "Explicit ordinary fields preserve unselected target AI state")
        let denoise = try MacAdjustmentTransfer.capture(scope: .custom([.chromaDenoise]), snapshot: state(), context: raw)
        rejects("Ordinary denoise cannot be reported as applied while target AI overrides it") {
            _ = try MacAdjustmentTransfer.prepare(payload: denoise, target: state(target), context: raw)
        }
        check(try MacAdjustmentTransfer.prepare(payload: denoise, target: state(), context: raw) == state(),
              "Existing AI-off denoise behavior remains unchanged")
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

    static func refinedRecipeTransfers() throws {
        let recipe = try JSONDecoder().decode(MasterRecipe.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json")))
        let fields: Set<AdjustmentTransferField> = [.blackPoint, .whitePoint, .vibrance, .clarity, .dehaze,
            .curve, .sCurve, .gradingShadows, .gradingMidtones, .gradingHighlights]
        var source = Adjustments(); source.applyMasterRecipe(recipe)
        var neutralTarget = Adjustments()
        neutralTarget.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 10))
        for strength in [0.0, 0.5, 1, 2] {
            source.strength = strength
            let partial = try MacAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
            let plain = try MacAdjustmentTransfer.prepare(payload: partial, target: state(), context: raw).settings
            check(plain.masterRecipeID == nil && plain.toneSettings == source.renderToneSettings &&
                  plain.atmosphereSettings == source.renderAtmosphereSettings && plain.gradingSettings == source.renderGradingSettings &&
                  plain.curveSettings == source.renderCurveSettings, "V4 partial paste materializes every new group once at \(strength)")
            let complete = try MacAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
            let restored = try MacAdjustmentTransfer.prepare(payload: complete, target: state(neutralTarget), context: raw).settings
            check(restored.recipeSettingsVersion == 4 && restored.strength == strength && restored.toneSettings == source.toneSettings &&
                  restored.curveSettings == source.curveSettings && restored.gradingSettings == source.gradingSettings,
                  "Complete v4 transfer preserves logical values and version, including zero strength")
        }
        source.strength = 0.5
        let incomplete = try MacAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.recipeDependencies), snapshot: state(source), context: raw)
        let lutOnly = try MacAdjustmentTransfer.prepare(payload: incomplete, target: state(neutralTarget), context: raw)
        check(lutOnly.settings.masterRecipeID == nil && lutOnly.filmID == "recipe-lut:hamada_daylight_v2",
              "Old dependency selection cannot accidentally activate an incomplete v4 recipe")
        var target = Adjustments(); target.applyMasterRecipe(recipe); target.strength = 2; target.tint = 0
        let partial = try MacAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        let merged = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw).settings
        check(merged.masterRecipeID == target.masterRecipeID && merged.renderToneSettings == source.renderToneSettings &&
              merged.renderGradingSettings == source.renderGradingSettings,
              "V4 partial paste into a recipe inversely maps current contributions")
        for (a, b) in zip(merged.renderCurveSettings.points, source.renderCurveSettings.points) {
            check(a.x == b.x && abs(a.y - b.y) < 1e-12, "Inverse curve transfer preserves effective points")
        }
        target.strength = 0
        rejects("Nonidentity refinements cannot enter a zero-strength recipe target") {
            _ = try MacAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        }
        target.strength = 0.5; source.strength = 1
        let strengthOnly = try MacAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: state(source), context: raw)
        let changed = try MacAdjustmentTransfer.prepare(payload: strengthOnly, target: state(target), context: raw).settings
        check(changed.strength == 1 && changed.renderToneSettings == target.renderToneSettings &&
              changed.renderAtmosphereSettings == target.renderAtmosphereSettings && changed.renderGradingSettings == target.renderGradingSettings &&
              changed.renderCurveSettings == target.renderCurveSettings,
              "Changing recipe strength through partial paste preserves all unselected refinement effects")
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
    static func manualLensSelectionTransport() throws {
        var source = Adjustments()
        source.lensCorrection = LensCorrectionSettings(mode: .manual)
        for scope: AdjustmentTransferScope in [.all, .custom([.lensProfile])] {
            let payload = try MacAdjustmentTransfer.capture(scope: scope, snapshot: state(source), context: raw)
            check(payload[.lensProfile] == .string(source.lensSettings.coreProfileID), "Manual lens uses reserved nonempty transport")
            let restored = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(payload))
            check(restored == payload, "Manual lens payload round-trips")
            let applied = try MacAdjustmentTransfer.prepare(payload: restored, target: state(), context: raw)
            check(applied.settings.lensSettings.mode == .manual && applied.settings.lensSettings.profileID == nil,
                "Manual lens without profile preserves selection mode and nil profile")
        }
        let standard = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(standard.fields.isDisjoint(with: AdjustmentTransferField.lensFields), "Default scope excludes manual lens selection")
        source.lensCorrection = LensCorrectionSettings(distortion: true, mode: .manual)
        let enabled = try MacAdjustmentTransfer.capture(scope: .custom([.lensDistortion, .lensProfile]), snapshot: state(source), context: raw)
        var permissive = raw; var validated = false
        permissive.validateLensRequest = { _ in validated = true }
        rejects("Enabled manual lens without profile rejects") {
            _ = try MacAdjustmentTransfer.prepare(payload: enabled, target: state(), context: permissive)
        }
        check(!validated, "Missing manual profile rejects before target validation")
    }

}
