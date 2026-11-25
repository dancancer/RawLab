import CoreGraphics
import Foundation
import XCTest
@testable import RawLabKit

final class InspectionSuiteTests: XCTestCase {
    func testColorSampleMemberwiseAndTextFormatting() {
        let sample = InspectionColorSample(
            r: 255,
            g: 128,
            b: 0,
            hueDeg: 30.1,
            saturationPct: 100.0,
            brightnessPct: 100.0,
            luminance: 0.568
        )
        XCTAssertEqual(sample.rgbText, "255 128 0")
        XCTAssertEqual(sample.hsbText, "30° 100% 100%")
    }

    func testInspectionSessionStateMax4AnchorsAndTransientGrayToggle() {
        var session = InspectionSessionState()
        for i in 0..<4 {
            XCTAssertNotNil(session.pinAnchor(atSourcePoint: CGPoint(x: 0.1 * Double(i + 1), y: 0.5)))
        }
        XCTAssertFalse(session.canPinMore)
        XCTAssertNil(session.pinAnchor(atSourcePoint: CGPoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(session.anchors.count, 4)

        session.selectOverlay(.warmCoolBW)
        session.toggleNeutralGray50()
        XCTAssertEqual(session.overlay, .neutralGray50)
        session.toggleNeutralGray50()
        XCTAssertEqual(session.overlay, .warmCoolBW)

        session.toggleNeutralGray50()
        XCTAssertTrue(session.handleEscape())
        XCTAssertEqual(session.overlay, .warmCoolBW)
        XCTAssertTrue(session.handleEscape())
        XCTAssertEqual(session.overlay, .none)

        session.resetForNewSource()
        XCTAssertTrue(session.anchors.isEmpty)
        XCTAssertEqual(session.overlay, .none)
    }

    private func canonicalSortedJSON(_ raw: String) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [])
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    func testZeroEditStateAndCanonicalRecipePollution() throws {
        var rawSettings = RawSettings.default
        rawSettings.exposure = 0.4
        rawSettings.contrast = 1.12
        rawSettings.geometry = GeometrySettings(cropX: 0.1, cropY: 0.1, cropWidth: 0.8, cropHeight: 0.8, quarterTurns: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baseState = PhotoEditState(settings: rawSettings, filmID: "PROVIA")
        let baseData = try encoder.encode(baseState)
        let recipeState = CanonicalEditRecipe.State(
            processing: .current,
            x3fMode: .normal,
            exposureMode: "preview",
            isRaster: false,
            geometry: rawSettings.geometrySettings
        )
        let baseRecipe = try canonicalSortedJSON(CanonicalEditRecipe.encode(recipeState))

        var session = InspectionSessionState()
        for mode in InspectionOverlayMode.allCases {
            session.selectOverlay(mode)
            _ = session.pinAnchor(atSourcePoint: CGPoint(x: 0.4, y: 0.6))
            let stateData = try encoder.encode(baseState)
            let recipeAfter = try canonicalSortedJSON(CanonicalEditRecipe.encode(recipeState))
            XCTAssertEqual(stateData, baseData)
            XCTAssertEqual(recipeAfter, baseRecipe)
        }
    }
}
