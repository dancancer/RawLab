import XCTest
@testable import RawLabKit

final class CanonicalEditRecipeTests: XCTestCase {
    func testEncodeRawSettingsProducesCanonicalV7JSON() throws {
        var settings = RawSettings.default
        settings.processing = .c5
        settings.x3fMode = .legacy
        settings.exposureMode = .scene
        settings.toneControls = ToneControlsSettings(blackPoint: 25, whitePoint: -15, vibrance: 30)
        settings.atmosphere = AtmosphereSettings(clarity: 40, dehaze: -20)
        settings.toneCurveConfig = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)],
            channels: ToneCurveChannels(
                red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.55), .init(x: 1, y: 1)]),
                green: ToneCurveShape(),
                blue: ToneCurveShape()
            )
        )
        settings.colorGrading = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 210, saturation: 35),
            midtones: ColorGradingWheel(hue: 45, saturation: 12),
            highlights: ColorGradingWheel(hue: 350, saturation: 20)
        )
        settings.hsl.setExact(.hue, channel: 0, value: 18)
        settings.geometry = GeometrySettings(
            cropX: 0.1, cropY: 0.2, cropWidth: 0.7, cropHeight: 0.6,
            quarterTurns: 1, flipHorizontal: true, flipVertical: false,
            straightenDegrees: -3.5, perspectiveHorizontal: 0.25, perspectiveVertical: -0.15
        )
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false, mode: .manual, profileID: "lens-123", vignetting: true)
        settings.photoEffects = PhotoEffectsSettings(vignetteAmount: -40, grainAmount: 30)
        settings.denoise = RawDenoiseSettings(enabled: true, luma: 15, chroma: 60, coarse: 70)
        settings.displayChromaDenoise = 1

        let json = try settings.canonicalParamsJSON(isRaster: false)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schema_version"] as? Int, 7)
        XCTAssertEqual(root["x3f_mode"] as? String, "legacy")

        let processing = try XCTUnwrap(root["processing"] as? [String: Any])
        XCTAssertEqual(processing["family"] as? String, "rawlab")
        XCTAssertEqual(processing["version"] as? Int, 2)
        XCTAssertEqual(processing["quality"] as? String, "standard")

        let edits = try XCTUnwrap(root["edits"] as? [String: Any])
        let exposure = try XCTUnwrap(edits["exposure"] as? [String: Any])
        XCTAssertEqual(exposure["mode"] as? String, "scene")

        let tone = try XCTUnwrap(edits["tone"] as? [String: Any])
        XCTAssertEqual(tone["black_point"] as? Double ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertEqual(tone["white_point"] as? Double ?? 0, -0.15, accuracy: 1e-6)

        let curve = try XCTUnwrap(tone["curve"] as? [String: Any])
        XCTAssertEqual(curve["mode"] as? String, "custom")
        XCTAssertNotNil(curve["channels"])

        let color = try XCTUnwrap(edits["color"] as? [String: Any])
        XCTAssertEqual(color["vibrance"] as? Double ?? 0, 0.30, accuracy: 1e-6)

        let effects = try XCTUnwrap(edits["effects"] as? [String: Any])
        XCTAssertEqual(effects["clarity"] as? Double ?? 0, 0.40, accuracy: 1e-6)
        XCTAssertEqual(effects["dehaze"] as? Double ?? 0, -0.20, accuracy: 1e-6)
        XCTAssertEqual(effects["vignette_amount"] as? Double ?? 0, -40, accuracy: 1e-6)

        let lens = try XCTUnwrap(edits["lens_correction"] as? [String: Any])
        XCTAssertEqual(lens["profile_id"] as? String, "lens-123")
        XCTAssertEqual(lens["vignetting"] as? Bool, true)
    }

    func testEncodeAdjustmentsRasterOmitsX3fAndForcesSensorExposure() throws {
        var adjustments = Adjustments()
        adjustments.processing = .legacy
        adjustments.exposureMode = .preview
        adjustments.rawNoiseReduction = 2
        adjustments.lensCorrection = LensCorrectionSettings(distortion: true, tca: false, autoCrop: true, mode: .automatic)

        let json = try adjustments.canonicalParamsJSON(isRaster: true)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schema_version"] as? Int, 5)
        XCTAssertNil(root["x3f_mode"])

        let input = try XCTUnwrap(root["input"] as? [String: Any])
        XCTAssertEqual(input["type"] as? String, "raster")

        let edits = try XCTUnwrap(root["edits"] as? [String: Any])
        let exposure = try XCTUnwrap(edits["exposure"] as? [String: Any])
        XCTAssertEqual(exposure["mode"] as? String, "sensor")
        let wb = try XCTUnwrap(edits["white_balance"] as? [String: Any])
        XCTAssertEqual(wb["mode"] as? String, "none")
        let denoise = try XCTUnwrap(edits["denoise"] as? [String: Any])
        XCTAssertEqual(denoise["raw_level"] as? Int, 0)
        let lens = try XCTUnwrap(edits["lens_correction"] as? [String: Any])
        XCTAssertNil(lens["profile_id"])
    }

    func testUnpinnedCurveEndpointsEmitSchemaVersion17WhilePinnedStaysLegacy() throws {
        var pinned = RawSettings.default
        pinned.toneCurveConfig = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)]
        )
        let pinnedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(pinned.canonicalParamsJSON(isRaster: false).data(using: .utf8))
        ) as? [String: Any])
        XCTAssertEqual(pinnedRoot["schema_version"] as? Int, 7)

        let pinnedRasterRoot = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(pinned.canonicalParamsJSON(isRaster: true).data(using: .utf8))
        ) as? [String: Any])
        XCTAssertEqual(pinnedRasterRoot["schema_version"] as? Int, 5)

        var unpinnedMaster = RawSettings.default
        unpinnedMaster.toneCurveConfig = ToneCurveSettings(
            mode: .custom,
            points: [.init(x: 0, y: 0.2), .init(x: 1, y: 0.8)]
        )
        let unpinnedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(unpinnedMaster.canonicalParamsJSON(isRaster: false).data(using: .utf8))
        ) as? [String: Any])
        XCTAssertEqual(unpinnedRoot["schema_version"] as? Int, 17)

        var unpinnedChannel = RawSettings.default
        unpinnedChannel.toneCurveConfig = ToneCurveSettings(
            channels: ToneCurveChannels(
                red: ToneCurveShape(mode: .custom, points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)])
            )
        )
        let channelRoot = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(unpinnedChannel.canonicalParamsJSON(isRaster: true).data(using: .utf8))
        ) as? [String: Any])
        XCTAssertEqual(channelRoot["schema_version"] as? Int, 17)
    }
}
