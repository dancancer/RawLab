import XCTest

final class RecentPhotoUITests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_RECENT_UI"] == "1" else {
            throw XCTSkip("Use recent-photo-ui.sh with a dedicated simulator")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testRecentPhotoReopensAfterRestartAndTracksReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        app.launch()
        app.buttons["editor.import.empty"].tap()
        let imported = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 15), "Seed the dedicated simulator with a photo")
        imported.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        wait { app.buttons["editor.compare"].isEnabled }
        app.buttons["editor.group.light"].tap()
        app.buttons["tool.exposure"].tap()
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { app.buttons["recents.open"].isEnabled }
        app.buttons["recents.open"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recents.photo."))
        wait { rows.count == 1 }
        app.segmentedControls["recents.filter"].buttons["Edited"].tap()
        XCTAssertEqual(rows.count, 1)
        app.segmentedControls["recents.filter"].buttons["Unedited"].tap()
        wait { rows.count == 0 }
        app.terminate()
        app.launch()
        app.buttons["recents.open.empty"].tap()
        wait { rows.count == 1 }
        app.segmentedControls["recents.filter"].buttons["Edited"].tap()
        wait { rows.count == 1 }
        capture("recent-edited-after-restart", app)
        rows.firstMatch.tap()
        wait { app.buttons["editor.compare"].isEnabled }
        app.buttons["editor.reset"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Reset All Adjustments")).firstMatch.tap()
        app.alerts.buttons["Reset"].tap()
        wait { app.buttons["recents.open"].isEnabled }
        app.buttons["recents.open"].tap()
        XCTAssertTrue(app.segmentedControls["recents.filter"].buttons["Edited"].isSelected,
                      "Returning from editing preserves the active edit filter")
        wait { rows.count == 0 }
        app.segmentedControls["recents.filter"].buttons["Unedited"].tap()
        wait { rows.count == 1 }
        capture("recent-reset-to-original", app)
        rows.firstMatch.press(forDuration: 1)
        app.buttons["Remove from recently opened"].tap()
        wait { rows.count == 0 }
    }

    private func wait(_ condition: @escaping () -> Bool) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 30)
        XCTAssertEqual(result, .completed, XCUIApplication().debugDescription)
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
