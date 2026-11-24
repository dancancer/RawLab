import Foundation
import XCTest
@testable import RawLabKit

final class HDRSettingsTests: XCTestCase {
    func testHDRSettingsPersistenceConversionValidationAndReset() throws {
        var channelSettings = HDRSettings()
        channelSettings.toneSettings.curve.channels.red = .identity.inserting(x: 0.5, y: 0.6)
        XCTAssertEqual(channelSettings.processingVersion, 8)
        XCTAssertEqual(channelSettings.recordVersion, 9)
        let channelCopy = try JSONDecoder().decode(HDRSettings.self, from: JSONEncoder().encode(channelSettings))
        XCTAssertEqual(channelCopy, channelSettings)
        XCTAssertFalse(channelCopy.isIdentity)
        channelSettings.reset()
        XCTAssertTrue(channelSettings.isIdentity)
        XCTAssertTrue(channelSettings.toneSettings.curve.channels.isDefault)

        var settings = HDRSettings()
        XCTAssertEqual(settings.mode, .hdr)
        XCTAssertTrue(settings.isIdentity)
        XCTAssertTrue(settings.isValid)
        settings.exposure = 1.5; settings.temperature = 10000; settings.tint = 42
        settings.contrast = -75; settings.highlights = 100; settings.shadows = -100; settings.saturation = -100
        settings.geometry.quarterTurns = 1

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var camera = HDRSettings()
        camera.cameraDevelopmentSettings.whiteBalance = .temperature
        camera.cameraDevelopmentSettings.temperature = 8400
        camera.cameraDevelopmentSettings.tint = 24
        camera.cameraDevelopmentSettings.exposureReference = .sensor
        camera.cameraDevelopmentSettings.fbddLevel = 1

        var draft = HDRCameraDevelopmentSettings()
        draft.selectWhiteBalance(.temperature)
        XCTAssertEqual(draft.temperature, 6500)
        XCTAssertEqual(draft.tint, 0)
        draft.temperature = 5000; draft.tint = 17
        let external = draft
        draft = HDRCameraDevelopmentSettings()
        draft = external
        XCTAssertEqual(draft, external)
        draft.selectWhiteBalance(.temperature)
        XCTAssertEqual(draft, external)
        draft.selectWhiteBalance(.asShot)
        XCTAssertEqual(draft.whiteBalance, .asShot)
        XCTAssertEqual(draft.temperature, 0)
        XCTAssertEqual(draft.tint, 0)

        camera.geometry.cropWidth = 0.75
        camera.cameraDevelopmentSettings.lensDistortion = true
        camera.cameraDevelopmentSettings.lensTCA = true
        camera.cameraDevelopmentSettings.lensAutoCrop = false
        camera.cameraDevelopmentSettings.lensProfile = "test-lens"
        let reference = camera.neutralGeometrySettings
        XCTAssertEqual(reference.geometry, camera.geometry)
        XCTAssertTrue(reference.cameraDevelopmentSettings.lensDistortion)
        XCTAssertTrue(reference.cameraDevelopmentSettings.lensTCA)
        XCTAssertFalse(reference.cameraDevelopmentSettings.lensAutoCrop)
        XCTAssertEqual(reference.cameraDevelopmentSettings.lensProfile, "test-lens")
        XCTAssertEqual(reference.cameraDevelopmentSettings.whiteBalance, .asShot)
        XCTAssertEqual(reference.cameraDevelopmentSettings.fbddLevel, 0)
        XCTAssertEqual(reference.cameraDevelopmentSettings.exposureReference, .metadata)

        let cameraJSON = try encoder.encode(camera)
        let decodedCamera = try JSONDecoder().decode(HDRSettings.self, from: cameraJSON)
        XCTAssertEqual(decodedCamera, camera)
        XCTAssertEqual(decodedCamera.recordVersion, 8)
        XCTAssertEqual(decodedCamera.processingVersion, 1)
        XCTAssertFalse(decodedCamera.isIdentity)
        camera.reset()
        XCTAssertEqual(camera.recordVersion, 8)
        XCTAssertTrue(camera.isIdentity)

        let data = try encoder.encode(settings)
        let restoredRecord = try JSONDecoder().decode(HDRSettings.self, from: data)
        XCTAssertEqual(restoredRecord, settings)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("record_version"))
        XCTAssertTrue(text.contains("hdr_processing_version"))
        XCTAssertFalse(text.contains("headroom"))
        XCTAssertFalse(text.contains("preview"))

        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        unknown["record_version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: unknown))) { error in
            XCTAssertTrue(error is DecodingError)
        }

        var invalid = settings
        invalid.exposure = .nan
        XCTAssertFalse(invalid.isValid)
        invalid = settings
        invalid.exposure = 5
        XCTAssertFalse(invalid.isValid)

        var initial = HDRSettings()
        initial.exposure = 2; initial.contrast = -25; initial.highlights = 50; initial.geometry.quarterTurns = 2
        let enabled = try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: true)
        XCTAssertEqual(enabled.exposure, 2)
        XCTAssertEqual(enabled.contrast, -25)
        XCTAssertEqual(enabled.highlights, 50)
        XCTAssertEqual(enabled.geometry.quarterTurns, 2)
        XCTAssertEqual(enabled.temperature, 6500)
        XCTAssertEqual(enabled.tint, 0)

        XCTAssertThrowsError(try HDRSettings.enabling(stored: nil, initial: initial, sourceIsHDR: false)) { error in
            XCTAssertEqual(error as? HDRSettings.ModeError, .unsupportedSource)
        }

        settings.mode = .sdr
        let restored = try HDRSettings.enabling(stored: settings, initial: initial, sourceIsHDR: true)
        XCTAssertEqual(restored.mode, .hdr)
        XCTAssertEqual(restored.exposure, settings.exposure)
        XCTAssertEqual(restored.tint, 42)
        var reset = restored
        reset.reset()
        XCTAssertEqual(reset.mode, .hdr)
        XCTAssertTrue(reset.isIdentity)

        XCTAssertEqual(restoredRecord.recordVersion, 1)
        XCTAssertTrue(restoredRecord.toneSettings.isDefault)
        XCTAssertFalse(text.contains("\"tone\""))

        var tone = restoredRecord
        tone.toneSettings.blackPoint = -36.5
        tone.toneSettings.whitePoint = 20
        tone.toneSettings.curveStrength = 33
        tone.toneSettings.curve = .init(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)])
        let toneData = try encoder.encode(tone)
        let toneRestored = try JSONDecoder().decode(HDRSettings.self, from: toneData)
        XCTAssertEqual(toneRestored, tone)
        XCTAssertEqual(toneRestored.recordVersion, 2)
        XCTAssertEqual(toneRestored.processingVersion, 2)

        var wrongVersion = try XCTUnwrap(JSONSerialization.jsonObject(with: toneData) as? [String: Any])
        wrongVersion["record_version"] = 1
        wrongVersion["hdr_processing_version"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: wrongVersion))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        tone.reset()
        XCTAssertTrue(tone.isIdentity)
        XCTAssertEqual(tone.processingVersion, 2)
        XCTAssertTrue(tone.toneSettings.isDefault)

        var color = restoredRecord
        color.colorSettings.vibrance = 33.5
        color.colorSettings.hsl.setExact(.hue, channel: 0, value: -21.25)
        color.colorSettings.grading.highlights.hue = 220
        let colorData = try encoder.encode(color)
        let colorRestored = try JSONDecoder().decode(HDRSettings.self, from: colorData)
        XCTAssertEqual(colorRestored, color)
        XCTAssertEqual(colorRestored.processingVersion, 3)
        XCTAssertTrue(colorRestored.toneSettings.isDefault)

        var invalidColorRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: colorData) as? [String: Any])
        invalidColorRecord.removeValue(forKey: "tone")
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: invalidColorRecord))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        color.reset()
        XCTAssertTrue(color.isIdentity)
        XCTAssertEqual(color.processingVersion, 3)
        XCTAssertTrue(color.colorSettings.isDefault)

        var rendition = colorRestored
        rendition.renditionSettings.peakLimitEV = 2
        rendition.renditionSettings.sdrExposureEV = -0.5
        rendition.renditionSettings.sdrContrast = 25
        rendition.renditionSettings.sdrSaturation = -15
        let renditionData = try encoder.encode(rendition)
        let renditionRestored = try JSONDecoder().decode(HDRSettings.self, from: renditionData)
        XCTAssertEqual(renditionRestored, rendition)
        XCTAssertEqual(renditionRestored.recordVersion, 4)
        XCTAssertTrue(colorRestored.renditionSettings.isDefault)

        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: renditionData) as? [String: Any])
        for field in ["tone", "color", "rendition"] {
            var incomplete = record
            incomplete.removeValue(forKey: field)
            XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: incomplete))) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
        rendition.reset()
        XCTAssertTrue(rendition.isIdentity)
        XCTAssertEqual(rendition.processingVersion, 4)
        XCTAssertTrue(rendition.renditionSettings.isDefault)

        var effects = renditionRestored
        effects.effectsSettings.vignetteAmount = -55
        effects.effectsSettings.grainAmount = 40
        let effectsData = try encoder.encode(effects)
        let effectsRestored = try JSONDecoder().decode(HDRSettings.self, from: effectsData)
        XCTAssertEqual(effectsRestored, effects)
        XCTAssertEqual(effectsRestored.recordVersion, 5)
        XCTAssertTrue(renditionRestored.effectsSettings.isDefault)
        effects.effectsSettings.reset(vignette: true)
        XCTAssertEqual(effects.effectsSettings.vignetteAmount, 0)
        XCTAssertEqual(effects.effectsSettings.grainAmount, 40)
        effects.reset()
        XCTAssertTrue(effects.isIdentity)
        XCTAssertEqual(effects.processingVersion, 5)
        XCTAssertTrue(effectsRestored.detailSettings.isDefault)

        var detail = HDRSettings()
        detail.detailSettings = .init(sharpening: 1.5, clarity: 0.45, dehaze: -0.5, denoise: 0.75)
        let detailData = try encoder.encode(detail)
        let restoredDetail = try JSONDecoder().decode(HDRSettings.self, from: detailData)
        XCTAssertEqual(restoredDetail, detail)
        XCTAssertEqual(restoredDetail.recordVersion, 6)
        let detailJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: detailData) as? [String: Any])
        for invalidDetail in [[:], ["sharpening": 1.5, "clarity": 0.45, "dehaze": -0.5, "denoise": 1.25]] {
            var changed = detailJSON
            changed["detail"] = invalidDetail
            let broken = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: broken)) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
        detail.reset()
        XCTAssertTrue(detail.isIdentity)
        XCTAssertEqual(detail.processingVersion, 6)

        var look = restoredDetail
        let fingerprint = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        look.lookSettings = .init(sha256: fingerprint, name: "Fixture", strength: 0.8)
        let lookData = try encoder.encode(look)
        let reopenedLook = try JSONDecoder().decode(HDRSettings.self, from: lookData)
        XCTAssertEqual(reopenedLook, look)
        XCTAssertEqual(reopenedLook.processingVersion, 7)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = try XCTUnwrap(reopenedLook.lookSettings.asset(in: directory))
        XCTAssertFalse(reopenedLook.lookSettings.assetIsAvailable(in: directory))
        try Data("abc".utf8).write(to: resource)
        XCTAssertTrue(reopenedLook.lookSettings.assetIsAvailable(in: directory))
        try Data("abcd".utf8).write(to: resource)
        XCTAssertFalse(reopenedLook.lookSettings.assetIsAvailable(in: directory))
        look.reset()
        XCTAssertTrue(look.isIdentity)
        XCTAssertEqual(look.processingVersion, 7)
    }

    func testFreeEndpointXRequiresProcessingVersion10() throws {
        var freeY = HDRSettings()
        freeY.toneSettings.curve = ToneCurveSettings(mode: .custom, points: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.9)])
        XCTAssertEqual(freeY.processingVersion, 9)
        XCTAssertEqual(freeY.recordVersion, 10)

        var freeX = HDRSettings()
        freeX.toneSettings.curve.channels.green = ToneCurveShape(mode: .custom, points: [.init(x: 0.1, y: 0), .init(x: 0.9, y: 1)])
        XCTAssertEqual(freeX.processingVersion, 10)
        XCTAssertEqual(freeX.recordVersion, 11)
        let encoded = try JSONEncoder().encode(freeX)
        XCTAssertEqual(try JSONDecoder().decode(HDRSettings.self, from: encoded), freeX)

        // 声称 v9 却带端点 x 内移的记录是不一致数据，必须拒绝而不是静默改写版本号。
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["hdr_processing_version"] = 9
        object["record_version"] = 10
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: object)))
        object["hdr_processing_version"] = 11
        object["record_version"] = 12
        XCTAssertThrowsError(try JSONDecoder().decode(HDRSettings.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
