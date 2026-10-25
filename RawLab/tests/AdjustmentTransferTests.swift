import Foundation

@main struct IOSAdjustmentTransferTests {
    static func check(_ value: Bool, _ label: String) {
        guard value else { fatalError(label) }; print("PASS: \(label)")
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError(label) } catch { print("PASS: \(label)") }
    }
    static var raw: IOSAdjustmentTransferContext {
        .init(identifier: "source", isRaw: true,
            availableLookIDs: ["builtin:PROVIA.cube", "recipe:hamada_daylight_v2"],
            builtinLookIDs: ["PROVIA.cube": "PROVIA"], cameraTemperature: 5200, cameraTint: 10)
    }
    static func state(_ settings: RawSettings = .default) -> PhotoEditState {
        .init(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
    }
    static func payload(_ values: [String: AdjustmentTransferValue], recipe: AdjustmentRecipeContext? = nil) throws -> AdjustmentTransferPayload {
        try .init(source: .init(identifier: "frozen", isRaw: true, processingVersion: 2, recipe: recipe), values: values)
    }

    static func atmospherePersistence() throws {
        let input = Data("{\"atmosphere\":{\"clarity\":-37.25,\"dehaze\":42.5}}".utf8)
        let settings = try JSONDecoder().decode(RawSettings.self, from: input)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        let atmosphere = json["atmosphere"] as? [String: Double]
        check(atmosphere == ["clarity": -37.25, "dehaze": 42.5], "Atmosphere values survive a persisted edit round trip")
    }

    static func atmosphereControls() throws {
        var source = RawSettings.default
        source.clarity = -37.251234; source.dehaze = 42.5
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(source))
        check(restored == source, "Atmosphere precision survives persistence")
        let old = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        check(old.atmosphere == nil && old.atmosphereSettings.isIdentity, "Missing atmosphere extension is identity")
        let zero = try JSONDecoder().decode(RawSettings.self, from: Data("{\"atmosphere\":{\"clarity\":0,\"dehaze\":0}}".utf8))
        check(zero.atmosphere == nil, "Explicit identity atmosphere normalizes to absent storage")
        for invalid in [-100.001, 100.001] {
            for field in ["clarity", "dehaze"] {
                rejects("Out-of-range atmosphere is rejected on load") {
                    let json = try JSONSerialization.data(withJSONObject: ["atmosphere": ["clarity": field == "clarity" ? invalid : 0, "dehaze": field == "dehaze" ? invalid : 0]])
                    _ = try JSONDecoder().decode(RawSettings.self, from: json)
                }
            }
        }
        let fields: Set<AdjustmentTransferField> = [.clarity, .dehaze]
        let modified = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == fields, "Modified scope contains exactly the atmosphere changes")
        let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(fields.isSubset(of: standard.fields) && fields.allSatisfy { $0.group == "effects" }, "Atmosphere belongs to standard and effects scopes")
        check(try IOSAdjustmentTransfer.prepare(payload: modified, target: state(), context: raw).settings.atmosphereSettings == source.atmosphereSettings,
            "Atmosphere paste retains exact values")
        var target = RawSettings.default; target.clarity = 71; target.dehaze = -29
        let partial = try IOSAdjustmentTransfer.capture(scope: .custom([.dehaze]), snapshot: state(source), context: raw)
        let merged = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.clarity == 71 && merged.settings.dehaze == 42.5, "Partial paste preserves unselected clarity")
        let legacy = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.atmosphereSettings == target.atmosphereSettings,
            "Legacy payload preserves target atmosphere")
        source.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!); source.lutStrength = 0
        target.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!); target.lutStrength = 0
        let recipe = try IOSAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: recipe, target: state(target), context: raw).settings.atmosphereSettings == source.atmosphereSettings,
            "Atmosphere is independent of zero recipe strength")
        var effects = RawSettings.default; effects.clarity = 31; effects.dehaze = -23; effects.vibrance = 19
        let resetContext = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        check(EditorAdjustmentRules.isModified(.group(.effects), snapshot: state(effects), context: resetContext), "Atmosphere-only edits mark effects group modified")
        if case .candidate(let reset, _) = EditorAdjustmentRules.prepareReset(.group(.effects), snapshot: state(effects), context: resetContext) {
            check(reset.settings.atmosphereSettings.isIdentity && reset.settings.vibrance == 19, "Effects reset clears atmosphere and preserves color")
        } else { fatalError("Atmosphere reset must prepare a candidate") }
    }

    static func toneControls() throws {
        var source = RawSettings.default
        source.blackPoint = -37.25; source.whitePoint = 42.5; source.vibrance = 18.125
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(source))
        check(restored == source, "Tone controls persist as one optional object")
        let old = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        check(old.toneControls == nil && old.toneSettings.isIdentity, "Legacy missing tone object retains identity")
        for invalid in [-100.1, 100.1] {
            rejects("Persisted tone values outside the UI range are rejected") {
                _ = try JSONDecoder().decode(RawSettings.self, from: Data("{\"toneControls\":{\"blackPoint\":\(invalid),\"whitePoint\":0,\"vibrance\":0}}".utf8))
            }
        }
        let fields: Set<AdjustmentTransferField> = [.blackPoint, .whitePoint, .vibrance]
        let modified = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == fields, "Modified scope includes exactly the changed tone fields")
        let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(fields.isSubset(of: standard.fields), "Standard copy includes all tone fields")
        let applied = try IOSAdjustmentTransfer.prepare(payload: modified, target: state(), context: raw)
        check(applied.settings.toneSettings == source.toneSettings, "Tone transfer keeps exact UI units")
        var target = RawSettings.default
        target.blackPoint = 71; target.whitePoint = -29; target.vibrance = -63
        let partial = try IOSAdjustmentTransfer.capture(scope: .custom([.whitePoint]), snapshot: state(source), context: raw)
        let merged = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.blackPoint == 71 && merged.settings.whitePoint == 42.5 && merged.settings.vibrance == -63,
            "Partial tone paste preserves unselected target fields")
        let legacy = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.toneSettings == target.toneSettings,
            "Legacy payload omitting tone fields does not reset target tone")
        source.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        source.lutStrength = 0
        target.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        target.lutStrength = 0
        let recipeCopy = try IOSAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        let recipeMerged = try IOSAdjustmentTransfer.prepare(payload: recipeCopy, target: state(target), context: raw)
        check(recipeMerged.settings.toneSettings == source.toneSettings,
            "Tone controls remain independent of source and target recipe strength, including zero")
        var resetSource = source; resetSource.masterRecipeID = nil
        let snapshot = state(resetSource)
        let resetContext = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        check(EditorAdjustmentRules.isModified(.group(.light), snapshot: snapshot, context: resetContext)
            && EditorAdjustmentRules.isModified(.tool(.adjustment(.vibrance)), snapshot: snapshot, context: resetContext),
            "New controls participate in group and tool modified state")
        if case .candidate(let reset, _) = EditorAdjustmentRules.prepareReset(.group(.light), snapshot: snapshot, context: resetContext) {
            check(reset.settings.blackPoint == 0 && reset.settings.whitePoint == 0 && reset.settings.vibrance == 18.125,
                "Light reset clears black and white point while preserving vibrance")
        } else { fatalError("Tone light reset must prepare a candidate") }
        if case .candidate(let reset, _) = EditorAdjustmentRules.prepareReset(.group(.color), snapshot: snapshot, context: resetContext) {
            check(reset.settings.vibrance == 0 && reset.settings.blackPoint == -37.25,
                "Color reset clears vibrance and preserves black point")
        } else { fatalError("Tone color reset must prepare a candidate") }
        check(AdjustmentTransferField.blackPoint.group == "light" && AdjustmentTransferField.whitePoint.group == "light"
            && AdjustmentTransferField.vibrance.group == "color", "Tone controls appear in light and color copy groups")
    }

    static func colorGrading() throws {
        var source = RawSettings.default
        source.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        source.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        source.gradingSettings[.highlights] = ColorGradingWheel(hue: 359.999999, saturation: 99.5)
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(source))
        check(restored == source, "All grading values persist exactly, including pending hue")
        let old = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        check(old.colorGrading == nil && old.gradingSettings.isDefault, "Old settings missing grading remain default")
        let zeroJSON = try JSONSerialization.data(withJSONObject: ["colorGrading": ["shadows": ["hue": 0, "saturation": 0],
            "midtones": ["hue": 0, "saturation": 0], "highlights": ["hue": 0, "saturation": 0]]])
        check(try JSONDecoder().decode(RawSettings.self, from: zeroJSON).colorGrading == nil,
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
        let captured = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(captured.fields == fields, "Modified copy includes complete grading objects and pending hue")
        check(fields.isSubset(of: try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw).fields),
            "Standard copy includes all three grading zones")
        let roundTrip = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(captured))
        check(roundTrip == captured, "Grading payload JSON round-trips exactly")
        var target = RawSettings.default
        target.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        target.gradingSettings[.highlights] = ColorGradingWheel(hue: 50, saturation: 15.125)
        let partial = try IOSAdjustmentTransfer.capture(scope: .custom([.gradingMidtones]), snapshot: state(source), context: raw)
        let merged = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.gradingSettings.midtones == source.gradingSettings.midtones
            && merged.settings.gradingSettings.shadows == target.gradingSettings.shadows
            && merged.settings.gradingSettings.highlights == target.gradingSettings.highlights,
            "Partial grading paste preserves both unselected zones")
        let legacy = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: legacy, target: state(target), context: raw).settings.gradingSettings == target.gradingSettings,
            "Old payloads do not reset grading")
        source.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        target.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        source.lutStrength = 0; target.lutStrength = 0
        let recipeCopy = try IOSAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: recipeCopy, target: state(target), context: raw).settings.gradingSettings == source.gradingSettings,
            "Grading is independent of recipe strength, including zero")
        let valid: [String: Any] = ["shadows": ["hue": 231.25, "saturation": 0],
            "midtones": ["hue": 0, "saturation": 0], "highlights": ["hue": 0, "saturation": 0]]
        for wheel in [["hue": -0.1, "saturation": 0], ["hue": 360, "saturation": 0], ["hue": 0, "saturation": 100.01],
                      ["hue": 0], ["hue": 0, "saturation": 0, "lightness": 0]] {
            var invalid = valid; invalid["shadows"] = wheel
            rejects("Persisted grading rejects incomplete, unknown and out-of-range wheel fields") {
                _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: ["colorGrading": invalid]))
            }
            rejects("Transfer rejects incomplete, unknown and out-of-range wheel fields") {
                let value = AdjustmentTransferValue.object(wheel.mapValues { .number($0) })
                _ = try AdjustmentTransferPayload(source: captured.source, values: [AdjustmentTransferField.gradingShadows.rawValue: value])
            }
        }
        var incomplete = valid; incomplete.removeValue(forKey: "midtones")
        rejects("Persisted grading requires all three zones when the object is present") {
            _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: ["colorGrading": incomplete]))
        }
        var resetSource = RawSettings.default
        resetSource.gradingSettings = source.gradingSettings
        let context = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        let snapshot = state(resetSource)
        if case .candidate(let reset, _) = EditorAdjustmentRules.prepareReset(.gradingZone(.midtones), snapshot: snapshot, context: context) {
            check(reset.settings.gradingSettings.midtones.isDefault && reset.settings.gradingSettings.shadows == source.gradingSettings.shadows
                && reset.settings.gradingSettings.highlights == source.gradingSettings.highlights, "Zone reset preserves sibling precision")
        } else { fatalError("Expected grading zone reset") }
        for scope in [EditorAdjustmentScope.allGrading, .group(.color), .tool(.adjustment(.colorGrading))] {
            if case .candidate(let reset, _) = EditorAdjustmentRules.prepareReset(scope, snapshot: snapshot, context: context) {
                check(reset.settings.gradingSettings.isDefault, "Tool and color-group resets clear every grading value")
            } else { fatalError("Expected grading reset") }
        }
    }

    static func toneCurve() throws {
        var source = RawSettings.default
        source.toneCurve = 0.65
        source.curveSettings = ToneCurveSettings.identity.inserting(x: 0.25, y: 0.12).inserting(x: 0.75, y: 0.88)
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(source))
        check(restored == source, "Curve mode, binary64 points and inactive legacy scalar persist")
        let modified = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields.contains(.curve) && modified.fields.contains(.sCurve), "Modified scope keeps curve and inactive legacy scalar")
        let partial = try IOSAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: state(source), context: raw)
        var target = RawSettings.default
        target.toneCurve = -0.25
        let merged = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(target), context: raw)
        check(merged.settings.curveSettings == source.curveSettings && merged.settings.toneCurve == -0.25,
            "Pasting curve mode and points preserves unselected legacy scalar")
        let scalar = try IOSAdjustmentTransfer.capture(scope: .custom([.sCurve]), snapshot: state(target), context: raw)
        let legacyOnly = try IOSAdjustmentTransfer.prepare(payload: scalar, target: state(source), context: raw)
        check(legacyOnly.settings.curveSettings == source.curveSettings && legacyOnly.settings.toneCurve == -0.25,
            "Old scalar-only payload preserves unselected custom curve mode")
        let bytes = try JSONEncoder().encode(partial)
        check(try JSONDecoder().decode(AdjustmentTransferPayload.self, from: bytes) == partial, "Curve payload round trip")
        var bad = source
        bad.curveSettings.points[1].x = 0
        rejects("Invalid native curve cannot enter a transfer") {
            _ = try IOSAdjustmentTransfer.capture(scope: .custom([.curve]), snapshot: state(bad), context: raw)
        }
    }

    static func main() throws {
        try toneCurve()
        try colorGrading()
        try atmospherePersistence()
        try atmosphereControls()
        try toneControls()
        try scopes()
        try recipes()
        try whiteBalance()
        try objects()
        try manualLensSelectionTransport()
        try fixtures()
    }
    static func scopes() throws {
        var source = RawSettings.default
        source.exposure = 1.25; source.contrast = 1.2; source.geometry.cropWidth = 0.8
        check(source.hsl.setExact(.hue, channel: 0, value: 12.375), "Fractional HSL fixture is valid")
        let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(!standard.fields.contains(.cropWidth), "Default copy excludes geometry")
        let all = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        check(all.fields == Set(AdjustmentTransferField.allCases), "All copy includes every contract field")
        let modified = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(modified.fields == [.exposure, .contrast, .hslHueRed], "Modified uses logical defaults rather than history")
        var target = RawSettings.default; target.processing = .legacy; target.sharpening = 0.47; target.lutID = "PROVIA"
        let original = state(target).replacing(settings: target, preservingFilmID: nil)
        let result = try IOSAdjustmentTransfer.prepare(payload: modified, target: original, context: raw)
        check(result.settings.exposure == 1.25 && result.settings.contrast == 1.2 && result.settings.hsl.hue[0] == 12.375,
            "Core multipliers and exact HSL copy without UI quantization")
        check(result.settings.sharpening == 0.47 && result.settings.processing == .legacy && result.filmID == nil
            && result.updatedAt == original.updatedAt && result.settings.lutID == "PROVIA", "Unselected values and explicit nil metadata survive")
        source.exposure = 3
        check(modified[.exposure] == .number(1.25), "Source changes do not mutate copied values")
        check(try IOSAdjustmentTransfer.prepare(payload: all, target: state(allTarget()), context: raw) == state(allTarget()),
            "Identical all paste preserves the exact native state")
        var draft = raw; draft.hasUncommittedDraft = true
        rejects("A draft cannot be captured") { _ = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: original, context: draft) }
        rejects("iOS cannot silently clamp wider contract exposure") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["light.exposure": .number(8)]), target: original, context: raw)
        }
    }
    static func allTarget() -> RawSettings {
        var s = RawSettings.default; s.exposure = 1.25; s.contrast = 1.2; s.geometry.cropWidth = 0.8
        _ = s.hsl.setExact(.hue, channel: 0, value: 12.375); return s
    }
    static func recipes() throws {
        var source = RawSettings.default; source.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        source.lutStrength = 0.5; source.exposure = 1.4; source.contrast = 1.4; source.tint = 0
        _ = source.hsl.setExact(.hue, channel: 0, value: 12.375)
        let copy = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure, .contrast, .hslHueRed]), snapshot: state(source), context: raw)
        var target = RawSettings.default; target.saturation = 1.3
        let result = try IOSAdjustmentTransfer.prepare(payload: copy, target: state(target), context: raw)
        check(result.settings.exposure == 0.7 && Float(result.settings.contrast) == Float(1.2)
            && result.settings.hsl.hue[0] == 6.1875 && result.settings.masterRecipeID == nil, "Source recipe strength is applied once")
        target.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!); target.lutStrength = 0.5
        let inverted = try IOSAdjustmentTransfer.prepare(payload: copy, target: state(target), context: raw)
        check(inverted.settings.exposure == 1.4 && inverted.settings.lutStrength == 0.5, "Selected contribution is inverted into target recipe")
        let partial = try IOSAdjustmentTransfer.capture(scope: .custom([.look, .contrast]), snapshot: state(source), context: raw)
        let independent = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(), context: raw)
        check(independent.settings.lutID == "recipe-lut:hamada_daylight_v2" && independent.settings.masterRecipeID == nil,
            "Partial recipe look becomes an independent LUT")
        let full = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        let copied = try IOSAdjustmentTransfer.prepare(payload: full, target: state(), context: raw)
        check(copied.settings.masterRecipeID == source.masterRecipeID && copied.settings.hsl == source.hsl,
            "Complete current recipe retains logical values and identity")
        source.lutStrength = 0.7
        let fractional = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        check(fractional.source.recipe?.strength == source.recipeScale,
            "iOS recipe context records the renderer's actual Float strength")
        check(try IOSAdjustmentTransfer.prepare(payload: fractional, target: state(source), context: raw) == state(source),
            "Fractional-strength all paste is an exact native no-op")
        var legacyValues = full.values
        legacyValues["color.hsl.hue.red"] = .number(37.25)
        let fullLegacy = try payload(legacyValues, recipe: .init(id: "hamada_daylight_v2", strength: 0.5, settingsVersion: 2))
        let legacyRecipe = try IOSAdjustmentTransfer.prepare(payload: fullLegacy, target: state(), context: raw)
        check(legacyRecipe.settings.masterRecipeID == source.masterRecipeID
            && legacyRecipe.settings.renderedRecipe(cameraTemperature: 5200, cameraTint: 10).hsl.hue[0] == 37.25,
            "Full legacy HSL is represented without changing its effective contribution")
        let legacy = try payload(["color.hsl.hue.red": .number(37.25)],
            recipe: .init(id: "hamada_daylight_v2", strength: 0.5, settingsVersion: 2))
        check(try IOSAdjustmentTransfer.prepare(payload: legacy, target: state(), context: raw).settings.hsl.hue[0] == 37.25,
            "Legacy HSL does not acquire current recipe strength")
        var zero = target; zero.lutStrength = 0
        rejects("Nonzero contribution cannot be hidden in zero-strength target recipe") {
            _ = try IOSAdjustmentTransfer.prepare(payload: copy, target: state(zero), context: raw)
        }
        var missing = raw; missing.availableLookIDs = []
        rejects("Missing recipe LUT is blocked before changing target") {
            _ = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(), context: missing)
        }
    }
    static func whiteBalance() throws {
        let relative = try payload(["color.white_balance.mode": .string("camera"),
            "color.white_balance.temperature_kelvin": .null, "color.white_balance.tint": .number(8)],
            recipe: .init(id: "hamada_daylight_v2", strength: 0.5, settingsVersion: 3))
        let result = try IOSAdjustmentTransfer.prepare(payload: relative, target: state(), context: raw)
        check(result.settings.whiteBalanceMode == .custom && result.settings.temperature == 5200 && result.settings.tint == 14,
            "Relative tint resolves against target calibration once")
        var missing = raw; missing.cameraTemperature = nil; missing.cameraTint = nil
        rejects("Missing target calibration cannot become fallback white balance") {
            _ = try IOSAdjustmentTransfer.prepare(payload: relative, target: state(), context: missing)
        }
        rejects("Fixed tint alone cannot silently replace camera mode") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["color.white_balance.tint": .number(20)]), target: state(), context: raw)
        }
        var target = RawSettings.default; target.whiteBalanceMode = .custom; target.temperature = 6100; target.tint = -8
        let fixed = try IOSAdjustmentTransfer.prepare(payload: payload(["color.white_balance.temperature_kelvin": .number(4700)]), target: state(target), context: raw)
        check(fixed.settings.temperature == 4700 && fixed.settings.tint == -8, "Independent temperature preserves fixed tint")
        let fractionalTint = try IOSAdjustmentTransfer.prepare(payload: payload(["color.white_balance.tint": .number(12.1)]),
            target: state(target), context: raw)
        check(fractionalTint.settings.tint == 12.1 && fractionalTint.settings.temperature == 6100,
            "Fractional tint keeps core Float precision without false incompatibility")
        var raster = raw; raster.isRaw = false
        rejects("RAW white balance cannot be dropped on a raster target") {
            _ = try IOSAdjustmentTransfer.prepare(payload: relative, target: state(), context: raster)
        }
    }
    static func objects() throws {
        var source = RawSettings.default; source.noiseReduction = 0.25
        let copy = try IOSAdjustmentTransfer.capture(scope: .modified, snapshot: state(source), context: raw)
        check(copy.fields == [.postRGBDenoise] && copy[.postRGBDenoise] == .number(0.25), "Legacy post-RGB request has its own field")
        check(try IOSAdjustmentTransfer.prepare(payload: copy, target: state(), context: raw).settings.noiseReduction == 0.25,
            "Legacy post-RGB request survives iOS transfer")
        rejects("RAW FBDD is not mapped to iOS post-RGB denoise") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.raw_level": .number(1)]), target: state(), context: raw)
        }
        var target = RawSettings.default; target.displayChromaDenoise = 2
        let nullChroma = try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.chroma_mode": .null]), target: state(target), context: raw)
        check(nullChroma.settings.displayChromaDenoise == 0, "Null legacy chroma maps to the real disabled native request")
        source.denoise = .init(enabled: true, luma: 2, chroma: 3, coarse: 4); source.noiseReduction = 0
        let wavelet = try IOSAdjustmentTransfer.capture(scope: .custom([.waveletDenoise]), snapshot: state(source), context: raw)
        let denoised = try IOSAdjustmentTransfer.prepare(payload: wavelet, target: state(target), context: raw)
        check(denoised.settings.denoise == source.denoise && denoised.settings.displayChromaDenoise == 2,
            "Wavelet request preserves independently selected native chroma")
        let disabled = try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.wavelet": .null]), target: denoised, context: raw)
        check(disabled.settings.denoise == RawDenoiseSettings() && disabled.settings.displayChromaDenoise == 2,
            "Null wavelet maps to a disabled native request without clearing chroma")
        rejects("Noncanonical wavelet preset label is not silently discarded") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.wavelet": .object([
                "enabled": .boolean(true), "luma": .number(0), "chroma": .number(46), "coarse": .number(50), "preset": .string("clean")])]),
                target: state(), context: raw)
        }
        target.noiseReduction = 0.4
        rejects("Wavelet enable cannot silently disable unselected active post-RGB denoise") {
            _ = try IOSAdjustmentTransfer.prepare(payload: wavelet, target: state(target), context: raw)
        }
        target = .default; target.geometry.cropX = 0.2; target.geometry.cropWidth = 0.5
        let cropped = try IOSAdjustmentTransfer.prepare(payload: payload(["geometry.crop.width": .number(0.6)]), target: state(target), context: raw)
        check(cropped.settings.geometry.cropWidth == 0.6 && cropped.settings.geometry.cropX == 0.2, "Crop width keeps unselected position")
        rejects("Merged crop must fit the canvas") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["geometry.crop.width": .number(0.9)]), target: state(target), context: raw)
        }
        rejects("Fractional effect cannot be silently rounded by the iOS model") {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload(["effects.grain.amount": .number(2.5)]), target: state(), context: raw)
        }
        var rasterContext = raw; rasterContext.isRaw = false
        for request: [String: AdjustmentTransferValue] in [
            ["geometry.lens.profile_id": .string("fixture-profile")],
            ["geometry.lens.auto_crop": .boolean(false)]
        ] {
            rejects("Raster rejects selected inactive lens request instead of dropping it") {
                _ = try IOSAdjustmentTransfer.prepare(payload: payload(request), target: state(), context: rasterContext)
            }
        }
        let lens = try payload(["geometry.lens.distortion": .boolean(true)])
        rejects("Enabled lens correction requires actual target calibration") {
            _ = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: raw)
        }
        var context = raw; var checked = false; context.validateLensRequest = { _ in checked = true }
        let corrected = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: context)
        check(checked && corrected.settings.lensSettings.distortion, "Lens preflight validates the merged target request")
    }
    static func fixtures() throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/adjustment-transfer-v1.json"))) as! [String: Any]
        for vector in root["vectors"] as! [[String: Any]] {
            let id = vector["id"] as! String, data = try JSONSerialization.data(withJSONObject: vector["payload"]!)
            if vector["valid"] as! Bool {
                let value = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data)
                check(try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(value)) == value, "Shared accepted vector: \(id)")
                if let expected = vector["neutral_effective"] as? [String: Double] {
                    let prepared = try IOSAdjustmentTransfer.prepare(payload: value, target: state(), context: raw)
                    let actual = IOSAdjustmentTransfer.effectiveNumbers(prepared.settings)
                    check(expected.allSatisfy { Float(actual[AdjustmentTransferField(rawValue: $0.key)!]!) == Float($0.value) }, "Shared effective vector: \(id)")
                }
            } else { rejects("Shared rejected vector: \(id)") { _ = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data) } }
        }
    }
    static func manualLensSelectionTransport() throws {
        var source = RawSettings.default
        source.lensCorrection = LensCorrectionSettings(mode: .manual)
        for scope: AdjustmentTransferScope in [.all, .custom([.lensProfile])] {
            let payload = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: state(source), context: raw)
            check(payload[.lensProfile] == .string(source.lensSettings.coreProfileID), "Manual lens uses reserved nonempty transport")
            let restored = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(payload))
            check(restored == payload, "Manual lens payload round-trips")
            let applied = try IOSAdjustmentTransfer.prepare(payload: restored, target: state(), context: raw)
            check(applied.settings.lensSettings.mode == .manual && applied.settings.lensSettings.profileID == nil,
                "Manual lens without profile preserves selection mode and nil profile")
        }
        let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(standard.fields.isDisjoint(with: AdjustmentTransferField.lensFields), "Default scope excludes manual lens selection")
        source.lensCorrection = LensCorrectionSettings(distortion: true, mode: .manual)
        let enabled = try IOSAdjustmentTransfer.capture(scope: .custom([.lensDistortion, .lensProfile]), snapshot: state(source), context: raw)
        var permissive = raw; var validated = false
        permissive.validateLensRequest = { _ in validated = true }
        rejects("Enabled manual lens without profile rejects") {
            _ = try IOSAdjustmentTransfer.prepare(payload: enabled, target: state(), context: permissive)
        }
        check(!validated, "Missing manual profile rejects before target validation")
    }

}
