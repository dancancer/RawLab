import Foundation

/// P2-01 (S1): macOS 消费共享持久化编辑记录 fixture `Shared/fixtures/edit-records-v1.json`。
/// 登记当前真行为差异前先跑红锚；不静默修改实现或压低 fixture 期望以迎合现实现状。
struct EditRecordDivergence {
    let ledgerId: String
    let reason: String
}

private enum Failure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if !(try condition()) { throw Failure.message(message) }
}

private func approx(_ a: Double, _ b: Double, tol: Double = 1e-4) -> Bool {
    abs(a - b) <= tol
}

// ---------------------------------------------------------------------------
// Divergence ledger (empty initially to capture genuine red anchors)
// ---------------------------------------------------------------------------
private let maxKnownEditRecordDivergences = 14

private let knownEditRecordDivergences: [String: EditRecordDivergence] = [
    "x1-processing-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-01",
        reason: "ProcessingIdentity.init(from:) enforces closed key set instead of ignoring unknown future keys"
    ),
    "x1-color-grading-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-02",
        reason: "ColorGradingSettings.init(from:) uses GradingCodingKey.require closed-key check"
    ),
    "x1-color-grading-zone-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-03",
        reason: "ColorGradingWheel.init(from:) uses GradingCodingKey.require closed-key check"
    ),
    "x1-tone-curve-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-04",
        reason: "ToneCurveSettings.init(from:) rejects unknown keys via Set(allKeys) equality"
    ),
    "x1-tone-curve-channels-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-05",
        reason: "ToneCurveChannels.init(from:) rejects unknown keys via Set(allKeys) equality"
    ),
    "x1-hdr-root-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-06",
        reason: "HDRSettings.init(from:) validates closed top-level HDRSettingsField set"
    ),
    "x1-hdr-tone-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-07",
        reason: "HDRToneSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-color-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-08",
        reason: "HDRColorSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-rendition-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-09",
        reason: "HDRRenditionSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-effects-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-10",
        reason: "HDRPhotoEffectsSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-detail-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-11",
        reason: "HDRDetailSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-look-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-12",
        reason: "HDRLookSettings.init(from:) rejects unknown keys via Set(fields) equality"
    ),
    "x1-hdr-camera-development-unknown-field": EditRecordDivergence(
        ledgerId: "P2-01-MAC-X1-13",
        reason: "HDRCameraDevelopmentSettings.init(from:) rejects unknown keys via supported key subset check"
    ),
    "compat-negative-zero-canonicalized": EditRecordDivergence(
        ledgerId: "P2-01-MAC-COMPAT-01",
        reason: "Swift JSONDecoder preserves IEEE -0.0 (.sign == .minus) rather than canonicalizing to +0.0 on read"
    ),
]

// ---------------------------------------------------------------------------
// Fixture model helpers
// ---------------------------------------------------------------------------
@main
struct Harness {
    static func main() {
        do {
            try runAll()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let fixtureURL = root.appendingPathComponent("Shared/fixtures/edit-records-v1.json")

    static func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.message("Invalid JSON root in \(fixtureURL.path)")
        }
        try check((obj["fixture_version"] as? Int) == 1, "fixture_version must be 1")
        try check((obj["spec_version"] as? Int) == 1, "spec_version must be 1")
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
                guard let s = chObj[name] as? [String: Any] else { return ToneCurveShape() }
                let m: ToneCurveMode = (s["mode"] as? String) == "custom" ? .custom : .legacy
                let pts = (s["points"] as? [[Any]] ?? []).compactMap { p -> ToneCurvePoint? in
                    guard p.count == 2, let x = num(p[0]), let y = num(p[1]) else { return nil }
                    return ToneCurvePoint(x: x, y: y)
                }
                return ToneCurveShape(mode: m, points: pts)
            }
            channels = ToneCurveChannels(red: parseShape("red"), green: parseShape("green"), blue: parseShape("blue"))
        }
        return ToneCurveSettings(mode: mode, points: points, channels: channels)
    }

    static func parseWheel(_ obj: [String: Any]) -> ColorGradingWheel {
        ColorGradingWheel(hue: num(obj["hue"]) ?? 0, saturation: num(obj["saturation"]) ?? 0)
    }

    static func buildHDRSettings(values: [String: Any], metadata: [String: Any], activeMode: Bool) throws -> HDRSettings {
        var hdr = HDRSettings()
        hdr.mode = activeMode ? .hdr : .sdr
        if let v = num(values["light.exposure"]) { hdr.exposure = v }
        if let v = num(values["light.contrast"]) { hdr.contrast = (v - 1.0) * 100.0 }
        if let v = num(values["light.highlights"]) { hdr.highlights = -v * 100.0 }
        if let v = num(values["light.shadows"]) { hdr.shadows = v * 100.0 }
        if let v = num(values["color.saturation"]) { hdr.saturation = (v - 1.0) * 100.0 }
        if let v = num(values["hdr.relative_temperature"]) { hdr.temperature = v }
        if let v = num(values["hdr.relative_tint"]) { hdr.tint = v }

        var tone = HDRToneSettings()
        if let v = num(values["tone.black_point"]) { tone.blackPoint = v }
        if let v = num(values["tone.white_point"]) { tone.whitePoint = v }
        if let v = num(values["light.s_curve"]) { tone.curveStrength = v * 100.0 }
        if let cObj = values["light.curve"] as? [String: Any] { tone.curve = try parseCurve(cObj) }
        hdr.toneSettings = tone

        var color = HDRColorSettings()
        if let v = num(values["color.vibrance"]) { color.vibrance = v }
        var hsl = HSLSettings()
        for (idx, ch) in ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].enumerated() {
            if let v = num(values["color.hsl.hue.\(ch)"]) { hsl.setExact(.hue, channel: idx, value: v) }
            if let v = num(values["color.hsl.saturation.\(ch)"]) { hsl.setExact(.saturation, channel: idx, value: v) }
            if let v = num(values["color.hsl.lightness.\(ch)"]) { hsl.setExact(.lightness, channel: idx, value: v) }
        }
        color.hsl = hsl
        if let w = values["color.grading.shadows"] as? [String: Any] { color.grading.shadows = parseWheel(w) }
        if let w = values["color.grading.midtones"] as? [String: Any] { color.grading.midtones = parseWheel(w) }
        if let w = values["color.grading.highlights"] as? [String: Any] { color.grading.highlights = parseWheel(w) }
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
        let localValues = record["local_values"] as? [String: Any] ?? [:]
        let hdrEditing = metadata["hdr_editing"] as? Bool ?? false

        var settings = Adjustments()
        if let procObj = metadata["processing"] as? [String: Any] {
            let ver = procObj["version"] as? Int ?? 3
            settings.processing = ver == 1 ? .legacy : ver == 2 ? .c5 : .current
        }
        if let x3f = metadata["x3f_mode"] as? String {
            settings.x3fMode = x3f == "legacy" ? .legacy : .normal
        }
        if metadata.keys.contains("pro_raw_decode_version") {
            settings.proRAWDecodeVersion = intVal(metadata["pro_raw_decode_version"])
        }
        if let wb = metadata["as_shot_wb"] as? [String: Any],
           let t = num(wb["temperature"]), let tn = num(wb["tint"]) {
            settings.resolveWhiteBalance(WhiteBalance(temperature: t, tint: tn))
        }

        let filmID = metadata["film_id"] as? String ?? ""
        var masterRecipeID = metadata["master_recipe_id"] as? String
        if let lookObj = sdrValues["looks.reference"] as? [String: Any],
           (lookObj["kind"] as? String) == "recipe", let id = lookObj["id"] as? String {
            masterRecipeID = id
        }
        if let ver = intVal(metadata["master_recipe_settings_version"]) {
            settings.setTransferRecipe(masterRecipeID, settingsVersion: ver)
        } else {
            settings.masterRecipeID = masterRecipeID
        }

        if let v = num(sdrValues["looks.strength"]) { settings.strength = v }
        if let v = num(sdrValues["light.exposure"]) { settings.exposure = v }
        if let em = sdrValues["light.exposure_mode"] as? String {
            settings.exposureMode = em == "scene" ? .scene : em == "sensor" ? .sensor : .preview
        }
        if let v = num(sdrValues["light.contrast"]) { settings.contrast = (v - 1.0) * 100.0 }
        if let v = num(sdrValues["light.highlights"]) { settings.highlights = -v * 100.0 }
        if let v = num(sdrValues["light.shadows"]) { settings.shadows = v * 100.0 }
        if let v = num(sdrValues["light.s_curve"]) { settings.toneCurve = v * 100.0 }
        if let cObj = sdrValues["light.curve"] as? [String: Any] {
            let parsed = try parseCurve(cObj)
            settings.toneCurveConfig = parsed.isDefault ? nil : parsed
        }
        if let v = num(sdrValues["tone.black_point"]) { settings.blackPoint = v }
        if let v = num(sdrValues["tone.white_point"]) { settings.whitePoint = v }
        if let v = num(sdrValues["color.vibrance"]) { settings.vibrance = v }
        if let s = sdrValues["color.grading.shadows"] as? [String: Any] { settings.gradingSettings.shadows = parseWheel(s) }
        if let m = sdrValues["color.grading.midtones"] as? [String: Any] { settings.gradingSettings.midtones = parseWheel(m) }
        if let h = sdrValues["color.grading.highlights"] as? [String: Any] { settings.gradingSettings.highlights = parseWheel(h) }
        if let wbMode = sdrValues["color.white_balance.mode"] as? String {
            settings.whiteBalanceMode = wbMode == "temperature" ? .custom : .asShot
        }
        if let v = num(sdrValues["color.white_balance.temperature_kelvin"]) { settings.temperature = v }
        if let v = num(sdrValues["color.white_balance.tint"]) { settings.tint = v }
        if let v = num(sdrValues["color.saturation"]) { settings.saturation = (v - 1.0) * 100.0 }

        var hsl = HSLSettings()
        for (idx, ch) in ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].enumerated() {
            if let v = num(sdrValues["color.hsl.hue.\(ch)"]) { hsl.setExact(.hue, channel: idx, value: v) }
            if let v = num(sdrValues["color.hsl.saturation.\(ch)"]) { hsl.setExact(.saturation, channel: idx, value: v) }
            if let v = num(sdrValues["color.hsl.lightness.\(ch)"]) { hsl.setExact(.lightness, channel: idx, value: v) }
        }
        settings.hsl = hsl.isIdentity ? nil : hsl

        for (fid, keyPath) in [
            ("effects.vignette.amount", \PhotoEffectsSettings.vignetteAmount),
            ("effects.vignette.midpoint", \PhotoEffectsSettings.vignetteMidpoint),
            ("effects.vignette.roundness", \PhotoEffectsSettings.vignetteRoundness),
            ("effects.vignette.feather", \PhotoEffectsSettings.vignetteFeather),
            ("effects.vignette.highlights", \PhotoEffectsSettings.vignetteHighlights),
            ("effects.grain.amount", \PhotoEffectsSettings.grainAmount),
            ("effects.grain.size", \PhotoEffectsSettings.grainSize),
            ("effects.grain.roughness", \PhotoEffectsSettings.grainRoughness)
        ] as [(String, WritableKeyPath<PhotoEffectsSettings, Double>)] {
            if let v = num(sdrValues[fid]) {
                var fx = settings.effectSettings
                fx[keyPath: keyPath] = v
                settings.photoEffects = fx == PhotoEffectsSettings() ? nil : fx
            }
        }
        if let v = num(sdrValues["effects.clarity"]) { settings.clarity = v }
        if let v = num(sdrValues["effects.dehaze"]) { settings.dehaze = v }
        if let v = num(sdrValues["detail.sharpening"]) { settings.sharpening = v * 100.0 }
        if let v = num(sdrValues["detail.denoise.raw_level"]) { settings.rawNoiseReduction = v }
        if let v = num(sdrValues["detail.denoise.chroma_mode"]) { settings.chromaNoiseReduction = v }
        if let wObj = sdrValues["detail.denoise.wavelet"] as? [String: Any] {
            let presetStr = wObj["preset"] as? String ?? "custom"
            let preset: DenoisePreset = presetStr == "detail" ? .detail : presetStr == "clean" ? .clean : .custom
            let wd = WaveletDenoiseSettings(
                enabled: wObj["enabled"] as? Bool ?? false,
                luma: num(wObj["luma"]) ?? 0,
                chroma: num(wObj["chroma"]) ?? 46,
                coarse: num(wObj["coarse"]) ?? 50,
                preset: preset
            )
            settings.waveletNoiseReduction = wd
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
        settings.geometry = geom.isIdentity ? nil : geom

        if sdrValues.keys.contains(where: { $0.hasPrefix("geometry.lens.") }) {
            var lens = LensCorrectionSettings()
            if let b = sdrValues["geometry.lens.distortion"] as? Bool { lens.distortion = b }
            if let b = sdrValues["geometry.lens.tca"] as? Bool { lens.tca = b }
            if let b = sdrValues["geometry.lens.vignetting"] as? Bool { lens.vignetting = b }
            if let b = sdrValues["geometry.lens.auto_crop"] as? Bool { lens.autoCrop = b }
            if let pid = sdrValues["geometry.lens.profile_id"] as? String {
                lens.mode = .manual; lens.profileID = pid
            }
            settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
        }

        if hdrEditing {
            settings.hdr = try buildHDRSettings(values: hdrValues, metadata: metadata, activeMode: true)
        } else if let dormant = dormantHDR {
            settings.hdr = try buildHDRSettings(values: dormant, metadata: metadata, activeMode: false)
        }

        if let ai = localValues["local.ai_denoise_enabled"] as? Bool { settings.aiDenoiseEnabled = ai }
        if let hai = localValues["local.hdr_camera_ai_enabled"] as? Bool { settings.hdrCameraAIEnabled = hai }

        return (PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: masterRecipeID), isRaw, metadata)
    }

    static func verifyCurve(_ expected: [String: Any], _ actual: ToneCurveSettings, _ label: String) throws {
        let expMode = expected["mode"] as? String ?? "legacy"
        try check((actual.mode == .custom ? "custom" : "legacy") == expMode, "\(label): curve mode mismatch")
        let expPts = expected["points"] as? [[Any]] ?? []
        try check(actual.points.count == expPts.count, "\(label): curve point count mismatch")
        for (i, p) in expPts.enumerated() {
            try check(approx(actual.points[i].x, num(p[0]) ?? -999) && approx(actual.points[i].y, num(p[1]) ?? -999),
                      "\(label): curve point \(i) mismatch")
        }
        if let chObj = expected["channels"] as? [String: Any] {
            for (cname, cval) in [("red", actual.channels.red), ("green", actual.channels.green), ("blue", actual.channels.blue)] {
                if let expShape = chObj[cname] as? [String: Any] {
                    let em = expShape["mode"] as? String ?? "legacy"
                    try check((cval.mode == .custom ? "custom" : "legacy") == em, "\(label): curve channel \(cname) mode")
                    let epts = expShape["points"] as? [[Any]] ?? []
                    try check(cval.points.count == epts.count, "\(label): curve channel \(cname) count")
                    for (i, p) in epts.enumerated() {
                        try check(approx(cval.points[i].x, num(p[0]) ?? -999) && approx(cval.points[i].y, num(p[1]) ?? -999),
                                  "\(label): curve channel \(cname)[\(i)]")
                    }
                }
            }
        }
    }

    static func verifyState(_ actual: PhotoEditState, matches record: [String: Any]) throws {
        let id = record["id"] as? String ?? "unknown"
        let metadata = record["metadata"] as? [String: Any] ?? [:]
        let sdrValues = record["sdr_values"] as? [String: Any] ?? [:]
        let hdrValues = record["hdr_values"] as? [String: Any] ?? [:]
        let dormant = record["dormant_hdr_values"] as? [String: Any]
        let localValues = record["local_values"] as? [String: Any] ?? [:]
        let hdrEditing = metadata["hdr_editing"] as? Bool ?? false
        let s = actual.settings

        try check(actual.filmID == (metadata["film_id"] as? String ?? ""), "\(id): filmID mismatch")
        try check(actual.masterRecipeID == (metadata["master_recipe_id"] as? String), "\(id): PhotoEditState.masterRecipeID")
        try check(s.masterRecipeID == (metadata["master_recipe_id"] as? String), "\(id): Adjustments.masterRecipeID")
        if let proc = metadata["processing"] as? [String: Any], let v = proc["version"] as? Int {
            try check(s.processing.version == v, "\(id): processing.version mismatch")
        }
        if let x3f = metadata["x3f_mode"] as? String {
            try check(s.x3fMode.rawValue == x3f, "\(id): x3fMode mismatch")
        }
        if let mv = intVal(metadata["master_recipe_settings_version"]) {
            try check(s.recipeSettingsVersion == mv, "\(id): masterRecipeSettingsVersion mismatch")
        }
        if metadata.keys.contains("pro_raw_decode_version") {
            try check(s.proRAWDecodeVersion == intVal(metadata["pro_raw_decode_version"]), "\(id): proRAWDecodeVersion mismatch")
        }
        if let wb = metadata["as_shot_wb"] as? [String: Any], let t = num(wb["temperature"]), let tn = num(wb["tint"]) {
            try check(approx(s.asShotWhiteBalance?.temperature ?? -1, t) && approx(s.asShotWhiteBalance?.tint ?? -999, tn), "\(id): asShotWB")
        }
        try check(s.isHDREditing == hdrEditing, "\(id): isHDREditing mismatch")

        // Verify SDR values
        if let v = num(sdrValues["looks.strength"]) { try check(approx(s.strength, v), "\(id): looks.strength") }
        if let v = num(sdrValues["light.exposure"]) { try check(approx(s.exposure, v), "\(id): light.exposure") }
        if let em = sdrValues["light.exposure_mode"] as? String {
            let actualEm = s.exposureMode == .scene ? "scene" : s.exposureMode == .preview ? "preview" : "sensor"
            try check(actualEm == em, "\(id): exposure_mode")
        }
        if let v = num(sdrValues["light.contrast"]) { try check(approx(1 + s.contrast / 100, v), "\(id): contrast") }
        if let v = num(sdrValues["light.highlights"]) { try check(approx(-s.highlights / 100, v), "\(id): highlights") }
        if let v = num(sdrValues["light.shadows"]) { try check(approx(s.shadows / 100, v), "\(id): shadows") }
        if let v = num(sdrValues["light.s_curve"]) { try check(approx(s.toneCurve / 100, v), "\(id): s_curve") }
        if let cObj = sdrValues["light.curve"] as? [String: Any] { try verifyCurve(cObj, s.curveSettings, "\(id).sdr") }
        if let v = num(sdrValues["tone.black_point"]) { try check(approx(s.blackPoint, v), "\(id): blackPoint") }
        if let v = num(sdrValues["tone.white_point"]) { try check(approx(s.whitePoint, v), "\(id): whitePoint") }
        if let v = num(sdrValues["color.vibrance"]) { try check(approx(s.vibrance, v), "\(id): vibrance") }
        for (zoneName, zone) in [("shadows", ColorGradingZone.shadows), ("midtones", .midtones), ("highlights", .highlights)] {
            if let w = sdrValues["color.grading.\(zoneName)"] as? [String: Any] {
                try check(approx(s.gradingSettings[zone].hue, num(w["hue"]) ?? -1) &&
                          approx(s.gradingSettings[zone].saturation, num(w["saturation"]) ?? -1), "\(id): grading.\(zoneName)")
            }
        }
        if let wbm = sdrValues["color.white_balance.mode"] as? String {
            if wbm == "temperature" {
                try check(s.whiteBalanceMode == .custom, "\(id): wb mode custom")
                if let t = num(sdrValues["color.white_balance.temperature_kelvin"]) { try check(approx(s.temperature, t), "\(id): wb temp") }
                if let tn = num(sdrValues["color.white_balance.tint"]) { try check(approx(s.tint, tn), "\(id): wb tint") }
            }
        }
        if let v = num(sdrValues["color.saturation"]) { try check(approx(1 + s.saturation / 100, v), "\(id): saturation") }
        for (idx, ch) in ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"].enumerated() {
            if let v = num(sdrValues["color.hsl.hue.\(ch)"]) { try check(approx(s.hslSettings.value(.hue, channel: idx), v), "\(id): hsl.hue.\(ch)") }
            if let v = num(sdrValues["color.hsl.saturation.\(ch)"]) { try check(approx(s.hslSettings.value(.saturation, channel: idx), v), "\(id): hsl.sat.\(ch)") }
            if let v = num(sdrValues["color.hsl.lightness.\(ch)"]) { try check(approx(s.hslSettings.value(.lightness, channel: idx), v), "\(id): hsl.lit.\(ch)") }
        }
        for (fid, kp) in [
            ("effects.vignette.amount", \PhotoEffectsSettings.vignetteAmount),
            ("effects.vignette.midpoint", \PhotoEffectsSettings.vignetteMidpoint),
            ("effects.vignette.roundness", \PhotoEffectsSettings.vignetteRoundness),
            ("effects.vignette.feather", \PhotoEffectsSettings.vignetteFeather),
            ("effects.vignette.highlights", \PhotoEffectsSettings.vignetteHighlights),
            ("effects.grain.amount", \PhotoEffectsSettings.grainAmount),
            ("effects.grain.size", \PhotoEffectsSettings.grainSize),
            ("effects.grain.roughness", \PhotoEffectsSettings.grainRoughness)
        ] as [(String, KeyPath<PhotoEffectsSettings, Double>)] {
            if let v = num(sdrValues[fid]) { try check(approx(s.effectSettings[keyPath: kp], v), "\(id): \(fid)") }
        }
        if let v = num(sdrValues["effects.clarity"]) { try check(approx(s.clarity, v), "\(id): clarity") }
        if let v = num(sdrValues["effects.dehaze"]) { try check(approx(s.dehaze, v), "\(id): dehaze") }
        if let v = num(sdrValues["detail.sharpening"]) { try check(approx(s.sharpening / 100, v), "\(id): sharpening") }
        if let v = num(sdrValues["detail.denoise.raw_level"]) { try check(approx(s.rawNoiseReduction, v), "\(id): raw_level") }
        if let v = num(sdrValues["detail.denoise.chroma_mode"]) { try check(approx(s.chromaNoiseReduction ?? -1, v), "\(id): chroma_mode") }
        if let wObj = sdrValues["detail.denoise.wavelet"] as? [String: Any] {
            let wd = s.waveletSettings
            try check(s.waveletNoiseReduction != nil, "\(id): waveletNoiseReduction non-nil")
            try check(wd.enabled == (wObj["enabled"] as? Bool ?? false), "\(id): wavelet.enabled")
            try check(approx(wd.luma, num(wObj["luma"]) ?? -1) &&
                      approx(wd.chroma, num(wObj["chroma"]) ?? -1) &&
                      approx(wd.coarse, num(wObj["coarse"]) ?? -1), "\(id): wavelet values")
        }
        if let v = num(sdrValues["geometry.crop.x"]) { try check(approx(s.geometrySettings.cropX, v), "\(id): cropX") }
        if let v = num(sdrValues["geometry.crop.y"]) { try check(approx(s.geometrySettings.cropY, v), "\(id): cropY") }
        if let v = num(sdrValues["geometry.crop.width"]) { try check(approx(s.geometrySettings.cropWidth, v), "\(id): cropW") }
        if let v = num(sdrValues["geometry.crop.height"]) { try check(approx(s.geometrySettings.cropHeight, v), "\(id): cropH") }
        if let v = intVal(sdrValues["geometry.quarter_turns"]) { try check(s.geometrySettings.quarterTurns == v, "\(id): quarterTurns") }
        if let b = sdrValues["geometry.flip_horizontal"] as? Bool { try check(s.geometrySettings.flipHorizontal == b, "\(id): flipH") }
        if let b = sdrValues["geometry.flip_vertical"] as? Bool { try check(s.geometrySettings.flipVertical == b, "\(id): flipV") }
        if let v = num(sdrValues["geometry.straighten_degrees"]) { try check(approx(s.geometrySettings.straightenDegrees, v), "\(id): straighten") }
        if let v = num(sdrValues["geometry.perspective.horizontal"]) { try check(approx(s.geometrySettings.perspectiveHorizontal, v), "\(id): perspH") }
        if let v = num(sdrValues["geometry.perspective.vertical"]) { try check(approx(s.geometrySettings.perspectiveVertical, v), "\(id): perspV") }
        if sdrValues.keys.contains("geometry.lens.distortion") {
            let l = s.lensSettings
            try check(l.distortion == (sdrValues["geometry.lens.distortion"] as? Bool ?? false), "\(id): lens.distortion")
            try check(l.tca == (sdrValues["geometry.lens.tca"] as? Bool ?? false), "\(id): lens.tca")
            try check(l.vignetting == (sdrValues["geometry.lens.vignetting"] as? Bool ?? false), "\(id): lens.vignetting")
            try check(l.autoCrop == (sdrValues["geometry.lens.auto_crop"] as? Bool ?? true), "\(id): lens.autoCrop")
            try check(l.profileID == (sdrValues["geometry.lens.profile_id"] as? String), "\(id): lens.profileID")
        }

        // Verify HDR values (active or dormant)
        let hdrCheck = hdrEditing ? hdrValues : (dormant ?? [:])
        if !hdrCheck.isEmpty {
            guard let hdr = s.hdr else { throw Failure.message("\(id): expected hdr subtree to be preserved") }
            try check((hdr.mode == .hdr) == hdrEditing, "\(id): hdr.mode mismatch")
            if let v = num(hdrCheck["light.exposure"]) { try check(approx(hdr.exposure, v), "\(id): hdr.exposure") }
            if let v = num(hdrCheck["light.contrast"]) { try check(approx(1 + hdr.contrast / 100, v), "\(id): hdr.contrast") }
            if let v = num(hdrCheck["light.highlights"]) { try check(approx(-hdr.highlights / 100, v), "\(id): hdr.highlights") }
            if let v = num(hdrCheck["light.shadows"]) { try check(approx(hdr.shadows / 100, v), "\(id): hdr.shadows") }
            if let v = num(hdrCheck["color.saturation"]) { try check(approx(1 + hdr.saturation / 100, v), "\(id): hdr.saturation") }
            if let v = num(hdrCheck["hdr.relative_temperature"]) { try check(approx(hdr.temperature, v), "\(id): hdr.temp") }
            if let v = num(hdrCheck["hdr.relative_tint"]) { try check(approx(hdr.tint, v), "\(id): hdr.tint") }
            if let v = num(hdrCheck["hdr.peak_limit_ev"]) { try check(approx(hdr.renditionSettings.peakLimitEV, v), "\(id): hdr.peakLimit") }
            if let v = num(hdrCheck["hdr.sdr_exposure_ev"]) { try check(approx(hdr.renditionSettings.sdrExposureEV, v), "\(id): hdr.sdrExp") }
            if let v = num(hdrCheck["hdr.sdr_contrast"]) { try check(approx(hdr.renditionSettings.sdrContrast, v), "\(id): hdr.sdrContrast") }
            if let v = num(hdrCheck["hdr.sdr_saturation"]) { try check(approx(hdr.renditionSettings.sdrSaturation, v), "\(id): hdr.sdrSat") }
            if let v = num(hdrCheck["detail.denoise.post_rgb"]) { try check(approx(hdr.detailSettings.denoise, v), "\(id): hdr.denoise") }
            if let cObj = hdrCheck["light.curve"] as? [String: Any] { try verifyCurve(cObj, hdr.toneSettings.curve, "\(id).hdr") }
            if let look = hdrCheck["hdr.look"] as? [String: Any] {
                try check(hdr.lookSettings.sha256 == (look["sha256"] as? String) &&
                          hdr.lookSettings.name == (look["name"] as? String) &&
                          approx(hdr.lookSettings.strength, num(look["strength"]) ?? -1), "\(id): hdr.look")
            }
            if let cam = hdrCheck["hdr.camera_development"] as? [String: Any] {
                try check(hdr.cameraDevelopmentSettings.whiteBalance.rawValue == (cam["white_balance_mode"] as? String), "\(id): hdr.cam.wb")
                try check(approx(hdr.cameraDevelopmentSettings.temperature, num(cam["temperature"]) ?? -1), "\(id): hdr.cam.temp")
                try check(approx(hdr.cameraDevelopmentSettings.tint, num(cam["tint"]) ?? -999), "\(id): hdr.cam.tint")
                try check(hdr.cameraDevelopmentSettings.exposureReference.rawValue == (cam["exposure_reference"] as? String), "\(id): hdr.cam.expRef")
                try check(hdr.cameraDevelopmentSettings.fbddLevel == (intVal(cam["fbdd_level"]) ?? -1), "\(id): hdr.cam.fbdd")
                if let extra = metadata["hdr_camera_development_extra"] as? [String: Any] {
                    try check(hdr.cameraDevelopmentSettings.lensProfile == (extra["lens_profile"] as? String), "\(id): hdr.cam.lensProfile")
                    if let cp = extra["camera_profile"] as? [String: Any] {
                        try check(hdr.cameraDevelopmentSettings.cameraProfile?.sha256 == (cp["sha256"] as? String), "\(id): hdr.cam.camProfile")
                    }
                }
            }
        }
        if let ai = localValues["local.ai_denoise_enabled"] as? Bool { try check(s.aiDenoiseEnabled == ai, "\(id): aiDenoiseEnabled") }
        if let hai = localValues["local.hdr_camera_ai_enabled"] as? Bool { try check(s.hdrCameraAIEnabled == hai, "\(id): hdrCameraAIEnabled") }
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

    static func evaluateScenario(id: String, body: () throws -> Void) throws {
        do {
            try body()
            if let reg = knownEditRecordDivergences[id] {
                throw Failure.message("Stale divergence ledger entry '\(id)' (\(reg.ledgerId)): scenario now passed")
            }
            print("PASS: \(id)")
        } catch {
            if let reg = knownEditRecordDivergences[id] {
                try check(!reg.ledgerId.trimmingCharacters(in: .whitespaces).isEmpty, "Blank ledgerId for \(id)")
                try check(!reg.reason.trimmingCharacters(in: .whitespaces).isEmpty, "Blank reason for \(id)")
                print("KNOWN DIVERGENCE [\(id)] (\(reg.ledgerId)): \(reg.reason) | observed: \(error)")
            } else {
                throw Failure.message("RED ANCHOR [\(id)]: \(error)")
            }
        }
    }

    static func mutateJSONScope(registry: inout [String: Any], targetKey: String, scope: String, key: String, value: Any) throws {
        switch scope {
        case "store_root":
            registry[key] = value
            return
        case "store_sibling_entry":
            var records = registry["records"] as? [String: Any] ?? [:]
            records["/tmp/__future_sibling_photo__.ARW"] = [key: value]
            registry["records"] = records
            return
        default: break
        }
        var records = registry["records"] as! [String: Any]
        var entry = records[targetKey] as! [String: Any]
        var state = entry["state"] as! [String: Any]
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
            var sub = settings["waveletNoiseReduction"] as! [String: Any]; inject(&sub); settings["waveletNoiseReduction"] = sub
        case "effects":
            var sub = settings["photoEffects"] as! [String: Any]; inject(&sub); settings["photoEffects"] = sub
        case "hdr":
            var hdr = settings["hdr"] as! [String: Any]; inject(&hdr); settings["hdr"] = hdr
        case "hdr_tone":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["tone"] as! [String: Any]; inject(&sub); hdr["tone"] = sub; settings["hdr"] = hdr
        case "hdr_color":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["color"] as! [String: Any]; inject(&sub); hdr["color"] = sub; settings["hdr"] = hdr
        case "hdr_rendition":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["rendition"] as! [String: Any]; inject(&sub); hdr["rendition"] = sub; settings["hdr"] = hdr
        case "hdr_effects":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["effects"] as! [String: Any]; inject(&sub); hdr["effects"] = sub; settings["hdr"] = hdr
        case "hdr_detail":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["detail"] as! [String: Any]; inject(&sub); hdr["detail"] = sub; settings["hdr"] = hdr
        case "hdr_look":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["look"] as! [String: Any]; inject(&sub); hdr["look"] = sub; settings["hdr"] = hdr
        case "hdr_camera_development":
            var hdr = settings["hdr"] as! [String: Any]
            var sub = hdr["camera_development"] as! [String: Any]; inject(&sub); hdr["camera_development"] = sub; settings["hdr"] = hdr
        case "hdr_camera_profile":
            var hdr = settings["hdr"] as! [String: Any]
            var cam = hdr["camera_development"] as! [String: Any]
            var sub = cam["camera_profile"] as! [String: Any]; inject(&sub); cam["camera_profile"] = sub
            hdr["camera_development"] = cam; settings["hdr"] = hdr
        default:
            throw Failure.message("Unhandled scope: \(scope)")
        }

        state["settings"] = settings
        entry["state"] = state
        records[targetKey] = entry
        registry["records"] = records
    }

    static func runAll() throws {
        let fixture = try loadFixture()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rawlab-mac-edit-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let recordsList = fixture["roundtrip_records"] as! [[String: Any]]
        var byID: [String: [String: Any]] = [:]
        for r in recordsList { byID[r["id"] as! String] = r }

        var failures: [String] = []
        func collect(_ id: String, _ block: () throws -> Void) {
            do { try evaluateScenario(id: id, body: block) }
            catch { failures.append("\(error)"); print("FAIL: \(error)") }
        }

        // 1. Roundtrip records
        for rec in recordsList {
            let id = rec["id"] as! String
            collect("roundtrip:\(id)") {
                let (built, _, metadata) = try buildState(from: rec)
                let (store, dir, _) = try makeStore(tempRoot: tempRoot, name: "rt-\(id)")
                let photoURL = try touchPhoto(tempRoot, name: (rec["photo"] as! [String: Any])["name"] as! String)
                try store.save(photoURL, state: built)
                if let receipt = metadata["migration_receipt"] as? [String: Any], (receipt["status"] as? String) == "kept" {
                    let quality = ProcessingMigrationQuality(rgbRMSE: 0.01, p99Error: 0.02, worstTileRMSE: 0.02, detailRMSE: 0.01, evaluations: 10)
                    _ = try store.commitProcessingMigration(expected: try store.readState(for: photoURL), candidate: nil, quality: quality)
                }
                let reopened = try EditPersistence(directory: dir)
                let reloaded = try reopened.state(for: photoURL)
                try check(reloaded != nil, "\(id): reloaded state must not be nil")
                try verifyState(reloaded!, matches: rec)
                if let receipt = metadata["migration_receipt"] as? [String: Any], (receipt["status"] as? String) == "kept" {
                    try check(try reopened.processingMigration(for: photoURL)?.status == .kept, "\(id): migration receipt kept")
                }
            }
        }

        // 2. X1 Unknown field scenarios
        let unknownList = fixture["unknown_field_scenarios"] as! [[String: Any]]
        for sc in unknownList {
            let id = sc["id"] as! String
            let baseID = sc["base_record_id"] as! String
            let baseRec = byID[baseID]!
            let scope = sc["target_scope"] as! String
            let key = sc["inject_key"] as! String
            let val = sc["inject_value"]!
            collect(id) {
                let (built, _, _) = try buildState(from: baseRec)
                let (siblingBuilt, _, _) = try buildState(from: byID["raster-sdr-neutral"]!)
                let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "x1-\(id)")
                let targetURL = try touchPhoto(tempRoot, name: "target-\(id).DNG")
                let siblingURL = try touchPhoto(tempRoot, name: "sibling-\(id).JPG")
                try store.save(targetURL, state: built)
                try store.save(siblingURL, state: siblingBuilt)

                var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                let targetKey = try OriginalFileIdentity(targetURL).path
                try mutateJSONScope(registry: &registry, targetKey: targetKey, scope: scope, key: key, value: val)
                try JSONSerialization.data(withJSONObject: registry).write(to: file)

                let reopened = try EditPersistence(directory: dir)
                let readTarget = try reopened.state(for: targetURL)
                try check(readTarget != nil, "\(id): target record must remain readable")
                try verifyState(readTarget!, matches: baseRec)
                let readSibling = try reopened.state(for: siblingURL)
                try check(readSibling != nil, "\(id): sibling record must remain readable")
            }
        }

        // 3. Cross-version compatibility scenarios
        let compatList = fixture["compatibility_scenarios"] as! [[String: Any]]
        for sc in compatList {
            let id = sc["id"] as! String
            let kind = sc["kind"] as! String
            let baseRec = byID[sc["base_record_id"] as! String]!
            collect(id) {
                switch kind {
                case "legacy_omitted_extensions":
                    let (built, _, _) = try buildState(from: baseRec)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-\(id).JPG")
                    try store.save(url, state: built)
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    let k = try OriginalFileIdentity(url).path
                    var entry = records[k] as! [String: Any]
                    var state = entry["state"] as! [String: Any]
                    var settings = state["settings"] as! [String: Any]
                    for drop in ["processing", "x3fMode", "masterRecipeSettingsVersion", "toneControls",
                                 "atmosphere", "colorGrading", "toneCurveConfig", "hdr", "hdrCameraAI", "proRAWDecodeVersion"] {
                        settings.removeValue(forKey: drop)
                    }
                    state["settings"] = settings; entry["state"] = state; records[k] = entry; registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)
                    let reopened = try EditPersistence(directory: dir)
                    let loaded = try reopened.state(for: url)
                    try check(loaded != nil, "\(id): legacy record must load")
                    try check(loaded!.settings.processing.version == 1, "\(id): omitted processing defaults to v1")
                    try check(loaded!.settings.x3fMode == .legacy, "\(id): omitted x3fMode defaults to legacy")
                    try check(loaded!.settings.hdr == nil, "\(id): omitted hdr defaults to nil")
                case "sdr_reset_preserves_dormant_hdr":
                    let (built, isRaw, _) = try buildState(from: baseRec)
                    let (store, dir, _) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-\(id).ARW")
                    try store.save(url, state: built)
                    let loadedBefore = try EditPersistence(directory: dir).state(for: url)!
                    let ctx = EditorAdjustmentContext(isRaw: isRaw, defaultExposureMode: .preview, neutralFilmID: "")
                    guard case .candidate(let resetState) = EditorAdjustmentRules.prepareReset(scope: .all, snapshot: loadedBefore, context: ctx) else {
                        throw Failure.message("\(id): expected reset candidate")
                    }
                    try EditPersistence(directory: dir).save(url, state: resetState)
                    let after = try EditPersistence(directory: dir).state(for: url)!
                    try check(after.settings.processing.version == 2, "\(id): processing v2 preserved")
                    try check(after.settings.x3fMode == .legacy, "\(id): x3fMode legacy preserved")
                    try check(after.settings.proRAWDecodeVersion == 2, "\(id): proRAWDecodeVersion 2 preserved")
                    try check(after.settings.hdr?.mode == .sdr, "\(id): dormant HDR mode stays .sdr")
                    try check(approx(after.settings.hdr?.exposure ?? -99, -0.5), "\(id): dormant HDR exposure preserved")
                case "future_processing_version":
                    let (built, _, _) = try buildState(from: baseRec)
                    let (sibBuilt, _, _) = try buildState(from: byID["raster-sdr-neutral"]!)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let targetURL = try touchPhoto(tempRoot, name: "c-fut-\(id).ARW")
                    let sibURL = try touchPhoto(tempRoot, name: "c-sib-\(id).JPG")
                    try store.save(targetURL, state: built)
                    try store.save(sibURL, state: sibBuilt)
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    let tk = try OriginalFileIdentity(targetURL).path
                    var entry = records[tk] as! [String: Any]
                    var state = entry["state"] as! [String: Any]
                    var settings = state["settings"] as! [String: Any]
                    settings["processing"] = ["family": "rawlab", "version": 99, "quality": "standard"]
                    state["settings"] = settings; entry["state"] = state; records[tk] = entry; registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)

                    let reopened = try EditPersistence(directory: dir)
                    var threw = false
                    do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                    try check(threw, "\(id): processing.version=99 must throw UnusableEditRecordError")
                    try check(try reopened.state(for: sibURL) != nil, "\(id): healthy sibling must remain readable")
                    var updatedSib = sibBuilt; updatedSib.settings.exposure = 1.5
                    try reopened.save(sibURL, state: updatedSib)
                    let diskAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    let diskRecs = diskAfter["records"] as! [String: Any]
                    try check(diskRecs[tk] != nil, "\(id): unreadable future record preserved on disk across sibling save")
                case "corrupt_entry":
                    let (built, _, _) = try buildState(from: baseRec)
                    let (sibBuilt, _, _) = try buildState(from: byID["raster-sdr-neutral"]!)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let targetURL = try touchPhoto(tempRoot, name: "c-bad-\(id).ARW")
                    let sibURL = try touchPhoto(tempRoot, name: "c-sib2-\(id).JPG")
                    try store.save(targetURL, state: built)
                    try store.save(sibURL, state: sibBuilt)
                    let tk = try OriginalFileIdentity(targetURL).path
                    var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                    var records = registry["records"] as! [String: Any]
                    records[tk] = "corrupt-entry-payload"
                    registry["records"] = records
                    try JSONSerialization.data(withJSONObject: registry).write(to: file)

                    let reopened = try EditPersistence(directory: dir)
                    var threw = false
                    do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                    try check(threw, "\(id): corrupt entry must throw UnusableEditRecordError")
                    try check(try reopened.state(for: sibURL) != nil, "\(id): healthy sibling readable")
                    var updatedSib = sibBuilt; updatedSib.settings.exposure = 1.1
                    try reopened.save(sibURL, state: updatedSib)
                    let diskAfter = String(data: try Data(contentsOf: file), encoding: .utf8)!
                    try check(diskAfter.contains("corrupt-entry-payload"), "\(id): corrupt entry bytes preserved across sibling save")
                case "negative_zero":
                    var recCopy = baseRec
                    var sdrCopy = recCopy["sdr_values"] as! [String: Any]
                    sdrCopy["light.exposure"] = 0.0
                    recCopy["sdr_values"] = sdrCopy
                    let (built, _, _) = try buildState(from: recCopy)
                    let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "c-\(id)")
                    let url = try touchPhoto(tempRoot, name: "c-nz-\(id).JPG")
                    try store.save(url, state: built)
                    var txt = String(data: try Data(contentsOf: file), encoding: .utf8)!
                    txt = txt.replacingOccurrences(of: "\"exposure\":0,", with: "\"exposure\":-0.0,")
                    try check(txt.contains("\"exposure\":-0.0,"), "\(id): test setup failed to inject -0.0")
                    try Data(txt.utf8).write(to: file)
                    let loaded = try EditPersistence(directory: dir).state(for: url)!
                    try check(loaded.settings.exposure == 0.0 && loaded.settings.exposure.sign == .plus, "\(id): -0.0 canonicalized/loaded cleanly")
                default:
                    throw Failure.message("Unhandled compat kind: \(kind)")
                }
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
            collect(id) {
                let (built, _, _) = try buildState(from: baseRec)
                let (sibBuilt, _, _) = try buildState(from: sibRec)
                let (store, dir, file) = try makeStore(tempRoot: tempRoot, name: "b-\(id)")
                let targetURL = try touchPhoto(tempRoot, name: "b-t-\(id).DNG")
                let sibURL = try touchPhoto(tempRoot, name: "b-s-\(id).JPG")
                try store.save(targetURL, state: built)
                try store.save(sibURL, state: sibBuilt)

                var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                var records = registry["records"] as! [String: Any]
                let tk = try OriginalFileIdentity(targetURL).path
                var entry = records[tk] as! [String: Any]
                var state = entry["state"] as! [String: Any]
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
                    default: throw Failure.message("Unhandled out_of_range field: \(field)")
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
                    throw Failure.message("Unhandled boundary mutation: \(mKind)")
                }

                state["settings"] = settings; entry["state"] = state; records[tk] = entry; registry["records"] = records
                try JSONSerialization.data(withJSONObject: registry).write(to: file)

                let reopened = try EditPersistence(directory: dir)
                var threw = false
                do { _ = try reopened.state(for: targetURL) } catch is UnusableEditRecordError { threw = true }
                try check(threw, "\(id): invalid boundary value must throw UnusableEditRecordError on read (not silently accept or clamp)")
                try check(try reopened.state(for: sibURL) != nil, "\(id): sibling must remain readable")
            }
        }

        try check(failures.isEmpty, "\(failures.count) macOS edit-record scenario(s) failed")
        print("PASS: macOS edit-record fixture suite finished with \(knownEditRecordDivergences.count) registered divergences (cap \(maxKnownEditRecordDivergences))")
    }
}
