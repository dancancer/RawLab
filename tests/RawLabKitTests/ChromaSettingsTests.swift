import Foundation
import XCTest
@testable import RawLabKit

final class ChromaSettingsTests: XCTestCase {
    func testChromaSettingsDefaultsMigrationPersistenceResetAndXTransSupport() throws {
        var settings = Adjustments()
        XCTAssertEqual(settings.denoiseMode, 0, "New denoising defaults off")
        XCTAssertEqual(ChromaNoiseReductionMode.allCases.map(\.title), ["停用", "细节优先", "去噪优先"], "Mode labels")

        settings.rawNoiseReduction = 2
        let encoded = try JSONEncoder().encode(settings)
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "chromaNoiseReduction")
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(
            decoded.rawNoiseReduction == 2 && decoded.denoiseMode == 3 && decoded.chromaNoiseReduction == 0,
            "Old FBDD record retains its original meaning"
        )

        settings = decoded
        settings.set(.denoiseMode, to: 1)
        XCTAssertTrue(settings.rawNoiseReduction == 0 && settings.chromaNoiseReduction == 1, "Selecting new mode clears legacy FBDD")

        settings.set(.denoiseMode, to: 2)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.denoiseMode == 2 && restored.rawNoiseReduction == 0, "New mode persists independently")

        settings.reset(.detail)
        XCTAssertTrue(
            settings.denoiseMode == 0 && settings.chromaNoiseReduction == 0 && settings.rawNoiseReduction == 0,
            "Reset clears both legacy and new denoising"
        )
        XCTAssertEqual(settings, Adjustments(), "Reset keeps default state canonical")

        settings.set(.denoiseMode, to: 1)
        settings.resolveRawNoiseReductionSupport(false)
        XCTAssertEqual(settings.denoiseMode, 1, "X-Trans FBDD capability does not disable chroma denoising")
    }
}
