import XCTest
import UIKit

final class ParameterInputUITests: XCTestCase {
    func testGradingZoneSelectionKeepsPendingHueAndPreciseInputWrapsEndpoint() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en", "-Grading"]; app.launch()
        let hue = app.buttons["grading.hue.value"]
        XCTAssertTrue(hue.waitForExistence(timeout: 10))
        app.buttons["grading.zone.midtones"].tap()
        app.buttons["grading.zone.shadows"].tap()
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "0")
        XCTAssertEqual(app.staticTexts["fixture.gradingHue"].label, "231.25")
        XCTAssertEqual(hue.value as? String, "231.25 °", "An off-grid pending hue remains readable without rounding")
        hue.tap()
        let picker = app.pickerWheels.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let title = String(describing: picker.value!).components(separatedBy: ",")[0]
        picker.adjust(toPickerWheelValue: "\(title), 360.0 °")
        app.buttons["adjustment.wheel.apply"].tap()
        XCTAssertEqual(app.staticTexts["fixture.gradingHue"].label, "0.0")
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "1")
        XCTAssertTrue(app.buttons["grading.saturation.value"].isHittable)
    }

    func testCanonicalGridDigitsStayCompactAndPercentApplyDoesNotWrite() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en"]; app.launch()
        let strength = app.buttons["fixture.strength.value"]
        XCTAssertTrue(strength.waitForExistence(timeout: 5)); XCTAssertEqual(strength.value as? String, "29 %")
        strength.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5)); XCTAssertTrue((wheel.value as? String ?? "").hasSuffix(", 29 %"))
        app.buttons["adjustment.wheel.apply"].tap()
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "0", "Unchanged scaled percent keeps its original candidate")
        let exposure = app.buttons["fixture.exposure.value"]; exposure.tap()
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.adjust(toPickerWheelValue: "Exposure, +0.35 EV")
        app.buttons["adjustment.wheel.apply"].tap()
        XCTAssertEqual(exposure.value as? String, "+0.35 EV", "Canonical native picker EV does not expose binary tails")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "canonical-grid-compact-digits"; image.lifetime = .keepAlways; add(image)
    }

    func testRulerMinimumKeepsTicksAcrossBothHalves() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-Endpoint"]; app.launch()
        let ruler = app.descendants(matching: .any)["fixture.endpoint"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        let shot = ruler.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = "ruler-minimum-ticks"; attachment.lifetime = .keepAlways; add(attachment)
        let cg = try XCTUnwrap(shot.image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let factor = Double(cg.width) / ruler.frame.width
        var left = 0, right = 0
        for y in Int(18 * factor)..<Int(34 * factor) {
            for x in 4..<(cg.width - 4) {
                let i = (y * cg.width + x) * 4
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                if abs(r - g) < 8 && abs(g - b) < 8 && r < 220 {
                    if x < cg.width / 2 { left += 1 } else { right += 1 }
                }
            }
        }
        print("PARAMETER_TICKS left=\(left) right=\(right) size=\(cg.width)x\(cg.height)")
        XCTAssertGreaterThan(left, 20, "Minimum cannot leave half of the ruler blank")
        XCTAssertGreaterThan(right, 20)
    }

    func testSameValueNewSourceDismissesOldInputWithoutWriting() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en"]; app.launch()
        let value = app.buttons["hsl.hue.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        app.buttons["fixture.changeSourceSoon"].tap()
        value.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.adjust(toPickerWheelValue: "\(String(describing: wheel.value!).components(separatedBy: ",")[0]), +1")
        let changed = NSPredicate(format: "label == 'true'")
        expectation(for: changed, evaluatedWith: app.staticTexts["fixture.sourceChanged"])
        waitForExpectations(timeout: 15)
        let dismissed = NSPredicate { _, _ in !app.buttons["adjustment.wheel.apply"].exists }
        expectation(for: dismissed, evaluatedWith: nil); waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["fixture.originalHue"].label, "0.5")
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "0")
    }

    func testCancelThenChangeChannelPreservesOriginal() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en"]; app.launch()
        let value = app.buttons["hsl.hue.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10)); value.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5)); wheel.adjust(toPickerWheelValue: "\(String(describing: wheel.value!).components(separatedBy: ",")[0]), +1")
        app.buttons["adjustment.wheel.cancel"].tap()
        XCTAssertTrue(app.buttons["hsl.channel.1"].waitForExistence(timeout: 5)); app.buttons["hsl.channel.1"].tap()
        XCTAssertEqual(app.buttons["hsl.hue.value"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["fixture.originalHue"].label, "0.5")
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "0")
    }

    func testLegacyHalfValueIsReadableAndUnchangedApplyDoesNotWrite() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en"]
        app.launch()
        let value = app.buttons["hsl.hue.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "legacy-half-row"; screenshot.lifetime = .keepAlways; add(screenshot)
        print("PARAMETER_LEGACY value=\(value.value ?? "nil") original=\(app.staticTexts["fixture.originalHue"].label)")
        XCTAssertEqual(value.value as? String, "+0.5", "A stored half-step must remain distinguishable from 1")
        value.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((app.pickerWheels.firstMatch.value as? String ?? "").contains("0.5"))
        app.buttons["adjustment.wheel.apply"].tap()
        XCTAssertEqual(app.staticTexts["fixture.originalHue"].label, "0.5")
        XCTAssertEqual(app.staticTexts["fixture.writes"].label, "0")
    }

    func testOrdinaryHSLRowsFitOneLineAndNoPerRowFineOrReset() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.parameter-inputs")
        app.launchArguments = ["-RawLab.language", "en"]; app.launch()
        let value = app.buttons["hsl.hue.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        let ruler = app.descendants(matching: .any)["hsl.hue.ruler"]
        print("PARAMETER_ROW value=\(value.frame) ruler=\(ruler.frame) lightness=\(app.buttons["hsl.lightness.value"].frame)")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "parameter-row-layout"; image.lifetime = .keepAlways; add(image)
        XCTAssertLessThanOrEqual(abs(value.frame.midY - ruler.frame.midY), 4, "Ordinary type keeps name, track and value on the same row")
        XCTAssertFalse(app.buttons["hsl.hue.fine"].exists)
        XCTAssertFalse(app.buttons["hsl.hue.reset"].exists)
        XCTAssertTrue(app.buttons["hsl.lightness.value"].isHittable, "All three axes fit the normal phone parameter budget")
        XCTAssertTrue(app.scrollViews["fixture.parameters"].frame.contains(app.buttons["hsl.lightness.value"].frame))
    }
}
