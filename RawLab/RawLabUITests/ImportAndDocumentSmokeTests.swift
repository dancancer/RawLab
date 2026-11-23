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

    func testDocumentImportLookAndErrorLogSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_UI"] == "1" else {
            throw XCTSkip("Run document-import-ui.sh on a dedicated simulator with seeded Documents fixtures")
        }
        let robot = LibraryImportRobot.launch(language: "en")
        robot.assertEmptyEditor()

        let rejectedFile = "RawLabTextAsJPEG.jpeg"
        let unsupported = robot.app.staticTexts["Selected Item Is Not a Supported Image."].firstMatch

        robot.openMenuAction(identifier: "collection.open", labels: ["Batch editing"])
        let collectionFiles = robot.app.buttons["collection.files"]
        XCTAssertTrue(collectionFiles.waitForExistence(timeout: 10), robot.app.debugDescription)
        collectionFiles.tap()
        robot.selectDocumentFromRawLabFolder(rejectedFile)
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), robot.app.debugDescription)
        robot.app.buttons["Close"].firstMatch.tap()

        robot.importFileFromRawLabFolder("RawLabImportFixture.png")
        let editor = EditorRobot(app: robot.app)
        editor.waitForCondition(timeout: 30) { robot.app.buttons["editor.export"].isEnabled }

        editor.openTool("film", in: "looks")
        let addLook = robot.app.buttons["looks.import"]
        XCTAssertTrue(addLook.waitForExistence(timeout: 10), robot.app.debugDescription)
        addLook.tap()
        robot.selectDocumentFromRawLabFolder("RawLabImportFixture.cube")
        editor.applyDraft()
        let film = robot.app.buttons["tool.film"]
        robot.waitForCondition(timeout: 15) { film.value as? String == "RawLabImportFixture" }
        XCTAssertTrue(robot.app.descendants(matching: .any)["editor.photo"].exists)

        robot.openMenuAction(identifier: "adjustment.copy.open", labels: ["Copy Adjustments"])
        let copy = robot.app.buttons["adjustment.copy.confirm"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), robot.app.debugDescription)
        robot.revealInMenu(copy)
        robot.waitForCondition(timeout: 5) { copy.isEnabled && copy.isHittable }
        copy.tap()
        robot.waitForCondition(timeout: 10) { !copy.exists }

        robot.openMenuAction(identifier: "adjustment.paste.open", labels: ["Paste Adjustments"])
        let pasteFiles = robot.app.buttons["adjustment.paste.chooseFiles"]
        XCTAssertTrue(pasteFiles.waitForExistence(timeout: 10), robot.app.debugDescription)
        pasteFiles.tap()
        robot.selectDocumentFromRawLabFolder(rejectedFile)
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), robot.app.debugDescription)
        robot.app.buttons["adjustment.transfer.close"].tap()

        robot.openMenuAction(identifier: "diagnostics.export", labels: ["Export Error Log"])
        robot.saveDocumentToRawLabFolder()
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
        let deleteButtons = robot.app.buttons.matching(identifier: "looks.deleteUnreadable")
        XCTAssertTrue(deleteButtons.firstMatch.waitForExistence(timeout: 5), robot.app.debugDescription)
        while deleteButtons.count > 0 {
            let remaining = deleteButtons.count
            deleteButtons.element(boundBy: 0).tap()
            let confirm = robot.app.alerts.buttons["looks.deleteUnreadable.confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), robot.app.debugDescription)
            confirm.tap()
            robot.waitForCondition(timeout: 10) { deleteButtons.count < remaining }
        }
        robot.app.buttons["Done"].tap()
        XCTAssertFalse(unreadable.exists)

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
        robot.waitForCondition(timeout: 20) {
            robot.app.descendants(matching: .any)["editor.photo"].exists || robot.app.buttons["editor.group.looks"].exists
        }
        editor.openTool("exposure", in: "light")
        editor.resetDraft()
        editor.applyDraft()

        robot.openRecents()
        robot.waitForCondition(timeout: 10) { rows.count == 0 }
        robot.app.segmentedControls["recents.filter"].buttons["Unedited"].tap()
        robot.waitForCondition(timeout: 10) { rows.count == 1 }
    }

    func testOfflineCameraWorkspaceSmoke() throws {
        let robot = LibraryImportRobot.launch(language: "zh-Hans")
        robot.assertEmptyEditor()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func dismissSystemAlertIfNeeded() {
            for label in ["允许", "好", "OK", "Allow"] {
                let button = springboard.alerts.buttons[label].firstMatch
                if button.exists { button.tap() }
            }
        }
        func capture(_ name: String) {
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let dir = ProcessInfo.processInfo.environment["RAWLAB_CAMERA_SHOT_DIR"], !dir.isEmpty {
                try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        func navigateBack() {
            let back = robot.app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5), robot.app.debugDescription)
            back.tap()
        }

        let openCamera = robot.app.buttons["editor.camera.empty"]
        XCTAssertTrue(openCamera.waitForExistence(timeout: 10), robot.app.debugDescription)
        openCamera.tap()
        dismissSystemAlertIfNeeded()

        XCTAssertTrue(robot.app.descendants(matching: .any)["camera.home"].waitForExistence(timeout: 10), robot.app.debugDescription)
        XCTAssertTrue(robot.app.buttons["camera.entry.import"].exists)
        XCTAssertTrue(robot.app.buttons["camera.entry.tether"].exists)
        XCTAssertTrue(robot.app.buttons["camera.history"].exists)
        capture("01-ios-camera-home")

        robot.app.buttons["camera.entry.import"].tap()
        dismissSystemAlertIfNeeded()
        XCTAssertTrue(robot.app.descendants(matching: .any)["camera.connect"].waitForExistence(timeout: 10), robot.app.debugDescription)
        let connectContinue = robot.app.buttons["camera.connect.continue"]
        XCTAssertTrue(connectContinue.waitForExistence(timeout: 5), robot.app.debugDescription)
        XCTAssertTrue(connectContinue.isEnabled)
        XCTAssertTrue(robot.app.buttons["camera.manual"].exists)
        XCTAssertTrue(robot.app.buttons["camera.help"].exists)
        capture("02-ios-camera-connect-import")

        robot.app.buttons["camera.manual"].tap()
        XCTAssertTrue(robot.app.descendants(matching: .any)["camera.manual.page"].waitForExistence(timeout: 10), robot.app.debugDescription)
        XCTAssertTrue(robot.app.textFields["camera.wifi.ssid"].exists)
        XCTAssertTrue(robot.app.secureTextFields["camera.wifi.password"].exists)
        XCTAssertTrue(robot.app.buttons["camera.wifi.join"].exists)
        XCTAssertFalse(robot.app.buttons["camera.wifi.continue"].exists)
        capture("03-ios-camera-manual-wifi")
        navigateBack()

        XCTAssertTrue(robot.app.buttons["camera.help"].waitForExistence(timeout: 5), robot.app.debugDescription)
        robot.app.buttons["camera.help"].tap()
        XCTAssertTrue(robot.app.descendants(matching: .any)["camera.help.page"].waitForExistence(timeout: 10), robot.app.debugDescription)
        capture("04-ios-camera-help")
        navigateBack()
        navigateBack()

        XCTAssertTrue(robot.app.buttons["camera.entry.tether"].waitForExistence(timeout: 10), robot.app.debugDescription)
        robot.app.buttons["camera.entry.tether"].tap()
        dismissSystemAlertIfNeeded()
        let cardConfirm = robot.app.switches["camera.card.confirm"]
        XCTAssertTrue(cardConfirm.waitForExistence(timeout: 10), robot.app.debugDescription)
        let tetherContinue = robot.app.buttons["camera.connect.continue"]
        XCTAssertTrue(tetherContinue.waitForExistence(timeout: 5), robot.app.debugDescription)
        XCTAssertFalse(tetherContinue.isEnabled)
        capture("05-ios-camera-connect-tether-locked")

        cardConfirm.tap()
        robot.waitForCondition(timeout: 5) { tetherContinue.isEnabled }
        capture("06-ios-camera-connect-tether-confirmed")
        navigateBack()

        XCTAssertTrue(robot.app.buttons["camera.history"].waitForExistence(timeout: 10), robot.app.debugDescription)
        robot.app.buttons["camera.history"].tap()
        capture("07-ios-camera-history")
        navigateBack()

        let storage = robot.app.buttons["保存位置"]
        XCTAssertTrue(storage.waitForExistence(timeout: 10), robot.app.debugDescription)
        storage.tap()
        XCTAssertTrue(robot.app.descendants(matching: .any)["camera.originals.summary"].waitForExistence(timeout: 10), robot.app.debugDescription)
        capture("08-ios-camera-storage")
    }
}
