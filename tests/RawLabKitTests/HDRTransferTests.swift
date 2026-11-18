import Foundation
import XCTest
@testable import RawLabKit

final class HDRTransferTests: XCTestCase {
    func testHDRTransferV1ThroughV8AndCameraDevelopment() throws {
        var channels = HDRSettings()
        channels.toneSettings.curve.channels.red = .identity.inserting(x: 0.5, y: 0.625)
        let channelPayload = try HDRAdjustmentTransfer.capture(settings: channels, identifier: "channels", processingVersion: 2, scope: .modified)
        let channelResult = try HDRAdjustmentTransfer.prepare(payload: channelPayload, target: HDRSettings())
        XCTAssertEqual(channelPayload.source.hdrProcessingVersion, 8)
        XCTAssertEqual(channelResult.toneSettings.curve, channels.toneSettings.curve)

        var source = HDRSettings()
        source.exposure = 1; source.temperature = 10000; source.tint = 42
        source.contrast = -25; source.highlights = 50; source.shadows = 20; source.saturation = -30
        source.geometry.quarterTurns = 1
        let payload = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .all)
        XCTAssertEqual(payload.payloadVersion, 2)
        XCTAssertEqual(payload.scopeVersion, 2)
        XCTAssertEqual(payload.source.hdrProcessingVersion, 1)
        XCTAssertNil(payload[.temperature])
        XCTAssertEqual(payload[.hdrTemperature], .number(10000))
        XCTAssertEqual(payload[.hdrTint], .number(42))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: data)
        let unchanged = try HDRAdjustmentTransfer.prepare(payload: decoded, target: source)
        XCTAssertEqual(unchanged, source)

        let target = try HDRAdjustmentTransfer.prepare(payload: decoded, target: HDRSettings())
        let deltas = [
            target.exposure - source.exposure,
            target.contrast - source.contrast,
            target.highlights - source.highlights,
            target.shadows - source.shadows,
            target.saturation - source.saturation
        ]
        XCTAssertTrue(deltas.allSatisfy { abs($0) <= 1e-12 })
        XCTAssertEqual(target.geometry, source.geometry)
        XCTAssertEqual(target.temperature, source.temperature)
        XCTAssertEqual(target.tint, source.tint)

        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(payload))

        let exposure = try HDRAdjustmentTransfer.capture(settings: source, identifier: "hdr-source", processingVersion: 2, scope: .custom([.exposure]))
        let compatible = try HDRAdjustmentTransfer.legacyPayload(exposure)
        XCTAssertEqual(compatible.payloadVersion, 1)
        XCTAssertNil(compatible.source.hdrProcessingVersion)
        XCTAssertEqual(compatible[.exposure], .number(1))

        let v1 = try AdjustmentTransferPayload(
            source: .init(identifier: "old", isRaw: true, processingVersion: 1, recipe: nil),
            values: [AdjustmentTransferField.exposure.rawValue: .number(2)]
        )
        XCTAssertEqual(v1.payloadVersion, 1)
        let fromOld = try HDRAdjustmentTransfer.prepare(payload: v1, target: source)
        XCTAssertEqual(fromOld.exposure, 2)
        XCTAssertEqual(fromOld.temperature, 10000)
        XCTAssertEqual(fromOld.mode, .hdr)

        let invalid = try AdjustmentTransferPayload(source: v1.source, values: [AdjustmentTransferField.exposure.rawValue: .number(8)])
        XCTAssertThrowsError(try HDRAdjustmentTransfer.prepare(payload: invalid, target: source))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory)
        let preset = try store.create(name: "HDR preset", payload: payload)
        XCTAssertEqual(preset.payload.payloadVersion, 2)
        XCTAssertEqual(preset.payload.source.hdrProcessingVersion, 1)

        let neutral = HDRSettings()
        let forSDR = try HDRAdjustmentTransfer.batchPayload(settings: neutral, identifier: "source", processingVersion: 2, targetIsHDR: false)
        XCTAssertFalse(forSDR.fields.contains(where: \.isHDRRelative))
        let forHDR = try HDRAdjustmentTransfer.batchPayload(settings: neutral, identifier: "source", processingVersion: 2, targetIsHDR: true)
        XCTAssertTrue(forHDR.fields.contains(.hdrTemperature))
        XCTAssertTrue(forHDR.fields.contains(.cropWidth))

        var nonneutral = neutral
        nonneutral.tint = 15
        let unsupported = try HDRAdjustmentTransfer.batchPayload(settings: nonneutral, identifier: "source", processingVersion: 2, targetIsHDR: false)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(unsupported))

        var tone = neutral
        tone.toneSettings.blackPoint = 22.5
        tone.toneSettings.whitePoint = -12
        tone.toneSettings.curveStrength = 35
        tone.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)])
        let tonePayload = try HDRAdjustmentTransfer.capture(settings: tone, identifier: "tone", processingVersion: 2, scope: .modified)
        XCTAssertEqual(tonePayload.fields, AdjustmentTransferField.hdrTone)
        XCTAssertEqual(tonePayload.source.hdrProcessingVersion, 2)
        XCTAssertEqual(tonePayload[.blackPoint], .number(22.5))
        XCTAssertEqual(tonePayload[.sCurve], .number(0.35))
        XCTAssertEqual(try HDRAdjustmentTransfer.prepare(payload: tonePayload, target: neutral), tone)
        let savedTonePreset = try store.create(name: "HDR tone preset", payload: tonePayload)
        XCTAssertEqual(savedTonePreset.payload.values, tonePayload.values)
        XCTAssertEqual(savedTonePreset.payload.source.hdrProcessingVersion, 2)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(tonePayload))

        let ordinaryCurve = try AdjustmentTransferPayload(source: v1.source, values: ["light.curve": tone.toneSettings.curve.transferValue])
        XCTAssertThrowsError(try HDRAdjustmentTransfer.prepare(payload: ordinaryCurve, target: neutral))
        XCTAssertThrowsError(try AdjustmentTransferPayload(source: payload.source, values: tonePayload.values))

        var color = neutral
        color.colorSettings.vibrance = 42
        color.colorSettings.hsl.setExact(.saturation, channel: 5, value: -12.5)
        color.colorSettings.grading.highlights = .init(hue: 120, saturation: 35)
        let colorPayload = try HDRAdjustmentTransfer.capture(settings: color, identifier: "color", processingVersion: 2, scope: .modified)
        XCTAssertEqual(colorPayload.fields, [.vibrance, .hslSaturationBlue, .gradingHighlights])
        XCTAssertEqual(colorPayload.source.hdrProcessingVersion, 3)
        let colorPreset = try store.create(name: "HDR color preset", payload: colorPayload)
        XCTAssertEqual(try HDRAdjustmentTransfer.prepare(payload: colorPreset.payload, target: neutral), color)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(colorPayload))
        let sdrColor = try AdjustmentTransferPayload(source: v1.source, values: colorPayload.values)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.prepare(payload: sdrColor, target: neutral))
        XCTAssertThrowsError(try AdjustmentTransferPayload(source: tonePayload.source, values: colorPayload.values))

        var rendition = neutral
        rendition.renditionSettings.peakLimitEV = 2.25
        rendition.renditionSettings.sdrExposureEV = -0.75
        rendition.renditionSettings.sdrContrast = 17
        rendition.renditionSettings.sdrSaturation = -34
        let renditionPayload = try HDRAdjustmentTransfer.capture(settings: rendition, identifier: "rendition", processingVersion: 2, scope: .modified)
        XCTAssertEqual(renditionPayload.fields, AdjustmentTransferField.hdrRendition)
        XCTAssertEqual(renditionPayload.source.hdrProcessingVersion, 4)
        let renditionPreset = try store.create(name: "HDR rendition preset", payload: renditionPayload)
        XCTAssertEqual(try HDRAdjustmentTransfer.prepare(payload: renditionPreset.payload, target: neutral), rendition)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(renditionPayload))
        XCTAssertThrowsError(try AdjustmentTransferPayload(source: colorPayload.source, values: renditionPayload.values))

        var effects = neutral
        effects.effectsSettings.vignetteAmount = -60
        effects.effectsSettings.grainAmount = 50
        let effectsPayload = try HDRAdjustmentTransfer.capture(settings: effects, identifier: "effects", processingVersion: 2, scope: .modified)
        let effectPreset = try store.create(name: "HDR effects preset", payload: effectsPayload)
        let appliedEffects = try HDRAdjustmentTransfer.prepare(payload: effectPreset.payload, target: neutral)
        XCTAssertEqual(effectsPayload.source.hdrProcessingVersion, 5)
        XCTAssertEqual(effectsPayload.fields, [.vignetteAmount, .grainAmount])
        XCTAssertEqual(appliedEffects, effects)
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(effectsPayload))

        var detail = neutral
        detail.detailSettings = .init(sharpening: 1.5, clarity: 0.5, dehaze: -0.25, denoise: 0.75)
        let detailPayload = try HDRAdjustmentTransfer.capture(settings: detail, identifier: "detail", processingVersion: 2, scope: .modified)
        let appliedDetail = try HDRAdjustmentTransfer.prepare(payload: detailPayload, target: neutral)
        XCTAssertEqual(detailPayload.source.hdrProcessingVersion, 6)
        XCTAssertEqual(detailPayload.fields, AdjustmentTransferField.hdrDetail)
        XCTAssertEqual(detailPayload[.clarity], .number(50))
        XCTAssertEqual(detailPayload[.dehaze], .number(-25))
        XCTAssertEqual(appliedDetail, detail)
        do {
            _ = try HDRAdjustmentTransfer.legacyPayload(detailPayload)
            XCTFail("HDR detail applied to SDR")
        } catch AdjustmentTransferError.incompatible(let field) {
            XCTAssertEqual(field, "hdr.detail")
        }

        detail.reset()
        let neutralForSDR = try HDRAdjustmentTransfer.batchPayload(settings: detail, identifier: "detail", processingVersion: 2, targetIsHDR: false)
        XCTAssertTrue(neutralForSDR.fields.isDisjoint(with: AdjustmentTransferField.hdrDetail))

        var look = neutral
        look.lookSettings = .init(sha256: String(repeating: "a", count: 64), name: "Fixture", strength: 0.65)
        let lookPayload = try HDRAdjustmentTransfer.capture(settings: look, identifier: "look", processingVersion: 2, scope: .modified)
        let restoredPayload = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(lookPayload))
        let appliedLook = try HDRAdjustmentTransfer.prepare(payload: restoredPayload, target: neutral)
        XCTAssertEqual(restoredPayload.source.hdrProcessingVersion, 7)
        XCTAssertEqual(restoredPayload.fields, [.hdrLook])
        XCTAssertEqual(appliedLook, look)
        do {
            _ = try HDRAdjustmentTransfer.legacyPayload(restoredPayload)
            XCTFail("HDR look reached SDR")
        } catch AdjustmentTransferError.incompatible(let field) {
            XCTAssertEqual(field, "hdr.look")
        }

        var sourceCamera = HDRCameraDevelopmentSettings()
        sourceCamera.whiteBalance = .temperature; sourceCamera.temperature = 8800; sourceCamera.tint = -9
        sourceCamera.exposureReference = .sensor; sourceCamera.fbddLevel = 2
        sourceCamera.lensDistortion = true; sourceCamera.lensProfile = "source lens"
        var cameraHDR = neutral
        cameraHDR.cameraDevelopmentSettings = sourceCamera
        let cameraPayload = try HDRAdjustmentTransfer.capture(settings: cameraHDR, identifier: "camera", processingVersion: 2, scope: .modified, cameraRAW: true)
        let cameraRoundTrip = try JSONDecoder().decode(AdjustmentTransferPayload.self, from: JSONEncoder().encode(cameraPayload))
        XCTAssertEqual(cameraRoundTrip, cameraPayload)
        XCTAssertEqual(cameraPayload.source.hdrProcessingVersion, 1)
        XCTAssertEqual(cameraPayload.fields, [.hdrCameraDevelopment])
        XCTAssertNil(cameraPayload[.hdrCameraDevelopment]?.object?["lens_profile"])

        var targetCamera = HDRCameraDevelopmentSettings()
        targetCamera.lensTCA = true; targetCamera.lensAutoCrop = false; targetCamera.lensProfile = "target lens"
        var targetHDR = neutral
        targetHDR.cameraDevelopmentSettings = targetCamera
        let cameraResult = try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: targetHDR, cameraRAW: true)
        let appliedCamera = cameraResult.cameraDevelopmentSettings
        XCTAssertEqual(appliedCamera.temperature, 8800)
        XCTAssertEqual(appliedCamera.tint, -9)
        XCTAssertEqual(appliedCamera.exposureReference, .sensor)
        XCTAssertEqual(appliedCamera.fbddLevel, 2)
        XCTAssertTrue(appliedCamera.lensTCA)
        XCTAssertFalse(appliedCamera.lensDistortion)
        XCTAssertFalse(appliedCamera.lensAutoCrop)
        XCTAssertEqual(appliedCamera.lensProfile, "target lens")

        let profile = ["sha256": String(repeating: "a", count: 64), "name": "D65 linear"]
        var profiledRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(targetHDR)) as? [String: Any])
        var profiledDevelopment = try XCTUnwrap(profiledRecord["camera_development"] as? [String: Any])
        profiledDevelopment["camera_profile"] = profile
        profiledRecord["camera_development"] = profiledDevelopment
        let reopened = try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: profiledRecord))
        let edited = try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: reopened, cameraRAW: true)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        XCTAssertEqual((saved["camera_development"] as? [String: Any])?["camera_profile"] as? [String: String], profile)

        XCTAssertThrowsError(try HDRAdjustmentTransfer.prepare(payload: cameraRoundTrip, target: neutral))
        XCTAssertThrowsError(try HDRAdjustmentTransfer.legacyPayload(cameraRoundTrip))

        let reset = try HDRAdjustmentTransfer.capture(settings: neutral, identifier: "camera", processingVersion: 2, scope: .custom([.hdrCameraDevelopment]), cameraRAW: true)
        let resetResult = try HDRAdjustmentTransfer.prepare(payload: reset, target: cameraResult, cameraRAW: true)
        XCTAssertEqual(resetResult.cameraDevelopmentSettings, targetCamera)

        let batch = try HDRAdjustmentTransfer.batchPayload(settings: cameraHDR, identifier: "camera", processingVersion: 2, targetIsHDR: true)
        XCTAssertFalse(batch.fields.contains(.hdrCameraDevelopment))

        var invalidCamera = try XCTUnwrap(cameraPayload[.hdrCameraDevelopment]?.object)
        invalidCamera["fbdd_level"] = .number(1.5)
        XCTAssertThrowsError(try AdjustmentTransferPayload(source: cameraPayload.source, values: ["hdr.camera_development": .object(invalidCamera)]))
    }
}
