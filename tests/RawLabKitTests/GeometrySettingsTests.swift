import Foundation
import XCTest
@testable import RawLabKit

final class GeometrySettingsTests: XCTestCase {
    func testGeometryMigrationBoundsResetAndValidation() throws {
        var settings = Adjustments()
        XCTAssertTrue(
            settings.geometry == nil && settings.geometrySettings.isIdentity && settings.isDefault(.geometry),
            "new edits keep the full original canvas"
        )

        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        XCTAssertTrue(
            legacy.geometry == nil && legacy.geometrySettings.isIdentity && legacy.exposureMode == .scene,
            "old records retain their exposure interpretation and identity geometry"
        )

        let partial = try JSONDecoder().decode(Adjustments.self, from: Data("{\"geometry\":{\"quarterTurns\":1}}".utf8))
        XCTAssertTrue(
            partial.geometrySettings.quarterTurns == 1 && partial.geometrySettings.cropWidth == 1 &&
                partial.geometrySettings.cropHeight == 1 && !partial.geometrySettings.flipHorizontal,
            "missing geometry fields use identity values"
        )

        settings.setGeometry(.cropWidth, to: 0.6)
        settings.setGeometry(.cropHeight, to: 0.7)
        settings.setGeometry(.cropX, to: 0.2)
        settings.setGeometry(.cropY, to: 0.1)
        settings.rotateGeometry(clockwise: true)
        settings.flipGeometry(horizontal: true)
        settings.flipGeometry(horizontal: false)
        settings.setGeometry(.straightenDegrees, to: -7.5)
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored == settings && !restored.isDefault(.geometry), "every geometry setting survives JSON")

        let neutral = settings.neutralGeometrySettings
        XCTAssertTrue(
            neutral.geometrySettings == settings.geometrySettings && neutral.exposure == 0 && neutral.masterRecipeID == nil,
            "color comparison uses the same crop and transformed canvas"
        )

        settings.setGeometry(.cropX, to: 1)
        XCTAssertTrue(
            settings.geometrySettings.cropX == 1 - settings.geometrySettings.cropWidth && settings.geometrySettings.isValid,
            "moving the crop cannot extend its right edge beyond the canvas"
        )

        settings.setGeometry(.cropWidth, to: 1)
        XCTAssertTrue(
            settings.geometrySettings.cropWidth == 1 - settings.geometrySettings.cropX && settings.geometrySettings.isValid,
            "expanding the crop retains its valid origin"
        )

        settings.setGeometry(.cropHeight, to: 0)
        settings.setGeometry(.cropY, to: 1)
        XCTAssertTrue(
            settings.geometrySettings.cropHeight > 0 && settings.geometrySettings.isValid,
            "crop height stays positive at the lower and upper boundaries"
        )

        settings.setGeometry(.straightenDegrees, to: 100)
        XCTAssertEqual(settings.geometrySettings.straightenDegrees, 45, "straightening uses the core angle range")

        let finite = settings
        settings.setGeometry(.cropX, to: .nan)
        settings.setGeometry(.straightenDegrees, to: .infinity)
        XCTAssertEqual(settings, finite, "nonfinite numeric edits leave the current crop unchanged")

        settings.reset(.geometry)
        XCTAssertTrue(settings.geometry == nil && settings.isDefault(.geometry), "group reset restores identity")

        for _ in 0..<4 { settings.rotateGeometry(clockwise: false) }
        XCTAssertNil(settings.geometry, "four left turns return to identity")

        settings.rotateGeometry(clockwise: true)
        settings.rotateGeometry(clockwise: false)
        XCTAssertNil(settings.geometry, "left and right turns cancel")

        settings.flipGeometry(horizontal: true)
        settings.flipGeometry(horizontal: true)
        XCTAssertNil(settings.geometry, "two flips return to identity")

        settings.rotateGeometry(clockwise: true)
        settings.resetAll()
        XCTAssertTrue(settings.geometry == nil && settings.isDefault, "reset all includes geometry")

        for record in [
            "{\"cropX\":0.8,\"cropWidth\":0.5}",
            "{\"cropWidth\":0}",
            "{\"quarterTurns\":4}",
            "{\"straightenDegrees\":46}",
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(Adjustments.self, from: Data("{\"geometry\":\(record)}".utf8)),
                "Invalid saved geometry accepted: \(record)"
            ) { error in
                if case DecodingError.dataCorrupted = error {
                    return
                }
                XCTFail("Expected DecodingError.dataCorrupted for \(record), got \(error)")
            }
        }
    }

    func testGeometrySixLanguageLocalizationKeys() throws {
        let keys = [
            "几何编辑", "几何", "裁切、旋转、翻转和拉直", "水平翻转", "垂直翻转", "重置几何编辑",
            "向右旋转 90°", "向左旋转 90°", "裁切左边", "裁切上边", "裁切宽度", "裁切高度", "拉直",
            "裁切位置和尺寸按旋转、翻转与拉直后的画布百分比设置。", "无效的几何参数",
        ]
        let resources = RawLabKitTestSupport.repoRoot.appendingPathComponent("RawLabMac/Resources")
        for language in ["en", "zh-Hans", "de", "fr", "ja", "es"] {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let strings = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]
            )
            for key in keys {
                XCTAssertEqual(strings[key]?.isEmpty, false, "\(language): geometry key \(key)")
            }
        }
    }
}
