import XCTest

final class X3fRenderingUITests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["RAWLAB_X3F_UI"] == "1" else { throw XCTSkip("Dedicated X3F simulator only") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.privacy"].waitForExistence(timeout: 20))
        return app
    }

    func testModeSwitchExportAndReopen() throws {
        let app = try launch()
        importFile(app, stem: "X3F-Normal")
        ready(app)
        showContext(app)
        XCTAssertTrue(mode(app).label.contains("正常显影") || (mode(app).value as? String)?.contains("正常显影") == true, app.debugDescription)
        capture(app, "x3f-normal-context")
        selectMode(app, "伪红外（旧版）")
        closeContext(app); ready(app); capture(app, "x3f-legacy-preview")
        showContext(app); selectMode(app, "正常显影"); closeContext(app); ready(app)
        capture(app, "x3f-normal-preview")
        exportPhoto(app, captureName: "x3f-exported")
        app.terminate(); app.launch()
        importFile(app, stem: "X3F-Normal"); ready(app); showContext(app)
        XCTAssertTrue(mode(app).label.contains("正常显影") || (mode(app).value as? String)?.contains("正常显影") == true, app.debugDescription)
        capture(app, "x3f-normal-reopened")
    }

    func testLegacyLensCorrectionSwitchesToNormal() throws {
        let app = try launch()
        importFile(app, stem: "X3F-Lens"); ready(app)
        showLensTool(app)
        XCTAssertTrue(app.buttons["tool.lens"].isEnabled)
        XCTAssertEqual(app.buttons["tool.lens"].value as? String, "已调整")
        closeDraft(app)
        showContext(app)
        XCTAssertTrue(mode(app).label.contains("伪红外") || (mode(app).value as? String)?.contains("伪红外") == true)
        capture(app, "x3f-legacy-with-lens")
        selectMode(app, "正常显影"); closeContext(app); ready(app)
        showLensTool(app)
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled)
        capture(app, "x3f-normal-lens-disabled")
        closeDraft(app)
        exportPhoto(app, captureName: "x3f-lens-switch-exported")
        app.terminate(); app.launch()
        importFile(app, stem: "X3F-Lens"); ready(app); showContext(app)
        XCTAssertTrue(mode(app).label.contains("正常显影") || (mode(app).value as? String)?.contains("正常显影") == true)
        closeContext(app); showLensTool(app)
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled)
        capture(app, "x3f-lens-switch-reopened")
    }

    private func showLensTool(_ app: XCUIApplication) {
        if !app.buttons["tool.lens"].exists { app.buttons["editor.group.geometry"].tap() }
        XCTAssertTrue(app.buttons["tool.lens"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func closeDraft(_ app: XCUIApplication) {
        let cancel = app.buttons["editor.draft.cancel"]
        if cancel.exists { cancel.tap(); ready(app) }
    }

    private func exportPhoto(_ app: XCUIApplication, captureName: String) {
        app.buttons["editor.export"].tap()
        let save = app.buttons["保存当前照片"]
        XCTAssertTrue(save.waitForExistence(timeout: 15)); save.tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15)); confirm.tap()
        let saved = app.alerts.staticTexts["已保存到照片。"]
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons.matching(NSPredicate(format: "label IN %@", ["允许添加照片", "允许添加", "允许", "Allow Add Photos", "Allow"])).firstMatch
        wait {
            if allow.exists { allow.tap() }
            return saved.exists
        }
        capture(app, captureName)
        app.alerts.buttons["关闭"].tap()
    }

    func testFailedNormalImportOffersLegacyAfterRestart() throws {
        let app = try launch()
        importFile(app, stem: "X3F-Unsupported")
        let retry = app.buttons["x3f.retryLegacy"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 90), app.debugDescription)
        capture(app, "x3f-first-import-recovery")
        retry.tap(); ready(app); showContext(app)
        selectMode(app, "正常显影"); closeContext(app)
        XCTAssertTrue(app.buttons["editor.preview.retry"].waitForExistence(timeout: 90), app.debugDescription)
        // 等待普通编辑持久化，再验证失败的已保存模式也不会封死恢复入口。
        Thread.sleep(forTimeInterval: 1)
        app.terminate(); app.launch()
        importFile(app, stem: "X3F-Unsupported")
        XCTAssertTrue(retry.waitForExistence(timeout: 90), app.debugDescription)
        retry.tap(); ready(app); showContext(app)
        XCTAssertTrue(mode(app).label.contains("伪红外") || (mode(app).value as? String)?.contains("伪红外") == true, app.debugDescription)
        capture(app, "x3f-reopened-legacy-recovery")
    }

    private func importFile(_ app: XCUIApplication, stem: String) {
        let stem = stem + "-" + ProcessInfo.processInfo.environment["RAWLAB_X3F_UI_RUN_ID"]!
        app.buttons["editor.privacy"].tap()
        app.collectionViews.buttons["editor.import.file"].firstMatch.tap()
        let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), app.debugDescription); browse.tap()
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "iPhone")).firstMatch
        if !local.waitForExistence(timeout: 3) { browse.tap() }
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription); local.tap()
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "RawLab")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15), app.debugDescription); folder.tap()
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", stem, stem)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription); file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
    }
    private func ready(_ app: XCUIApplication) { wait { app.buttons["editor.export"].isEnabled && app.buttons["editor.compare"].isEnabled } }
    private func showContext(_ app: XCUIApplication) {
        app.buttons["editor.privacy"].tap(); app.buttons["照片处理设置"].tap()
        XCTAssertTrue(mode(app).waitForExistence(timeout: 15), app.debugDescription)
    }
    private func mode(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "x3f.mode").firstMatch }
    private func selectMode(_ app: XCUIApplication, _ title: String) {
        mode(app).tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription); option.tap()
    }
    private func closeContext(_ app: XCUIApplication) { app.buttons["关闭"].firstMatch.tap() }
    private func wait(_ condition: @escaping () -> Bool) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 120)
        XCTAssertEqual(result, .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
