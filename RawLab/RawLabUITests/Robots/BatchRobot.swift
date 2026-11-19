import XCTest

@MainActor
struct BatchRobot {
    let app: XCUIApplication

    func openCollection() {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), app.debugDescription)
        privacy.tap()
        let collection = app.buttons["collection.open"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5), app.debugDescription)
        collection.tap()
    }

    func assertExportButton(enabled: Bool) {
        let export = app.buttons["collection.export"]
        for _ in 0..<3 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(export.isEnabled, enabled, app.debugDescription)
    }

    func startCollectionExport() {
        let export = app.buttons["collection.export"]
        for _ in 0..<3 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10) && export.isEnabled, app.debugDescription)
        export.tap()
    }
}
