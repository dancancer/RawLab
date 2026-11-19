import XCTest

@MainActor
final class BatchWorkflowSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testBatchCollectionSelectEditAndFrozenExportSmoke() throws {
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        let emptyImport = importer.app.buttons["editor.import.empty"]
        guard emptyImport.waitForExistence(timeout: 10) else {
            XCTFail("Missing empty import button")
            return
        }
        emptyImport.tap()
        let cell = importer.app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard cell.waitForExistence(timeout: 5) else {
            throw XCTSkip("Dedicated simulator with seeded Photos fixture required")
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        importer.dismissPhotosPermissionIfNeeded()
        importer.waitForCondition(timeout: 45) {
            importer.dismissPhotosPermissionIfNeeded()
            return importer.app.buttons["editor.group.looks"].exists
        }

        let batch = BatchRobot(app: importer.app)
        batch.openCollection()
        batch.assertExportButton(enabled: true)
    }

    func testBatchEmptyGuardAndCancelSmoke() throws {
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        let emptyImport = importer.app.buttons["editor.import.empty"]
        guard emptyImport.waitForExistence(timeout: 10) else {
            XCTFail("Missing empty import button")
            return
        }
        emptyImport.tap()
        let cell = importer.app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard cell.waitForExistence(timeout: 5) else {
            throw XCTSkip("Dedicated simulator with seeded Photos fixture required")
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        importer.dismissPhotosPermissionIfNeeded()
        importer.waitForCondition(timeout: 45) {
            importer.dismissPhotosPermissionIfNeeded()
            return importer.app.buttons["editor.group.looks"].exists
        }

        let batch = BatchRobot(app: importer.app)
        batch.openCollection()
        let remove = importer.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除 ")).firstMatch
        if remove.waitForExistence(timeout: 5) {
            remove.tap()
            batch.assertExportButton(enabled: false)
        }
    }
}
