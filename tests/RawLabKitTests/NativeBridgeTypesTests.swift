import Foundation
import XCTest
@testable import RawLabKit
@testable import RawLabNativeTypes

final class NativeBridgeTypesTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabNativeTypesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testAtmosphereHSLAndToneControlsNativeConfigs() {
        let atmosphere = AtmosphereSettings(clarity: 35, dehaze: -20)
        let atmConfig = atmosphere.nativeConfig
        XCTAssertEqual(atmConfig.version, UInt32(SONY2FUJI_ATMOSPHERE_CONFIG_VERSION))
        XCTAssertEqual(atmConfig.struct_size, UInt32(MemoryLayout<sony2fuji_atmosphere_config>.size))
        XCTAssertEqual(atmConfig.clarity, 0.35, accuracy: 1e-5)
        XCTAssertEqual(atmConfig.dehaze, -0.20, accuracy: 1e-5)

        var hsl = HSLSettings()
        hsl.setExact(.hue, channel: 0, value: 10)
        hsl.setExact(.hue, channel: 4, value: -12)
        hsl.setExact(.saturation, channel: 7, value: 80)
        hsl.setExact(.lightness, channel: 7, value: -50)
        var hslConfig = hsl.nativeConfig
        XCTAssertEqual(hslConfig.version, UInt32(SONY2FUJI_HSL_CONFIG_VERSION))
        XCTAssertEqual(hslConfig.struct_size, UInt32(MemoryLayout<sony2fuji_hsl_config>.size))
        withUnsafeBytes(of: &hslConfig.hue) { bytes in
            XCTAssertEqual(bytes.bindMemory(to: Float.self)[0], 10, accuracy: 1e-5)
            XCTAssertEqual(bytes.bindMemory(to: Float.self)[4], -12, accuracy: 1e-5)
        }
        withUnsafeBytes(of: &hslConfig.saturation) { bytes in
            XCTAssertEqual(bytes.bindMemory(to: Float.self)[7], 80, accuracy: 1e-5)
        }
        withUnsafeBytes(of: &hslConfig.lightness) { bytes in
            XCTAssertEqual(bytes.bindMemory(to: Float.self)[7], -50, accuracy: 1e-5)
        }

        let toneControls = ToneControlsSettings(blackPoint: -25, whitePoint: 40, vibrance: 18)
        let tcConfig = toneControls.nativeConfig
        XCTAssertEqual(tcConfig.version, UInt32(SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION))
        XCTAssertEqual(tcConfig.struct_size, UInt32(MemoryLayout<sony2fuji_tone_controls_config>.size))
        XCTAssertEqual(tcConfig.black_point, -0.25, accuracy: 1e-5)
        XCTAssertEqual(tcConfig.white_point, 0.40, accuracy: 1e-5)
        XCTAssertEqual(tcConfig.vibrance, 0.18, accuracy: 1e-5)
    }

    func testColorGradingNativeConfigAndHueWraparound() {
        let near360 = ColorGradingWheel(hue: 359.9999999, saturation: 25, luminance: -10)
        XCTAssertEqual(near360.nativeHue, 0)

        let wheel360 = ColorGradingWheel(hue: 360, saturation: 40, luminance: 12)
        XCTAssertEqual(wheel360.nativeHue, 0)

        let grading = ColorGradingSettings(
            shadows: ColorGradingWheel(hue: 210, saturation: 30, luminance: -15),
            midtones: near360,
            highlights: ColorGradingWheel(hue: 45, saturation: 20, luminance: 10),
            global: ColorGradingWheel(hue: 120, saturation: 5, luminance: 2),
            blending: 65,
            balance: -18
        )
        let v1 = grading.nativeConfig
        XCTAssertEqual(v1.version, UInt32(SONY2FUJI_COLOR_GRADING_CONFIG_VERSION))
        XCTAssertEqual(v1.struct_size, UInt32(MemoryLayout<sony2fuji_color_grading_config>.size))
        XCTAssertEqual(v1.shadows_hue, 210, accuracy: 1e-5)
        XCTAssertEqual(v1.midtones_hue, 0)
        XCTAssertEqual(v1.highlights_saturation, 20, accuracy: 1e-5)

        let v2 = grading.nativeV2Config
        XCTAssertEqual(v2.version, UInt32(SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION))
        XCTAssertEqual(v2.struct_size, UInt32(MemoryLayout<sony2fuji_color_grading_v2_config>.size))
        XCTAssertEqual(v2.shadows_luminance, -15, accuracy: 1e-5)
        XCTAssertEqual(v2.global_hue, 120, accuracy: 1e-5)
        XCTAssertEqual(v2.global_luminance, 2, accuracy: 1e-5)
        XCTAssertEqual(v2.blending, 65, accuracy: 1e-5)
        XCTAssertEqual(v2.balance, -18, accuracy: 1e-5)
    }

    func testToneCurveNativeConfigsTruncateTo33Points() {
        let manyPoints = (0..<40).map { idx in
            ToneCurvePoint(x: Double(idx) / 39.0, y: Double(idx) / 39.0)
        }
        let shape = ToneCurveShape(mode: .custom, points: manyPoints)
        var shapeConfig = shape.nativeConfig
        XCTAssertEqual(shapeConfig.version, UInt32(SONY2FUJI_TONE_CURVE_CONFIG_VERSION))
        XCTAssertEqual(shapeConfig.struct_size, UInt32(MemoryLayout<sony2fuji_tone_curve_config>.size))
        XCTAssertEqual(shapeConfig.mode, SONY2FUJI_CURVE_CUSTOM)
        XCTAssertEqual(shapeConfig.count, 40)
        withUnsafeBytes(of: &shapeConfig.points) { bytes in
            let pts = bytes.bindMemory(to: sony2fuji_curve_point.self)
            XCTAssertEqual(pts[0].x, 0, accuracy: 1e-6)
            XCTAssertEqual(pts[32].x, 32.0 / 39.0, accuracy: 1e-6)
        }

        let settings = ToneCurveSettings(
            mode: .custom,
            points: manyPoints,
            channels: ToneCurveChannels(),
            applyToLuminosity: true,
            parametric: ToneCurveParametric(highlights: 12, lights: 8, darks: -6, shadows: -14)
        )
        let v2 = settings.nativeSetV2Config
        XCTAssertEqual(v2.version, UInt32(SONY2FUJI_TONE_CURVE_SET_V2_CONFIG_VERSION))
        XCTAssertEqual(v2.struct_size, UInt32(MemoryLayout<sony2fuji_tone_curve_set_v2_config>.size))
        XCTAssertEqual(v2.apply_to_luminosity, 1)
        XCTAssertEqual(v2.parametric.version, UInt32(SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION))
        XCTAssertEqual(v2.parametric.highlights, 12, accuracy: 1e-5)
        XCTAssertEqual(v2.parametric.shadows, -14, accuracy: 1e-5)
    }

    func testDCPCompilerErrorMappingAndImportOptions() {
        let cases: [(sony2fuji_dcp_error, DCPCompilerError)] = [
            (SONY2FUJI_DCP_ERROR_MALFORMED, .malformed),
            (SONY2FUJI_DCP_ERROR_TOO_LARGE, .tooLarge),
            (SONY2FUJI_DCP_ERROR_INVALID_CALIBRATION, .invalidCalibration),
            (SONY2FUJI_DCP_ERROR_MISSING_TONE_CURVE, .missingToneCurve),
            (SONY2FUJI_DCP_ERROR_AUTOMATIC_BLACK, .automaticBlack),
            (SONY2FUJI_DCP_ERROR_TRIPLE_ILLUMINANT, .tripleIlluminant),
            (SONY2FUJI_DCP_ERROR_UNSUPPORTED_STAGES, .unsupportedStages),
            (SONY2FUJI_DCP_ERROR_INVALID_TABLE, .invalidTable),
            (SONY2FUJI_DCP_ERROR_INVALID_TONE_CURVE, .invalidToneCurve),
            (SONY2FUJI_DCP_ERROR_INVALID_EXPOSURE, .invalidExposure),
            (SONY2FUJI_DCP_ERROR_NONE, .malformed),
        ]
        for (reason, expected) in cases {
            let mapped = DCPCompilerError(reason: reason)
            XCTAssertEqual(mapped, expected)
            XCTAssertFalse((mapped.errorDescription ?? "").isEmpty)
        }
        let defaults = DCPImportOptions()
        XCTAssertNil(defaults.toneCurveJSON)
        XCTAssertFalse(defaults.omitAutomaticBlack)
    }

    func testLUTCompatibilityContractsAndLookRegistryCodec() throws {
        let srgbSignal = LUTCompatibilitySignal(space: "srgb", reference: "display", range: "0..1")
        let slogSignal = LUTCompatibilitySignal(space: "slog3-sgamut3", reference: "scene", range: "0..1")
        let displayToScene = LUTCompatibilityContract(
            version: 1, input: srgbSignal, output: slogSignal,
            interpolation: "tetrahedral", baseRendering: "source-display"
        )
        let invalid = LUTCompatibility(sourceSHA256: "abc", contract: displayToScene)
        XCTAssertFalse(invalid.hasCompleteContract)
        XCTAssertFalse(invalid.canImport)

        var validContract = LUTCompatibilityContract(
            version: 1, input: slogSignal, output: srgbSignal,
            interpolation: "tetrahedral", baseRendering: "none"
        )
        validContract.selectInput("vlog-vgamut")
        XCTAssertEqual(validContract.input.reference, "scene")
        XCTAssertEqual(validContract.baseRendering, "none")

        let compat = LUTCompatibility(sourceSHA256: "abc", contract: validContract, photoStyle: "vlog", extremeValues: true)
        XCTAssertTrue(compat.hasCompleteContract)
        XCTAssertFalse(compat.canImport)
        var confirmed = compat
        confirmed.confirmedExtremeValues = true
        XCTAssertTrue(confirmed.canImport)
        XCTAssertTrue(confirmed.supportsPreview(displayInput: false))
        XCTAssertFalse(confirmed.supportsPreview(displayInput: true))

        let displayCandidate = LUTCompatibilityCandidate(
            id: "cand1",
            contract: LUTCompatibilityContract(
                version: 1, input: srgbSignal, output: srgbSignal,
                interpolation: "tetrahedral", baseRendering: "rawlab-neutral-v1"
            ),
            basis: "file-parameters",
            assumptions: ["neutral-base"]
        )
        let displayCompat = LUTCompatibility(sourceSHA256: "abc", contract: validContract, photoStyle: "std", extremeValues: false)
        let appliedDisplay = displayCompat.applying(displayCandidate, displayInput: true)
        XCTAssertEqual(appliedDisplay?.contract.baseRendering, "source-display")
        XCTAssertTrue(appliedDisplay?.supportsPreview(displayInput: true) == true)

        let id1 = UUID().uuidString
        let look = UserLook(id: id1, name: "Film A", fileName: "\(id1).cube", sourceName: "film.cube", format: "cube", formatVersion: 0)
        XCTAssertTrue(LookRegistryCodec.isValid(look))

        let registryURL = temporaryRoot.appendingPathComponent("registry.json")
        let broken = LookLibraryUnreadableLook(id: "bad-id", fileName: "bad.cube", json: "{\"id\":\"bad-id\",\"fileName\":\"bad.cube\",\"name\":\"Broken\"}")
        let encoded = try LookRegistryCodec.encodeRegistry(looks: [look], unreadable: [broken])
        try encoded.write(to: registryURL)

        let parsed = try LookRegistryCodec.readRegistry(at: registryURL)
        XCTAssertEqual(parsed.looks, [look])
        XCTAssertEqual(parsed.unreadable, [broken])
        XCTAssertEqual(broken.displayName, "Broken")

        try Data("{\"version\":2,\"looks\":[]}".utf8).write(to: registryURL)
        XCTAssertThrowsError(try LookRegistryCodec.readRegistry(at: registryURL))
    }
}
