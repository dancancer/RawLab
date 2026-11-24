import RawLabKit
import Foundation

@main enum HDRNativeRequestTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func parse(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrapData(json)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func XCTUnwrapData(_ string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw HDRNativeError.invalidSettings
        }
        return data
    }

    static func main() throws {
        require(HDRNativeError.invalidSettings.status == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "HDRNativeError.invalidSettings status mismatch")
        require(MemoryLayout<sony2fuji_hdr_image_pair_v1>.size == 208,
                "Swift HDR pair layout differs from C11 contract")
        require(MemoryLayout<sony2fuji_hdr_render_options_v1>.size == 16 &&
                SONY2FUJI_HDR_RENDER_OPTIONS_V1_VERSION == 1,
                "Swift HDR render_options_v1 layout differs from C11 contract")

        let cameraError = HDRNativeError(
            status: SONY2FUJI_STATUS_UNSUPPORTED,
            reason: UInt32(SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT),
            field: UInt32(SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT)
        )
        require(cameraError.errorDescription == L10n.text("无效或不可用的相机显影设置（白平衡或镜头校正）。"),
                "HDR camera white-balance failures must not blame lens correction alone")

        var channelSettings = HDRSettings()
        channelSettings.toneSettings.curve.channels.red = .identity.inserting(x: 0.5, y: 0.6)
        let channelJSON = try CanonicalEditRecipe.hdrSessionStateJSON(settings: channelSettings)
        let channelRoot = try parse(channelJSON)
        let channelProcessing = channelRoot["processing"] as! [String: Any]
        let channelEdits = channelRoot["edits"] as! [String: Any]
        let channelTone = channelEdits["tone"] as! [String: Any]
        let channelCurve = channelTone["curve"] as! [String: Any]
        let channels = channelCurve["channels"] as! [String: Any]
        let redChannel = channels["red"] as! [String: Any]
        require(channelRoot["schema_version"] as? Int == 15 &&
                channelProcessing["family"] as? String == "rawlab_hdr" &&
                channelProcessing["version"] as? Int == 8,
                "HDR v8 SessionState header mismatch")
        require((redChannel["points"] as? [[Double]]) == [[0, 0], [0.5, 0.6], [1, 1]],
                "HDR v8 SessionState red channel points mismatch")

        var settings = HDRSettings()
        settings.exposure = 1.25
        settings.temperature = 7200
        settings.tint = -12
        settings.contrast = 30
        settings.highlights = 20
        settings.shadows = 40
        settings.saturation = 10
        settings.geometry.quarterTurns = 1
        settings.geometry.flipHorizontal = true

        let v6JSON = try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings)
        let v6Root = try parse(v6JSON)
        let v6Edits = v6Root["edits"] as! [String: Any]
        let v6Tone = v6Edits["tone"] as! [String: Double]
        let v6WB = v6Edits["white_balance"] as! [String: Any]
        let v6Geo = v6Edits["geometry"] as! [String: Any]
        require(v6Root["schema_version"] as? Int == 6 && v6WB["mode"] as? String == "relative" &&
                v6WB["relative_temperature"] as? Double == 7200 && v6WB["relative_tint"] as? Double == -12,
                "HDR v6 SessionState WB mismatch")
        require(v6Tone["contrast"] == 1.3 && v6Tone["highlights"] == -0.2 &&
                v6Tone["shadows"] == 0.4 && v6Tone["saturation"] == 1.1,
                "HDR v6 SessionState tone mismatch")
        require(v6Geo["quarter_turns"] as? Int == 1 && v6Geo["flip_horizontal"] as? Bool == true,
                "HDR v6 SessionState geometry mismatch")
        require(!v6JSON.contains("headroom") && !v6JSON.contains("session.raw") && !v6JSON.contains("session.png"),
                "HDR SessionState leaked headroom or dummy path")

        let data = try HDRRecipe.document(
            settings: settings,
            input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"),
            baseColor: .displayP3,
            longEdge: 1600
        )
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let edits = root["edits"] as! [String: Any]
        let tone = edits["tone"] as! [String: Double]
        let wb = edits["white_balance"] as! [String: Any]
        require(root["schema_version"] as? Int == 6 && wb["mode"] as? String == "relative", "HDR JSON context missing")
        require(tone["contrast"] == 1.3 && tone["highlights"] == -0.2 && tone["shadows"] == 0.4, "HDR canonical transfer units differ")
        require(!String(decoding: data, as: UTF8.self).contains("headroom"), "display/source headroom entered a recipe")

        settings.toneSettings.blackPoint = -42
        settings.toneSettings.whitePoint = 11
        settings.toneSettings.curveStrength = -27
        settings.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)])
        let extendedRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings))
        let extendedProcessing = extendedRoot["processing"] as! [String: Any]
        let extendedEdits = extendedRoot["edits"] as! [String: Any]
        let extendedTone = extendedEdits["tone"] as! [String: Any]
        let curve = extendedTone["curve"] as! [String: Any]
        require(extendedRoot["schema_version"] as? Int == 8 && extendedProcessing["version"] as? Int == 2,
                "HDR v2 SessionState negotiation differs")
        require(extendedTone["black_point"] as? Double == -0.42 && extendedTone["white_point"] as? Double == 0.11 &&
                extendedTone["s_curve"] as? Double == 0 && curve["mode"] as? String == "custom" &&
                curve["points"] as? [[Double]] == [[0, 0], [0.5, 0.4], [1, 1]],
                "HDR v8 tone fields differ")

        settings.colorSettings.vibrance = 23
        settings.colorSettings.hsl.setExact(.saturation, channel: 7, value: -12.5)
        settings.colorSettings.grading.midtones = .init(hue: 210, saturation: 17)
        let colorRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings))
        let colorEdits = colorRoot["edits"] as! [String: Any]
        require(colorRoot["schema_version"] as? Int == 9 &&
                (colorEdits["color"] as? [String: Double])?["vibrance"] == 0.23 &&
                (colorEdits["hsl"] as? [String: [Double]])?["saturation"]?.last == -12.5 &&
                (colorEdits["color_grading"] as? [String: [String: Double]])?["midtones"]?["hue"] == 210,
                "Swift HDR v9 SessionState changed color values")

        settings.renditionSettings.peakLimitEV = 2
        settings.renditionSettings.sdrExposureEV = -0.5
        settings.renditionSettings.sdrContrast = 25
        settings.renditionSettings.sdrSaturation = -15
        let renditionRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings))
        let renditionEdits = renditionRoot["edits"] as! [String: Any]
        require(renditionRoot["schema_version"] as? Int == 10 &&
                (renditionEdits["rendition"] as? [String: Double]) == [
                    "peak_limit_ev": 2, "sdr_exposure_ev": -0.5, "sdr_contrast": 0.25, "sdr_saturation": -0.15
                ], "Swift HDR v10 SessionState changed rendition values")

        settings.effectsSettings.vignetteAmount = -50
        settings.effectsSettings.grainAmount = 40
        settings.effectsSettings.grainSize = 30
        let effectsRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings))
        let effectsEdits = effectsRoot["edits"] as! [String: Any]
        require(effectsRoot["schema_version"] as? Int == 11 &&
                (effectsEdits["effects"] as? [String: Double])?["grain_amount"] == 40,
                "Swift HDR v11 SessionState lost effects")

        settings.detailSettings = .init(sharpening: 1.25, clarity: 0.5, dehaze: -0.4, denoise: 0.75)
        let detailRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings))
        let detailEdits = detailRoot["edits"] as! [String: Any]
        require(detailRoot["schema_version"] as? Int == 12 &&
                (detailEdits["detail"] as? [String: Double]) == [
                    "sharpening": 1.25, "clarity": 0.5, "dehaze": -0.4, "denoise": 0.75
                ], "Swift HDR v12 SessionState lost detail")

        let hash = String(repeating: "a", count: 64)
        settings.lookSettings = .init(sha256: hash, name: "HDR fixture", strength: 0.75)
        let directory = URL(fileURLWithPath: "/tmp/hdr-look-fixtures")
        let lookRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings, lookDirectory: directory))
        let lookEdits = lookRoot["edits"] as! [String: Any]
        let lookObj = lookEdits["look"] as! [String: Any]
        require(lookRoot["schema_version"] as? Int == 13 &&
                lookObj["strength"] as? Double == 0.75 &&
                lookObj["path"] as? String == directory.path + "/" + hash + ".cube" &&
                lookObj["sha256"] as? String == hash,
                "Swift HDR v13 SessionState look mismatch")

        var v9Settings = settings
        v9Settings.toneSettings.curve = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.6), .init(x: 1, y: 0.9)],
            applyToLuminosity: true,
            parametric: ToneCurveParametric(
                highlights: -15, lights: 10, darks: -5, shadows: 20,
                splitShadow: 0.2, splitMidtone: 0.5, splitHighlight: 0.8
            )
        )
        let sharpenedRoot = try parse(try CanonicalEditRecipe.hdrSessionStateJSON(
            settings: v9Settings, outputSharpening: .standard, lookDirectory: directory
        ))
        let sharpenedProcessing = sharpenedRoot["processing"] as! [String: Any]
        let sharpenedEdits = sharpenedRoot["edits"] as! [String: Any]
        let sharpenedCurve = (sharpenedEdits["tone"] as! [String: Any])["curve"] as! [String: Any]
        let sharpenedParam = sharpenedCurve["parametric"] as! [String: Double]
        let sharpenedOutput = sharpenedRoot["output"] as! [String: Any]
        require(sharpenedRoot["schema_version"] as? Int == 16 &&
                sharpenedProcessing["version"] as? Int == 9 &&
                sharpenedCurve["apply_to_luminosity"] as? Bool == true &&
                sharpenedParam["shadows"] == 20 &&
                sharpenedParam["split_shadow"] == 0.2 &&
                sharpenedOutput["output_sharpening"] as? String == "standard",
                "HDR v16 SessionState parametric/output_sharpening mismatch")

        var cam = HDRCameraDevelopmentSettings()
        cam.whiteBalance = .temperature
        cam.temperature = 5400
        cam.tint = 8
        cam.lensDistortion = true
        cam.lensProfile = "lens-42"
        let camRoot = try parse(try CanonicalEditRecipe.hdrCameraDevelopmentJSON(
            camera: cam, processingVersion: 3, useAI: true
        ))
        let camDev = camRoot["camera_development"] as! [String: Any]
        require(camDev["wb_mode"] as? String == "temperature" &&
                camDev["temperature"] as? Double == 5400 &&
                camDev["lens_profile_id"] as? String == "lens-42" &&
                camDev["use_ai"] as? Bool == true &&
                camDev["processing_version"] as? Int == 3,
                "HDR camera_development SessionState JSON mismatch")

        settings.mode = .sdr
        do {
            _ = try CanonicalEditRecipe.hdrSessionStateJSON(settings: settings)
            fatalError("SDR mode entered HDR")
        } catch HDRRecipe.Failure.invalidSettings {}

        print("PASS shared HDR JSON SessionState and v6/v8/v9/v10/v11/v12/v13/v15/v16 logical mapping")
    }
}
