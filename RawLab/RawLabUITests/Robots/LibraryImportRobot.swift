import XCTest

@MainActor
struct LibraryImportRobot {
    let app: XCUIApplication

    @discardableResult
    static func launch(language: String = "en", arguments: [String] = [], environment: [String: String] = [:]) -> LibraryImportRobot {
        let app = XCUIApplication()
        let locale = language == "zh-Hans" ? "zh_CN" : "en_US"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-RawLab.language", language] + arguments
        for (k, v) in environment {
            app.launchEnvironment[k] = v
        }
        app.launch()
        return LibraryImportRobot(app: app)
    }

    func waitForCondition(timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(100_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition: \(app.debugDescription)")
    }

    func assertEmptyEditor(importButtonTitle: String? = nil) {
        let emptyImport = app.buttons["editor.import.empty"]
        XCTAssertTrue(emptyImport.waitForExistence(timeout: 10), app.debugDescription)
        if let importButtonTitle {
            XCTAssertEqual(emptyImport.label, importButtonTitle)
        }
        XCTAssertTrue(app.buttons["editor.import"].isEnabled)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        XCTAssertFalse(app.buttons["tool.film"].exists)
    }

    func importFirstSeededPhoto() {
        let emptyImport = app.buttons["editor.import.empty"]
        if emptyImport.waitForExistence(timeout: 5) {
            emptyImport.tap()
        } else {
            app.buttons["editor.import"].tap()
        }
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "Seeded simulator photo missing: \(app.debugDescription)")
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        dismissPhotosPermissionIfNeeded()
        waitForCondition(timeout: 45) {
            dismissPhotosPermissionIfNeeded()
            return app.descendants(matching: .any)["editor.photo"].exists || app.buttons["editor.group.looks"].exists
        }
    }

    @discardableResult
    func dismissPhotosPermissionIfNeeded() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", [
            "Allow Full Access", "Allow Access to All Photos", "Allow",
            "允许完全访问", "允许访问所有照片", "允许",
        ])).firstMatch
        if allow.exists {
            allow.tap()
            return true
        }
        return false
    }

    func openOverflowMenu() {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 15), app.debugDescription)
        waitForCondition(timeout: 10) { privacy.isHittable }
        privacy.tap()
    }

    func openFilesPickerFromEmptyOrMenu() {
        let direct = app.buttons["editor.import.file"]
        if direct.exists && direct.isHittable {
            direct.tap()
            return
        }
        openOverflowMenu()
        XCTAssertTrue(direct.waitForExistence(timeout: 5), app.debugDescription)
        revealInMenu(direct)
        direct.tap()
    }

    func cancelSystemPicker() {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        waitForCondition(timeout: 10) { !cancel.exists }
    }

    func openRecents() {
        let emptyRecents = app.buttons["recents.open.empty"]
        if emptyRecents.exists && emptyRecents.isHittable {
            emptyRecents.tap()
            return
        }
        openOverflowMenu()
        let item = app.buttons["recents.open"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        revealInMenu(item)
        item.tap()
    }

    func revealInMenu(_ element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable {
            let container = app.collectionViews.firstMatch
            if container.exists {
                container.swipeUp()
            } else {
                break
            }
        }
    }
}
