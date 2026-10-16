import XCTest

final class EditorV4UITests: XCTestCase {
    func testRAWNativeHistoryPerspectiveAndBatchEntry() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_RAW_INTEGRATION_UI"] == "1" else {
            throw XCTSkip("Run on a dedicated Photos library seeded with one RAW and explicitly enable RAWLAB_RAW_INTEGRATION_UI.")
        }
        let app = try launchImportedEditor()
        XCTAssertTrue(app.buttons["tool.lens"].isEnabled, "The system picker must import the original RAW")
        try setValue("+0.35", title: "Exposure", unit: "EV", control: "adjustment", in: app)
        try selectTool("geometry", in: app)
        try setValue("12", title: "Horizontal Perspective", control: "geometry.perspectiveHorizontal", in: app)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "An unapplied RAW draft must block export")
        applyDraft(in: app)
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Adjustments Saved'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.terminate()
        launchEnglish(app)
        try importFirstVisiblePhoto(in: app)
        XCTAssertEqual(try number(app.buttons["adjustment.value"]), 0.35, accuracy: 0.0001)
        try selectTool("geometry", in: app)
        XCTAssertEqual(try number(app.buttons["geometry.perspectiveHorizontal.value"]), 12, accuracy: 0.0001)
        XCTAssertFalse(app.buttons["editor.draft.apply"].isEnabled, "Restored RAW geometry starts as an unchanged draft")
        app.buttons["editor.draft.cancel"].tap()
        app.buttons["editor.export"].tap()
        let batch = app.buttons["editor.batchExport"]
        waitUntil(timeout: 90) { batch.isEnabled }
        batch.tap()
        let pick = app.buttons["batch.pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["batch.export"].isEnabled)
        pick.tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        waitUntil(timeout: 90) { app.buttons["batch.export"].isEnabled }
        XCTAssertTrue(app.staticTexts["DJI_20250602164503_0444_D.DNG"].exists,
                      "The batch must retain the seeded RAW rather than a preview or JPEG")
        capture("v08-integrated-raw-history-perspective-batch", in: app)
    }

    func testGeometrySourceRestorationUsesUncroppedPreview() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_SOURCE_HARNESS"] == "1" else {
            throw XCTSkip("Run RawLab/tests/geometry-source-ui.sh to enable the separate source-restoration harness.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.geometry-source")
        app.launch()
        let probe = app.staticTexts["geometry.review.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = probe.value as? String, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["done"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 120), .completed)
        let text = try XCTUnwrap(probe.value as? String)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [String: Bool])
        print("Geometry source harness result: \(text)")
        XCTAssertGreaterThanOrEqual(checks.count, 35)
        let failures = checks.filter { !$0.value }.map(\.key).sorted()
        XCTAssertTrue(failures.isEmpty, "Failed checks: \(failures)\n\(text)")
    }

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
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Entering an unchanged geometry draft must block export")
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
        XCTAssertFalse(app.buttons["effects.vignette.reset"].exists,
                       "Collapsed vignette keeps the group reset out of the compact surface")
        XCTAssertFalse(app.buttons["effects.vignette.vignetteAmount.reset"].exists,
                       "Collapsed vignette keeps the intensity reset out of the compact surface")
        let advanced = app.buttons["effects.vignette.advanced"].firstMatch
        try revealInPanel(advanced, in: app)
        advanced.tap()
        XCTAssertTrue(app.buttons["effects.vignette.reset"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["effects.vignette.vignetteAmount.reset"].waitForExistence(timeout: 5))
        resetIfEnabled("effects.vignette.reset", in: app)
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
        XCTAssertFalse(app.buttons["editor.export"].isEnabled, "Returning to a committed geometry value remains an active draft")
        app.buttons["editor.draft.cancel"].tap()
        XCTAssertFalse(app.buttons["tool.lens"].isEnabled, "Lens correction is unavailable for the raster fixture")
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
    }

    func testFileImportMenuDisablesWhileEditorIsBusy() {
        let app = XCUIApplication()
        launchEnglish(app, additionalArguments: ["-RawLab.testBusyEditor"])
        assertFileImportItem(enabled: false, in: app)
        app.terminate()
    }

    private func assertFunctionalEmptyEditor(in app: XCUIApplication, importLabel: String) {
        let emptyImport = app.buttons["editor.import.empty"]
        XCTAssertTrue(emptyImport.waitForExistence(timeout: 5))
        XCTAssertEqual(emptyImport.label, importLabel)
        XCTAssertTrue(emptyImport.isEnabled && emptyImport.isHittable)
        XCTAssertGreaterThanOrEqual(emptyImport.frame.height, 44)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(emptyImport.frame))
        XCTAssertTrue(app.buttons["editor.import"].isEnabled && app.buttons["editor.import"].isHittable)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        XCTAssertFalse(app.buttons["editor.adjustments"].isEnabled)
        XCTAssertFalse(app.buttons["tool.film"].exists)
        let labels = Set(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })
        XCTAssertTrue(labels.isSubset(of: Set(["RawLab", importLabel])), "The empty editor must show only functional copy and its optional navigation title")
    }

    private func assertFileImportItem(enabled: Bool, in app: XCUIApplication) {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), app.debugDescription)
        privacy.tap()
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(file.isEnabled, enabled, "File import must follow editor draft/busy lock")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        waitUntil { !file.exists }
    }

    private func cancelFileImporter(in app: XCUIApplication) {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), app.debugDescription)
        privacy.tap()
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The Files picker can only be opened from a clean editor state")
        file.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        waitUntil(timeout: 10) { !cancel.exists && app.descendants(matching: .any)["editor.photo"].exists }
    }

    private func openAndCancelPhotoPicker(_ identifier: String, in app: XCUIApplication) {
        app.buttons[identifier].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        waitUntil { !cancel.exists && app.buttons["editor.import.empty"].isHittable }
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
            let distance = frame.isEmpty ? panelFrame.height * 0.6 : abs(frame.midY - panelFrame.midY)
            let amount = min(0.6, max(0.12, distance / max(1, panelFrame.height)))
            let startY: CGFloat = up ? 0.82 : 0.18
            let endY = startY + (up ? -amount : amount)
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: startY))
                .press(forDuration: 0.1,
                       thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: endY)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
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
        assertNativeWheelVisible(in: app)
        assertWheelContextVisible(in: app)
        XCTAssertTrue(app.buttons["adjustment.wheel.cancel"].isHittable)
        XCTAssertTrue(app.buttons["adjustment.wheel.apply"].isHittable)
    }

    private func selectWheelValue(_ formatted: String, title: String, unit: String = "", in app: XCUIApplication) throws {
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        let wheel = picker.pickerWheels.firstMatch
        let current = try XCTUnwrap(wheel.value as? String, "Native picker value missing")
        let suffix = unit.isEmpty ? "" : " " + unit
        let nativeTitle = picker.label.isEmpty ? title : picker.label
        // UIPickerView uses grouped thousands in its row accessibility labels while
        // the value context intentionally keeps the compact formatter. Preserve
        // signed values such as +20 exactly as authored by the test.
        let sign: String
        if let first = formatted.first, first == "+" || first == "-" {
            sign = String(first)
        } else {
            sign = ""
        }
        let magnitudeText = sign.isEmpty ? formatted : String(formatted.dropFirst())
        let magnitude = Double(magnitudeText) ?? 0
        let groupedMagnitude = abs(magnitude) >= 1000
            ? NumberFormatter.localizedString(from: NSNumber(value: abs(magnitude)), number: .decimal)
            : magnitudeText
        let grouped = sign + groupedMagnitude
        let target = current.contains(nativeTitle + ",") ? nativeTitle + ", " + grouped + suffix
            : !unit.isEmpty && current.contains(suffix) ? formatted + suffix : formatted
        wheel.adjust(toPickerWheelValue: target)
        waitUntil {
            let draft = app.staticTexts["adjustment.wheel.draft"].label
            return draft.contains(formatted) || draft.contains(grouped)
        }
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
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return try XCTUnwrap(Double(token) ?? formatter.number(from: token)?.doubleValue,
                             "Non-numeric value: \(value)", file: file, line: line)
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

    private func assertNativeWheelVisible(in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        let wheel = picker.pickerWheels.firstMatch
        let standardIPad = min(app.frame.width, app.frame.height) >= 700
            && !app.launchArguments.contains("UICTContentSizeCategoryAccessibilityXXXL")
        waitUntil {
            guard wheel.isHittable else { return false }
            return !standardIPad || (picker.frame.height >= 200
                && app.frame.insetBy(dx: -1, dy: -1).contains(picker.frame))
        }
        XCTAssertTrue(wheel.isHittable, "The native selection wheel must remain reachable")
        if standardIPad {
            XCTAssertGreaterThanOrEqual(picker.frame.height, 200, "The iPad popover must show the selection wheel")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(picker.frame),
                          "The iPad selection wheel must fit within the window")
        }
    }

    private func assertWheelContextVisible(in app: XCUIApplication) {
        for identifier in ["adjustment.wheel.title", "adjustment.wheel.draft", "adjustment.wheel.range", "adjustment.wheel.default"] {
            let element = app.descendants(matching: .any)[identifier]
            waitUntil { element.isHittable && app.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
            XCTAssertTrue(element.isHittable, "Wheel context must be visible when opened: \(identifier)")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(element.frame), "Complete wheel context must fit in the window")
        }
    }

    private func assertLargeTextPhotoVisible(in app: XCUIApplication) {
        let photo = app.descendants(matching: .any)["editor.photo"]
        waitUntil {
            photo.frame.height >= 80 && app.frame.insetBy(dx: -1, dy: -1).contains(photo.frame)
        }
        XCTAssertGreaterThanOrEqual(photo.frame.height, 80, "Large text must preserve a visible photo region")
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
