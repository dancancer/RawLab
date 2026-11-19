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

    func selectGroup(_ group: String) {
        let button = app.buttons["editor.group.\(group)"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        waitForCondition(timeout: 15) { button.isEnabled && button.isHittable }
        if !button.isSelected {
            button.tap()
        }
    }

    func openTool(_ tool: String, in group: String? = nil) {
        if let group, !app.buttons["tool.\(tool)"].exists {
            selectGroup(group)
        }
        let toolButton = app.buttons["tool.\(tool)"]
        XCTAssertTrue(toolButton.waitForExistence(timeout: 10), app.debugDescription)
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

    func openExportSheet() {
        let exportButton = app.buttons["editor.export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 15), app.debugDescription)
        waitForCondition(timeout: 20) { exportButton.isEnabled }
        exportButton.tap()
    }
}
