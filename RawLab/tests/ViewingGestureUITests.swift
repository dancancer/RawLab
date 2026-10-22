import XCTest

final class ViewingGestureUITests: XCTestCase {
    func testSingleDoubleHoldUseActualNativeTouchSequences() {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.viewing-gesture")
        app.launch()
        let photo = app.images["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let state = app.staticTexts["viewing.state"]
        photo.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "pure=1"), object: state)], timeout: 3), .completed)
        XCTAssertTrue(state.label.contains("pure=1"), "single tap must enter pure preview: \(state.label)")
        photo.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "pure=0"), object: state)], timeout: 3), .completed)
        XCTAssertTrue(state.label.contains("pure=0"))
        photo.doubleTap()
        XCTAssertTrue(state.label.contains("pure=0"), "double tap must not dispatch single tap")
        XCTAssertGreaterThan(Double(app.staticTexts["viewing.zoom"].label) ?? 0, 1.1, "double tap from fit must reach native pixels, not remain at fit")
        photo.press(forDuration: 0.7)
        XCTAssertTrue(state.label.contains("hold=0") && state.label.contains("begin=1") && state.label.contains("end=1"), "hold release must restore and not tap: \(state.label)")
        XCTAssertTrue(state.label.contains("pure=0"))
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(state.label.contains("begin=1"), "pan must not begin a hold")
        photo.pinch(withScale: 1.2, velocity: 1)
        XCTAssertTrue(state.label.contains("pure=0") && state.label.contains("begin=1"), "two-finger zoom must not begin hold or tap")
        photo.doubleTap()
        XCTAssertEqual(Double(app.staticTexts["viewing.zoom"].label) ?? 0, 1, accuracy: 0.001)
        app.buttons["viewing.compare"].tap()
        XCTAssertTrue(app.images["editor.photo.before"].exists, "side by side must expose the neutral pane")
        app.buttons["viewing.wipe"].tap()
        let split = app.descendants(matching: .any).matching(identifier: "editor.compare.split").firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 3))
        let line = split.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        line.press(forDuration: 0.05, thenDragTo: line.withOffset(CGVector(dx: 35, dy: 0)))
        XCTAssertGreaterThan(Double(app.staticTexts["viewing.split"].label) ?? 0, 0.5)
        app.buttons["viewing.center"].tap()
        XCTAssertEqual(Double(app.staticTexts["viewing.split"].label) ?? -1, 0.5)
        app.buttons["viewing.compare"].tap()
        app.buttons["viewing.compare"].tap()
        XCTAssertTrue(split.exists, "close/reopen must restore wipe preference")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }
}
