import XCTest

final class AdjustmentRulerEnabledUITests: XCTestCase {
    func testHostedDisabledRulerRejectsSystemKeysAndTouch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.ruler-enabled")
        app.launchEnvironment["RAWLAB_RULER_UI_MODE"] = "1"
        app.launch()
        let ruler = app.descendants(matching: .any)["ruler.enabled.regression"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        print("AX_ENABLED: type=\(ruler.elementType.rawValue) enabled=\(ruler.isEnabled) hittable=\(ruler.isHittable)")
        XCTAssertTrue(ruler.isEnabled)
        let from = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        let to = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
        from.press(forDuration: 0.05, thenDragTo: to)
        let initial = try XCTUnwrap(Double(app.staticTexts["ruler.value"].label))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertEqual(try XCTUnwrap(Double(app.staticTexts["ruler.value"].label)), initial + 1)
        app.buttons["ruler.lockSoon"].tap()
        to.press(forDuration: 0.05, thenDragTo: from,
                 withVelocity: XCUIGestureVelocity(rawValue: 40), thenHoldForDuration: 0.1)
        XCTAssertTrue(app.staticTexts["ruler.locked"].waitForExistence(timeout: 3))
        let locked = NSPredicate(format: "label == %@", "true")
        expectation(for: locked, evaluatedWith: app.staticTexts["ruler.locked"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["ruler.editingAtLock"].label, "true", "Lock must happen during an actual pan")
        XCTAssertEqual(app.staticTexts["ruler.editing"].label, "false", "Disable must cancel the in-flight pan")
        let writes = app.staticTexts["ruler.writes"].label
        let value = app.staticTexts["ruler.value"].label
        XCTAssertEqual(writes, app.staticTexts["ruler.lockedWrites"].label)
        XCTAssertEqual(value, app.staticTexts["ruler.lockedValue"].label)
        print("AX_DISABLED: type=\(ruler.elementType.rawValue) enabled=\(ruler.isEnabled) hittable=\(ruler.isHittable)")
        print(app.debugDescription)
        XCTAssertFalse(ruler.isEnabled, "SwiftUI must export the disabled state to the actual AX node")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertEqual(app.staticTexts["ruler.writes"].label, writes)
        XCTAssertEqual(app.staticTexts["ruler.value"].label, value)
        app.buttons["ruler.unlock"].tap()
        XCTAssertTrue(ruler.isEnabled)
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertNotEqual(app.staticTexts["ruler.writes"].label, writes)
    }
}
