import XCTest

@MainActor
struct EditorRobot {
    let app: XCUIApplication

    func waitForCondition(timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(100_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for editor condition: \(app.debugDescription)")
    }

    func returnToOverviewIfInTool() {
        let cancel = app.buttons["editor.draft.cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
            waitForCondition(timeout: 10) { app.scrollViews["editor.groups"].exists || app.buttons["editor.export"].exists }
        }
    }

    func selectGroup(_ group: String) {
        returnToOverviewIfInTool()
        let button = app.buttons["editor.group.\(group)"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        let groups = app.scrollViews["editor.groups"]
        if groups.exists {
            for _ in 0..<8 where !button.isHittable || !groups.frame.contains(CGPoint(x: button.frame.midX, y: button.frame.midY)) {
                if button.frame.midX < groups.frame.midX { groups.swipeRight() } else { groups.swipeLeft() }
            }
        }
        waitForCondition(timeout: 15) { button.isEnabled && button.isHittable }
        if !button.isSelected {
            button.tap()
        }
    }

    func openTool(_ tool: String, in group: String? = nil) {
        returnToOverviewIfInTool()
        if let group, !app.buttons["tool.\(tool)"].exists {
            selectGroup(group)
        }
        let toolButton = app.buttons["tool.\(tool)"]
        XCTAssertTrue(toolButton.waitForExistence(timeout: 10), app.debugDescription)
        let strip = app.scrollViews["editor.tools"]
        if strip.exists {
            for _ in 0..<8 where !toolButton.isHittable || !strip.frame.contains(CGPoint(x: toolButton.frame.midX, y: toolButton.frame.midY)) {
                if toolButton.frame.midX < strip.frame.midX { strip.swipeRight() } else { strip.swipeLeft() }
            }
        }
        waitForCondition(timeout: 10) { toolButton.isEnabled && toolButton.isHittable }
        toolButton.tap()
        XCTAssertTrue(app.scrollViews["editor.panel"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func dragRuler(increasing: Bool = true) {
        let ruler = app.descendants(matching: .any)["adjustment.ruler"].firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 10), app.debugDescription)
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = ruler.coordinate(withNormalizedOffset: CGVector(dx: increasing ? 0.78 : 0.22, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    func applyDraft() {
        let apply = app.buttons["editor.draft.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), app.debugDescription)
        waitForCondition(timeout: 10) { apply.isEnabled }
        apply.tap()
        waitForCondition(timeout: 15) { !apply.exists && app.scrollViews["editor.tools"].exists }
    }

    func cancelDraft() {
        let cancel = app.buttons["editor.draft.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        waitForCondition(timeout: 15) { !cancel.exists && app.scrollViews["editor.tools"].exists }
    }

    func undoDraft() {
        let undo = app.buttons["editor.draft.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5) && undo.isEnabled, app.debugDescription)
        undo.tap()
    }

    func redoDraft() {
        let redo = app.buttons["editor.draft.redo"]
        XCTAssertTrue(redo.waitForExistence(timeout: 5) && redo.isEnabled, app.debugDescription)
        redo.tap()
    }

    func resetDraft() {
        let reset = app.buttons["editor.draft.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5) && reset.isEnabled, app.debugDescription)
        reset.tap()
    }

    func toggleFineMode() {
        let more = app.buttons["editor.tool.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let fine = app.switches["editor.fine"].firstMatch
        if fine.waitForExistence(timeout: 5) {
            fine.tap()
        } else {
            let fineBtn = app.buttons["editor.fine"].firstMatch
            XCTAssertTrue(fineBtn.waitForExistence(timeout: 5), app.debugDescription)
            fineBtn.tap()
        }
    }

    func openExportMenu() {
        returnToOverviewIfInTool()
        let exportButton = app.buttons["editor.export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 15), app.debugDescription)
        waitForCondition(timeout: 20) { exportButton.isEnabled }
        exportButton.tap()
    }

    func openExportSheet() {
        openExportMenu()
        let saveItem = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Save Current Photo", "保存当前照片"]
        )).firstMatch
        XCTAssertTrue(saveItem.waitForExistence(timeout: 10), app.debugDescription)
        waitForCondition(timeout: 10) { saveItem.isEnabled && saveItem.isHittable }
        saveItem.tap()
        XCTAssertTrue(app.buttons["editor.export.confirm"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func exportCurrentPhotoToLibrary(longEdge: Int? = nil) {
        openExportSheet()
        if let longEdge {
            let picker = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Export Size", "导出尺寸"
            )).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            picker.tap()
            let custom = app.buttons.matching(NSPredicate(
                format: "label IN %@", ["Specify long edge", "指定长边"]
            )).firstMatch
            XCTAssertTrue(custom.waitForExistence(timeout: 5), app.debugDescription)
            custom.tap()
            let field = app.textFields.matching(NSPredicate(
                format: "label IN %@", ["Export Long Edge (Pixels)", "导出长边像素"]
            )).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            field.tap()
            field.typeText("\(longEdge)")
        }
        let confirm = app.buttons["editor.export.confirm"]
        waitForCondition(timeout: 10) { confirm.isEnabled && confirm.isHittable }
        confirm.tap()
        let importer = LibraryImportRobot(app: app)
        let saved = app.alerts.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["Saved to Photos.", "已保存到照片。"]
        )).firstMatch
        waitForCondition(timeout: 90) {
            importer.dismissPhotosPermissionIfNeeded()
            return saved.exists
        }
        let close = app.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["Close", "关闭"]
        )).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        waitForCondition(timeout: 15) { !saved.exists && app.buttons["editor.export"].isEnabled }
    }

    func openProcessingSettings() {
        returnToOverviewIfInTool()
        let importer = LibraryImportRobot(app: app)
        importer.openMenuAction(labels: ["Photo processing settings", "照片处理设置"])
        waitForCondition(timeout: 10) {
            app.switches["hdr.editMode"].exists || app.descendants(matching: .any)["x3f.mode"].exists
        }
    }

    func closeProcessingSettings() {
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        waitForCondition(timeout: 10) { !close.exists }
    }
}
