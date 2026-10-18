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

    func testFunctionalEmptyEditorAtLargestTextSizeInBothOrientations() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "de",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        for portrait in [true, false] {
            XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
            waitUntil { (app.frame.height > app.frame.width) == portrait }
            let emptyImport = app.buttons["editor.import.empty"]
            for _ in 0..<3 where !emptyImport.isHittable {
                app.scrollViews.containing(.button, identifier: "editor.import.empty").firstMatch.swipeUp()
            }
            assertFunctionalEmptyEditor(in: app, importLabel: "Foto importieren")
            capture("empty-functional-ax-de-\(portrait ? "portrait" : "landscape")", in: app)
            openAndCancelPhotoPicker("editor.import.empty", in: app)
        }
    }

    func testAccessibilityLargeTextEmptyEditorAndNativeWheelsInBothOrientations() throws {
        let app = XCUIApplication()
        launchEnglish(app, additionalArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let emptyImport = app.buttons["editor.import.empty"]
        XCTAssertTrue(emptyImport.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        XCTAssertFalse(app.buttons["editor.adjustments"].isEnabled)
        XCTAssertTrue(emptyImport.isHittable)
        capture("v4-large-text-empty-portrait", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        for _ in 0..<3 where !emptyImport.isHittable {
            app.scrollViews.containing(.button, identifier: "editor.import.empty").firstMatch.swipeUp()
        }
        XCTAssertTrue(emptyImport.isHittable)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        capture("v4-large-text-empty-landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        waitUntil { app.frame.height > app.frame.width }
        try importFirstVisiblePhoto(in: app)
        try selectTool("exposure", in: app)
        resetIfEnabled("adjustment.reset", in: app)
        let value = app.buttons["adjustment.value"]
        try openWheel("adjustment.value", in: app)
        try selectWheelValue("+0.50", title: "Exposure", unit: "EV", in: app)
        capture("v4-large-text-wheel-portrait", in: app)
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001)
        try setValue("-0.25", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001)
        try revealInPanel(app.descendants(matching: .any)["adjustment.ruler"], in: app)
        assertLargeTextPhotoVisible(in: app)
        capture("v4-large-text-editor-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        try revealInPanel(value, in: app)
        XCTAssertTrue(value.isHittable)
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001)
        try openWheel("adjustment.value", in: app)
        try selectWheelValue("+0.75", title: "Exposure", unit: "EV", in: app)
        capture("v4-large-text-wheel-landscape", in: app)
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001)
        try setValue("+1.00", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), 1, accuracy: 0.0001)
        try revealInPanel(app.descendants(matching: .any)["adjustment.ruler"], in: app)
        assertLargeTextPhotoVisible(in: app)
        capture("v4-large-text-editor-landscape", in: app)
    }

    func testRasterJPEGExportConfirmationUsesCommittedValuesAndBlocksDirtyGeometry() throws {
        let app = try launchImportedEditor()
        try selectTool("temperature", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "tool.temperature").count, 1)
        XCTAssertEqual(app.buttons["tool.temperature"].label, "White Balance")
        XCTAssertFalse(app.buttons["tool.tint"].exists,
                       "Tint remains an editable parameter, not a second toolbar entry")
        let rasterTemperature = app.buttons["whiteBalance.temperature.value"]
        let rasterTint = app.buttons["whiteBalance.tint.value"]
        XCTAssertTrue(rasterTemperature.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(rasterTint.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.segmentedControls["whiteBalance.mode"].exists,
                       "Raster white balance has no RAW camera mode")
        XCTAssertFalse(rasterTemperature.isEnabled, "Raster temperature is a RAW-only control")
        XCTAssertFalse(rasterTint.isEnabled, "Raster tint is a RAW-only control")
        XCTAssertEqual(try number(rasterTemperature), 6500, accuracy: 0.0001)
        XCTAssertEqual(try number(rasterTint), 0, accuracy: 0.0001)
        assertFileImportItem(enabled: true, in: app)
        cancelFileImporter(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists,
                      "Canceling the Files picker keeps the imported raster preview")
        try selectTool("exposure", in: app)
        try setValue("+0.40", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        cancelFileImporter(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.4, accuracy: 0.0001,
                       "Canceling the Files picker keeps the committed raster edit")
        try selectTool("geometry", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "An unchanged geometry draft must block every export entry")
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        try setValue("1.2", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Unapplied geometry must block export")
        assertFileImportItem(enabled: false, in: app)
        applyDraft(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.4, accuracy: 0.0001)
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
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.4, accuracy: 0.0001)
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.straighten.value"]), 1.2, accuracy: 0.0001,
                       "Canceling the export sheet preserves the committed geometry")
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Returning to a committed geometry value remains an active draft")
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled, "Lens correction is unavailable for the raster fixture")
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
    }

    func testFilesPickerSelectsSeededRasterFromLocalStorage() throws {
        let app = XCUIApplication()
        launchEnglish(app)
        try selectSeededFilesImage(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 60),
                      app.debugDescription)
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.debugDescription)
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled,
                       "A raster selected through Files must not expose RAW-only lens correction")
        XCTAssertEqual(app.buttons["tool.temperature"].label, "White Balance")
        capture("v4-files-raster-imported", in: app)
    }

    func testFileImportMenuDisablesWhileEditorIsBusy() {
        let app = XCUIApplication()
        launchEnglish(app, additionalArguments: ["-RawLab.testBusyEditor"])
        assertFileImportItem(enabled: false, in: app)
        app.terminate()
    }

}
