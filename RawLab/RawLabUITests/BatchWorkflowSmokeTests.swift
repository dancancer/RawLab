import XCTest

@MainActor
final class BatchWorkflowSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchAndOpenSeededBatch() throws -> (LibraryImportRobot, BatchRobot) {
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        let emptyImport = importer.app.buttons["editor.import.empty"]
        guard emptyImport.waitForExistence(timeout: 10) else {
            XCTFail("Missing empty import button")
            return (importer, BatchRobot(app: importer.app))
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
        return (importer, batch)
    }

    func testBatchCollectionSelectEditAndFrozenExportSmoke() throws {
        let (_, batch) = try launchAndOpenSeededBatch()
        batch.assertExportButton(enabled: true)
        batch.startCollectionExport()
        XCTAssertTrue(batch.app.buttons["collection.export.start"].waitForExistence(timeout: 10), batch.app.debugDescription)
        batch.app.buttons["collection.export.cancel"].tap()
    }

    func testBatchEmptyGuardAndCancelSmoke() throws {
        let (importer, batch) = try launchAndOpenSeededBatch()
        batch.assertExportButton(enabled: true)

        let remove = importer.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除 ")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), importer.app.debugDescription)
        remove.tap()
        batch.assertExportButton(enabled: false)
    }
}
