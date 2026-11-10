import Foundation

@main enum HDRTransferTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    static func main() throws {
        var channels = HDRSettings()
        channels.toneSettings.curve.channels.red = .identity.inserting(x: 0.5, y: 0.625)
        let channelPayload = try HDRAdjustmentTransfer.capture(settings: channels, identifier: "channels", processingVersion: 2, scope: .modified)
        let channelResult = try HDRAdjustmentTransfer.prepare(payload: channelPayload, target: HDRSettings())
        check(channelPayload.source.hdrProcessingVersion == 8 && channelResult.toneSettings.curve == channels.toneSettings.curve,
              "HDR channel transfer must preserve v8 curves")

        var source = HDRSettings(); source.exposure = 1; source.temperature = 10000; source.tint = 42
        source.contrast = -25; source.highlights = 50; source.shadows = 20; source.saturation = -30
        source.geometry.quarterTurns = 1
        let payload = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .all)
        check(payload.payloadVersion == 2 && payload.scopeVersion == 2 && payload.source.hdrProcessingVersion == 1,
            "HDR payload lost its independent version")
        check(payload[.temperature] == nil && payload[.hdrTemperature] == .number(10000) && payload[.hdrTint] == .number(42),
            "relative WB was stored as RAW Kelvin")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data)
        let unchanged = try HDRAdjustmentTransfer.prepare(payload: decoded, target: source)
        check(unchanged == source, "copying identical logical values created a false history change")
        let target = try HDRAdjustmentTransfer.prepare(payload: decoded, target: HDRSettings())
        let deltas = [target.exposure-source.exposure, target.contrast-source.contrast, target.highlights-source.highlights,
            target.shadows-source.shadows, target.saturation-source.saturation]
        check(deltas.allSatisfy { abs($0) <= 1e-12 } && target.geometry == source.geometry &&
            target.temperature == source.temperature && target.tint == source.tint,
            "HDR payload round-trip changed UI scale or geometry")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(payload); fatalError("relative HDR WB was applied to an SDR/RAW target") }
        catch AdjustmentTransferError.incompatible {}
        let exposure = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .custom([.exposure]))
        let compatible = try HDRAdjustmentTransfer.legacyPayload(exposure)
        check(compatible.payloadVersion == 1 && compatible.source.hdrProcessingVersion == nil && compatible[.exposure] == .number(1),
            "common-value transfer changed mode or lost compatibility")
        let v1 = try AdjustmentTransferPayload(source: .init(identifier: "old", isRaw: true, processingVersion: 1, recipe: nil),
            values: [AdjustmentTransferField.exposure.rawValue: .number(2)])
        check(v1.payloadVersion == 1, "old payload was automatically upgraded")
        let fromOld = try HDRAdjustmentTransfer.prepare(payload: v1, target: source)
        check(fromOld.exposure == 2 && fromOld.temperature == 10000 && fromOld.mode == .hdr, "v1 common transfer replaced HDR context")
        let invalid = try AdjustmentTransferPayload(source: v1.source, values: [AdjustmentTransferField.exposure.rawValue: .number(8)])
        do { _ = try HDRAdjustmentTransfer.prepare(payload: invalid, target: source); fatalError("HDR destination silently clamped out-of-range input") }
        catch AdjustmentTransferError.incompatible {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory)
        let preset = try store.create(name: "HDR preset", payload: payload)
        check(preset.payload.payloadVersion == 2 && preset.payload.source.hdrProcessingVersion == 1, "preset stripped HDR source context")
        let neutral=HDRSettings()
        let forSDR=try HDRAdjustmentTransfer.batchPayload(settings:neutral,identifier:"source",processingVersion:2,targetIsHDR:false)
        check(!forSDR.fields.contains(where:\.isHDRRelative),"neutral HDR WB must leave another family's WB unchanged")
        let forHDR=try HDRAdjustmentTransfer.batchPayload(settings:neutral,identifier:"source",processingVersion:2,targetIsHDR:true)
        check(forHDR.fields.contains(.hdrTemperature) && forHDR.fields.contains(.cropWidth),"HDR target did not receive complete HDR snapshot")
        var nonneutral=neutral; nonneutral.tint=15
        let unsupported=try HDRAdjustmentTransfer.batchPayload(settings:nonneutral,identifier:"source",processingVersion:2,targetIsHDR:false)
        do { _ = try HDRAdjustmentTransfer.legacyPayload(unsupported); fatalError("nonneutral relative WB silently applied to another family") }
        catch AdjustmentTransferError.incompatible {}
        var tone = neutral
        tone.toneSettings.blackPoint = 22.5
        tone.toneSettings.whitePoint = -12
        tone.toneSettings.curveStrength = 35
        tone.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)])
        let tonePayload = try HDRAdjustmentTransfer.capture(settings: tone, identifier: "tone", processingVersion: 2, scope: .modified)
        check(tonePayload.fields == AdjustmentTransferField.hdrTone && tonePayload.source.hdrProcessingVersion == 2 &&
            tonePayload[.blackPoint] == .number(22.5) && tonePayload[.sCurve] == .number(0.35),
            "HDR tone selection lost scope or canonical values")
        let appliedTone = try HDRAdjustmentTransfer.prepare(payload: tonePayload, target: neutral)
        check(appliedTone == tone, "HDR tone payload lost settings")
        let savedTonePreset = try store.create(name: "HDR tone preset", payload: tonePayload)
        check(savedTonePreset.payload.values == tonePayload.values && savedTonePreset.payload.source.hdrProcessingVersion == 2,
              "saved preset lost HDR tone version or fields")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(tonePayload); fatalError("HDR curve applied to SDR") }
        catch AdjustmentTransferError.incompatible {}
        let ordinaryCurve = try AdjustmentTransferPayload(source: v1.source, values: ["light.curve": tone.toneSettings.curve.transferValue])
        do { _ = try HDRAdjustmentTransfer.prepare(payload: ordinaryCurve, target: neutral); fatalError("SDR curve applied to HDR") }
        catch AdjustmentTransferError.incompatible {}
        do { _ = try AdjustmentTransferPayload(source: payload.source, values: tonePayload.values); fatalError("v1 accepted HDR tone values") }
        catch AdjustmentTransferError.invalidPayload {}
        var color = neutral
        color.colorSettings.vibrance = 42
        color.colorSettings.hsl.setExact(.saturation, channel: 5, value: -12.5)
        color.colorSettings.grading.highlights = .init(hue: 120, saturation: 35)
        let colorPayload = try HDRAdjustmentTransfer.capture(settings: color, identifier: "color", processingVersion: 2, scope: .modified)
        check(colorPayload.fields == [.vibrance, .hslSaturationBlue, .gradingHighlights] &&
              colorPayload.source.hdrProcessingVersion == 3, "HDR color scope lost version or fields")
        let colorPreset = try store.create(name: "HDR color preset", payload: colorPayload)
        let appliedColor = try HDRAdjustmentTransfer.prepare(payload: colorPreset.payload, target: neutral)
        check(appliedColor == color, "HDR color transfer lost settings")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(colorPayload); fatalError("HDR color applied to SDR") }
        catch AdjustmentTransferError.incompatible {}
        let sdrColor = try AdjustmentTransferPayload(source: v1.source, values: colorPayload.values)
        do { _ = try HDRAdjustmentTransfer.prepare(payload: sdrColor, target: neutral); fatalError("SDR color applied to HDR") }
        catch AdjustmentTransferError.incompatible {}
        do { _ = try AdjustmentTransferPayload(source: tonePayload.source, values: colorPayload.values); fatalError("v2 accepted HDR color values") }
        catch AdjustmentTransferError.invalidPayload {}
        var rendition = neutral
        rendition.renditionSettings.peakLimitEV = 2.25
        rendition.renditionSettings.sdrExposureEV = -0.75
        rendition.renditionSettings.sdrContrast = 17
        rendition.renditionSettings.sdrSaturation = -34
        let renditionPayload = try HDRAdjustmentTransfer.capture(settings: rendition, identifier: "rendition",
            processingVersion: 2, scope: .modified)
        check(renditionPayload.fields == AdjustmentTransferField.hdrRendition &&
              renditionPayload.source.hdrProcessingVersion == 4, "HDR rendition scope lost version or fields")
        let renditionPreset = try store.create(name: "HDR rendition preset", payload: renditionPayload)
        let appliedRendition = try HDRAdjustmentTransfer.prepare(payload: renditionPreset.payload, target: neutral)
        check(appliedRendition == rendition, "HDR rendition preset lost settings")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(renditionPayload); fatalError("HDR rendition applied to SDR") }
        catch AdjustmentTransferError.incompatible {}
        do { _ = try AdjustmentTransferPayload(source: colorPayload.source, values: renditionPayload.values); fatalError("v3 accepted HDR rendition values") }
        catch AdjustmentTransferError.invalidPayload {}
        var effects = neutral
        effects.effectsSettings.vignetteAmount = -60
        effects.effectsSettings.grainAmount = 50
        let effectsPayload = try HDRAdjustmentTransfer.capture(settings: effects, identifier: "effects",
            processingVersion: 2, scope: .modified)
        let effectPreset = try store.create(name: "HDR effects preset", payload: effectsPayload)
        let appliedEffects = try HDRAdjustmentTransfer.prepare(payload: effectPreset.payload, target: neutral)
        check(effectsPayload.source.hdrProcessingVersion == 5 && effectsPayload.fields == [.vignetteAmount, .grainAmount] &&
              appliedEffects == effects, "HDR effects transfer lost settings")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(effectsPayload); fatalError("HDR effects applied to SDR") }
        catch AdjustmentTransferError.incompatible {}
        var detail = neutral
        detail.detailSettings = .init(sharpening: 1.5, clarity: 0.5, dehaze: -0.25, denoise: 0.75)
        let detailPayload = try HDRAdjustmentTransfer.capture(settings: detail, identifier: "detail",
            processingVersion: 2, scope: .modified)
        let appliedDetail = try HDRAdjustmentTransfer.prepare(payload: detailPayload, target: neutral)
        check(detailPayload.source.hdrProcessingVersion == 6 && detailPayload.fields == AdjustmentTransferField.hdrDetail &&
              detailPayload[.clarity]?.number == 50 && detailPayload[.dehaze]?.number == -25 && appliedDetail == detail,
              "HDR detail transfer lost settings or canonical units")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(detailPayload); fatalError("HDR detail applied to SDR") }
        catch AdjustmentTransferError.incompatible(let field) { check(field == "hdr.detail", "Wrong HDR detail blocker") }
        detail.reset()
        let neutralForSDR = try HDRAdjustmentTransfer.batchPayload(settings: detail, identifier: "detail",
            processingVersion: 2, targetIsHDR: false)
        check(neutralForSDR.fields.isDisjoint(with: AdjustmentTransferField.hdrDetail), "Neutral detail blocks mixed batch")
        var look = neutral
        look.lookSettings = .init(sha256: String(repeating: "a", count: 64), name: "Fixture", strength: 0.65)
        let lookPayload = try HDRAdjustmentTransfer.capture(settings: look, identifier: "look", processingVersion: 2, scope: .modified)
        let restoredPayload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(lookPayload))
        let appliedLook = try HDRAdjustmentTransfer.prepare(payload: restoredPayload, target: neutral)
        check(restoredPayload.source.hdrProcessingVersion == 7 && restoredPayload.fields == [.hdrLook] && appliedLook == look,
              "HDR transfer lost the look fingerprint or strength")
        do { _ = try HDRAdjustmentTransfer.legacyPayload(restoredPayload); fatalError("HDR look reached SDR") }
        catch AdjustmentTransferError.incompatible(let field) { check(field == "hdr.look", "Wrong HDR look blocker") }
        var sourceCamera = HDRCameraDevelopmentSettings()
        sourceCamera.whiteBalance = .temperature; sourceCamera.temperature = 8800; sourceCamera.tint = -9
        sourceCamera.exposureReference = .sensor; sourceCamera.fbddLevel = 2
        sourceCamera.lensDistortion = true; sourceCamera.lensProfile = "source lens"
        var cameraHDR = neutral; cameraHDR.cameraDevelopmentSettings = sourceCamera
        let cameraPayload = try HDRAdjustmentTransfer.capture(settings: cameraHDR, identifier: "camera", processingVersion: 2,
            scope: .modified, cameraRAW: true)
        let cameraRoundTrip = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(cameraPayload))
        check(cameraRoundTrip == cameraPayload && cameraPayload.source.hdrProcessingVersion == 1 &&
              cameraPayload.fields == [.hdrCameraDevelopment] && cameraPayload[.hdrCameraDevelopment]?.object?["lens_profile"] == nil,
              "Camera adjustments changed rendering version or copied source lens calibration")
        var targetCamera = HDRCameraDevelopmentSettings()
        targetCamera.lensTCA = true; targetCamera.lensAutoCrop = false; targetCamera.lensProfile = "target lens"
        var targetHDR = neutral; targetHDR.cameraDevelopmentSettings = targetCamera
        let cameraResult = try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: targetHDR, cameraRAW: true)
        let appliedCamera = cameraResult.cameraDevelopmentSettings
        check(appliedCamera.temperature == 8800 && appliedCamera.tint == -9 && appliedCamera.exposureReference == .sensor &&
              appliedCamera.fbddLevel == 2 && appliedCamera.lensTCA && !appliedCamera.lensDistortion &&
              !appliedCamera.lensAutoCrop && appliedCamera.lensProfile == "target lens", "Portable camera settings replaced target lens choices")
        let profile = ["sha256": String(repeating: "a", count: 64), "name": "D65 linear"]
        var profiledRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(targetHDR)) as! [String: Any]
        var profiledDevelopment = profiledRecord["camera_development"] as! [String: Any]
        profiledDevelopment["camera_profile"] = profile
        profiledRecord["camera_development"] = profiledDevelopment
        let reopened = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: profiledRecord))
        let edited = try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: reopened, cameraRAW: true)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as! [String: Any]
        check((saved["camera_development"] as? [String: Any])?["camera_profile"] as? [String: String] == profile,
              "Reopening or applying portable settings lost the target camera profile")
        do { _ = try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: neutral); fatalError("Camera payload reached gain-map HDR") }
        catch AdjustmentTransferError.incompatible {}
        do { _ = try HDRAdjustmentTransfer.legacyPayload(cameraRoundTrip); fatalError("Camera payload reached SDR") }
        catch AdjustmentTransferError.incompatible {}
        let reset = try HDRAdjustmentTransfer.capture(settings: neutral, identifier: "camera", processingVersion: 2,
            scope: .custom([.hdrCameraDevelopment]), cameraRAW: true)
        let resetResult = try HDRAdjustmentTransfer.prepare(payload: reset, target: cameraResult, cameraRAW: true)
        check(resetResult.cameraDevelopmentSettings == targetCamera, "Explicit camera reset lost the target lens")
        let batch = try HDRAdjustmentTransfer.batchPayload(settings: cameraHDR, identifier: "camera", processingVersion: 2, targetIsHDR: true)
        check(!batch.fields.contains(.hdrCameraDevelopment), "Uniform batch replaced per-target camera development")
        var invalidCamera = cameraPayload[.hdrCameraDevelopment]!.object!
        invalidCamera["fbdd_level"] = .number(1.5)
        do {
            _ = try AdjustmentTransferPayload(source: cameraPayload.source, values: ["hdr.camera_development": .object(invalidCamera)])
            fatalError("Nonintegral FBDD accepted")
        } catch AdjustmentTransferError.invalidPayload {}
        print("PASS HDR v1 through v7 transfer, camera development v1, mixed-mode preflight and preset persistence")
    }
}
