import XCTest

@MainActor
final class EditorWorkflowSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchWithSeededPhoto(language: String = "en", arguments: [String] = []) throws -> (LibraryImportRobot, EditorRobot) {
        let importer = LibraryImportRobot.launch(language: language, arguments: arguments)
        let emptyImport = importer.app.buttons["editor.import.empty"]
        guard emptyImport.waitForExistence(timeout: 10) else {
            XCTFail("Missing empty import button")
            return (importer, EditorRobot(app: importer.app))
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
            return importer.app.descendants(matching: .any)["editor.photo"].exists || importer.app.buttons["editor.group.looks"].exists
        }
        return (importer, EditorRobot(app: importer.app))
    }

    func testWorkbenchGroupsToolsDraftApplyCancelUndoRedoResetSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto()
        editor.openTool("exposure", in: "light")
        let valueButton = editor.app.buttons["adjustment.value"]
        let before = valueButton.value as? String
        editor.dragRuler(increasing: true)
        let dragged = valueButton.value as? String
        XCTAssertNotEqual(dragged, before)
        editor.undoDraft()
        editor.redoDraft()
        editor.cancelDraft()

        editor.openTool("exposure", in: "light")
        XCTAssertEqual(valueButton.value as? String, before)
        editor.dragRuler(increasing: true)
        editor.applyDraft()
        editor.openTool("exposure", in: "light")
        editor.resetDraft()
        editor.applyDraft()
    }

    func testParameterRulerNumericWheelAndFineModeSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto()
        editor.openTool("exposure", in: "light")
        editor.toggleFineMode()
        let value = editor.app.buttons["adjustment.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        let applyWheel = editor.app.buttons["adjustment.wheel.apply"]
        if applyWheel.waitForExistence(timeout: 5) {
            editor.app.buttons["adjustment.wheel.default"].tap()
            applyWheel.tap()
        }
        editor.cancelDraft()
    }

    func testLooksSearchRecentAndMasterRecipeSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto()
        editor.openTool("film", in: "looks")
        let search = editor.app.textFields["looks.search"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("ACROS\n")
            let acros = editor.app.buttons["ACROS"]
            if acros.waitForExistence(timeout: 5) { acros.tap() }
        }
        editor.applyDraft()

        editor.openTool("recipe", in: "looks")
        editor.cancelDraft()
    }

    func testToneCurveHslGradingEffectsAndCropLockSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto()
        for (group, tool) in [("light", "toneCurve"), ("color", "hsl"), ("color", "colorGrading"), ("effects", "vignette"), ("geometry", "geometry")] {
            editor.openTool(tool, in: group)
            XCTAssertTrue(editor.app.scrollViews["editor.panel"].exists)
            editor.cancelDraft()
        }
    }

    func testPortraitLandscapeAndAccessibilityLayoutSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"])
        editor.openTool("exposure", in: "light")
        XCTAssertTrue(editor.app.buttons["editor.draft.apply"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.app.scrollViews["editor.panel"].waitForExistence(timeout: 10))
        editor.cancelDraft()
    }

    func testExportPrivacyAndAboutNavigationSmoke() throws {
        let (importer, editor) = try launchWithSeededPhoto()
        editor.openExportSheet()
        XCTAssertTrue(editor.app.buttons["editor.export.confirm"].waitForExistence(timeout: 10))
        editor.app.buttons["Cancel"].firstMatch.tap()

        importer.openOverflowMenu()
        let usage = importer.app.switches["usage.consent"]
        if usage.waitForExistence(timeout: 5) {
            XCTAssertTrue(usage.isHittable)
        }
    }
}
