import XCTest

@MainActor
final class EditorWorkflowSmokeTests: XCTestCase {
    private let seedRawStem = "DJI_20250602164503_0444_D"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchWithSeededPhoto(
        language: String = "en",
        arguments: [String] = [],
        preferDownloadsRaw: Bool = true
    ) throws -> (LibraryImportRobot, EditorRobot) {
        let importer = LibraryImportRobot.launch(language: language, arguments: arguments)
        if preferDownloadsRaw, importer.importFileFromDownloadsIfPresent(stem: seedRawStem) {
            return (importer, EditorRobot(app: importer.app))
        }
        let emptyImport = importer.app.buttons["editor.import.empty"]
        guard emptyImport.waitForExistence(timeout: 10) else {
            XCTFail("Missing empty import button")
            return (importer, EditorRobot(app: importer.app))
        }
        emptyImport.tap()
        let cell = importer.app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard cell.waitForExistence(timeout: 5) else {
            throw XCTSkip("Dedicated simulator with seeded Photos/Downloads fixture required")
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
        XCTAssertTrue(valueButton.waitForExistence(timeout: 10), editor.app.debugDescription)
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
        XCTAssertTrue(value.waitForExistence(timeout: 5), editor.app.debugDescription)
        value.tap()
        let cancelWheel = editor.app.buttons["adjustment.wheel.cancel"]
        let applyWheel = editor.app.buttons["adjustment.wheel.apply"]
        XCTAssertTrue(applyWheel.waitForExistence(timeout: 5), editor.app.debugDescription)
        XCTAssertTrue(cancelWheel.waitForExistence(timeout: 5), editor.app.debugDescription)
        let title = editor.app.staticTexts["adjustment.wheel.title"]
        let draft = editor.app.staticTexts["adjustment.wheel.draft"]
        let wheel = editor.app.descendants(matching: .any)["adjustment.wheel"].firstMatch
        let defaultButton = editor.app.buttons["adjustment.wheel.default"]
        if wheel.exists && title.exists && wheel.frame.minY >= title.frame.maxY {
            let headerMidX = (cancelWheel.frame.minX + applyWheel.frame.maxX) / 2
            for element in [title, draft, wheel, defaultButton] where element.exists {
                XCTAssertEqual(element.frame.midX, headerMidX, accuracy: 4.0,
                               "Expected \(element.identifier) to be horizontally centered")
            }
        }
        defaultButton.tap()
        applyWheel.tap()
        editor.waitForCondition(timeout: 5) { !applyWheel.exists }
        editor.cancelDraft()
    }

    func testLooksSearchRecentAndMasterRecipeSmoke() throws {
        let (_, editor) = try launchWithSeededPhoto()
        editor.openTool("film", in: "looks")
        let openSearch = editor.app.buttons["looks.search.open"]
        XCTAssertTrue(openSearch.waitForExistence(timeout: 5), editor.app.debugDescription)
        openSearch.tap()
        let search = editor.app.textFields["looks.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), editor.app.debugDescription)
        search.tap()
        search.typeText("ACROS\n")
        let acros = editor.app.buttons["ACROS"]
        XCTAssertTrue(acros.waitForExistence(timeout: 5), editor.app.debugDescription)
        acros.tap()
        XCTAssertTrue(acros.isSelected, editor.app.debugDescription)
        editor.applyDraft()
        XCTAssertEqual(editor.app.buttons["tool.film"].value as? String, "ACROS")

        editor.openTool("masterRecipe", in: "looks")
        XCTAssertTrue(editor.app.scrollViews["masterRecipe.choices"].waitForExistence(timeout: 5), editor.app.debugDescription)
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
        let cancel = editor.app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), editor.app.debugDescription)
        cancel.tap()

        editor.exportCurrentPhotoToLibrary(longEdge: 128)
        editor.exportCurrentPhotoToLibrary(longEdge: 1024)
        editor.exportCurrentPhotoToLibrary(longEdge: nil)

        importer.openMenuAction(identifier: "editor.privacy.open", labels: ["Privacy settings"])
        let usage = importer.app.switches["usage.consent"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5), importer.app.debugDescription)
        XCTAssertTrue(usage.isHittable)
        XCTAssertEqual(usage.value as? String, "1")
        importer.app.buttons["usage.done"].tap()
    }
}
