import XCTest

final class EditorV4UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Photos full-access permission") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow Full Access' OR label == '允许完全访问'")).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testExposureNativeWheelCancelApplySignAndDefault() throws {
        let app = try launchImportedEditor()
        try selectTool("exposure", in: app)
        resetIfEnabled("adjustment.reset", in: app)
        let value = app.buttons["adjustment.value"]
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001)
        capture("v4-loaded-exposure", in: app)

        try openWheel("adjustment.value", in: app)
        try selectWheelValue("+0.50", title: "Exposure", unit: "EV", in: app)
        capture("v4-native-exposure-wheel", in: app)
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001, "Cancel must leave the editor value unchanged")

        try setValue("+0.50", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), 0.5, accuracy: 0.0001)
        XCTAssertTrue((value.value as? String)?.hasPrefix("+") == true, value.debugDescription)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.50 EV")

        try setValue("-0.25", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001)
        XCTAssertTrue((value.value as? String)?.hasPrefix("-") == true, value.debugDescription)

        try openWheel("adjustment.value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        XCTAssertTrue(app.staticTexts["adjustment.wheel.draft"].label.contains("0.00"))
        app.buttons["adjustment.wheel.cancel"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
        XCTAssertEqual(try number(value), -0.25, accuracy: 0.0001, "Canceling the default choice must preserve the committed value")
        try openWheel("adjustment.value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { app.buttons["adjustment.value"].isHittable }
        XCTAssertEqual(try number(value), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["adjustment.reset"].isEnabled)
    }

    func testRulerAndFineAdjustmentKeepExposureGridAndLimits() throws {
        let app = try launchImportedEditor()
        try selectTool("exposure", in: app)
        resetIfEnabled("adjustment.reset", in: app)
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        try revealInPanel(ruler, in: app)
        XCTAssertTrue(ruler.isHittable)
        XCTAssertGreaterThan(ruler.frame.width, ruler.frame.height, "The adjustment ruler must run horizontally")
        dragRuler(ruler, from: 0.75, to: 0.25)
        capture("v4-ruler-after-standard-drag", in: app)
        waitUntil { (try? self.number(app.buttons["adjustment.value"])) != 0 }
        let standard = try number(app.buttons["adjustment.value"])
        assertExposureGrid(standard)
        XCTAssertGreaterThan(standard, 0)
        XCTAssertEqual(try number(ruler), standard, accuracy: 0.0001)

        resetIfEnabled("adjustment.reset", in: app)
        let fine = app.buttons["adjustment.fine"]
        try revealInPanel(fine, in: app)
        let standardSensitivity = fine.value as? String
        fine.tap()
        XCTAssertTrue(fine.isSelected, fine.debugDescription)
        XCTAssertNotEqual(fine.value as? String, standardSensitivity)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.75, to: 0.25)
        waitUntil { (try? self.number(app.buttons["adjustment.value"])) != 0 }
        let precise = try number(app.buttons["adjustment.value"])
        assertExposureGrid(precise)
        XCTAssertGreaterThan(precise, 0)
        XCTAssertLessThan(precise, standard, "The same gesture in fine mode must move fewer legal steps")
        XCTAssertEqual(try number(ruler), precise, accuracy: 0.0001)
        fine.tap()
        XCTAssertFalse(fine.isSelected)
        XCTAssertEqual(fine.value as? String, standardSensitivity)

        try setValue("+4.00", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.75, to: 0.25)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 4, accuracy: 0.0001)
        try setValue("-4.00", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try revealInPanel(ruler, in: app)
        dragRuler(ruler, from: 0.25, to: 0.75)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), -4, accuracy: 0.0001)
        resetIfEnabled("adjustment.reset", in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0, accuracy: 0.0001)
        capture("v4-exposure-ruler", in: app)
    }

    func testGeometryDraftCancelApplyAndToolExitPreserveCommittedValue() throws {
        let app = try launchImportedEditor()
        try selectTool("geometry", in: app)
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        let straighten = app.buttons["geometry.straighten.value"]
        XCTAssertEqual(try number(straighten), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)

        try setValue("2.3", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        waitUntil(timeout: 60) { app.buttons["editor.draft.apply"].isEnabled }
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5), "Cancel returns to ordinary editing")
        XCTAssertFalse(app.buttons["editor.draft.apply"].exists)
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(straighten), 0, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)

        try setValue("3.4", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        applyDraft(in: app)
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5), "Apply returns to ordinary editing")
        XCTAssertFalse(app.buttons["editor.draft.apply"].exists)
        try selectTool("geometry", in: app)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled)
        XCTAssertEqual(try number(straighten), 3.4, accuracy: 0.0001)

        try setValue("51", title: "Horizontal Perspective", control: "geometry.perspectiveHorizontal", in: app)
        applyDraft(in: app)
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 51, accuracy: 0.0001,
                       "Perspective must retain the legal integer value across draft application")

        try setValue("4.5", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        try selectTool("exposure", in: app)
        let discard = app.buttons["Discard Adjustments"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        let continueEditing = app.buttons["Continue Editing"]
        XCTAssertTrue(continueEditing.waitForExistence(timeout: 5), app.debugDescription)
        continueEditing.tap()
        XCTAssertEqual(try number(straighten), 4.5, accuracy: 0.0001, "Continuing editing keeps the active draft")
        try selectTool("exposure", in: app)
        discard.tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(straighten), 3.4, accuracy: 0.0001, "Discarding the draft restores the committed geometry")
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 51, accuracy: 0.0001)
        capture("v4-geometry-committed", in: app)
    }

    func testCropWidthWheelUnlocksAspectForCornerDragAndRotationPreservesDraft() throws {
        let app = try launchImportedEditor()
        try selectTool("geometry", in: app)
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        let aspect = app.buttons["geometry.aspectRatio"]
        try revealInPanel(aspect, in: app)
        aspect.tap()
        let square = app.buttons["1:1"]
        XCTAssertTrue(square.waitForExistence(timeout: 5), app.debugDescription)
        square.tap()
        XCTAssertTrue(aspect.label.contains("1:1"), aspect.debugDescription)
        let width = app.buttons["geometry.cropWidth.value"]
        let height = app.buttons["geometry.cropHeight.value"]
        let squareWidth = try number(width)
        let squareHeight = try number(height)
        let squareRatio = squareWidth / squareHeight
        let narrowedWidth = max(1, (squareWidth * 0.75 * 10).rounded() / 10)
        try setValue(String(format: "%.1f", narrowedWidth), title: "Crop Width", unit: "%", control: "geometry.cropWidth", in: app)
        XCTAssertEqual(try number(width), narrowedWidth, accuracy: 0.1)
        XCTAssertEqual(try number(height), squareHeight, accuracy: 0.1)
        XCTAssertFalse(aspect.label.contains("1:1"), "A numeric crop edit must release the selected aspect ratio")

        let corner = app.descendants(matching: .any)["geometry.crop.bottomRight"]
        XCTAssertTrue(corner.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(corner.isHittable, corner.debugDescription)
        let start = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -40, dy: 0)))
        waitUntil {
            guard let current = try? self.number(width) else { return false }
            return current < narrowedWidth
        }
        let draggedWidth = try number(width)
        let draggedHeight = try number(height)
        XCTAssertLessThan(draggedWidth, narrowedWidth)
        XCTAssertEqual(draggedHeight, squareHeight, accuracy: 0.1, "A free horizontal corner drag must not resize crop height")
        XCTAssertGreaterThan(abs(draggedWidth / draggedHeight - squareRatio), squareRatio * 0.05,
                             "The corner must not snap the crop back to the previous 1:1 ratio")
        let cropIDs = ["cropX", "cropY", "cropWidth", "cropHeight"]
        let portraitValues = try cropIDs.map { try number(app.buttons["geometry.\($0).value"]) }
        capture("v4-free-crop-draft-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        waitForLandscapeSidePanel(in: app)
        XCTAssertTrue(app.buttons["editor.draft.cancel"].waitForExistence(timeout: 5))
        for (index, id) in cropIDs.enumerated() {
            XCTAssertEqual(try number(app.buttons["geometry.\(id).value"]), portraitValues[index], accuracy: 0.1,
                           "Rotation must preserve the active crop draft")
        }
        XCTAssertFalse(aspect.label.contains("1:1"))
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        capture("v4-free-crop-draft-landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        waitUntil { app.frame.height > app.frame.width }
        for (index, id) in cropIDs.enumerated() {
            XCTAssertEqual(try number(app.buttons["geometry.\(id).value"]), portraitValues[index], accuracy: 0.1)
        }
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5))
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(width), 100, accuracy: 0.1)
        XCTAssertEqual(try number(height), 100, accuracy: 0.1)
    }

    func testMasterRecipeNamesAndTilesRemainReachable() throws {
        let app = try launchImportedEditor()
        try selectTool("masterRecipe", in: app)
        let choices = app.scrollViews["masterRecipe.choices"]
        XCTAssertTrue(choices.waitForExistence(timeout: 5))
        let recipes = [
            ("neutral", "No Recipe"),
            ("hamada_daylight_v2", "滨田英明"),
            ("takashi_yasui_zen", "保井崇志"),
            ("takahiro_sakai_blue", "酒井贵弘"),
            ("withluke_epic", "withluke"),
            ("daniel_casson_autumn", "Daniel Casson"),
            ("billy_dinh_cinema", "Billy Dinh"),
            ("rkrkrk_cyberpunk", "rkrkrk"),
            ("samalive_vintage", "Samalive"),
            ("iwona_fairy_tale", "Iwona"),
            ("cinestill_800t", "CineStill 800T"),
            ("wilson_lee_golden", "Wilson Lee"),
            ("luizclas_portrait", "Luiz Clas"),
            ("ivan_ivanchenko_twilight", "Ivan Ivanchenko"),
            ("jungraphy_neon", "Jungraphy")
        ]
        for (id, name) in recipes {
            let tile = app.buttons["recipe." + id]
            try revealHorizontally(tile, in: choices, app: app)
            XCTAssertEqual(tile.label, name)
            XCTAssertTrue(tile.isHittable, tile.debugDescription)
            XCTAssertGreaterThanOrEqual(tile.frame.height, 88, "Each tile needs room for its icon and full recipe name")
            if id == "hamada_daylight_v2" || id == "jungraphy_neon" {
                capture("v4-recipe-tile-" + id, screenshot: tile.screenshot())
            }
        }
        let selected = app.buttons["recipe.hamada_daylight_v2"]
        try revealHorizontally(selected, in: choices, app: app)
        tapVisible(selected, in: app)
        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(app.buttons["tool.masterRecipe"].value as? String, "滨田英明")
        XCTAssertTrue(app.buttons["masterRecipe.strength.value"].waitForExistence(timeout: 5))
        capture("v4-master-recipe-selected", in: app)
    }

    func testVignetteHighlightAvailabilityAndHSLChannelValues() throws {
        let app = try launchImportedEditor()
        try selectTool("vignette", in: app)
        resetIfEnabled("effects.vignette.reset", in: app)
        let advanced = app.buttons["effects.vignette.advanced"].firstMatch
        try revealInPanel(advanced, in: app)
        advanced.tap()
        capture("v4-vignette-after-expand", in: app)
        let highlights = app.buttons["effects.vignette.vignetteHighlights.value"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 5))
        XCTAssertFalse(highlights.isEnabled)
        XCTAssertTrue(app.staticTexts["effects.vignette.highlightsUnavailable"].exists)
        try setValue("-20", title: "Intensity", control: "effects.vignette.vignetteAmount", in: app)
        XCTAssertTrue(highlights.isEnabled)
        XCTAssertFalse(app.staticTexts["effects.vignette.highlightsUnavailable"].exists)
        try setValue("25", title: "Highlight Protection", control: "effects.vignette.vignetteHighlights", in: app)
        XCTAssertEqual(try number(highlights), 25, accuracy: 0.0001)
        try setValue("+20", title: "Intensity", control: "effects.vignette.vignetteAmount", in: app)
        XCTAssertFalse(highlights.isEnabled)
        XCTAssertEqual(try number(highlights), 25, accuracy: 0.0001, "Unavailable controls must retain their stored value")

        try selectTool("hsl", in: app)
        let red = app.buttons["hsl.channel.0"]
        red.tap()
        try setValue("+12", title: "Hue", control: "hsl.hue", in: app)
        app.buttons["hsl.channel.1"].tap()
        let otherChannelValue = try number(app.buttons["hsl.hue.value"])
        XCTAssertNotEqual(otherChannelValue, 12)
        red.tap()
        XCTAssertEqual(try number(app.buttons["hsl.hue.value"]), 12, accuracy: 0.0001)
        resetIfEnabled("hsl.hue.reset", in: app)
        XCTAssertEqual(try number(app.buttons["hsl.hue.value"]), 0, accuracy: 0.0001)
        capture("v4-hsl-native-controls", in: app)
    }

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
        let portraitWheel = app.descendants(matching: .any)["adjustment.wheel"].frame
        capture("v4-ipad-wheel-portrait", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil { app.frame.width > app.frame.height }
        waitForLandscapeSidePanel(in: app)
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["adjustment.wheel.draft"].label.contains("+0.75"))
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
        capture("v4-large-text-editor-landscape", in: app)
    }

    func testRasterJPEGExportConfirmationUsesCommittedValuesAndBlocksDirtyGeometry() throws {
        let app = try launchImportedEditor()
        try selectTool("exposure", in: app)
        try setValue("+0.40", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try selectTool("geometry", in: app)
        if app.buttons["geometry.reset"].isEnabled {
            resetIfEnabled("geometry.reset", in: app)
            applyDraft(in: app)
            try selectTool("geometry", in: app)
        }
        try setValue("1.2", title: "Straighten", unit: "°", control: "geometry.straighten", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Unapplied geometry must block export")
        applyDraft(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.4, accuracy: 0.0001)
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
        app.buttons["editor.export"].tap()
        let save = app.buttons["Save Current Photo"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        waitUntil(timeout: 60) { save.isEnabled }
        XCTAssertFalse(app.buttons["editor.batchExport"].isEnabled, "Batch RAW export is unavailable for the raster fixture")
        XCTAssertTrue(app.buttons["Export Rendered DNG…"].isEnabled, "Rendered DNG supports the raster buffer")
        save.tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(confirm.isHittable)
        let size = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export Size'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(size.label.contains("Original Resolution") || (size.value as? String)?.contains("Original Resolution") == true,
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
        app.buttons["editor.draft.cancel"].tap()
    }

    private func launchImportedEditor() throws -> XCUIApplication {
        let app = XCUIApplication()
        launchEnglish(app)
        try importFirstVisiblePhoto(in: app)
        return app
    }

    private func launchEnglish(_ app: XCUIApplication, additionalArguments: [String] = []) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 10))
    }

    // The parent runner seeds a clean Photos library with one generated/public image.
    private func importFirstVisiblePhoto(in app: XCUIApplication) throws {
        let empty = app.buttons["editor.import.empty"]
        if empty.isHittable { empty.tap() } else { app.buttons["editor.import"].tap() }
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let photo = try XCTUnwrap(photos.allElementsBoundByIndex.first { element in
            element.frame.width > 0 && app.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }, "The native Photos picker needs a visible seeded image")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitUntil(timeout: 90) {
            let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow Full Access' OR label == '允许完全访问'")).firstMatch
            if allow.exists { allow.tap() }
            return app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists
        }
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tool.exposure"].waitForExistence(timeout: 10))
    }

    private func selectTool(_ name: String, in app: XCUIApplication) throws {
        let tool = app.buttons["tool." + name]
        let strips = app.scrollViews.containing(.button, identifier: "tool." + name).allElementsBoundByIndex
        let strip = try XCTUnwrap(strips.min { $0.frame.height < $1.frame.height }, "Editor tool strip missing")
        try revealHorizontally(tool, in: strip, app: app)
        tapVisible(tool, in: app)
    }

    private func revealHorizontally(_ element: XCUIElement, in strip: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<18 {
            let frame = element.frame
            if frame.width > 0 && strip.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let right = frame.midX < strip.frame.midX
            strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.25 : 0.75, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.70 : 0.30, dy: 0.5)))
        }
        XCTFail("Could not reveal \(element.identifier) in \(strip.identifier)")
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    private func revealInPanel(_ element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<12 {
            let frame = element.frame
            let panelFrame = panel.frame
            let visible = panelFrame.insetBy(dx: 0, dy: min(40, panelFrame.height * 0.2))
            if element.isHittable && visible.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let up = frame.isEmpty || frame.midY > visible.midY
            let distance = frame.isEmpty ? panelFrame.height * 0.6
                : up ? max(0, frame.midY - visible.maxY) : max(0, visible.minY - frame.midY)
            let amount = min(0.6, max(0.12, distance / max(1, panelFrame.height)))
            let startY: CGFloat = up ? 0.82 : 0.18
            let endY = startY + (up ? -amount : amount)
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: startY))
                .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: endY)))
        }
        capture("v4-unreachable-" + element.identifier, in: app)
        XCTFail("Could not reveal \(element.identifier): element \(element.frame), panel \(panel.frame)")
    }

    private func openWheel(_ identifier: String, in app: XCUIApplication) throws {
        let button = app.buttons[identifier]
        try revealInPanel(button, in: app)
        button.tap()
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(picker.pickerWheels.count, 1, "The value editor must expose one native picker wheel")
        XCTAssertEqual(picker.pickerWheels.firstMatch.elementType, .pickerWheel)
        XCTAssertTrue(app.buttons["adjustment.wheel.cancel"].isHittable)
        XCTAssertTrue(app.buttons["adjustment.wheel.apply"].isHittable)
    }

    private func selectWheelValue(_ formatted: String, title: String, unit: String = "", in app: XCUIApplication) throws {
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        let wheel = picker.pickerWheels.firstMatch
        let current = try XCTUnwrap(wheel.value as? String, "Native picker value missing")
        let suffix = unit.isEmpty ? "" : " " + unit
        let nativeTitle = picker.label.isEmpty ? title : picker.label
        let target = current.contains(nativeTitle + ",") ? nativeTitle + ", " + formatted + suffix
            : !unit.isEmpty && current.contains(suffix) ? formatted + suffix : formatted
        wheel.adjust(toPickerWheelValue: target)
        waitUntil { app.staticTexts["adjustment.wheel.draft"].label.contains(formatted) }
    }

    private func setValue(_ formatted: String, title: String, unit: String = "", control: String, in app: XCUIApplication) throws {
        try openWheel(control + ".value", in: app)
        try selectWheelValue(formatted, title: title, unit: unit, in: app)
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
    }

    private func applyDraft(in app: XCUIApplication) {
        let apply = app.buttons["editor.draft.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        waitUntil(timeout: 60) { apply.isEnabled && apply.isHittable }
        apply.tap()
        waitUntil { app.buttons["adjustment.value"].exists && !apply.exists }
    }

    private func resetIfEnabled(_ identifier: String, in app: XCUIApplication) {
        let reset = app.buttons[identifier]
        if reset.isEnabled {
            try? revealInPanel(reset, in: app)
            reset.tap()
        }
    }

    private func dragRuler(_ ruler: XCUIElement, from start: CGFloat, to end: CGFloat) {
        ruler.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.4)))
    }

    private func number(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let value = try XCTUnwrap(element.value as? String, "Value missing for \(element.identifier)", file: file, line: line)
        let token = value.split(separator: " ").first.map(String.init) ?? value
        return try XCTUnwrap(Double(token), "Non-numeric value: \(value)", file: file, line: line)
    }

    private func assertExposureGrid(_ value: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(value, -4, file: file, line: line)
        XCTAssertLessThanOrEqual(value, 4, file: file, line: line)
        XCTAssertEqual(value / 0.05, (value / 0.05).rounded(), accuracy: 0.0001, file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, file: file, line: line)
    }

    private func waitForLandscapeSidePanel(in app: XCUIApplication) {
        let panel = app.scrollViews["editor.panel"]
        waitUntil {
            let frame = panel.frame
            return app.frame.width > app.frame.height && frame.width > 0
                && frame.minX > app.frame.midX && frame.maxX <= app.frame.maxX + 1
                && app.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }
        let settled = panel.frame
        waitUntil { panel.frame == settled }
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        capture(name, screenshot: XCUIScreen.main.screenshot())
    }

    private func capture(_ name: String, screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
