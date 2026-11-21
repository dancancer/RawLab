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
            "Allow Full Access", "Allow Access to All Photos", "Allow Add Photos", "Allow",
            "允许完全访问", "允许访问所有照片", "允许添加照片", "允许添加", "允许",
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

    func openMenuAction(identifier: String? = nil, labels: [String] = []) {
        openOverflowMenu()
        let predicate: NSPredicate
        if let identifier, !labels.isEmpty {
            predicate = NSPredicate(format: "identifier == %@ OR label IN %@", identifier, labels)
        } else if let identifier {
            predicate = NSPredicate(format: "identifier == %@", identifier)
        } else {
            predicate = NSPredicate(format: "label IN %@", labels)
        }
        let item = app.buttons.matching(predicate).firstMatch
        let menu = app.collectionViews.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5) || item.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !item.exists || !item.isHittable {
            if menu.exists { menu.swipeUp() } else { break }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        waitForCondition(timeout: 5) { item.isEnabled && item.isHittable }
        item.tap()
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
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        waitForCondition(timeout: 10) { !cancel.exists }
    }

    func openLocalRawLabDocumentsFolder() {
        let action = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Save", "取消", "存储"])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 12), app.debugDescription)
        let folder = app.cells.matching(NSPredicate(
            format: "identifier == %@ OR identifier BEGINSWITH %@",
            "RawLab", "RawLab, "
        )).firstMatch
        let local = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS[c] %@ OR label CONTAINS[c] %@)",
            "DOC.sidebar.item.", "iPhone", "iPad"
        )).firstMatch
        let location = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["On My iPad", "On My iPhone", "我的 iPad", "我的 iPhone"]
        )).firstMatch
        if !folder.exists && !local.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.exists && browse.isHittable { browse.tap() }
        }
        waitForCondition(timeout: 10) { folder.exists || local.exists || location.exists }
        if !folder.exists {
            if local.exists {
                local.tap()
            } else {
                XCTAssertTrue(location.exists, app.debugDescription)
                location.tap()
            }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        waitForCondition(timeout: 10) { folder.isHittable }
        folder.tap()
        if !folder.waitForNonExistence(timeout: 2) && folder.exists && folder.isHittable {
            folder.doubleTap()
        }
        waitForCondition(timeout: 10) { !folder.exists }
    }

    func selectDocumentFromRawLabFolder(_ name: String) {
        openLocalRawLabDocumentsFolder()
        selectFileCell(named: name)
    }

    func importFileFromRawLabFolder(_ name: String) {
        openFilesPickerFromEmptyOrMenu()
        selectDocumentFromRawLabFolder(name)
        waitForCondition(timeout: 60) {
            dismissPhotosPermissionIfNeeded()
            return app.descendants(matching: .any)["editor.photo"].exists || app.buttons["editor.group.looks"].exists
        }
    }

    func importFileFromDownloadsIfPresent(stem: String) -> Bool {
        openFilesPickerFromEmptyOrMenu()
        let action = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 12), app.debugDescription)
        let local = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS[c] %@ OR label CONTAINS[c] %@)",
            "DOC.sidebar.item.", "iPad", "iPhone"
        )).firstMatch
        if !local.waitForExistence(timeout: 5) {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.exists && browse.isHittable { browse.tap() }
        }
        guard local.waitForExistence(timeout: 8) else {
            cancelSystemPicker()
            return false
        }
        local.tap()
        let downloads = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@",
            "Downloads", "下载项"
        )).firstMatch
        guard downloads.waitForExistence(timeout: 8) else {
            cancelSystemPicker()
            return false
        }
        downloads.tap()
        let file = fileCell(named: stem)
        guard file.waitForExistence(timeout: 8) else {
            cancelSystemPicker()
            return false
        }
        file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        waitForCondition(timeout: 60) {
            dismissPhotosPermissionIfNeeded()
            return app.descendants(matching: .any)["editor.photo"].exists || app.buttons["editor.group.looks"].exists
        }
        return true
    }

    func saveDocumentToRawLabFolder() {
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 12), app.debugDescription)
        openLocalRawLabDocumentsFolder()
        waitForCondition(timeout: 5) { save.isEnabled && save.isHittable }
        save.tap()
        waitForCondition(timeout: 15) { !save.exists }
    }

    private func fileCell(named name: String) -> XCUIElement {
        let url = URL(fileURLWithPath: name)
        if url.pathExtension.isEmpty {
            return app.cells.matching(NSPredicate(
                format: "identifier == %@ OR identifier BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                name, name + ", ", name + ".", name + ","
            )).firstMatch
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let identifiers = ["\(stem), \(ext)", "\(name), \(ext)", name]
        return app.cells.matching(NSPredicate(
            format: "identifier IN %@ OR label == %@",
            identifiers, name
        )).firstMatch
    }

    private func selectFileCell(named name: String) {
        let file = fileCell(named: name)
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "Selected file \(name) must be enabled in picker")
        file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        waitForCondition(timeout: 15) { !file.exists }
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
