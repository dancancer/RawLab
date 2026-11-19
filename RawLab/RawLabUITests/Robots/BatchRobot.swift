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
        XCTAssertTrue(app.buttons["collection.photos"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func addFirstSeededPhotoFromPhotos() {
        let photosButton = app.buttons["collection.photos"]
        XCTAssertTrue(photosButton.waitForExistence(timeout: 10), app.debugDescription)
        photosButton.tap()
        let importer = LibraryImportRobot(app: app)
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), app.debugDescription)
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons.matching(NSPredicate(format: "label IN %@", ["Add", "添加"])).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        importer.dismissPhotosPermissionIfNeeded()
    }

    func assertExportButton(enabled: Bool) {
        let export = app.buttons["collection.export"]
        for _ in 0..<4 where !export.exists || !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && export.isEnabled != enabled {
            usleep(100_000)
        }
        XCTAssertEqual(export.isEnabled, enabled, app.debugDescription)
    }

    func startCollectionExport() {
        let export = app.buttons["collection.export"]
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10) && export.isEnabled, app.debugDescription)
        export.tap()
    }
}
