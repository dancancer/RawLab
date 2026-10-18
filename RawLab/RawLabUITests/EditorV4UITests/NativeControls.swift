import XCTest

extension EditorV4UITests {
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
        let discard = app.buttons["Discard Changes"]
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
            ("hamada_daylight_v2", "Hideaki Hamada"),
            ("takashi_yasui_zen", "Takashi Yasui"),
            ("takahiro_sakai_blue", "Takahiro Sakai"),
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
        XCTAssertEqual(app.buttons["tool.masterRecipe"].value as? String, "Hideaki Hamada")
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

}
