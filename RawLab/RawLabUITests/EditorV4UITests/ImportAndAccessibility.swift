import XCTest

extension EditorV4UITests {
    func testIPadRotationRetainsWheelDraftAndReanchorsPopover() throws {
        let app = XCUIApplication()
        launchEnglish(app)
        try XCTSkipIf(app.frame.width < 700, "iPad layout regression runs on the dedicated iPad simulator")
        try importFirstVisiblePhoto(in: app)
        try selectTool("exposure", in: app)
        resetIfEnabled("adjustment.reset", in: app)
        let portraitPanel = app.scrollViews["editor.panel"].frame
        capture("v4-ipad-editor-portrait", in: app)
        try openWheel("adjustment.value", in: app)
        try selectWheelValue("+0.75", title: "Exposure", unit: "EV", in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["adjustment.wheel"].exists,
                      "A changed popover draft must remain open when tapping outside")
        XCTAssertTrue(app.staticTexts["adjustment.wheel.draft"].label.contains("+0.75"))
        let portraitWheel = app.descendants(matching: .any)["adjustment.wheel"].frame
        capture("v4-ipad-wheel-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        waitForLandscapeSidePanel(in: app)
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        assertNativeWheelVisible(in: app)
        XCTAssertTrue(app.staticTexts["adjustment.wheel.draft"].label.contains("+0.75"))
        assertWheelContextVisible(in: app)
        XCTAssertTrue(app.buttons["adjustment.wheel.cancel"].isHittable)
        XCTAssertTrue(app.buttons["adjustment.wheel.apply"].isHittable)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(picker.frame), "The rotated wheel must remain within the iPad window")
        XCTAssertNotEqual(picker.frame, portraitWheel, "The popover must reanchor after rotation")
        capture("v4-ipad-wheel-landscape", in: app)
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { app.buttons["adjustment.value"].isHittable }
        waitForLandscapeSidePanel(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.75, accuracy: 0.0001)
        XCTAssertNotEqual(app.scrollViews["editor.panel"].frame, portraitPanel)
        XCTAssertTrue(app.frame.contains(app.scrollViews["editor.panel"].frame))
        capture("v4-ipad-editor-landscape", in: app)

        XCUIDevice.shared.orientation = .portrait
        waitUntil { app.frame.height > app.frame.width }
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.75, accuracy: 0.0001)
        try openWheel("adjustment.value", in: app)
        try selectWheelValue("-0.50", title: "Exposure", unit: "EV", in: app)
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { app.buttons["adjustment.value"].isHittable }
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.75, accuracy: 0.0001)
    }

    func testEmptyEditorUsesOnlyFunctionalCopyInAllLanguages() {
        let languages = [
            ("zh-Hans", "导入照片"), ("en", "Import Photo"),
            ("de", "Foto importieren"), ("fr", "Importer une photo"),
            ("ja", "写真を読み込む"), ("es", "Importar foto")
        ]
        for (language, importLabel) in languages {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", language]
            app.launch()
            for portrait in [true, false] {
                XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
                waitUntil { (app.frame.height > app.frame.width) == portrait }
                assertFunctionalEmptyEditor(in: app, importLabel: importLabel)
                let orientation = portrait ? "portrait" : "landscape"
                capture("empty-functional-\(language)-\(orientation)", in: app)
                openAndCancelPhotoPicker(portrait ? "editor.import.empty" : "editor.import", in: app)
                assertFunctionalEmptyEditor(in: app, importLabel: importLabel)
            }
            app.terminate()
        }
    }

    func testRasterJPEGExportConfirmationUsesCommittedValuesAndBlocksDirtyGeometry() throws {
        let app = try launchImportedEditor()
        // v0.8 two-level workbench: tiles live on the overview grid, one per selected group.
        try exitToOverviewIfNeeded(in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "tool.temperature").count, 0,
                       "White balance belongs to the colour group, not to the currently open light grid")
        let temperatureTile = try revealTool("temperature", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "tool.temperature").count, 1)
        XCTAssertEqual(temperatureTile.label, "White Balance")
        XCTAssertFalse(app.buttons["tool.tint"].exists,
                       "Tint remains an editable parameter, not a second toolbar entry")
        // v0.8 contract: a raster source disables the RAW-only white balance tile on the
        // overview grid (EditorLayout, same contract the PNG-fixture test relies on), so
        // tapping it must not open a tool page; the in-panel RAW temperature/tint rows are
        // unreachable from a JPEG fixture and are no longer asserted here.
        tapVisible(temperatureTile, in: app)
        XCTAssertFalse(temperatureTile.isEnabled, "A raster source must disable the white balance tile")
        XCTAssertFalse(app.scrollViews["editor.panel"].exists,
                       "The disabled raster white balance tile must not open a tool page")
        try exitToOverviewIfNeeded(in: app)
        assertFileImportItem(enabled: true, in: app)
        cancelFileImporter(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists,
                      "Canceling the Files picker keeps the imported raster preview")
        try selectTool("exposure", in: app)
        try setValue("+0.40", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        // v0.8: the Files entry lives on the overview, so a wheel value is committed before leaving the tool page.
        applyDraft(in: app)
        cancelFileImporter(in: app)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.40 EV",
                       "Canceling the Files picker keeps the committed raster edit")
        try selectTool("geometry", in: app)
        XCTAssertFalse(app.buttons["editor.export"].exists, "The tool workspace keeps export on the workbench overview")
        // v0.8: the per-tool reset is the workspace toolbar's editor.draft.reset button;
        // it resets the tool draft in place, so no apply-and-reopen round trip follows it.
        let workspaceReset = app.buttons["editor.draft.reset"]
        if workspaceReset.waitForExistence(timeout: 2), workspaceReset.isEnabled {
            workspaceReset.tap()
        }
        try setValue("1.2", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        XCTAssertFalse(app.buttons["editor.export"].exists, "Unapplied geometry must block export")
        XCTAssertFalse(app.buttons["editor.privacy"].exists,
                       "The tool workspace swaps the overview overflow (with Files) for the workspace menu while a draft is open")
        applyDraft(in: app)
        XCTAssertEqual(try revealTool("exposure", in: app).value as? String, "+0.40 EV",
                       "Applying geometry preserves the committed exposure value")
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
        assertFileImportItem(enabled: true, in: app)
        app.buttons["editor.export"].tap()
        let save = app.buttons["Save Current Photo"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        waitUntil(timeout: 60) { save.isEnabled }
        XCTAssertTrue(app.buttons["editor.batchExport"].isEnabled, "Batch export accepts the raster fixture")
        XCTAssertTrue(app.buttons["Export Rendered DNG…"].isEnabled, "Rendered DNG supports the raster buffer")
        save.tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(confirm.isHittable)
        let size = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export Size'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(size.label.contains("Original size") || (size.value as? String)?.contains("Original size") == true,
                      size.debugDescription)
        capture("v4-jpeg-export-confirmation-portrait", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height && confirm.isHittable }
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(size.isHittable)
        capture("v4-jpeg-export-confirmation-landscape", in: app)
        app.navigationBars["Save Current Photo"].buttons["Cancel"].tap()
        waitUntil { !confirm.exists }
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.40 EV",
                       "Canceling the export sheet preserves the committed exposure")
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.straighten.value"]), 1.2, accuracy: 0.0001,
                       "Canceling the export sheet preserves the committed geometry")
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)
        XCTAssertFalse(app.buttons["editor.export"].exists, "Returning to a committed geometry value remains an active draft")
        cancelToolWorkspace(in: app)
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled, "Lens correction is unavailable for the raster fixture")
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
    }

    func testFilesPickerSelectsSeededRasterFromLocalStorage() throws {
        let app = XCUIApplication()
        launchEnglish(app)
        try selectSeededFilesImage(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 60),
                      app.debugDescription)
        // v0.8: the workbench grid is the imported-ready anchor; the compare entry is collapsed into the overflow menu.
        XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 10), app.debugDescription)
        let lensTile = try revealTool("lens", in: app)
        XCTAssertFalse(lensTile.isEnabled,
                       "A raster selected through Files must not expose RAW-only lens correction")
        let temperatureTile = try revealTool("temperature", in: app)
        XCTAssertEqual(temperatureTile.label, "White Balance")
        capture("v4-files-raster-imported", in: app)
    }

    func testFileImportMenuDisablesWhileEditorIsBusy() {
        let app = XCUIApplication()
        launchEnglish(app, additionalArguments: ["-RawLab.testBusyEditor"])
        assertFileImportItem(enabled: false, in: app)
        app.terminate()
    }

}
