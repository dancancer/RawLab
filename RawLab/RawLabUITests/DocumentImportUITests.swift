import XCTest

final class DocumentImportUITests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_UI"] == "1" else {
            throw XCTSkip("Use document-import-ui.sh with a dedicated simulator")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFilesPickerCanBeCancelledAndReopened() {
        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        cancelPicker(in: app)
        openMenuImport("editor.import.file", in: app)
        cancelPicker(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openMenuImport("editor.import.file", in: app)
        cancelPicker(in: app)
        XCTAssertTrue(app.buttons["editor.import.empty"].exists)
    }

    func testLookPickerCanBeCancelledAndReopened() {
        let app = launchEditor()
        openMenuImport("editor.import.look", in: app)
        cancelPicker(in: app)
        openMenuImport("editor.import.file", in: app)
        cancelPicker(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openMenuImport("editor.import.look", in: app)
        cancelPicker(in: app)
    }

    func testFilesImportUsesPhotoContents() {
        if ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_RAW"] == "1" {
            assertPhotoImports("RawLabRawAsJPEG.jpeg")
        }
        assertPhotoImports("RawLabRasterAsRaw.arw")
        assertPhotoImports("RawLabPhotoWithoutExtension")

        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        selectFile("RawLabTextAsJPEG.jpeg", in: app)
        let unsupported = app.alerts["RawLab"].firstMatch.staticTexts["Selected Item Is Not a Supported Image."].firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["editor.photo"].exists)
    }

    private func assertPhotoImports(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = launchEditor()
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertFalse(photo.exists, file: file, line: line)
        app.buttons["editor.import.file"].tap()
        selectFile(name, in: app)
        let alert = app.alerts["RawLab"].firstMatch
        waitUntil(timeout: 60, file: file, line: line) { photo.exists || alert.exists }
        XCTAssertTrue(photo.exists, "\(name) did not reach the editor. \(app.debugDescription)", file: file, line: line)
    }

    func testPhotoAndLookSelectionsReachTheirOwnImports() {
        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        selectFile("RawLabImportFixture.png", in: app)
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 60), app.debugDescription)
        waitUntil { app.buttons["tool.film"].isEnabled }
        app.buttons["tool.film"].tap()
        let addLook = app.buttons["looks.import"]
        XCTAssertTrue(addLook.waitForExistence(timeout: 10), app.debugDescription)
        addLook.tap()
        selectFile("RawLabImportFixture.cube", in: app)
        let film = app.buttons["tool.film"]
        waitUntil { film.value as? String == "RawLabImportFixture" }
        XCTAssertEqual(film.value as? String, "RawLabImportFixture", "The selected LUT must reach the look handler")
        XCTAssertTrue(photo.exists, "Importing a LUT must preserve the current photo")
        openMenuImport("editor.import.file", in: app)
        cancelPicker(in: app)
        XCTAssertEqual(film.value as? String, "RawLabImportFixture")
        XCTAssertTrue(photo.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "photo-and-lut-imported"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCompatibilityCancellationAllowsAnotherLookImport() {
        let app = launchEditor()
        openMenuImport("editor.import.look", in: app)
        selectFile("RawLabUnknownLook.cube", in: app)
        let confirm = app.buttons["look.compatibility.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["Cancel"].firstMatch.tap()
        waitUntil { !confirm.exists }
        openMenuImport("editor.import.look", in: app)
        cancelPicker(in: app)
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.privacy"].waitForExistence(timeout: 20), app.debugDescription)
        waitUntil { app.buttons["editor.import"].isEnabled }
        return app
    }

    private func openMenuImport(_ identifier: String, in app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        let menu = app.collectionViews.containing(.button, identifier: identifier).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        let item = menu.buttons[identifier]
        waitUntil { item.isEnabled }
        func viewport() -> CGRect {
            let width = menu.frame.width
            return app.otherElements.containing(.button, identifier: identifier).allElementsBoundByIndex
                .map(\.frame)
                .filter { abs($0.width - width) < 1 && $0.height > 44 }
                .min { $0.height < $1.height } ?? menu.frame.intersection(app.frame)
        }
        // 原生菜单会把滚动区域外的行也报为可点击，必须先确认实际可见范围。
        for _ in 0..<4 {
            let visible = viewport().insetBy(dx: 0, dy: 8)
            if visible.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { break }
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.75))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.25))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(viewport().contains(CGPoint(x: item.frame.midX, y: item.frame.midY)), app.debugDescription)
        XCTAssertTrue(item.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "menu-before-" + identifier
        screenshot.lifetime = .keepAlways
        add(screenshot)
        item.tap()
    }

    private func cancelPicker(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
        cancel.tap()
        waitUntil { !cancel.exists }
    }

    private func selectFile(_ name: String, in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
        let local = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My ")).firstMatch
        if !local.exists {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
        }
        if local.waitForExistence(timeout: 5) {
            local.tap()
        } else {
            let location = app.buttons.matching(NSPredicate(format: "label IN %@", ["On My iPad", "On My iPhone"])).firstMatch
            XCTAssertTrue(location.waitForExistence(timeout: 10), app.debugDescription)
            location.tap()
        }
        let folder = app.cells.matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@",
                                                   "RawLab", "RawLab, ")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        let url = URL(fileURLWithPath: name)
        let identifiers = ["\(url.deletingPathExtension().lastPathComponent), \(url.pathExtension)",
                           "\(name), \(url.pathExtension)"]
        let predicate = url.pathExtension.isEmpty
            ? NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", name, name + ", ")
            : NSPredicate(format: "identifier IN %@", identifiers)
        let file = app.cells.matching(predicate).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The selected file type must be accepted by the picker")
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        waitUntil { !file.exists }
    }

    private func waitUntil(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }
}
