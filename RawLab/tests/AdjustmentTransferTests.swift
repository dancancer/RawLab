import Foundation

@main struct IOSAdjustmentTransferTests {
    static var legacyRecipe: MasterRecipe {
        // 固定测试旧版本的独立控制语义，不随 bundled catalog 的版本升级。
        let data = try! JSONEncoder().encode(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        var row = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["settingsVersion", "tone", "atmosphere", "grading", "curve"] { row.removeValue(forKey: key) }
        return try! JSONDecoder().decode(MasterRecipe.self, from: JSONSerialization.data(withJSONObject: row))
    }
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
        source.applyMasterRecipe(legacyRecipe); source.lutStrength = 0
        target.applyMasterRecipe(legacyRecipe); target.lutStrength = 0
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
        source.applyMasterRecipe(legacyRecipe)
        source.lutStrength = 0
        target.applyMasterRecipe(legacyRecipe)
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
        source.applyMasterRecipe(legacyRecipe)
        target.applyMasterRecipe(legacyRecipe)
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
        source.curveSettings.channels.red = .identity.inserting(x: 0.5, y: 0.6)
        source.curveSettings.channels.blue = .identity.inserting(x: 0.5, y: 0.4)
        let old = try JSONDecoder().decode(ToneCurveSettings.self, from: Data("{\"mode\":\"legacy\",\"points\":[]}".utf8))
        check(old.isDefault && old.channels.isDefault, "Old curve records default all independent channels")
        let scaled = source.curveSettings.scaled(by: 0.5)
        check(scaled.channels.red.points[1].y == 0.55 && scaled.channels.blue.points[1].y == 0.45,
              "Refinement scales every curve channel")
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

    // Q3/Q4：iOS 不建模解马赛克前 FBDD，非 0 值忽略并提示；处理版本沿用目标，不拒绝粘贴。
    static func ignoreNoticesAndVersion() throws {
        var notices = [AdjustmentTransferNotice]()
        var context = raw
        context.transferNotices = { notices.append($0) }
        var target = RawSettings.default
        target.noiseReduction = 0.2
        let old = AdjustmentTransferSource(identifier: "old", isRaw: true, processingVersion: 1, recipe: nil)
        let payload = try AdjustmentTransferPayload(source: old, values: [
            "light.exposure": .number(0.33), "detail.denoise.raw_level": .number(1), "detail.denoise.post_rgb": .number(0.5)])
        let result = try IOSAdjustmentTransfer.prepare(payload: payload, target: state(target), context: context)
        check(result.settings.exposure == 0.33 && result.settings.noiseReduction == 0.5 &&
            result.settings.processing.version == 3,
            "iOS applies post_rgb, ignores raw_level and keeps the target processing version on mismatch")
        check(notices == [.retainedTargetProcessingVersion, .ignoredRawDenoise],
            "iOS reports the retained processing version first and the ignored raw level once")
        var silentNotices = [AdjustmentTransferNotice]()
        var quiet = raw
        quiet.transferNotices = { silentNotices.append($0) }
        let current = AdjustmentTransferSource(identifier: "new", isRaw: true, processingVersion: 3, recipe: nil)
        let silent = try AdjustmentTransferPayload(source: current, values: ["detail.denoise.raw_level": .number(0)])
        _ = try IOSAdjustmentTransfer.prepare(payload: silent, target: state(target), context: quiet)
        check(silentNotices.isEmpty, "Matching processing version and zero placeholders prompt nothing")
    }

    static func main() throws {
        try scenarioFixtures()
        try neutralRawRequestsOnRaster()
        try fullNeutralRecipeOnRaster()
        try builtinRawRecipesOnRaster()
        try refinedRecipeTransfers()
        try toneCurve()
        try colorGrading()
        try atmospherePersistence()
        try atmosphereControls()
        try toneControls()
        try ignoreNoticesAndVersion()
        try scopes()
        try recipes()
        try recipeSourceOnHDR()
        try rasterExposureBaselineOnRaw()
        try whiteBalance()
        try objects()
        try manualLensSelectionTransport()
        try rasterPlaceholdersOnRaw()
        try fixtures()
    }

    static func refinedRecipeTransfers() throws {
        let recipe = try JSONDecoder().decode(MasterRecipe.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json")))
        var source = RawSettings.default; source.applyMasterRecipe(recipe)
        let fields: Set<AdjustmentTransferField> = [.blackPoint, .whitePoint, .vibrance, .clarity, .dehaze,
            .curve, .sCurve, .gradingShadows, .gradingMidtones, .gradingHighlights]
        for strength in [0.0, 0.5, 1, 2] {
            source.lutStrength = strength
            let expected = source.renderedRecipe(cameraTemperature: 5200, cameraTint: 10)
            var cleared = source
            let removal = cleared.clearMasterRecipe(context: .init(isRaw: true, defaultExposureMode: .preview,
                cameraTemperature: 5200, cameraTint: 10))
            check(removal == nil && cleared.masterRecipeID == nil && cleared.toneSettings == expected.toneSettings &&
                  cleared.curveSettings == expected.curveSettings && cleared.gradingSettings == expected.gradingSettings &&
                  cleared.atmosphereSettings == expected.atmosphereSettings && cleared.exposure == expected.exposure &&
                  cleared.editorEffectiveValues(isRaw: true, cameraTemperature: 5200, cameraTint: 10) ==
                    source.editorEffectiveValues(isRaw: true, cameraTemperature: 5200, cameraTint: 10),
                  "Direct recipe removal materializes current controls once")
            let partial = try IOSAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
            let plain = try IOSAdjustmentTransfer.prepare(payload: partial, target: state(), context: raw).settings
            check(plain.masterRecipeID == nil && plain.toneSettings == expected.toneSettings && plain.atmosphereSettings == expected.atmosphereSettings &&
                  plain.gradingSettings == expected.gradingSettings && plain.curveSettings == expected.curveSettings,
                  "V4 partial transfer materializes new controls once at \(strength)")
            let full = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
            let restored = try IOSAdjustmentTransfer.prepare(payload: full, target: state(), context: raw).settings
            check(restored.masterRecipeSettingsVersion == 4 && restored.toneSettings == source.toneSettings &&
                  restored.gradingSettings == source.gradingSettings && restored.curveSettings == source.curveSettings,
                  "Full v4 transfer preserves version and manual logical controls")
        }
        source.lutStrength = 0.5
        var extreme = source; extreme.exposure = 4; extreme.lutStrength = 2
        let unchanged = extreme
        check(extreme.clearMasterRecipe(context: .init(isRaw: true, defaultExposureMode: .preview,
            cameraTemperature: 5200, cameraTint: 10)) == .unrepresentable && extreme == unchanged,
              "Unrepresentable direct removal keeps the original edit")
        let removed = source.renderedRecipe(cameraTemperature: 5200, cameraTint: 10)
        let reported = Set(EditorAdjustmentRules.materializedFields(before: source, after: removed))
        check(Set(["黑场", "白场", "鲜艳度", "清晰度", "去朦胧", "曲线", "颜色分级"]).isSubset(of: reported),
              "Recipe removal reports every materialized modern control")
        let oldSelection = try IOSAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.recipeDependencies), snapshot: state(source), context: raw)
        let separated = try IOSAdjustmentTransfer.prepare(payload: oldSelection, target: state(), context: raw).settings
        check(separated.masterRecipeID == nil && separated.lutID == "recipe-lut:hamada_daylight_v2",
              "V4 requires modern dependencies before preserving recipe context")
        var target = source; target.tint = 0; source.lutStrength = 1
        let strengthOnly = try IOSAdjustmentTransfer.capture(scope: .custom([.strength]), snapshot: state(source), context: raw)
        let changed = try IOSAdjustmentTransfer.prepare(payload: strengthOnly, target: state(target), context: raw).settings
        let before = target.renderedRecipe(cameraTemperature: 5200, cameraTint: 10)
        let after = changed.renderedRecipe(cameraTemperature: 5200, cameraTint: 10)
        check(after.toneSettings == before.toneSettings && after.atmosphereSettings == before.atmosphereSettings &&
              after.gradingSettings == before.gradingSettings && after.curveSettings == before.curveSettings,
              "Strength-only paste preserves unselected effective v4 objects")
        source.lutStrength = 0.7
        let rounded = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        var preciseValues = rounded.values
        preciseValues[AdjustmentTransferField.strength.rawValue] = .number(0.7)
        let precise = try AdjustmentTransferPayload(source: .init(identifier: "desktop", isRaw: true, processingVersion: 2,
            recipe: .init(id: recipe.id, strength: 0.7, settingsVersion: 4)), values: preciseValues)
        let preciseResult = try IOSAdjustmentTransfer.prepare(payload: precise, target: state(), context: raw).settings
        let preciseCurve = preciseResult.renderedRecipe(cameraTemperature: 5200, cameraTint: 10).curveSettings
        for (actual, expected) in zip(preciseCurve.points, source.curveSettings.scaled(by: 0.7).points) {
            check(actual.x == expected.x && abs(actual.y - expected.y) < 1e-12,
                  "Desktop Double strength survives the iOS Float strength projection")
        }
    }
    static func scopes() throws {
        var source = RawSettings.default
        source.exposure = 1.25; source.contrast = 1.2; source.geometry.cropWidth = 0.8
        check(source.hsl.setExact(.hue, channel: 0, value: 12.375), "Fractional HSL fixture is valid")
        let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        check(!standard.fields.contains(.cropWidth), "Default copy excludes geometry")
        let all = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
        check(all.payloadVersion == 1 && all.fields == AdjustmentTransferField.legacyFields,
              "Version-1 all includes exactly the legacy contract fields")
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
    static func recipeSourceOnHDR() throws {
        var hdrContext = raw; hdrContext.isRaw = false; hdrContext.sourceIsHDR = true
        var hdrTarget = RawSettings.default; hdrTarget.hdr = HDRSettings()
        for strength in [0.5, 1.0] {
            var source = RawSettings.default; source.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
            source.lutStrength = strength; source.exposure = 1; source.contrast = 1.4
            let copy = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure, .contrast]), snapshot: state(source), context: raw)
            let applied = try IOSAdjustmentTransfer.prepare(payload: copy, target: state(hdrTarget), context: hdrContext).settings.hdr!
            check(applied.exposure == strength && abs(applied.contrast - 40 * strength) < 1e-9,
                "Recipe source strength is applied once on an HDR target at \(strength)")
        }
    }
    static func rasterExposureBaselineOnRaw() throws {
        var raster = raw; raster.identifier = "source.jpg"; raster.isRaw = false
        var jpeg = RawSettings.default; jpeg.exposureMode = .sensor; jpeg.exposure = 0.75
        for mode in [RawExposureMode.preview, .scene] {
            var target = RawSettings.default; target.exposureMode = mode
            for scope in [AdjustmentTransferScope.all, .custom([.exposureMode, .exposure])] {
                let copy = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: state(jpeg), context: raster)
                let applied = try IOSAdjustmentTransfer.prepare(payload: copy, target: state(target), context: raw)
                check(copy[.exposureMode] == .string("sensor") && applied.settings.exposureMode == mode && applied.settings.exposure == 0.75,
                    "JPEG paste keeps the RAW exposure baseline \(mode)")
            }
        }
        for mode in [RawExposureMode.scene, .sensor] {
            var source = RawSettings.default; source.exposureMode = mode
            let all = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(source), context: raw)
            check(try IOSAdjustmentTransfer.prepare(payload: all, target: state(), context: raw).settings.exposureMode == mode,
                "RAW all paste still copies the exposure baseline \(mode)")
        }
    }
    static func fullNeutralRecipeOnRaster() throws {
        var raster = raw; raster.isRaw = false
        var target = RawSettings.default
        target.exposureMode = .sensor
        target.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
        var source = target; source.whiteBalanceMode = .camera; source.tint = 0
        let complete = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
        let applied = try IOSAdjustmentTransfer.prepare(payload: complete, target: state(target), context: raster)
        check(applied != state(target) && applied.settings.tint == 0,
            "Full neutral RAW recipe clears previous raster recipe tint and counts as changed")
        check(IOSAdjustmentTransfer.values(applied.settings, context: raster)[AdjustmentTransferField.tint.rawValue] == .number(0),
            "Full neutral recipe exposes zero logical tint")
        check(try IOSAdjustmentTransfer.prepare(payload: complete, target: applied, context: raster) == applied,
            "Repeating full neutral recipe is unchanged")
    }

    static func builtinRawRecipesOnRaster() throws {
        var raster = raw; raster.isRaw = false
        raster.availableLookIDs.formUnion(MasterRecipe.allRecipes.map { "recipe:\($0.id)" })
        for recipe in MasterRecipe.allRecipes {
            for strength in [0.0, 0.5, 1.0, 2.0] {
                var source = RawSettings.default; source.applyMasterRecipe(recipe)
                source.lutStrength = strength
                var direct = RawSettings.default
                direct.exposureMode = .sensor
                direct.applyMasterRecipe(recipe); direct.lutStrength = strength
                var previous = RawSettings.default
                previous.exposureMode = .sensor
                previous.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!)
                for scope in [AdjustmentTransferScope.standard, .all] {
                    let captured = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: state(source), context: raw)
                    let frozen = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(captured))
                    let applied = try IOSAdjustmentTransfer.prepare(payload: frozen, target: state(previous), context: raster)
                    check(IOSAdjustmentTransfer.values(applied.settings, context: raster) == IOSAdjustmentTransfer.values(state(direct).settings, context: raster),
                        "Builtin RAW recipe matches direct raster application: \(recipe.id), strength \(strength)")
                    check(try IOSAdjustmentTransfer.prepare(payload: frozen, target: applied, context: raster) == applied,
                        "Repeating builtin RAW recipe is unchanged")
                }
                source.tint = recipe.tintDelta + 1
                let edited = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
                rejects("Manually edited full recipe tint remains incompatible with raster") {
                    _ = try IOSAdjustmentTransfer.prepare(payload: edited, target: state(previous), context: raster)
                }
                source.tint = recipe.tintDelta; source.whiteBalanceMode = .custom; source.temperature = 5400
                let fixed = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
                rejects("Full recipe with fixed WB remains incompatible with raster") {
                    _ = try IOSAdjustmentTransfer.prepare(payload: fixed, target: state(previous), context: raster)
                }
            }
        }
    }

    static func neutralRawRequestsOnRaster() throws {
        var raster = raw; raster.identifier = "target.jpg"; raster.isRaw = false
        var rasterSettings = RawSettings.default; rasterSettings.exposureMode = .sensor
        let target = state(rasterSettings)
        var source = RawSettings.default
        for mode in [RawExposureMode.scene, .preview, .sensor] {
            source.exposureMode = mode; source.exposure = 1.25
            let standard = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
            let applied = try IOSAdjustmentTransfer.prepare(payload: standard, target: target, context: raster)
            check(applied != target && applied.settings.exposure == 1.25,
                "RAW standard paste keeps other changes on JPEG")
            check(IOSAdjustmentTransfer.values(applied.settings, context: raster)[AdjustmentTransferField.whiteBalanceMode.rawValue] == .string("none")
                && applied.settings.whiteBalanceMode == .camera && applied.settings.temperature == 6500
                && applied.settings.tint == 0 && applied.settings.exposureMode == .sensor,
                "JPEG keeps native neutral white balance and sensor exposure for every RAW exposure mode")
            check(try IOSAdjustmentTransfer.prepare(payload: standard, target: applied, context: raster) == applied,
                "Repeating RAW standard paste on JPEG is unchanged")
            source.exposure = 0
            let neutral = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(source), context: raw)
            check(try IOSAdjustmentTransfer.prepare(payload: neutral, target: target, context: raster) == target,
                "Neutral RAW standard paste does not create a JPEG change")
            let exposureMode = try IOSAdjustmentTransfer.capture(scope: .custom([.exposureMode]), snapshot: state(source), context: raw)
            check(try IOSAdjustmentTransfer.prepare(payload: exposureMode, target: target, context: raster) == target,
                "RAW exposure mode alone does not create a JPEG change")
        }
        for field in AdjustmentTransferField.whiteBalanceFields {
            let partial = try IOSAdjustmentTransfer.capture(scope: .custom([field]), snapshot: state(source), context: raw)
            check(try IOSAdjustmentTransfer.prepare(payload: partial, target: target, context: raster) == target,
                "Selected neutral RAW white balance component is unchanged on JPEG")
        }
        source.applyMasterRecipe(legacyRecipe); source.whiteBalanceMode = .camera; source.tint = 0
        let recipeWB = try IOSAdjustmentTransfer.capture(scope: .custom(AdjustmentTransferField.whiteBalanceFields), snapshot: state(source), context: raw)
        check(try IOSAdjustmentTransfer.prepare(payload: recipeWB, target: target, context: raster) == target,
            "Zero recipe-relative tint is neutral on JPEG")
        for strength in [0.0, 1.0] {
            source.lutStrength = strength; source.tint = 5
            let relative = try IOSAdjustmentTransfer.capture(scope: .custom([.tint]), snapshot: state(source), context: raw)
            rejects("Nonzero recipe-relative tint is incompatible with JPEG even at zero strength") {
                _ = try IOSAdjustmentTransfer.prepare(payload: relative, target: target, context: raster)
            }
        }
        source = .default; source.whiteBalanceMode = .custom; source.temperature = 5400; source.tint = 3.5
        for fields in [AdjustmentTransferField.whiteBalanceFields, [.temperature], [.tint]] {
            let fixed = try IOSAdjustmentTransfer.capture(scope: .custom(fields), snapshot: state(source), context: raw)
            rejects("Fixed RAW white balance is still incompatible with JPEG") {
                _ = try IOSAdjustmentTransfer.prepare(payload: fixed, target: target, context: raster)
            }
        }
        var ignoredRaw: [AdjustmentTransferNotice] = []
        var noticing = raster
        noticing.transferNotices = { ignoredRaw.append($0) }
        check(try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.raw_level": .number(1)]), target: target, context: noticing) == target,
            "Nonzero RAW FBDD is ignored on raster targets instead of rejecting")
        check(Set(ignoredRaw) == [.ignoredRawDenoise, .retainedTargetProcessingVersion],
            "Ignored RAW FBDD and retained processing version are each reported once")
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
        var rawOnlyNotices: [AdjustmentTransferNotice] = []
        var rawNoticing = raw
        rawNoticing.transferNotices = { rawOnlyNotices.append($0) }
        let ignored = try IOSAdjustmentTransfer.prepare(payload: payload(["detail.denoise.raw_level": .number(1)]), target: state(), context: rawNoticing)
        check(ignored.settings.noiseReduction == RawSettings.default.noiseReduction &&
            rawOnlyNotices == [.retainedTargetProcessingVersion, .ignoredRawDenoise],
            "RAW FBDD is ignored with a notice and never maps to iOS post-RGB denoise")
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
        let selectedProfile = try IOSAdjustmentTransfer.prepare(payload: payload([
            "geometry.lens.profile_id": .string("fixture-profile")]), target: state(), context: rasterContext)
        check(selectedProfile.settings.lensSettings.profileID == "fixture-profile" && !selectedProfile.settings.lensSettings.isEnabled,
              "Raster preserves an inactive manual profile without claiming correction")
        let selectedCrop = try IOSAdjustmentTransfer.prepare(payload: payload([
            "geometry.lens.auto_crop": .boolean(false)]), target: state(), context: rasterContext)
        check(!selectedCrop.settings.lensSettings.autoCrop, "Raster preserves an inactive crop preference")
        let lens = try payload(["geometry.lens.distortion": .boolean(true)])
        rejects("Enabled lens correction requires actual target calibration") {
            _ = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: raw)
        }
        rejects("Raster enabled lens correction also requires actual target calibration") {
            _ = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: rasterContext)
        }
        var rasterChecked = false
        rasterContext.validateLensRequest = { _ in rasterChecked = true }
        let correctedRaster = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: rasterContext)
        check(rasterChecked && correctedRaster.settings.lensSettings.distortion, "Raster calibration is validated before applying lens settings")
        var context = raw; var checked = false; context.validateLensRequest = { _ in checked = true }
        let corrected = try IOSAdjustmentTransfer.prepare(payload: lens, target: state(), context: context)
        check(checked && corrected.settings.lensSettings.distortion, "Lens preflight validates the merged target request")
        let vignette = try payload(["geometry.lens.vignetting": .boolean(true)])
        let appliedVignette = try IOSAdjustmentTransfer.prepare(payload: vignette, target: state(), context: context)
        check(appliedVignette.settings.lensSettings.vignetting, "Vignetting-only transfer writes the changed lens setting")
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

    private static func matchesValue(_ actual: AdjustmentTransferValue?, _ expected: AdjustmentTransferValue, tolerance: Double = 1e-6) -> Bool {
        guard let actual else { return false }
        switch (actual, expected) {
        case (.null, .null): return true
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return abs(a - b) <= tolerance
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { matchesValue($0, $1, tolerance: tolerance) }
        case let (.object(a), .object(b)):
            return a.keys == b.keys && b.allSatisfy { matchesValue(a[$0.key], $0.value, tolerance: tolerance) }
        default: return false
        }
    }

    private static func errorReason(_ error: Error) -> String {
        switch error as? AdjustmentTransferError {
        case .incompatible: return "incompatible"
        case .unrepresentable: return "unrepresentable"
        case .missingLook: return "missing_look"
        default: return "other"
        }
    }

    static func rasterPlaceholdersOnRaw() throws {
        var raster = raw; raster.identifier = "source.jpg"; raster.isRaw = false
        raster.cameraTemperature = nil; raster.cameraTint = nil; raster.defaultExposureMode = .sensor
        var rawLens = raw; rawLens.validateLensRequest = { _ in }
        var target = RawSettings.default
        target.exposureMode = .scene
        target.whiteBalanceMode = .custom; target.temperature = 5850; target.tint = -18
        target.noiseReduction = 0.25
        target.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false, mode: .manual,
            profileID: "fixture-profile", vignetting: true)
        let before = state(target)

        var jpeg = RawSettings.default; jpeg.exposureMode = .sensor; jpeg.exposure = 0.75
        let all = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: state(jpeg), context: raster)
        let applied = try IOSAdjustmentTransfer.prepare(payload: all, target: before, context: rawLens)
        check(applied.settings.exposure == 0.75 && applied.settings.exposureMode == .scene
            && applied.settings.whiteBalanceMode == .custom && applied.settings.temperature == 5850 && applied.settings.tint == -18
            && applied.settings.noiseReduction == 0.25 && applied.settings.lensCorrection == target.lensCorrection,
            "Raster all paste skips placeholders and preserves RAW exposure baseline, custom WB, post-RGB denoise and lens")

        var neutralJpeg = RawSettings.default; neutralJpeg.exposureMode = .sensor
        let placeholders = Set<AdjustmentTransferField>([.exposureMode, .whiteBalanceMode, .temperature, .tint, .rawDenoise, .postRGBDenoise])
            .union(AdjustmentTransferField.lensFields)
        let placeholderOnly = try IOSAdjustmentTransfer.capture(scope: .custom(placeholders), snapshot: state(neutralJpeg), context: raster)
        check(try IOSAdjustmentTransfer.prepare(payload: placeholderOnly, target: before, context: rawLens) == before,
            "Explicitly selecting only raster placeholders is unchanged on RAW")

        var recipeTarget = RawSettings.default
        recipeTarget.applyMasterRecipe(MasterRecipe.recipe(for: "hamada_daylight_v2")!); recipeTarget.lutStrength = 1
        var lutJpeg = RawSettings.default; lutJpeg.exposureMode = .sensor; lutJpeg.lutID = "PROVIA"
        let lutRaster = try IOSAdjustmentTransfer.capture(scope: .standard, snapshot: state(lutJpeg), context: raster)
        let detached = try IOSAdjustmentTransfer.prepare(payload: lutRaster, target: state(recipeTarget), context: rawLens)
        check(detached.settings.whiteBalanceMode == .custom && detached.settings.temperature == 5200 && detached.settings.tint == 15,
            "Detaching RAW recipe with non-recipe raster paste preserves effective target WB instead of resetting to camera")
    }

    static func scenarioFixtures() throws {
        let url = URL(fileURLWithPath: "Shared/fixtures/adjustment-transfer-scenarios-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check(root["fixture_version"] as? Int == 1, "Scenario fixture version is 1")
        let scenarios = root["scenarios"] as! [[String: Any]]
        var ids = Set<String>()
        for scenario in scenarios {
            let id = scenario["id"] as! String
            check(ids.insert(id).inserted, "Unique scenario ID: \(id)")
            if let platforms = scenario["platforms"] as? [String], !platforms.contains("ios") { continue }
            let targetSpec = scenario["target"] as! [String: Any]
            let kind = targetSpec["kind"] as! String
            let asShot = (targetSpec["as_shot_wb"] as? [NSNumber])?.map(\.doubleValue)
            let lensValid = targetSpec["lens_valid"] as! Bool
            let availableLooks = Set(targetSpec["available_looks"] as! [String])
            var builtins = [String: String]()
            for look in availableLooks where look.hasPrefix("builtin:") {
                let file = String(look.dropFirst(8))
                builtins[file] = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            }

            var initialSettings = RawSettings.default
            if kind == "sdr_raster" { initialSettings.exposureMode = .sensor }
            if kind == "hdr" { initialSettings.hdr = HDRSettings() }
            let context = IOSAdjustmentTransferContext(identifier: "scenario-target", isRaw: kind == "sdr_raw",
                sourceIsHDR: kind == "hdr", availableLookIDs: availableLooks, builtinLookIDs: builtins,
                cameraTemperature: kind == "sdr_raw" ? asShot?[0] : nil,
                cameraTint: kind == "sdr_raw" ? asShot?[1] : nil,
                defaultExposureMode: kind == "sdr_raw" ? .preview : .sensor,
                validateLensRequest: lensValid ? { _ in } : nil)
            var targetState = state(initialSettings)
            if let seedObj = targetSpec["seed_payload"], !(seedObj is NSNull) {
                let seedPayload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: seedObj))
                var seedContext = context
                seedContext.validateLensRequest = { _ in }
                targetState = try IOSAdjustmentTransfer.prepare(payload: seedPayload, target: targetState, context: seedContext)
            }

            let payload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONSerialization.data(withJSONObject: scenario["payload"]!))
            let expectSpec = (scenario["platform_expect"] as? [String: [String: Any]])?["ios"] ?? (scenario["expect"] as! [String: Any])
            let expectedStatus = expectSpec["status"] as! String
            if expectedStatus == "rejected" {
                do {
                    _ = try IOSAdjustmentTransfer.prepare(payload: payload, target: targetState, context: context)
                    fatalError("Scenario \(id): expected rejected")
                } catch {
                    if let expectedReason = expectSpec["reason"] as? String {
                        check(errorReason(error) == expectedReason, "Scenario \(id): rejected reason \(expectedReason)")
                    } else {
                        print("PASS: Scenario \(id): rejected")
                    }
                }
                continue
            }
            let candidate = try IOSAdjustmentTransfer.prepare(payload: payload, target: targetState, context: context)
            let actualStatus = candidate == targetState ? "unchanged" : "applied"
            check(actualStatus == expectedStatus, "Scenario \(id): status \(expectedStatus)")
            if let valuesObj = expectSpec["values"] {
                let expectedValues = try JSONDecoder().decode([String: AdjustmentTransferValue].self, from: JSONSerialization.data(withJSONObject: valuesObj))
                let captured = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: candidate, context: context).values
                for key in expectedValues.keys.sorted() {
                    check(matchesValue(captured[key], expectedValues[key]!), "Scenario \(id): value \(key)")
                }
            }
            if let effectiveObj = expectSpec["effective"] as? [String: NSNumber] {
                let actualEffective = IOSAdjustmentTransfer.effectiveNumbers(candidate.settings)
                for key in effectiveObj.keys.sorted() {
                    let field = AdjustmentTransferField(rawValue: key)!
                    check(abs(actualEffective[field]! - effectiveObj[key]!.doubleValue) <= 1e-6, "Scenario \(id): effective \(key)")
                }
            }
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
