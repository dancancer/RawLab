import Foundation

/// P2-01 (S1): iOS 消费共享持久化编辑记录 fixture `Shared/fixtures/edit-records-v1.json`。
/// 先以空差异台账跑出真行为红锚；不静默修改实现或压低 fixture 期望以迎合现实现状。
struct EditRecordDivergence {
    let ledgerId: String
    let reason: String
    let expectedObservedSubstring: String?
}

private enum HarnessError: Error, CustomStringConvertible {
    case setup(String)
    var description: String {
        switch self { case .setup(let m): return "HARNESS/SETUP: \(m)" }
    }
}

private enum ExpectationMismatch: Error, CustomStringConvertible {
    case mismatch(String)
    var description: String {
        switch self { case .mismatch(let m): return m }
    }
}

enum EvalCatchScope {
    case expectationOnly
    case expectationOrPersistenceRejection
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if !(try condition()) { throw ExpectationMismatch.mismatch(message) }
}

private func checkSetup(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if !(try condition()) { throw HarnessError.setup(message) }
}

private func approx(_ a: Double, _ b: Double, tol: Double = 1e-4) -> Bool {
    abs(a - b) <= tol
}

// ---------------------------------------------------------------------------
// Divergence ledger (populated ONLY from observed red anchors)
// ---------------------------------------------------------------------------
private let maxKnownEditRecordDivergences = 12

private let knownEditRecordDivergences: [String: EditRecordDivergence] = [
    "roundtrip:full-sdr-raw-dormant-hdr": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-01",
        reason: "iOS SDR PhotoEffectsSettings rounds all 8 vignette/grain properties via .rounded() in init() (RawSettings.swift:130) instead of preserving exact fractional decimals (.25/.5/.75).",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-store-root-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-02",
        reason: "Tier 1 store-root unknown-field tolerance/sibling preservation passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-store-sibling-unknown-entry": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-03",
        reason: "Tier 1 store sibling entry preservation passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-record-root-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-04",
        reason: "Tier 1 record-root unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-settings-root-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-05",
        reason: "Tier 1 settings-root unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-tone-controls-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-06",
        reason: "Tier 1 toneControls unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-atmosphere-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-07",
        reason: "Tier 1 atmosphere unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-geometry-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-08",
        reason: "Tier 1 geometry unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-lens-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-09",
        reason: "Tier 1 lensCorrection unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-denoise-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-10",
        reason: "Tier 1 denoise unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-effects-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-MODEL-11",
        reason: "Tier 1 photoEffects unknown-field tolerance passes, but verifying reloaded full-sdr-raw-dormant-hdr target hits iOS SDR PhotoEffectsSettings.rounded() precision loss.",
        expectedObservedSubstring: "mismatched=8 [effects.vignette.amount(exp=-35.5,got=-36.0)"
    ),
    "x1-hdr-camera-profile-unknown-field": EditRecordDivergence(
        ledgerId: "EDIT-DIV-IOS-X1-01",
        reason: "Shared/HDRSettings.swift HDRCameraProfile uses synthesized Codable without closed-key checks, so an unknown key inside hdr.camera_development.camera_profile silently loads instead of failing as a version-bound Tier 2 render block.",
        expectedObservedSubstring: "Tier 2 unknown field in 'hdr_camera_profile' must throw UnusableEditRecordError"
    ),
]

@main
struct Harness {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let fixtureURL = root.appendingPathComponent("Shared/fixtures/edit-records-v1.json")

    static func main() {
        do {
            try runAll()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError.setup("Invalid JSON root in \(fixtureURL.path)")
        }
        try checkSetup((obj["fixture_version"] as? Int) == 1, "fixture_version must be 1")
        try checkSetup((obj["spec_version"] as? Int) == 1, "spec_version must be 1")
        return obj
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        return nil
    }

    static func intVal(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        }
        return nil
    }

    static func parseCurve(_ obj: [String: Any]) throws -> ToneCurveSettings {
        let modeStr = obj["mode"] as? String ?? "legacy"
        let mode: ToneCurveMode = modeStr == "custom" ? .custom : .legacy
        let ptsRaw = obj["points"] as? [[Any]] ?? []
        let points = ptsRaw.compactMap { pair -> ToneCurvePoint? in
            guard pair.count == 2, let x = num(pair[0]), let y = num(pair[1]) else { return nil }
            return ToneCurvePoint(x: x, y: y)
        }
        var channels = ToneCurveChannels()
        if let chObj = obj["channels"] as? [String: Any] {
            func parseShape(_ name: String) -> ToneCurveShape {
                guard let sub = chObj[name] as? [String: Any] else { return ToneCurveShape() }
                let mStr = sub["mode"] as? String ?? "legacy"
                let m: ToneCurveMode = mStr == "custom" ? .custom : .legacy
                let pr = sub["points"] as? [[Any]] ?? []
                let pts = pr.compactMap { pair -> ToneCurvePoint? in
                    guard pair.count == 2, let x = num(pair[0]), let y = num(pair[1]) else { return nil }
                    return ToneCurvePoint(x: x, y: y)
                }
                return ToneCurveShape(mode: m, points: pts)
            }
            channels = ToneCurveChannels(red: parseShape("red"), green: parseShape("green"), blue: parseShape("blue"))
        }
        return ToneCurveSettings(mode: mode, points: points, channels: channels)
    }

    static func parseGrading(_ sdr: [String: Any], prefix: String = "color.grading.") -> ColorGradingSettings {
        func wheel(_ key: String) -> ColorGradingWheel {
            guard let o = sdr[key] as? [String: Any] else { return ColorGradingWheel() }
            return ColorGradingWheel(hue: num(o["hue"]) ?? 0, saturation: num(o["saturation"]) ?? 0)
        }
        var grading = ColorGradingSettings()
        grading.shadows = wheel(prefix + "shadows")
        grading.midtones = wheel(prefix + "midtones")
        grading.highlights = wheel(prefix + "highlights")
        return grading
    }

    static func parseHSL(_ values: [String: Any]) -> HSLSettings {
        let channelKeys = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        var hsl = HSLSettings()
        for (i, ch) in channelKeys.enumerated() {
            if let v = num(values["color.hsl.hue.\(ch)"]) { hsl.setExact(.hue, channel: i, value: v) }
            if let v = num(values["color.hsl.saturation.\(ch)"]) { hsl.setExact(.saturation, channel: i, value: v) }
            if let v = num(values["color.hsl.lightness.\(ch)"]) { hsl.setExact(.lightness, channel: i, value: v) }
        }
        return hsl
    }

    static func buildHDRSettings(from values: [String: Any], metadata: [String: Any], activeMode: Bool) throws -> HDRSettings {
        var hdr = HDRSettings()
        hdr.mode = activeMode ? .hdr : .sdr
        if let v = num(values["light.exposure"]) { hdr.exposure = v }
        if let v = num(values["hdr.relative_temperature"]) { hdr.temperature = v }
        if let v = num(values["hdr.relative_tint"]) { hdr.tint = v }
        if let v = num(values["light.contrast"]) { hdr.contrast = (v - 1.0) * 100.0 }
        if let v = num(values["light.highlights"]) { hdr.highlights = -v * 100.0 }
        if let v = num(values["light.shadows"]) { hdr.shadows = v * 100.0 }
        if let v = num(values["color.saturation"]) { hdr.saturation = (v - 1.0) * 100.0 }

        var tone = HDRToneSettings()
        if let v = num(values["tone.black_point"]) { tone.blackPoint = v }
        if let v = num(values["tone.white_point"]) { tone.whitePoint = v }
        if let v = num(values["light.s_curve"]) { tone.curveStrength = v * 100.0 }
        if let cObj = values["light.curve"] as? [String: Any] { tone.curve = try parseCurve(cObj) }
        hdr.toneSettings = tone

        var color = HDRColorSettings()
        if let v = num(values["color.vibrance"]) { color.vibrance = v }
        color.hsl = parseHSL(values)
        color.grading = parseGrading(values)
        hdr.colorSettings = color

        var rendition = HDRRenditionSettings()
        if let v = num(values["hdr.peak_limit_ev"]) { rendition.peakLimitEV = v }
        if let v = num(values["hdr.sdr_exposure_ev"]) { rendition.sdrExposureEV = v }
        if let v = num(values["hdr.sdr_contrast"]) { rendition.sdrContrast = v }
        if let v = num(values["hdr.sdr_saturation"]) { rendition.sdrSaturation = v }
        hdr.renditionSettings = rendition

        var fx = HDRPhotoEffectsSettings()
        if let v = num(values["effects.vignette.amount"]) { fx.vignetteAmount = v }
        if let v = num(values["effects.vignette.midpoint"]) { fx.vignetteMidpoint = v }
        if let v = num(values["effects.vignette.roundness"]) { fx.vignetteRoundness = v }
        if let v = num(values["effects.vignette.feather"]) { fx.vignetteFeather = v }
        if let v = num(values["effects.vignette.highlights"]) { fx.vignetteHighlights = v }
        if let v = num(values["effects.grain.amount"]) { fx.grainAmount = v }
        if let v = num(values["effects.grain.size"]) { fx.grainSize = v }
        if let v = num(values["effects.grain.roughness"]) { fx.grainRoughness = v }
        hdr.effectsSettings = fx

        var detail = HDRDetailSettings()
        if let v = num(values["detail.sharpening"]) { detail.sharpening = v }
        if let v = num(values["effects.clarity"]) { detail.clarity = v / 100.0 }
        if let v = num(values["effects.dehaze"]) { detail.dehaze = v / 100.0 }
        if let v = num(values["detail.denoise.post_rgb"]) { detail.denoise = v }
        hdr.detailSettings = detail

        if let lookObj = values["hdr.look"] as? [String: Any],
           let sha = lookObj["sha256"] as? String,
           let name = lookObj["name"] as? String,
           let strength = num(lookObj["strength"]) {
            hdr.lookSettings = HDRLookSettings(sha256: sha, name: name, strength: strength)
        }

        if let camObj = values["hdr.camera_development"] as? [String: Any] {
            var cam = HDRCameraDevelopmentSettings()
            if let wb = camObj["white_balance_mode"] as? String, let parsed = HDRCameraDevelopmentSettings.WhiteBalance(rawValue: wb) {
                cam.whiteBalance = parsed
            }
            if let v = num(camObj["temperature"]) { cam.temperature = v }
            if let v = num(camObj["tint"]) { cam.tint = v }
            if let er = camObj["exposure_reference"] as? String, let parsed = HDRCameraDevelopmentSettings.ExposureReference(rawValue: er) {
                cam.exposureReference = parsed
            }
            if let fb = intVal(camObj["fbdd_level"]) { cam.fbddLevel = fb }
            if let extra = metadata["hdr_camera_development_extra"] as? [String: Any] {
                if let b = extra["lens_distortion"] as? Bool { cam.lensDistortion = b }
                if let b = extra["lens_tca"] as? Bool { cam.lensTCA = b }
                if let b = extra["lens_vignetting"] as? Bool { cam.lensVignetting = b }
                if let b = extra["lens_auto_crop"] as? Bool { cam.lensAutoCrop = b }
                if let lp = extra["lens_profile"] as? String { cam.lensProfile = lp }
                if let cp = extra["camera_profile"] as? [String: Any],
                   let sha = cp["sha256"] as? String, let name = cp["name"] as? String {
                    cam.cameraProfile = HDRCameraProfile(sha256: sha, name: name)
                }
            }
            hdr.cameraDevelopmentSettings = cam
        }

        var geom = GeometrySettings()
        if let v = num(values["geometry.crop.x"]) { geom.cropX = v }
        if let v = num(values["geometry.crop.y"]) { geom.cropY = v }
        if let v = num(values["geometry.crop.width"]) { geom.cropWidth = v }
        if let v = num(values["geometry.crop.height"]) { geom.cropHeight = v }
        if let v = intVal(values["geometry.quarter_turns"]) { geom.quarterTurns = v }
        if let b = values["geometry.flip_horizontal"] as? Bool { geom.flipHorizontal = b }
        if let b = values["geometry.flip_vertical"] as? Bool { geom.flipVertical = b }
        if let v = num(values["geometry.straighten_degrees"]) { geom.straightenDegrees = v }
        if let v = num(values["geometry.perspective.horizontal"]) { geom.perspectiveHorizontal = v }
        if let v = num(values["geometry.perspective.vertical"]) { geom.perspectiveVertical = v }
        hdr.geometry = geom
        return hdr
    }

    static func buildState(from record: [String: Any]) throws -> (state: PhotoEditState, isRaw: Bool, metadata: [String: Any]) {
        let photo = record["photo"] as? [String: Any] ?? [:]
        let isRaw = photo["is_raw"] as? Bool ?? true
        let metadata = record["metadata"] as? [String: Any] ?? [:]
        let sdrValues = record["sdr_values"] as? [String: Any] ?? [:]
        let hdrValues = record["hdr_values"] as? [String: Any] ?? [:]
        let dormantHDR = record["dormant_hdr_values"] as? [String: Any]
        let hdrEditing = metadata["hdr_editing"] as? Bool ?? false

        var settings = RawSettings.default
        if let procObj = metadata["processing"] as? [String: Any] {
            let ver = procObj["version"] as? Int ?? 3
            settings.processing = ver == 1 ? .legacy : ver == 2 ? .c5 : .current
        }
        if let x3f = metadata["x3f_mode"] as? String {
            settings.x3fMode = x3f == "legacy" ? .legacy : .normal
        }
        if let ver = intVal(metadata["master_recipe_settings_version"]) {
            settings.masterRecipeSettingsVersion = ver
        }
        if metadata.keys.contains("pro_raw_decode_version") {
            settings.proRAWDecodeVersion = intVal(metadata["pro_raw_decode_version"])
        }

        let filmRaw = metadata["film_id"] as? String ?? ""
        let filmID: String? = filmRaw.isEmpty ? nil : filmRaw
        var masterRecipeID = metadata["master_recipe_id"] as? String
        if let lookObj = sdrValues["looks.reference"] as? [String: Any],
           (lookObj["kind"] as? String) == "recipe", let id = lookObj["id"] as? String {
            masterRecipeID = id
        }
        settings.masterRecipeID = masterRecipeID
        if let filmID { settings.lutID = filmID }

        if let v = num(sdrValues["looks.strength"]) { settings.lutStrength = v }
        if let v = num(sdrValues["light.exposure"]) { settings.exposure = v }
        if let em = sdrValues["light.exposure_mode"] as? String {
            settings.exposureMode = em == "scene" ? .scene : em == "sensor" ? .sensor : .preview
        }
        if let v = num(sdrValues["light.contrast"]) { settings.contrast = v }
        if let v = num(sdrValues["light.highlights"]) { settings.highlights = v }
        if let v = num(sdrValues["light.shadows"]) { settings.shadows = v }
        if let v = num(sdrValues["light.s_curve"]) { settings.toneCurve = v }
        if let cObj = sdrValues["light.curve"] as? [String: Any] {
            settings.curveSettings = try parseCurve(cObj)
        }
        if let v = num(sdrValues["tone.black_point"]) { settings.blackPoint = v }
        if let v = num(sdrValues["tone.white_point"]) { settings.whitePoint = v }
        if let v = num(sdrValues["color.vibrance"]) { settings.vibrance = v }
        if sdrValues.keys.contains("color.grading.shadows") {
            settings.gradingSettings = parseGrading(sdrValues)
        }
        if let wbMode = sdrValues["color.white_balance.mode"] as? String {
            settings.whiteBalanceMode = wbMode == "temperature" ? .custom : .camera
        }
        if let v = num(sdrValues["color.white_balance.temperature_kelvin"]) { settings.temperature = v }
        if let v = num(sdrValues["color.white_balance.tint"]) { settings.tint = v }
        if let v = num(sdrValues["color.saturation"]) { settings.saturation = v }

        settings.hsl = parseHSL(sdrValues)

        var effects = PhotoEffectsSettings()
        if let v = num(sdrValues["effects.vignette.amount"]) { effects.vignetteAmount = v }
        if let v = num(sdrValues["effects.vignette.midpoint"]) { effects.vignetteMidpoint = v }
        if let v = num(sdrValues["effects.vignette.roundness"]) { effects.vignetteRoundness = v }
        if let v = num(sdrValues["effects.vignette.feather"]) { effects.vignetteFeather = v }
        if let v = num(sdrValues["effects.vignette.highlights"]) { effects.vignetteHighlights = v }
        if let v = num(sdrValues["effects.grain.amount"]) { effects.grainAmount = v }
        if let v = num(sdrValues["effects.grain.size"]) { effects.grainSize = v }
        if let v = num(sdrValues["effects.grain.roughness"]) { effects.grainRoughness = v }
        settings.photoEffects = effects

        if let v = num(sdrValues["effects.clarity"]) { settings.clarity = v }
        if let v = num(sdrValues["effects.dehaze"]) { settings.dehaze = v }
        if let v = num(sdrValues["detail.sharpening"]) { settings.sharpening = v }
        if let v = num(sdrValues["detail.denoise.post_rgb"]) { settings.noiseReduction = v }
        if let v = intVal(sdrValues["detail.denoise.chroma_mode"]) { settings.displayChromaDenoise = v }
        if let wObj = sdrValues["detail.denoise.wavelet"] as? [String: Any] {
            settings.denoise = RawDenoiseSettings(
                enabled: wObj["enabled"] as? Bool ?? false,
                luma: num(wObj["luma"]) ?? 0,
                chroma: num(wObj["chroma"]) ?? 46,
                coarse: num(wObj["coarse"]) ?? 50
            )
        }

        var geom = GeometrySettings()
        if let v = num(sdrValues["geometry.crop.x"]) { geom.cropX = v }
        if let v = num(sdrValues["geometry.crop.y"]) { geom.cropY = v }
        if let v = num(sdrValues["geometry.crop.width"]) { geom.cropWidth = v }
        if let v = num(sdrValues["geometry.crop.height"]) { geom.cropHeight = v }
        if let v = intVal(sdrValues["geometry.quarter_turns"]) { geom.quarterTurns = v }
        if let b = sdrValues["geometry.flip_horizontal"] as? Bool { geom.flipHorizontal = b }
        if let b = sdrValues["geometry.flip_vertical"] as? Bool { geom.flipVertical = b }
        if let v = num(sdrValues["geometry.straighten_degrees"]) { geom.straightenDegrees = v }
        if let v = num(sdrValues["geometry.perspective.horizontal"]) { geom.perspectiveHorizontal = v }
        if let v = num(sdrValues["geometry.perspective.vertical"]) { geom.perspectiveVertical = v }
        settings.geometry = geom

        if sdrValues.keys.contains(where: { $0.hasPrefix("geometry.lens.") }) {
            var lens = LensCorrectionSettings()
            if let b = sdrValues["geometry.lens.distortion"] as? Bool { lens.distortion = b }
            if let b = sdrValues["geometry.lens.tca"] as? Bool { lens.tca = b }
            if let b = sdrValues["geometry.lens.vignetting"] as? Bool { lens.vignetting = b }
            if let b = sdrValues["geometry.lens.auto_crop"] as? Bool { lens.autoCrop = b }
            if let lp = sdrValues["geometry.lens.profile_id"] as? String {
                lens.mode = .manual
                lens.profileID = lp
            }
            if let extra = metadata["lens_extra"] as? [String: Any] {
                if let fl = num(extra["focal_length"]) { lens.focalLength = fl }
                if let cf = num(extra["crop_factor"]) { lens.cropFactor = cf }
            }
            settings.lensCorrection = lens
        }

        if hdrEditing {
            settings.hdr = try buildHDRSettings(from: hdrValues, metadata: metadata, activeMode: true)
        } else if let dormantHDR {
            settings.hdr = try buildHDRSettings(from: dormantHDR, metadata: metadata, activeMode: false)
        }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let state = PhotoEditState(settings: settings, filmID: nil, updatedAt: date)
            .replacing(settings: settings, preservingFilmID: filmID)
        return (state, isRaw, metadata)
    }

    static func verifyState(_ actual: PhotoEditState, matches record: [String: Any]) throws {
        let id = record["id"] as! String
        let photo = record["photo"] as? [String: Any] ?? [:]
        let isRaw = photo["is_raw"] as? Bool ?? true
        let metadata = record["metadata"] as? [String: Any] ?? [:]
        let sdrValues = record["sdr_values"] as? [String: Any] ?? [:]
        let hdrValues = record["hdr_values"] as? [String: Any] ?? [:]
        let dormantHDR = record["dormant_hdr_values"] as? [String: Any]
        let hdrEditing = metadata["hdr_editing"] as? Bool ?? false
        let s = actual.settings

        var mismatches: [String] = []
        func verify(_ ok: Bool, _ detail: String) {
            if !ok { mismatches.append(detail) }
        }
        func verifyCurveInto(_ expected: [String: Any], _ actualCurve: ToneCurveSettings, _ label: String) {
            let expMode = expected["mode"] as? String ?? "legacy"
            verify((actualCurve.mode == .custom ? "custom" : "legacy") == expMode, "\(label).curve.mode")
            let expPts = expected["points"] as? [[Any]] ?? []
            verify(actualCurve.points.count == expPts.count, "\(label).curve.points.count")
            if actualCurve.points.count == expPts.count {
                for (idx, p) in expPts.enumerated() {
                    verify(approx(actualCurve.points[idx].x, num(p[0]) ?? -999) &&
                           approx(actualCurve.points[idx].y, num(p[1]) ?? -999), "\(label).curve.points[\(idx)]")
                }
            }
            if let ch = expected["channels"] as? [String: Any] {
                for (name, actualShape) in [("red", actualCurve.channels.red), ("green", actualCurve.channels.green), ("blue", actualCurve.channels.blue)] {
                    if let eShape = ch[name] as? [String: Any] {
                        let eMode = eShape["mode"] as? String ?? "legacy"
                        verify((actualShape.mode == .custom ? "custom" : "legacy") == eMode, "\(label).curve.\(name).mode")
                        let ePts = eShape["points"] as? [[Any]] ?? []
                        verify(actualShape.points.count == ePts.count, "\(label).curve.\(name).count")
                        if actualShape.points.count == ePts.count {
                            for (idx, p) in ePts.enumerated() {
                                verify(approx(actualShape.points[idx].x, num(p[0]) ?? -999) &&
                                       approx(actualShape.points[idx].y, num(p[1]) ?? -999), "\(label).curve.\(name)[\(idx)]")
                            }
                        }
                    }
                }
            }
        }
        func verifyHSLInto(_ values: [String: Any], _ actualHSL: HSLSettings, _ label: String) {
            let channelKeys = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
            for (i, ch) in channelKeys.enumerated() {
                if let e = num(values["color.hsl.hue.\(ch)"]) { verify(approx(actualHSL.value(.hue, channel: i), e), "\(label).hsl.hue.\(ch)") }
                if let e = num(values["color.hsl.saturation.\(ch)"]) { verify(approx(actualHSL.value(.saturation, channel: i), e), "\(label).hsl.sat.\(ch)") }
                if let e = num(values["color.hsl.lightness.\(ch)"]) { verify(approx(actualHSL.value(.lightness, channel: i), e), "\(label).hsl.lit.\(ch)") }
            }
        }
        func verifyGradingInto(_ values: [String: Any], _ actualGrading: ColorGradingSettings, _ label: String) {
            for (zoneName, zone) in [("shadows", ColorGradingZone.shadows), ("midtones", .midtones), ("highlights", .highlights)] {
                if let g = values["color.grading.\(zoneName)"] as? [String: Any] {
                    verify(approx(actualGrading[zone].hue, num(g["hue"]) ?? -1) &&
                           approx(actualGrading[zone].saturation, num(g["saturation"]) ?? -1), "\(label).grading.\(zoneName)")
                }
            }
        }
        func verifyGeomInto(_ values: [String: Any], _ actualGeom: GeometrySettings, _ label: String) {
            if let v = num(values["geometry.crop.x"]) { verify(approx(actualGeom.cropX, v), "\(label).cropX") }
            if let v = num(values["geometry.crop.y"]) { verify(approx(actualGeom.cropY, v), "\(label).cropY") }
            if let v = num(values["geometry.crop.width"]) { verify(approx(actualGeom.cropWidth, v), "\(label).cropW") }
            if let v = num(values["geometry.crop.height"]) { verify(approx(actualGeom.cropHeight, v), "\(label).cropH") }
            if let v = intVal(values["geometry.quarter_turns"]) { verify(actualGeom.quarterTurns == v, "\(label).turns") }
            if let b = values["geometry.flip_horizontal"] as? Bool { verify(actualGeom.flipHorizontal == b, "\(label).flipH") }
            if let b = values["geometry.flip_vertical"] as? Bool { verify(actualGeom.flipVertical == b, "\(label).flipV") }
            if let v = num(values["geometry.straighten_degrees"]) { verify(approx(actualGeom.straightenDegrees, v), "\(label).straighten") }
            if let v = num(values["geometry.perspective.horizontal"]) { verify(approx(actualGeom.perspectiveHorizontal, v), "\(label).perspH") }
            if let v = num(values["geometry.perspective.vertical"]) { verify(approx(actualGeom.perspectiveVertical, v), "\(label).perspV") }
        }

        let expFilmRaw = metadata["film_id"] as? String ?? ""
        let expFilm: String? = expFilmRaw.isEmpty ? nil : expFilmRaw
        verify(actual.filmID == expFilm, "filmID")
        verify(s.masterRecipeID == (metadata["master_recipe_id"] as? String), "masterRecipeID")
        if let lookRef = sdrValues["looks.reference"] as? [String: Any], let kind = lookRef["kind"] as? String {
            switch kind {
            case "recipe": verify(s.masterRecipeID == (lookRef["id"] as? String), "looks.reference.recipe")
            case "builtin", "managed": verify(actual.filmID == expFilm && !(actual.filmID?.isEmpty ?? true), "looks.reference.\(kind)")
            case "neutral": verify(actual.filmID == nil && s.masterRecipeID == nil, "looks.reference.neutral")
            default: break
            }
        }
        if let proc = metadata["processing"] as? [String: Any], let v = proc["version"] as? Int {
            verify(s.processing.version == v, "processing.version")
        }
        if let x3f = metadata["x3f_mode"] as? String {
            verify(s.x3fMode.rawValue == x3f, "x3fMode")
        }
        if let mv = intVal(metadata["master_recipe_settings_version"]) {
            verify(s.masterRecipeSettingsVersion == mv, "masterRecipeSettingsVersion")
        }
        if metadata.keys.contains("pro_raw_decode_version") {
            verify(s.proRAWDecodeVersion == intVal(metadata["pro_raw_decode_version"]), "proRAWDecodeVersion")
        }
        verify(s.isHDREditing == hdrEditing, "isHDREditing")

        if let v = num(sdrValues["looks.strength"]) { verify(approx(s.lutStrength, v), "looks.strength") }
        if let v = num(sdrValues["light.exposure"]) { verify(approx(s.exposure, v), "light.exposure") }
        if let em = sdrValues["light.exposure_mode"] as? String {
            let actualEm = s.exposureMode == .scene ? "scene" : s.exposureMode == .preview ? "preview" : "sensor"
            verify(actualEm == em, "light.exposure_mode")
        }
        if let v = num(sdrValues["light.contrast"]) { verify(approx(s.contrast, v), "light.contrast") }
        if let v = num(sdrValues["light.highlights"]) { verify(approx(s.highlights, v), "light.highlights") }
        if let v = num(sdrValues["light.shadows"]) { verify(approx(s.shadows, v), "light.shadows") }
        if let v = num(sdrValues["light.s_curve"]) { verify(approx(s.toneCurve, v), "light.s_curve") }
        if let cObj = sdrValues["light.curve"] as? [String: Any] { verifyCurveInto(cObj, s.curveSettings, "sdr") }
        if let v = num(sdrValues["tone.black_point"]) { verify(approx(s.blackPoint, v), "tone.black_point") }
        if let v = num(sdrValues["tone.white_point"]) { verify(approx(s.whitePoint, v), "tone.white_point") }
        if let v = num(sdrValues["color.vibrance"]) { verify(approx(s.vibrance, v), "color.vibrance") }
        verifyGradingInto(sdrValues, s.gradingSettings, "sdr")
        if let wb = sdrValues["color.white_balance.mode"] as? String {
            let actualWB = isRaw
                ? (s.whiteBalanceMode == .custom ? "temperature" : "camera")
                : (s.whiteBalanceMode == .camera ? "none" : "temperature")
            verify(actualWB == wb, "wb.mode")
        }
        if let v = num(sdrValues["color.white_balance.temperature_kelvin"]) { verify(approx(s.temperature, v), "wb.temp") }
        if let v = num(sdrValues["color.white_balance.tint"]) { verify(approx(s.tint, v), "wb.tint") }
        if let v = num(sdrValues["color.saturation"]) { verify(approx(s.saturation, v), "color.saturation") }
        verifyHSLInto(sdrValues, s.hsl, "sdr")

        if let v = num(sdrValues["effects.vignette.amount"]) { verify(approx(s.photoEffects.vignetteAmount, v), "effects.vignette.amount(exp=\(v),got=\(s.photoEffects.vignetteAmount))") }
        if let v = num(sdrValues["effects.vignette.midpoint"]) { verify(approx(s.photoEffects.vignetteMidpoint, v), "effects.vignette.midpoint(exp=\(v),got=\(s.photoEffects.vignetteMidpoint))") }
        if let v = num(sdrValues["effects.vignette.roundness"]) { verify(approx(s.photoEffects.vignetteRoundness, v), "effects.vignette.roundness(exp=\(v),got=\(s.photoEffects.vignetteRoundness))") }
        if let v = num(sdrValues["effects.vignette.feather"]) { verify(approx(s.photoEffects.vignetteFeather, v), "effects.vignette.feather(exp=\(v),got=\(s.photoEffects.vignetteFeather))") }
        if let v = num(sdrValues["effects.vignette.highlights"]) { verify(approx(s.photoEffects.vignetteHighlights, v), "effects.vignette.highlights(exp=\(v),got=\(s.photoEffects.vignetteHighlights))") }
        if let v = num(sdrValues["effects.grain.amount"]) { verify(approx(s.photoEffects.grainAmount, v), "effects.grain.amount(exp=\(v),got=\(s.photoEffects.grainAmount))") }
        if let v = num(sdrValues["effects.grain.size"]) { verify(approx(s.photoEffects.grainSize, v), "effects.grain.size(exp=\(v),got=\(s.photoEffects.grainSize))") }
        if let v = num(sdrValues["effects.grain.roughness"]) { verify(approx(s.photoEffects.grainRoughness, v), "effects.grain.roughness(exp=\(v),got=\(s.photoEffects.grainRoughness))") }
        if let v = num(sdrValues["effects.clarity"]) { verify(approx(s.clarity, v), "effects.clarity") }
        if let v = num(sdrValues["effects.dehaze"]) { verify(approx(s.dehaze, v), "effects.dehaze") }
        if let v = num(sdrValues["detail.sharpening"]) { verify(approx(s.sharpening, v), "detail.sharpening") }
        if let v = num(sdrValues["detail.denoise.post_rgb"]) { verify(approx(s.noiseReduction, v), "detail.denoise.post_rgb") }
        if let v = intVal(sdrValues["detail.denoise.chroma_mode"]) { verify(s.displayChromaDenoise == v, "detail.denoise.chroma_mode") }
        if let w = sdrValues["detail.denoise.wavelet"] as? [String: Any] {
            verify(s.denoise.enabled == (w["enabled"] as? Bool ?? false), "wavelet.enabled")
            verify(approx(s.denoise.luma, num(w["luma"]) ?? -1), "wavelet.luma")
            verify(approx(s.denoise.chroma, num(w["chroma"]) ?? -1), "wavelet.chroma")
            verify(approx(s.denoise.coarse, num(w["coarse"]) ?? -1), "wavelet.coarse")
            if let expPreset = w["preset"] as? String {
                let actualPreset = s.denoise.preset == .detail ? "detail" : s.denoise.preset == .clean ? "clean" : "custom"
                verify(actualPreset == expPreset, "wavelet.preset(exp=\(expPreset),got=\(actualPreset))")
            }
        }

        verifyGeomInto(sdrValues, s.geometry, "sdr")
        if sdrValues.keys.contains("geometry.lens.distortion") {
            let l = s.lensSettings
            verify(l.distortion == (sdrValues["geometry.lens.distortion"] as? Bool ?? false), "lens.dist")
            verify(l.tca == (sdrValues["geometry.lens.tca"] as? Bool ?? false), "lens.tca")
            verify(l.vignetting == (sdrValues["geometry.lens.vignetting"] as? Bool ?? false), "lens.vig")
            verify(l.autoCrop == (sdrValues["geometry.lens.auto_crop"] as? Bool ?? true), "lens.autoCrop")
            verify(l.profileID == (sdrValues["geometry.lens.profile_id"] as? String), "lens.profileID")
        }

        if let hdrCheck = hdrEditing ? hdrValues : dormantHDR {
            guard let hdr = s.hdr else { throw ExpectationMismatch.mismatch("\(id): expected hdr settings to be preserved") }
            verify((hdr.mode == .hdr) == hdrEditing, "hdr.mode")
            if let v = num(hdrCheck["light.exposure"]) { verify(approx(hdr.exposure, v), "hdr.exposure") }
            if let v = num(hdrCheck["hdr.relative_temperature"]) { verify(approx(hdr.temperature, v), "hdr.temp") }
            if let v = num(hdrCheck["hdr.relative_tint"]) { verify(approx(hdr.tint, v), "hdr.tint") }
            if let v = num(hdrCheck["light.contrast"]) { verify(approx(1 + hdr.contrast / 100, v), "hdr.contrast") }
            if let v = num(hdrCheck["light.highlights"]) { verify(approx(-hdr.highlights / 100, v), "hdr.highlights") }
            if let v = num(hdrCheck["light.shadows"]) { verify(approx(hdr.shadows / 100, v), "hdr.shadows") }
            if let v = num(hdrCheck["color.saturation"]) { verify(approx(1 + hdr.saturation / 100, v), "hdr.saturation") }
            if let v = num(hdrCheck["tone.black_point"]) { verify(approx(hdr.toneSettings.blackPoint, v), "hdr.blackPoint") }
            if let v = num(hdrCheck["tone.white_point"]) { verify(approx(hdr.toneSettings.whitePoint, v), "hdr.whitePoint") }
            if let v = num(hdrCheck["light.s_curve"]) { verify(approx(hdr.toneSettings.curveStrength / 100, v), "hdr.sCurve") }
            if let cObj = hdrCheck["light.curve"] as? [String: Any] { verifyCurveInto(cObj, hdr.toneSettings.curve, "hdr") }
            if let v = num(hdrCheck["color.vibrance"]) { verify(approx(hdr.colorSettings.vibrance, v), "hdr.vibrance") }
            verifyHSLInto(hdrCheck, hdr.colorSettings.hsl, "hdr")
            verifyGradingInto(hdrCheck, hdr.colorSettings.grading, "hdr")
            if let v = num(hdrCheck["hdr.peak_limit_ev"]) { verify(approx(hdr.renditionSettings.peakLimitEV, v), "hdr.peakLimit") }
            if let v = num(hdrCheck["hdr.sdr_exposure_ev"]) { verify(approx(hdr.renditionSettings.sdrExposureEV, v), "hdr.sdrExp") }
            if let v = num(hdrCheck["hdr.sdr_contrast"]) { verify(approx(hdr.renditionSettings.sdrContrast, v), "hdr.sdrCon") }
            if let v = num(hdrCheck["hdr.sdr_saturation"]) { verify(approx(hdr.renditionSettings.sdrSaturation, v), "hdr.sdrSat") }
            for (fid, kp) in [
                ("effects.vignette.amount", \HDRPhotoEffectsSettings.vignetteAmount),
                ("effects.vignette.midpoint", \HDRPhotoEffectsSettings.vignetteMidpoint),
                ("effects.vignette.roundness", \HDRPhotoEffectsSettings.vignetteRoundness),
                ("effects.vignette.feather", \HDRPhotoEffectsSettings.vignetteFeather),
                ("effects.vignette.highlights", \HDRPhotoEffectsSettings.vignetteHighlights),
                ("effects.grain.amount", \HDRPhotoEffectsSettings.grainAmount),
                ("effects.grain.size", \HDRPhotoEffectsSettings.grainSize),
                ("effects.grain.roughness", \HDRPhotoEffectsSettings.grainRoughness)
            ] as [(String, KeyPath<HDRPhotoEffectsSettings, Double>)] {
                if let v = num(hdrCheck[fid]) { verify(approx(hdr.effectsSettings[keyPath: kp], v), "hdr.\(fid)") }
            }
            if let v = num(hdrCheck["detail.sharpening"]) { verify(approx(hdr.detailSettings.sharpening, v), "hdr.detail.sharpening") }
            if let v = num(hdrCheck["effects.clarity"]) { verify(approx(hdr.detailSettings.clarity * 100, v), "hdr.clarity") }
            if let v = num(hdrCheck["effects.dehaze"]) { verify(approx(hdr.detailSettings.dehaze * 100, v), "hdr.dehaze") }
            if let v = num(hdrCheck["detail.denoise.post_rgb"]) { verify(approx(hdr.detailSettings.denoise, v), "hdr.denoise") }
            if let lk = hdrCheck["hdr.look"] as? [String: Any] {
                verify(hdr.lookSettings.sha256 == (lk["sha256"] as? String) &&
                       hdr.lookSettings.name == (lk["name"] as? String) &&
                       approx(hdr.lookSettings.strength, num(lk["strength"]) ?? -1), "hdr.look")
            }
            if let cam = hdrCheck["hdr.camera_development"] as? [String: Any] {
                verify(hdr.cameraDevelopmentSettings.whiteBalance.rawValue == (cam["white_balance_mode"] as? String), "hdr.cam.wb")
                verify(approx(hdr.cameraDevelopmentSettings.temperature, num(cam["temperature"]) ?? -1), "hdr.cam.temp")
                verify(approx(hdr.cameraDevelopmentSettings.tint, num(cam["tint"]) ?? -999), "hdr.cam.tint")
                verify(hdr.cameraDevelopmentSettings.exposureReference.rawValue == (cam["exposure_reference"] as? String), "hdr.cam.expRef")
                verify(hdr.cameraDevelopmentSettings.fbddLevel == (intVal(cam["fbdd_level"]) ?? -1), "hdr.cam.fbdd")
                if let extra = metadata["hdr_camera_development_extra"] as? [String: Any] {
                    if let b = extra["lens_distortion"] as? Bool { verify(hdr.cameraDevelopmentSettings.lensDistortion == b, "hdr.cam.lensDistortion") }
                    if let b = extra["lens_tca"] as? Bool { verify(hdr.cameraDevelopmentSettings.lensTCA == b, "hdr.cam.lensTCA") }
                    if let b = extra["lens_vignetting"] as? Bool { verify(hdr.cameraDevelopmentSettings.lensVignetting == b, "hdr.cam.lensVignetting") }
                    if let b = extra["lens_auto_crop"] as? Bool { verify(hdr.cameraDevelopmentSettings.lensAutoCrop == b, "hdr.cam.lensAutoCrop") }
                    verify(hdr.cameraDevelopmentSettings.lensProfile == (extra["lens_profile"] as? String), "hdr.cam.lensProfile")
                    if let cp = extra["camera_profile"] as? [String: Any] {
                        verify(hdr.cameraDevelopmentSettings.cameraProfile?.sha256 == (cp["sha256"] as? String) &&
                               hdr.cameraDevelopmentSettings.cameraProfile?.name == (cp["name"] as? String), "hdr.cam.camProfile")
                    }
                }
            }
            verifyGeomInto(hdrCheck, hdr.geometry, "hdr")
        }
        if !mismatches.isEmpty {
            throw ExpectationMismatch.mismatch("\(id): mismatched=\(mismatches.count) [" + mismatches.joined(separator: "; ") + "]")
        }
    }

    static func makeStore(tempRoot: URL, name: String) throws -> (store: EditPersistence, dir: URL, file: URL) {
        let dir = tempRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try EditPersistence(directory: dir), dir, dir.appendingPathComponent("edits.json"))
    }

    static func touchPhoto(_ tempRoot: URL, name: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data("fixture-\(name)".utf8).write(to: url)
        }
        return url
    }

    static func evaluateScenario(id: String, scope: EvalCatchScope, evaluatedIDs: inout Set<String>, body: () throws -> Void) throws {
        evaluatedIDs.insert(id)
        var bodyError: Error?
        do {
            try body()
        } catch {
            bodyError = error
        }
        guard let err = bodyError else {
            if let reg = knownEditRecordDivergences[id] {
                throw HarnessError.setup("Stale divergence ledger entry '\(id)' (\(reg.ledgerId)): scenario now passed")
            }
            print("PASS: \(id)")
            return
        }
        let isExpectationOrAllowedRejection: Bool
        switch err {
        case is ExpectationMismatch:
            isExpectationOrAllowedRejection = true
        case is UnusableEditRecordError:
            isExpectationOrAllowedRejection = (scope == .expectationOrPersistenceRejection)
        default:
            isExpectationOrAllowedRejection = false
        }
        guard isExpectationOrAllowedRejection else {
            throw err
        }
        if let reg = knownEditRecordDivergences[id] {
            try checkSetup(!reg.ledgerId.trimmingCharacters(in: .whitespaces).isEmpty, "Blank ledgerId for \(id)")
            try checkSetup(!reg.reason.trimmingCharacters(in: .whitespaces).isEmpty, "Blank reason for \(id)")
            if let expectedSub = reg.expectedObservedSubstring {
                try checkSetup("\(err)".contains(expectedSub),
                               "Divergence [\(id)] (\(reg.ledgerId)) observed '\(err)' missing expected substring '\(expectedSub)'")
            }
            print("KNOWN DIVERGENCE [\(id)] (\(reg.ledgerId)): \(reg.reason) | observed: \(err)")
        } else {
            throw ExpectationMismatch.mismatch("RED ANCHOR [\(id)]: \(err)")
        }
    }

    static func mutateJSONScope(registry: inout [String: Any], targetKey: String, scope: String, key: String, value: Any) throws {
        switch scope {
        case "store_root":
            registry[key] = value
            return
        case "store_sibling_entry":
            var records = registry["records"] as? [String: Any] ?? [:]
            records["content:future_sibling_entry"] = [key: value]
            registry["records"] = records
            return
        default: break
        }
        var records = registry["records"] as! [String: Any]
        var state = records[targetKey] as! [String: Any]
        var settings = state["settings"] as! [String: Any]

        func inject(_ dict: inout [String: Any]) { dict[key] = value }

        switch scope {
        case "record_root":
            inject(&state)
        case "settings_root":
            inject(&settings)
        case "processing":
            var sub = settings["processing"] as! [String: Any]; inject(&sub); settings["processing"] = sub
        case "tone_controls":
            var sub = settings["toneControls"] as! [String: Any]; inject(&sub); settings["toneControls"] = sub
        case "atmosphere":
            var sub = settings["atmosphere"] as! [String: Any]; inject(&sub); settings["atmosphere"] = sub
        case "color_grading":
            var sub = settings["colorGrading"] as! [String: Any]; inject(&sub); settings["colorGrading"] = sub
        case "color_grading_zone":
            var sub = settings["colorGrading"] as! [String: Any]
            var sh = sub["shadows"] as! [String: Any]; inject(&sh); sub["shadows"] = sh; settings["colorGrading"] = sub
        case "tone_curve":
            var sub = settings["toneCurveConfig"] as! [String: Any]; inject(&sub); settings["toneCurveConfig"] = sub
        case "tone_curve_channels":
            var sub = settings["toneCurveConfig"] as! [String: Any]
            var ch = sub["channels"] as! [String: Any]; inject(&ch); sub["channels"] = ch; settings["toneCurveConfig"] = sub
        case "geometry":
            var sub = settings["geometry"] as! [String: Any]; inject(&sub); settings["geometry"] = sub
        case "lens":
            var sub = settings["lensCorrection"] as! [String: Any]; inject(&sub); settings["lensCorrection"] = sub
        case "denoise":
            var sub = settings["denoise"] as! [String: Any]; inject(&sub); settings["denoise"] = sub
        case "effects":
            var sub = settings["photoEffects"] as! [String: Any]; inject(&sub); settings["photoEffects"] = sub
        case "hdr":
            var sub = settings["hdr"] as! [String: Any]; inject(&sub); settings["hdr"] = sub
        case "hdr_tone":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["tone"] as! [String: Any]; inject(&sub); hdr["tone"] = sub; settings["hdr"] = hdr
        case "hdr_color":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["color"] as! [String: Any]; inject(&sub); hdr["color"] = sub; settings["hdr"] = hdr
        case "hdr_rendition":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["rendition"] as! [String: Any]; inject(&sub); hdr["rendition"] = sub; settings["hdr"] = hdr
        case "hdr_effects":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["effects"] as! [String: Any]; inject(&sub); hdr["effects"] = sub; settings["hdr"] = hdr
        case "hdr_detail":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["detail"] as! [String: Any]; inject(&sub); hdr["detail"] = sub; settings["hdr"] = hdr
        case "hdr_look":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["look"] as! [String: Any]; inject(&sub); hdr["look"] = sub; settings["hdr"] = hdr
        case "hdr_camera_development":
            var hdr = settings["hdr"] as! [String: Any]; var sub = hdr["camera_development"] as! [String: Any]; inject(&sub); hdr["camera_development"] = sub; settings["hdr"] = hdr
        case "hdr_camera_profile":
            var hdr = settings["hdr"] as! [String: Any]; var cd = hdr["camera_development"] as! [String: Any]
            var cp = cd["camera_profile"] as! [String: Any]; inject(&cp); cd["camera_profile"] = cp; hdr["camera_development"] = cd; settings["hdr"] = hdr
        default:
            throw HarnessError.setup("Unhandled unknown_field target_scope: \(scope)")
        }
        state["settings"] = settings
        records[targetKey] = state
        registry["records"] = records
    }

    static func runAll() throws {
        let fixture = try loadFixture()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-ios-edit-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let roundtrip = fixture["roundtrip_records"] as! [[String: Any]]
        var byID: [String: [String: Any]] = [:]
        for rec in roundtrip { byID[rec["id"] as! String] = rec }

        var failures: [String] = []
        var evaluatedIDs: Set<String> = []
        func eval(_ id: String, scope: EvalCatchScope = .expectationOnly, body: () throws -> Void) {
            do {
                try evaluateScenario(id: id, scope: scope, evaluatedIDs: &evaluatedIDs, body: body)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                failures.append("\(error)")
            }
        }

        // 1. Roundtrip records
        for rec in roundtrip {
            let id = rec["id"] as! String
            let scenarioID = "roundtrip:\(id)"
            do {
                let (built, _, metadata) = try buildState(from: rec)
                let (store, dir, _) = try makeStore(tempRoot: tempRoot, name: "rt-\(id)")
                let photoURL = try touchPhoto(tempRoot, name: (rec["photo"] as! [String: Any])["name"] as! String)
                try store.save(photoURL, state: built)
                let pid = try PhotoIdentity.fallback(for: photoURL)
                let keepReceipt = (metadata["migration_receipt"] as? [String: Any])?["status"] as? String == "kept"
                if keepReceipt {
                    let quality = ProcessingMigrationQuality(rgbRMSE: 0.01, p99Error: 0.02, worstTileRMSE: 0.02, detailRMSE: 0.01, evaluations: 10)
                    _ = try store.commitProcessingMigration(expected: try store.readState(for: pid), candidate: nil, quality: quality)
                }
                eval(scenarioID) {
                    let reopened = try EditPersistence(directory: dir)
                    let reloaded = try reopened.state(for: photoURL)
                    try check(reloaded != nil, "\(id): reloaded state must not be nil")
                    try verifyState(reloaded!, matches: rec)
                    if keepReceipt {
                        try check(try reopened.processingMigration(for: pid)?.status == .kept, "\(id): migration receipt kept")
                    }
                }
            } catch {
                fputs("FAIL SETUP[\(scenarioID)]: \(error)\n", stderr)
                failures.append("SETUP[\(scenarioID)]: \(error)")
            }
        }

        // 2. X1 Unknown field scenarios (Two-Tier)
        let unknownList = fixture["unknown_field_scenarios"] as! [[String: Any]]
        for sc in unknownList {
            let id = sc["id"] as! String
            let baseID = sc["base_record_id"] as! String
            let baseRec = byID[baseID]!
            let scope = sc["target_scope"] as! String
            let key = sc["inject_key"] as! String
            let val = sc["inject_value"]!
            let expectPolicy = sc["expect"] as! String
            let preserveRawDiskEntry = sc["preserve_raw_disk_entry"] as? Bool ?? false
            do {
                let (built, _, _) = try buildState(from: baseRec)
                let (siblingBuilt, _, _) = try buildState(from: byID["raster-sdr-neutral"]!)
                let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "x1-\(id)")
                let targetURL = try touchPhoto(tempRoot, name: "target-\(id).DNG")
                let siblingURL = try touchPhoto(tempRoot, name: "sibling-\(id).JPG")
                try store.save(targetURL, state: built)
                try store.save(siblingURL, state: siblingBuilt)

                let rawData = try Data(contentsOf: file)
                var registry = try JSONSerialization.jsonObject(with: rawData) as! [String: Any]
                let targetKey = try PhotoIdentity.fallback(for: targetURL).key
                try mutateJSONScope(registry: &registry, targetKey: targetKey, scope: scope, key: key, value: val)
                try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys]).write(to: file)

                if expectPolicy == "load_preserving_values" {
                    eval(id, scope: .expectationOrPersistenceRejection) {
                        let reopened = try EditPersistence(directory: dir)
                        let loadedTarget = try reopened.state(for: targetURL)
                        try check(loadedTarget != nil, "\(id): target record must remain readable with unknown key in \(scope)")
                        let loadedSibling = try reopened.state(for: siblingURL)
                        try check(loadedSibling != nil, "\(id): sibling record must remain readable")
                        if preserveRawDiskEntry {
                            let updatedSib = siblingBuilt.replacing(settings: { var s = siblingBuilt.settings; s.exposure = 1.25; return s }(), preservingFilmID: siblingBuilt.filmID)
                            try reopened.save(siblingURL, state: updatedSib)
                            let diskAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                            let diskRecs = diskAfter["records"] as! [String: Any]
                            try check(diskRecs["content:future_sibling_entry"] != nil,
                                      "\(id): unknown sibling entry must remain preserved on disk across sibling save")
                        }
                        try verifyState(loadedTarget!, matches: baseRec)
                    }
                } else if expectPolicy == "reject_isolating_record" {
                    eval(id, scope: .expectationOnly) {
                        let reopened = try EditPersistence(directory: dir)
                        var threw = false
                        do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                        try check(threw, "\(id): Tier 2 unknown field in '\(scope)' must throw UnusableEditRecordError (not silently ignore)")
                        let loadedSibling = try reopened.state(for: siblingURL)
                        try check(loadedSibling != nil, "\(id): healthy sibling record must remain readable")
                        if preserveRawDiskEntry {
                            let updatedSib = siblingBuilt.replacing(settings: { var s = siblingBuilt.settings; s.exposure = 1.25; return s }(), preservingFilmID: siblingBuilt.filmID)
                            try reopened.save(siblingURL, state: updatedSib)
                            let diskAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                            let diskRecs = diskAfter["records"] as! [String: Any]
                            try check(diskRecs[targetKey] != nil,
                                      "\(id): rejected Tier 2 record raw disk entry must remain preserved across sibling save")
                        }
                    }
                } else {
                    throw HarnessError.setup("Unknown X1 expect policy '\(expectPolicy)' for \(id)")
                }
            } catch {
                fputs("FAIL SETUP[\(id)]: \(error)\n", stderr)
                failures.append("SETUP[\(id)]: \(error)")
            }
        }

        // 3. Compatibility scenarios
        let compatList = fixture["compatibility_scenarios"] as! [[String: Any]]
        for sc in compatList {
            let id = sc["id"] as! String
            let kind = sc["kind"] as! String
            let baseRec = byID[sc["base_record_id"] as! String]!
            do {
                switch kind {
                case "legacy_omitted_extensions":
                    let (built, _, _) = try buildState(from: baseRec)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-leg-\(id).JPG")
                    try store.save(url, state: built)
                    let key = try PhotoIdentity.fallback(for: url).key
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    var state = records[key] as! [String: Any]
                    var settings = state["settings"] as! [String: Any]
                    for dropKey in ["processing", "x3fMode", "masterRecipeSettingsVersion", "toneControls",
                                    "atmosphere", "colorGrading", "toneCurveConfig", "hdr", "proRAWDecodeVersion"] {
                        settings.removeValue(forKey: dropKey)
                    }
                    state["settings"] = settings; records[key] = state; registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)

                    let samples = sc["legacy_wire_samples"] as! [String: Any]
                    let iosSample = samples["ios_json"] as! [String: Any]
                    let wireDir = tempRoot.appendingPathComponent("c-wire-\(id)")
                    try FileManager.default.createDirectory(at: wireDir, withIntermediateDirectories: true)
                    let wirePhotoURL = wireDir.appendingPathComponent("legacy-ios.JPG")
                    try Data((iosSample["photo_bytes_utf8"] as! String).utf8).write(to: wirePhotoURL)
                    let wireFile = wireDir.appendingPathComponent("edits.json")
                    try Data((iosSample["store_json"] as! String).utf8).write(to: wireFile)
                    let wireExpect = iosSample["expect_decoded"] as! [String: Any]

                    eval(id) {
                        let loaded = try EditPersistence(directory: dir).state(for: url)!
                        try check(loaded.settings.processing == .legacy, "\(id): processing defaults to legacy v1")
                        try check(loaded.settings.x3fMode == .legacy, "\(id): x3fMode defaults to legacy")

                        let wireStore = try EditPersistence(directory: wireDir)
                        let wireLoaded = try wireStore.state(for: wirePhotoURL)
                        try check(wireLoaded != nil, "\(id): frozen ios_json legacy wire sample must decode")
                        if let w = wireLoaded {
                            try check(w.filmID == (wireExpect["film_id"] as? String), "\(id): wire filmID")
                            try check(approx(w.settings.exposure, num(wireExpect["exposure"])!), "\(id): wire exposure")
                            try check(approx(w.settings.contrast, num(wireExpect["contrast"])!), "\(id): wire contrast")
                            try check(approx(w.settings.saturation, num(wireExpect["saturation"])!), "\(id): wire saturation")
                            try check(approx(w.settings.temperature, num(wireExpect["temperature"])!), "\(id): wire temperature")
                            try check(approx(w.settings.tint, num(wireExpect["tint"])!), "\(id): wire tint")
                            try check(approx(w.settings.highlights, num(wireExpect["highlights"])!), "\(id): wire highlights")
                            try check(approx(w.settings.shadows, num(wireExpect["shadows"])!), "\(id): wire shadows")
                            try check(approx(w.settings.sharpening, num(wireExpect["sharpening"])!), "\(id): wire sharpening")
                            try check(w.settings.processing.version == (intVal(wireExpect["processing_version"]) ?? -1), "\(id): wire processing_version")
                            try check(w.settings.x3fMode.rawValue == (wireExpect["x3f_mode"] as! String), "\(id): wire x3f_mode")
                        }
                    }
                case "sdr_reset_preserves_dormant_hdr":
                    let (built, _, _) = try buildState(from: baseRec)
                    let (store, dir, _) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-rst-\(id).ARW")
                    try store.save(url, state: built)
                    eval(id) {
                        let ctx = EditorAdjustmentContext(isRaw: true, defaultExposureMode: .preview, cameraTemperature: 5400, cameraTint: -4)
                        let resetRes = EditorAdjustmentRules.prepareReset(.all, snapshot: built, context: ctx)
                        guard case .candidate(let resetState, _) = resetRes else {
                            throw ExpectationMismatch.mismatch("\(id): expected .candidate from prepareReset(.all)")
                        }
                        try EditPersistence(directory: dir).save(url, state: resetState)
                        let reloaded = try EditPersistence(directory: dir).state(for: url)!
                        try check(approx(reloaded.settings.hdr?.exposure ?? -99, -0.5) && reloaded.settings.hdr?.mode == .sdr, "\(id): dormant HDR preserved")
                        try check(reloaded.settings.proRAWDecodeVersion == 2, "\(id): proRAWDecodeVersion preserved")
                        try check(reloaded.settings.processing.version == 2, "\(id): processing version preserved")
                        try check(reloaded.settings.x3fMode == .legacy, "\(id): x3fMode preserved")
                    }
                case "future_processing_version":
                    let sibRec = byID[sc["sibling_record_id"] as! String]!
                    let (built, _, _) = try buildState(from: baseRec)
                    let (sibBuilt, _, _) = try buildState(from: sibRec)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let targetURL = try touchPhoto(tempRoot, name: "c-fut-\(id).ARW")
                    let sibURL = try touchPhoto(tempRoot, name: "c-sib-\(id).JPG")
                    try store.save(targetURL, state: built)
                    try store.save(sibURL, state: sibBuilt)
                    let tk = try PhotoIdentity.fallback(for: targetURL).key
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    var state = records[tk] as! [String: Any]
                    var settings = state["settings"] as! [String: Any]
                    settings["processing"] = ["family": "rawlab", "version": 99, "quality": "standard"]
                    state["settings"] = settings; records[tk] = state; registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)

                    eval(id) {
                        let reopened = try EditPersistence(directory: dir)
                        var threw = false
                        do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                        try check(threw, "\(id): processing.version=99 must throw UnusableEditRecordError")
                        try check(try reopened.state(for: sibURL) != nil, "\(id): healthy sibling must remain readable")
                        let updatedSib = sibBuilt.replacing(settings: { var s = sibBuilt.settings; s.exposure = 1.5; return s }(), preservingFilmID: sibBuilt.filmID)
                        try reopened.save(sibURL, state: updatedSib)
                        let diskAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                        let diskRecs = diskAfter["records"] as! [String: Any]
                        try check(diskRecs[tk] != nil, "\(id): unreadable future record preserved on disk across sibling save")
                    }
                case "corrupt_entry":
                    let sibRec = byID[sc["sibling_record_id"] as! String]!
                    let (built, _, _) = try buildState(from: baseRec)
                    let (sibBuilt, _, _) = try buildState(from: sibRec)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let targetURL = try touchPhoto(tempRoot, name: "c-bad-\(id).ARW")
                    let sibURL = try touchPhoto(tempRoot, name: "c-sib2-\(id).JPG")
                    try store.save(targetURL, state: built)
                    try store.save(sibURL, state: sibBuilt)
                    let tk = try PhotoIdentity.fallback(for: targetURL).key
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    records[tk] = "corrupt-entry-payload"
                    registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)

                    eval(id) {
                        let reopened = try EditPersistence(directory: dir)
                        var threw = false
                        do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                        try check(threw, "\(id): corrupt entry must throw UnusableEditRecordError")
                        try check(try reopened.state(for: sibURL) != nil, "\(id): healthy sibling readable")
                        let updatedSib = sibBuilt.replacing(settings: { var s = sibBuilt.settings; s.exposure = 1.1; return s }(), preservingFilmID: sibBuilt.filmID)
                        try reopened.save(sibURL, state: updatedSib)
                        let diskAfter = String(data: try Data(contentsOf: file), encoding: .utf8)!
                        try check(diskAfter.contains("corrupt-entry-payload"), "\(id): corrupt entry bytes preserved across sibling save")
                    }
                case "negative_zero":
                    var recCopy = baseRec
                    var sdrCopy = recCopy["sdr_values"] as! [String: Any]
                    sdrCopy["light.exposure"] = 0.0
                    recCopy["sdr_values"] = sdrCopy
                    let (built, _, _) = try buildState(from: recCopy)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-nz-\(id).JPG")
                    try store.save(url, state: built)
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    let tk = try PhotoIdentity.fallback(for: url).key
                    var state = records[tk] as! [String: Any]
                    var settings = state["settings"] as! [String: Any]
                    settings["exposure"] = "__NEG_ZERO_SENTINEL__"
                    state["settings"] = settings; records[tk] = state; registry["records"] = records
                    var txt = String(data: try JSONSerialization.data(withJSONObject: registry), encoding: .utf8)!
                    txt = txt.replacingOccurrences(of: "\"__NEG_ZERO_SENTINEL__\"", with: "-0.0")
                    try checkSetup(txt.contains("-0.0") && !txt.contains("__NEG_ZERO_SENTINEL__"), "\(id): test setup failed to inject -0.0")
                    try Data(txt.utf8).write(to: file)
                    let expectObj = sc["expect"] as! [String: Any]
                    let assertSignBit = expectObj["assert_sign_bit_positive"] as? Bool ?? false

                    eval(id) {
                        let loaded = try EditPersistence(directory: dir).state(for: url)!
                        try check(loaded.settings.exposure == 0.0, "\(id): -0.0 must compare equal to 0.0 (got \(loaded.settings.exposure))")
                        if assertSignBit {
                            try check(loaded.settings.exposure.sign == .plus,
                                      "\(id): -0.0 sign bit must canonicalize to .plus (got \(loaded.settings.exposure.sign))")
                        }
                    }
                default:
                    throw HarnessError.setup("Unhandled compat kind: \(kind)")
                }
            } catch {
                fputs("FAIL SETUP[\(id)]: \(error)\n", stderr)
                failures.append("SETUP[\(id)]: \(error)")
            }
        }

        // 4. Boundary rejection scenarios
        let boundaryList = fixture["boundary_scenarios"] as! [[String: Any]]
        for sc in boundaryList {
            let id = sc["id"] as! String
            let baseRec = byID[sc["base_record_id"] as! String]!
            let sibRec = byID[sc["sibling_record_id"] as! String]!
            let mutation = sc["mutation"] as! [String: Any]
            let mKind = mutation["kind"] as! String
            do {
                let (built, _, _) = try buildState(from: baseRec)
                let (sibBuilt, _, _) = try buildState(from: sibRec)
                let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "b-\(id)")
                let targetURL = try touchPhoto(tempRoot, name: "b-t-\(id).DNG")
                let sibURL = try touchPhoto(tempRoot, name: "b-s-\(id).JPG")
                try store.save(targetURL, state: built)
                try store.save(sibURL, state: sibBuilt)

                var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                var records = registry["records"] as! [String: Any]
                let tk = try PhotoIdentity.fallback(for: targetURL).key
                var state = records[tk] as! [String: Any]
                var settings = state["settings"] as! [String: Any]

                switch mKind {
                case "out_of_range":
                    let field = mutation["field"] as! String
                    let val = mutation["value"]!
                    switch field {
                    case "light.exposure": settings["exposure"] = val
                    case "color.white_balance.temperature_kelvin": settings["temperature"] = val
                    case "effects.vignette.amount":
                        var fx = settings["photoEffects"] as! [String: Any]; fx["vignetteAmount"] = val; settings["photoEffects"] = fx
                    case "color.hsl.hue.red":
                        var hsl = settings["hsl"] as! [String: Any]
                        var hue = hsl["hue"] as! [Double]; hue[0] = (val as! NSNumber).doubleValue; hsl["hue"] = hue; settings["hsl"] = hsl
                    case "color.grading.shadows.hue":
                        var cg = settings["colorGrading"] as! [String: Any]
                        var sh = cg["shadows"] as! [String: Any]; sh["hue"] = val; cg["shadows"] = sh; settings["colorGrading"] = cg
                    case "hdr.peak_limit_ev":
                        var hdr = settings["hdr"] as! [String: Any]
                        var r = hdr["rendition"] as! [String: Any]; r["peak_limit_ev"] = val; hdr["rendition"] = r; settings["hdr"] = hdr
                    default: throw HarnessError.setup("Unhandled out_of_range field: \(field)")
                    }
                case "crop_overflow":
                    var g = settings["geometry"] as! [String: Any]
                    g["cropX"] = mutation["cropX"]!
                    g["cropWidth"] = mutation["cropWidth"]!
                    settings["geometry"] = g
                case "invalid_exposure_mode":
                    settings["exposureMode"] = "future_unknown_mode"
                case "non_monotonic_curve":
                    settings["toneCurveConfig"] = [
                        "mode": "custom",
                        "points": [[0.0, 0.0], [0.6, 0.5], [0.4, 0.8], [1.0, 1.0]]
                    ]
                default:
                    throw HarnessError.setup("Unhandled boundary mutation: \(mKind)")
                }

                state["settings"] = settings; records[tk] = state; registry["records"] = records
                try JSONSerialization.data(withJSONObject: registry).write(to: file)

                eval(id) {
                    let reopened = try EditPersistence(directory: dir)
                    var threw = false
                    do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                    try check(threw, "\(id): invalid boundary value must throw UnusableEditRecordError on read (not silently accept or clamp)")
                    try check(try reopened.state(for: sibURL) != nil, "\(id): sibling must remain readable")
                }
            } catch {
                fputs("FAIL SETUP[\(id)]: \(error)\n", stderr)
                failures.append("SETUP[\(id)]: \(error)")
            }
        }

        let orphanKeys = Set(knownEditRecordDivergences.keys).subtracting(evaluatedIDs)
        try checkSetup(orphanKeys.isEmpty, "Orphan divergence ledger keys not evaluated: \(orphanKeys.sorted())")
        try checkSetup(knownEditRecordDivergences.count <= maxKnownEditRecordDivergences,
                       "Divergence count \(knownEditRecordDivergences.count) exceeds cap \(maxKnownEditRecordDivergences)")
        try checkSetup(failures.isEmpty, "\(failures.count) iOS edit-record scenario(s) failed")
        print("PASS: iOS edit-record fixture suite finished with \(knownEditRecordDivergences.count) registered divergences (cap \(maxKnownEditRecordDivergences), evaluated \(evaluatedIDs.count))")
    }
}
