import XCTest

@MainActor
final class ImportAndDocumentSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testEmptyEditorAndFilesPickerCancelReopenSmoke() throws {
        let robot = LibraryImportRobot.launch(language: "en")
        robot.assertEmptyEditor()
        robot.openFilesPickerFromEmptyOrMenu()
        robot.cancelSystemPicker()
        robot.assertEmptyEditor()

        XCUIDevice.shared.orientation = .landscapeLeft
        robot.openFilesPickerFromEmptyOrMenu()
        robot.cancelSystemPicker()
        robot.assertEmptyEditor()
    }

    func testDocumentAndUnreadableLookDeleteSurvivesRestartSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_UI"] == "1" else {
            throw XCTSkip("Run document-import-ui.sh on a dedicated simulator with seeded unreadable looks")
        }
        let robot = LibraryImportRobot.launch(language: "en")
        robot.importFirstSeededPhoto()
        let editor = EditorRobot(app: robot.app)
        editor.openTool("film", in: "looks")

        let unreadable = robot.app.buttons["looks.unreadable"]
        XCTAssertTrue(unreadable.waitForExistence(timeout: 10), robot.app.debugDescription)
        unreadable.tap()
        let deleteButton = robot.app.buttons.matching(identifier: "looks.deleteUnreadable").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), robot.app.debugDescription)
        deleteButton.tap()
        robot.app.alerts.buttons["looks.deleteUnreadable.confirm"].firstMatch.tap()
        robot.app.buttons["Done"].tap()

        robot.app.terminate()
        robot.app.launch()
        robot.importFirstSeededPhoto()
        editor.openTool("film", in: "looks")
        XCTAssertFalse(robot.app.buttons["looks.unreadable"].exists)
    }

    func testRecentPhotoFilterRestartAndResetSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_RECENT_UI"] == "1" else {
            throw XCTSkip("Run recent-photo-ui.sh on a dedicated simulator with seeded photo")
        }
        let robot = LibraryImportRobot.launch(language: "en")
        robot.importFirstSeededPhoto()
        let editor = EditorRobot(app: robot.app)
        editor.openTool("exposure", in: "light")
        editor.dragRuler()
        editor.applyDraft()

        robot.openRecents()
        let rows = robot.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recents.photo."))
        robot.waitForCondition(timeout: 10) { rows.count == 1 }
        robot.app.segmentedControls["recents.filter"].buttons["Edited"].tap()
        XCTAssertEqual(rows.count, 1)

        robot.app.terminate()
        robot.app.launch()
        robot.openRecents()
        robot.app.segmentedControls["recents.filter"].buttons["Edited"].tap()
        robot.waitForCondition(timeout: 10) { rows.count == 1 }
        rows.firstMatch.tap()
        editor.openTool("exposure", in: "light")
        editor.resetDraft()
        editor.applyDraft()
    }
}
