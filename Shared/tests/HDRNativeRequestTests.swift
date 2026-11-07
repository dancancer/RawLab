import Foundation

@main enum HDRNativeRequestTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        var settings=HDRSettings()
        require(MemoryLayout<sony2fuji_hdr_image_pair_v1>.size==208,"Swift HDR pair layout differs from C11 contract")
        settings.exposure=1.25; settings.temperature=7200; settings.tint = -12
        settings.contrast=30; settings.highlights=20; settings.shadows=40; settings.saturation=10
        settings.geometry.quarterTurns=1; settings.geometry.flipHorizontal=true
        let request=try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL,longEdge:1600).native.base.base.base.base.base.base
        require(request.version==1 && request.struct_size==88 && request.hdr_processing_version==1,"HDR ABI header differs")
        require(request.exposure_ev==1.25 && request.temperature==7200 && request.tint == -12,"HDR exposure/WB mapping differs")
        require(request.contrast==30 && request.highlights==20 && request.shadows==40 && request.saturation==10,"HDR logical tone mapping differs")
        require(request.quarter_turns==1 && request.flip_horizontal==1 && request.long_edge==1600,"HDR geometry/size mapping differs")
        let data=try HDRRecipe.document(settings:settings,input:URL(fileURLWithPath:"/tmp/source.heic"),
            output:URL(fileURLWithPath:"/tmp/output.jpg"),baseColor:.displayP3,longEdge:1600)
        let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let edits=root["edits"] as! [String:Any]
        let tone=edits["tone"] as! [String:Double]
        let wb=edits["white_balance"] as! [String:Any]
        require(root["schema_version"] as? Int==6 && wb["mode"] as? String=="relative","HDR JSON context missing")
        require(tone["contrast"]==1.3 && tone["highlights"] == -0.2 && tone["shadows"]==0.4,"HDR canonical transfer units differ")
        require(!String(decoding:data,as:UTF8.self).contains("headroom"),"display/source headroom entered a recipe")
        settings.toneSettings.blackPoint = -42
        settings.toneSettings.whitePoint = 11
        settings.toneSettings.curveStrength = -27
        settings.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)])
        let extended = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_PREVIEW)
        let nativeTone = withHDRRequestPrefix(extended) { UnsafeRawPointer($0).load(as: sony2fuji_hdr_request_v2.self) }
        require(nativeTone.base.version == 1 && nativeTone.base.struct_size == 648 && nativeTone.base.hdr_processing_version == 2,
                "Swift HDR tone ABI header differs")
        require(nativeTone.black_point == -42 && nativeTone.white_point == 11 && nativeTone.curve_strength == -27 && nativeTone.reserved == 0 &&
                nativeTone.curve.mode == SONY2FUJI_CURVE_CUSTOM && nativeTone.curve.count == 3 && nativeTone.curve.points.1.y == 0.4,
                "Swift HDR tone tail differs")
        let extendedData = try HDRRecipe.document(settings: settings, input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"), baseColor: .srgb)
        let extendedRoot = try JSONSerialization.jsonObject(with: extendedData) as! [String: Any]
        let processing = extendedRoot["processing"] as! [String: Any]
        let extendedEdits = extendedRoot["edits"] as! [String: Any]
        let extendedTone = extendedEdits["tone"] as! [String: Any]
        let curve = extendedTone["curve"] as! [String: Any]
        require(extendedRoot["schema_version"] as? Int == 8 && processing["version"] as? Int == 2,
                "HDR v2 recipe negotiation differs")
        require(extendedTone["black_point"] as? Double == -0.42 && extendedTone["white_point"] as? Double == 0.11 &&
                extendedTone["s_curve"] as? Double == 0 && curve["mode"] as? String == "custom" &&
                curve["points"] as? [[Double]] == [[0, 0], [0.5, 0.4], [1, 1]], "HDR v8 tone fields differ")
        settings.colorSettings.vibrance = 23
        settings.colorSettings.hsl.setExact(.saturation, channel: 7, value: -12.5)
        settings.colorSettings.grading.midtones = .init(hue: 210, saturation: 17)
        let nativeColor = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL).native.base.base.base.base
        require(nativeColor.base.base.struct_size == 792 && nativeColor.base.base.hdr_processing_version == 3 &&
                nativeColor.vibrance == 23 && nativeColor.hsl.saturation.7 == -12.5 &&
                nativeColor.grading.midtones_hue == 210 && nativeColor.grading.midtones_saturation == 17,
                "Swift HDR color ABI differs")
        let colorData = try HDRRecipe.document(settings: settings, input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"), baseColor: .srgb)
        let colorRoot = try JSONSerialization.jsonObject(with: colorData) as! [String: Any]
        let colorEdits = colorRoot["edits"] as! [String: Any]
        require(colorRoot["schema_version"] as? Int == 9 &&
                (colorEdits["color"] as? [String: Double])?["vibrance"] == 0.23 &&
                (colorEdits["hsl"] as? [String: [Double]])?["saturation"]?.last == -12.5 &&
                (colorEdits["color_grading"] as? [String: [String: Double]])?["midtones"]?["hue"] == 210,
                "Swift HDR v9 recipe changed color values")
        settings.renditionSettings.peakLimitEV = 2
        settings.renditionSettings.sdrExposureEV = -0.5
        settings.renditionSettings.sdrContrast = 25
        settings.renditionSettings.sdrSaturation = -15
        let nativeRendition = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL).native.base.base.base
        require(nativeRendition.base.base.base.struct_size == 808 &&
                nativeRendition.base.base.base.hdr_processing_version == 4 &&
                nativeRendition.base.vibrance == 23 && nativeRendition.peak_limit_ev == 2 &&
                nativeRendition.sdr_exposure_ev == -0.5 && nativeRendition.sdr_contrast == 25 &&
                nativeRendition.sdr_saturation == -15, "Swift HDR rendition ABI differs")
        let renditionData = try HDRRecipe.document(settings: settings, input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"), baseColor: .srgb)
        let renditionRoot = try JSONSerialization.jsonObject(with: renditionData) as! [String: Any]
        let renditionEdits = renditionRoot["edits"] as! [String: Any]
        require(renditionRoot["schema_version"] as? Int == 10 &&
                (renditionEdits["rendition"] as? [String: Double]) == [
                    "peak_limit_ev": 2, "sdr_exposure_ev": -0.5, "sdr_contrast": 0.25, "sdr_saturation": -0.15
                ], "Swift HDR v10 recipe changed rendition values")
        settings.effectsSettings.vignetteAmount = -50
        settings.effectsSettings.grainAmount = 40
        settings.effectsSettings.grainSize = 30
        let nativeEffects = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL).native.base.base
        require(nativeEffects.base.base.base.base.struct_size == 848 &&
                nativeEffects.base.base.base.base.hdr_processing_version == 5 &&
                nativeEffects.base.peak_limit_ev == 2 && nativeEffects.effects.vignette_amount == -50 &&
                nativeEffects.effects.grain_amount == 40 && nativeEffects.effects.grain_size == 30,
                "Swift HDR effects ABI differs")
        let effectsData = try HDRRecipe.document(settings: settings, input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"), baseColor: .srgb)
        let effectsRoot = try JSONSerialization.jsonObject(with: effectsData) as! [String: Any]
        let effectsEdits = effectsRoot["edits"] as! [String: Any]
        require(effectsRoot["schema_version"] as? Int == 11 &&
                (effectsEdits["effects"] as? [String: Double])?["grain_amount"] == 40, "Swift HDR v11 recipe lost effects")
        settings.detailSettings = .init(sharpening: 1.25, clarity: 0.5, dehaze: -0.4, denoise: 0.75)
        let detailRequest = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL)
        let detail = detailRequest.native.base
        let prefix = withHDRRequestPrefix(detailRequest) { $0.pointee }
        require(prefix.struct_size == 864 && prefix.hdr_processing_version == 6 &&
                detail.sharpening == 1.25 && detail.clarity == 0.5 && detail.dehaze == -0.4 && detail.denoise == 0.75,
                "Swift HDR detail ABI differs")
        let detailData = try HDRRecipe.document(settings: settings, input: URL(fileURLWithPath: "/tmp/source.heic"),
            output: URL(fileURLWithPath: "/tmp/output.jpg"), baseColor: .srgb)
        let detailRoot = try JSONSerialization.jsonObject(with: detailData) as! [String: Any]
        let detailEdits = detailRoot["edits"] as! [String: Any]
        require(detailRoot["schema_version"] as? Int == 12 &&
                (detailEdits["detail"] as? [String: Double]) == ["sharpening": 1.25, "clarity": 0.5, "dehaze": -0.4, "denoise": 0.75],
                "Swift HDR v12 recipe lost detail")
        let hash = String(repeating: "a", count: 64)
        settings.lookSettings = .init(sha256: hash, name: "HDR fixture", strength: 0.75)
        let directory = URL(fileURLWithPath: "/tmp/hdr-look-fixtures")
        let lookRequest = try makeHDRRequest(settings: settings, intent: SONY2FUJI_INTENT_FINAL, lookDirectory: directory)
        withHDRRequestPrefix(lookRequest) { pointer in
            let look = UnsafeRawPointer(pointer).load(as: sony2fuji_hdr_request_v7.self)
            require(pointer.pointee.struct_size == 952 && pointer.pointee.hdr_processing_version == 7 &&
                    look.look_strength == 0.75 && look.look_path.map { String(cString: $0) } == directory.path + "/" + hash + ".cube",
                    "Swift HDR look request lost path or strength")
            let bytes = withUnsafeBytes(of: look.look_sha256) { Data($0) }
            require(bytes == Data(hash.utf8) + Data([0]), "Swift HDR look fingerprint is not NUL-terminated")
        }
        for edge in [0,-1,65536] {
            do { _ = try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL,longEdge:edge); fatalError("invalid edge accepted") }
            catch HDRRequestError.invalidSettings {}
        }
        settings.mode = .sdr
        do { _ = try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL); fatalError("SDR mode entered HDR") }
        catch HDRRequestError.invalidSettings {}
        print("PASS shared HDR native requests and v6/v8/v9/v10/v11/v12/v13 logical mapping")
    }
}
