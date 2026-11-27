import Foundation
import XCTest
@testable import RawLabKit

final class WaveletSettingsTests: XCTestCase {
    func testWaveletSettingsDefaultsPresetsClampingPersistenceResetAndLegacyMigration() throws {
        var settings = Adjustments()
        XCTAssertTrue(!settings.waveletSettings.enabled && settings.isDefault(.detail), "New controls default off")

        settings.applyDenoisePreset(.detail)
        XCTAssertTrue(
            settings.waveletSettings.enabled && settings.waveletSettings.luma == 0 &&
                settings.waveletSettings.chroma == 46 && settings.waveletSettings.coarse == 50,
            "Detail preset"
        )

        settings.setDenoiseParameter(.luma, to: 57)
        XCTAssertTrue(settings.waveletSettings.preset == .custom && settings.waveletSettings.luma == 57, "Manual edit becomes custom")

        let previous = settings.waveletSettings
        settings.setDenoiseEnabled(false)
        XCTAssertTrue(
            !settings.waveletSettings.enabled && settings.waveletSettings.luma == previous.luma &&
                settings.waveletSettings.preset == .custom && settings.isDefault(.detail),
            "Off preserves values and resets output state"
        )

        settings.setDenoiseEnabled(true)
        XCTAssertEqual(settings.waveletSettings.luma, 57, "Re-enabling restores custom values")

        settings.setDenoiseParameter(.chroma, to: 1000)
        XCTAssertEqual(settings.waveletSettings.chroma, 100, "Parameter range clamped")

        let unchanged = settings
        settings.setDenoiseParameter(.chroma, to: .nan)
        XCTAssertEqual(settings, unchanged, "Nonfinite parameter ignored")

        let roundtrip = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundtrip, settings, "All denoise values and preset persist")

        var saved = Adjustments()
        saved.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 65, chroma: 72, coarse: 100, preset: .clean)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.waveletSettings.luma, 65, "Existing saved strengths are not silently rewritten by new presets")

        settings.reset(.detail)
        XCTAssertEqual(settings, Adjustments(), "Detail reset restores canonical defaults")

        for legacyMode in 0...2 {
            var old = Adjustments()
            old.rawNoiseReduction = legacyMode == 0 ? 2 : 0
            old.chromaNoiseReduction = legacyMode
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
            object.removeValue(forKey: "waveletNoiseReduction")
            settings = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(
                settings.waveletNoiseReduction == WaveletDenoiseSettings() && settings.denoiseMode == old.denoiseMode,
                "Missing candidate state retains legacy algorithm \(legacyMode)"
            )
            settings.applyDenoisePreset(.clean)
            XCTAssertTrue(
                settings.rawNoiseReduction == 0 && settings.chromaNoiseReduction == 0 &&
                    settings.waveletSettings.luma == 10 && settings.waveletSettings.chroma == 72,
                "Explicit preset replaces legacy without stacking"
            )
        }

        settings.resolveRawNoiseReductionSupport(false)
        XCTAssertTrue(settings.waveletSettings.enabled, "X-Trans supports new denoise controls")
    }
}
