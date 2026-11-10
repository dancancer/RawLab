import Foundation

@main enum HDRSettingsTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        var channelSettings = HDRSettings()
        channelSettings.toneSettings.curve.channels.red = .identity.inserting(x: 0.5, y: 0.6)
        require(channelSettings.processingVersion == 8 && channelSettings.recordVersion == 9, "HDR channel version")
        let channelCopy = try JSONDecoder().decode(HDRSettings.self, from: JSONEncoder().encode(channelSettings))
        require(channelCopy == channelSettings && !channelCopy.isIdentity, "HDR independent channel persistence")
        channelSettings.reset()
        require(channelSettings.isIdentity && channelSettings.toneSettings.curve.channels.isDefault, "HDR channel reset")

        var settings = HDRSettings()
        require(settings.mode == .hdr && settings.isIdentity && settings.isValid, "HDR defaults differ")
        settings.exposure = 1.5; settings.temperature = 10000; settings.tint = 42
        settings.contrast = -75; settings.highlights = 100; settings.shadows = -100; settings.saturation = -100
        settings.geometry.quarterTurns = 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var camera = HDRSettings()
        camera.cameraDevelopmentSettings.whiteBalance = .temperature
        camera.cameraDevelopmentSettings.temperature = 8400
        camera.cameraDevelopmentSettings.tint = 24
        camera.cameraDevelopmentSettings.exposureReference = .sensor
        camera.cameraDevelopmentSettings.fbddLevel = 1
        var draft = HDRCameraDevelopmentSettings()
        draft.selectWhiteBalance(.temperature)
        require(draft.temperature == 6500 && draft.tint == 0, "User WB selection did not initialize temperature")
        draft.temperature = 5000; draft.tint = 17
        let external = draft
        draft = HDRCameraDevelopmentSettings()
        draft = external
        require(draft == external, "External WB synchronization changed the saved temperature")
        draft.selectWhiteBalance(.temperature)
        require(draft == external, "Selecting the active WB mode reset the custom value")
        draft.selectWhiteBalance(.asShot)
        require(draft.whiteBalance == .asShot && draft.temperature == 0 && draft.tint == 0, "As-shot WB was not reset")
        camera.geometry.cropWidth = 0.75
        camera.cameraDevelopmentSettings.lensDistortion = true
        camera.cameraDevelopmentSettings.lensTCA = true
        camera.cameraDevelopmentSettings.lensAutoCrop = false
        camera.cameraDevelopmentSettings.lensProfile = "test-lens"
        let reference = camera.neutralGeometrySettings
        require(reference.geometry == camera.geometry && reference.cameraDevelopmentSettings.lensDistortion &&
                reference.cameraDevelopmentSettings.lensTCA && !reference.cameraDevelopmentSettings.lensAutoCrop &&
                reference.cameraDevelopmentSettings.lensProfile == "test-lens", "Neutral HDR reference lost lens geometry")
        require(reference.cameraDevelopmentSettings.whiteBalance == .asShot && reference.cameraDevelopmentSettings.fbddLevel == 0 &&
                reference.cameraDevelopmentSettings.exposureReference == .metadata, "Neutral HDR reference retained color development")
        let cameraJSON = try encoder.encode(camera)
        let decodedCamera = try JSONDecoder().decode(HDRSettings.self,from: cameraJSON)
        require(decodedCamera == camera && decodedCamera.recordVersion == 8 && decodedCamera.processingVersion == 1 &&
            !decodedCamera.isIdentity, "Camera RAW development is versioned independently of render controls")
        camera.reset()
        require(camera.recordVersion == 8 && camera.isIdentity, "Reset did not clear camera development in its own record")
        let data = try encoder.encode(settings)
        let restoredRecord = try JSONDecoder().decode(HDRSettings.self, from: data)
        require(restoredRecord == settings, "HDR settings did not round-trip")
        let text = String(decoding: data, as: UTF8.self)
        require(text.contains("record_version") && text.contains("hdr_processing_version"), "HDR version identity missing")
        require(!text.contains("headroom") && !text.contains("preview"), "runtime display state was persisted")
        var unknown = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        unknown["record_version"] = 2
        do {
            _ = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: unknown))
            fatalError("unknown HDR record was silently accepted")
        } catch is DecodingError {}
        var invalid = settings; invalid.exposure = .nan
        require(!invalid.isValid, "nonfinite HDR parameter accepted")
        invalid = settings; invalid.exposure = 5
        require(!invalid.isValid, "HDR exposure range was not checked")
        var initial = HDRSettings(); initial.exposure = 2; initial.contrast = -25
        initial.highlights = 50; initial.geometry.quarterTurns = 2
        let enabled = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: true)
        require(enabled.exposure == 2 && enabled.contrast == -25 && enabled.highlights == 50 &&
            enabled.geometry.quarterTurns == 2 && enabled.temperature == 6500 && enabled.tint == 0,
            "first HDR conversion did not copy common UI values")
        do {
            _ = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: false)
            fatalError("SDR source was elevated into HDR")
        } catch HDRSettings.ModeError.unsupportedSource {}
        settings.mode = .sdr
        let restored = try HDRSettings.enabling(stored: settings, initial: initial, sourceIsHDR: true)
        require(restored.mode == .hdr && restored.exposure == settings.exposure && restored.tint == 42,
            "existing HDR snapshot was rebuilt from dormant SDR values")
        var reset = restored; reset.reset()
        require(reset.mode == .hdr && reset.isIdentity, "HDR reset changed edit mode")
        require(restoredRecord.recordVersion == 1 && restoredRecord.toneSettings.isDefault && !text.contains("\"tone\""),
                "old HDR settings were upgraded on read")
        var tone = restoredRecord
        tone.toneSettings.blackPoint = -36.5
        tone.toneSettings.whitePoint = 20
        tone.toneSettings.curveStrength = 33
        tone.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)])
        let toneData = try encoder.encode(tone)
        let toneRestored = try JSONDecoder().decode(HDRSettings.self, from: toneData)
        require(toneRestored == tone && toneRestored.recordVersion == 2 && toneRestored.processingVersion == 2,
                "HDR tone record did not round-trip")
        var wrongVersion = try JSONSerialization.jsonObject(with: toneData) as! [String: Any]
        wrongVersion["record_version"] = 1
        wrongVersion["hdr_processing_version"] = 1
        do {
            _ = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: wrongVersion))
            fatalError("v1 silently accepted v2 tone values")
        } catch is DecodingError {}
        tone.reset()
        require(tone.isIdentity && tone.processingVersion == 2 && tone.toneSettings.isDefault,
                "reset downgraded the processing version or retained HDR tone")
        var color = restoredRecord
        color.colorSettings.vibrance = 33.5
        color.colorSettings.hsl.setExact(.hue, channel: 0, value: -21.25)
        color.colorSettings.grading.highlights.hue = 220
        let colorData = try encoder.encode(color)
        let colorRestored = try JSONDecoder().decode(HDRSettings.self, from: colorData)
        require(colorRestored == color && colorRestored.processingVersion == 3 &&
                colorRestored.toneSettings.isDefault, "HDR color record did not round-trip")
        var invalidColorRecord = try JSONSerialization.jsonObject(with: colorData) as! [String: Any]
        invalidColorRecord.removeValue(forKey: "tone")
        do {
            _ = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: invalidColorRecord))
            fatalError("v3 accepted a missing tone record")
        } catch is DecodingError {}
        color.reset()
        require(color.isIdentity && color.processingVersion == 3 && color.colorSettings.isDefault,
                "reset downgraded the processing version or retained HDR color")
        var rendition = colorRestored
        rendition.renditionSettings.peakLimitEV = 2
        rendition.renditionSettings.sdrExposureEV = -0.5
        rendition.renditionSettings.sdrContrast = 25
        rendition.renditionSettings.sdrSaturation = -15
        let renditionData = try encoder.encode(rendition)
        let renditionRestored = try JSONDecoder().decode(HDRSettings.self, from: renditionData)
        require(renditionRestored == rendition && renditionRestored.recordVersion == 4 &&
                colorRestored.renditionSettings.isDefault, "HDR rendition record did not round-trip")
        let record = try JSONSerialization.jsonObject(with: renditionData) as! [String: Any]
        for field in ["tone", "color", "rendition"] {
            var incomplete = record
            incomplete.removeValue(forKey: field)
            do {
                _ = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: incomplete))
                fatalError("v4 accepted a missing \(field) record")
            } catch is DecodingError {}
        }
        rendition.reset()
        require(rendition.isIdentity && rendition.processingVersion == 4 && rendition.renditionSettings.isDefault,
                "reset downgraded the processing version or retained the HDR rendition")
        var effects = renditionRestored
        effects.effectsSettings.vignetteAmount = -55
        effects.effectsSettings.grainAmount = 40
        let effectsData = try encoder.encode(effects)
        let effectsRestored = try JSONDecoder().decode(HDRSettings.self, from: effectsData)
        require(effectsRestored == effects && effectsRestored.recordVersion == 5 &&
                renditionRestored.effectsSettings.isDefault, "HDR effect settings did not round-trip")
        effects.effectsSettings.reset(vignette: true)
        require(effects.effectsSettings.vignetteAmount == 0 && effects.effectsSettings.grainAmount == 40,
                "HDR vignette reset changed grain")
        effects.reset()
        require(effects.isIdentity && effects.processingVersion == 5, "HDR effects reset changed version or retained edits")
        require(effectsRestored.detailSettings.isDefault, "Older HDR record gained detail edits")
        var detail = HDRSettings()
        detail.detailSettings = .init(sharpening: 1.5, clarity: 0.45, dehaze: -0.5, denoise: 0.75)
        let detailData = try encoder.encode(detail)
        let restoredDetail = try JSONDecoder().decode(HDRSettings.self, from: detailData)
        require(restoredDetail == detail && restoredDetail.recordVersion == 6, "HDR detail settings did not round-trip")
        let detailJSON = try JSONSerialization.jsonObject(with: detailData) as! [String: Any]
        for invalid in [[:], ["sharpening": 1.5, "clarity": 0.45, "dehaze": -0.5, "denoise": 1.25]] {
            var changed = detailJSON; changed["detail"] = invalid
            let broken = try JSONSerialization.data(withJSONObject: changed)
            do { _ = try JSONDecoder().decode(HDRSettings.self, from: broken); fatalError("Invalid HDR detail accepted") }
            catch is DecodingError {}
        }
        detail.reset()
        require(detail.isIdentity && detail.processingVersion == 6, "HDR detail reset changed version or retained edits")
        var look = restoredDetail
        let fingerprint = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        look.lookSettings = .init(sha256: fingerprint, name: "Fixture", strength: 0.8)
        let lookData = try encoder.encode(look)
        let reopenedLook = try JSONDecoder().decode(HDRSettings.self, from: lookData)
        require(reopenedLook == look && reopenedLook.processingVersion == 7, "HDR look resource did not round-trip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = reopenedLook.lookSettings.asset(in: directory)!
        require(!reopenedLook.lookSettings.assetIsAvailable(in: directory), "Missing HDR resource was admitted")
        try Data("abc".utf8).write(to: resource)
        require(reopenedLook.lookSettings.assetIsAvailable(in: directory), "Correct HDR resource was rejected")
        try Data("abcd".utf8).write(to: resource)
        require(!reopenedLook.lookSettings.assetIsAvailable(in: directory), "Changed HDR resource was admitted")
        look.reset()
        require(look.isIdentity && look.processingVersion == 7, "HDR look reset lost its processing version")
        print("PASS HDR settings persistence, conversion, validation and reset")
    }
}
