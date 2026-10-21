import XCTest

extension EditorUITests {
    func testHSLAndAutoExposureAdaptiveLayout() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        let auto = app.buttons["exposure.auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        auto.tap()
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        let first = app.buttons["tool.exposure"].value as? String
        auto.tap()
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, first, "Auto assigns an absolute EV")
        capture("auto-exposure-portrait")
        tapTool("hsl", in: app)
        let saturation = app.descendants(matching: .any)["hsl.saturation.ruler"]
        XCTAssertTrue(saturation.waitForExistence(timeout: 10))
        let panel = app.scrollViews["editor.panel"]
        revealRuler(saturation, in: app)
        XCTAssertTrue(saturation.isHittable)
        let saturationReset = app.buttons["hsl.saturation.reset"]
        if saturationReset.isEnabled { saturationReset.tap() }
        let originalSaturation = app.buttons["hsl.saturation.value"].value as? String
        dragRuler(saturation, increasing: false)
        XCTAssertNotEqual(app.buttons["hsl.saturation.value"].value as? String, originalSaturation)
        capture("hsl-portrait")
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let visibleTools = app.scrollViews.containing(.button, identifier: "tool.hsl").allElementsBoundByIndex
        let rotatedStrip = visibleTools.min { $0.frame.height < $1.frame.height }!
        let selectedTool = app.buttons["tool.hsl"].frame
        XCTAssertTrue(rotatedStrip.frame.contains(CGPoint(x: selectedTool.midX, y: selectedTool.midY)),
                      "Rotation keeps the selected tool visible")
        capture("hsl-landscape")
        revealRuler(saturation, in: app)
        XCTAssertTrue(saturation.isHittable)
        XCTAssertTrue(app.buttons["editor.export"].exists)
    }

    func testPhotoEffectsControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        tapTool("vignette", in: app)
        let amount = app.descendants(matching: .any)["effects.vignette.vignetteAmount.ruler"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        dragRuler(amount, increasing: false)
        XCTAssertFalse(app.buttons["effects.vignette.reset"].exists,
                       "Collapsed vignette does not expose the group reset")
        app.buttons["effects.vignette.advanced"].tap()
        for parameter in ["vignetteAmount", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights"] {
            let ruler = app.descendants(matching: .any)["effects.vignette.\(parameter).ruler"]
            revealRuler(ruler, in: app)
            XCTAssertTrue(ruler.isHittable, app.debugDescription)
        }
        capture("effects-vignette-portrait")
        revealRuler(amount, in: app)
        app.buttons["重置暗角"].tap()
        XCTAssertEqual(app.buttons["effects.vignette.vignetteAmount.value"].value as? String, "0")
        XCTAssertFalse(app.descendants(matching: .any)["effects.vignette.vignetteHighlights.ruler"].isEnabled)
        tapTool("grain", in: app)
        let grain = app.descendants(matching: .any)["effects.grain.grainAmount.ruler"]
        XCTAssertTrue(grain.waitForExistence(timeout: 5))
        dragRuler(grain)
        app.buttons["effects.grain.advanced"].tap()
        for parameter in ["grainAmount", "grainSize", "grainRoughness"] {
            let ruler = app.descendants(matching: .any)["effects.grain.\(parameter).ruler"]
            revealRuler(ruler, in: app)
            XCTAssertTrue(ruler.isHittable)
        }
        capture("effects-grain-portrait")
        revealRuler(grain, in: app)
        app.buttons["重置颗粒"].tap()
        XCTAssertEqual(app.buttons["effects.grain.grainAmount.value"].value as? String, "0")
    }

    func testEmptyEditorAndPanelVisibility() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        capture("empty-portrait")
        XCTAssertFalse(app.buttons["tool.film"].exists)
        XCTAssertFalse(app.buttons["editor.adjustments"].isEnabled)
        XCTAssertTrue(app.buttons["editor.import.empty"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("empty-landscape")
    }

    func testPhotoInfoOverlay() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let info = app.buttons["editor.photoInfo"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        XCTAssertEqual(info.value as? String, "文件信息")
        XCTAssertTrue(app.descendants(matching: .any)["editor.photoInfo.overlay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["editor.photoInfo.overlay"].label.contains("3072 × 3072"),
                      "The info overlay must show the original DNG size, not its embedded preview")
        capture("photo-info-file")
        info.tap()
        XCTAssertEqual(info.value as? String, "拍摄参数")
        info.tap()
        XCTAssertEqual(info.value as? String, "隐藏照片信息")
        XCTAssertFalse(app.descendants(matching: .any)["editor.photoInfo.overlay"].exists)
    }

    func testExportSizePickerPresetsAndValidation() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)

        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '导出尺寸'")).firstMatch
        let original = app.buttons["editor.export.confirm"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(original.isEnabled)
        XCTAssertTrue(picker.label.contains("原始尺寸"))
        capture("export-size-original")

        picker.tap()
        XCTAssertTrue(app.buttons["长边 2048 px"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["长边 2048 px"].tap()
        XCTAssertTrue(picker.label.contains("长边 2048 px"))
        capture("export-size-2048")

        picker.tap()
        XCTAssertTrue(app.buttons["指定长边"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["指定长边"].tap()
        let invalid = app.textFields["导出长边像素"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 5), app.debugDescription)
        invalid.tap()
        invalid.typeText("70000")
        XCTAssertFalse(original.isEnabled)
        capture("export-size-custom-invalid")
        app.buttons["取消"].tap()

        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        let validPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '导出尺寸'")).firstMatch
        let validConfirm = app.buttons["editor.export.confirm"]
        validPicker.tap()
        app.buttons["指定长边"].tap()
        let valid = app.textFields["导出长边像素"]
        XCTAssertTrue(valid.waitForExistence(timeout: 5), app.debugDescription)
        valid.tap()
        valid.typeText("1024")
        XCTAssertTrue(validConfirm.isEnabled)
        capture("export-size-custom-valid")
        validConfirm.tap()
        XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout: 60), app.alerts.debugDescription)
        app.alerts.buttons["关闭"].tap()
    }

    // Seed the simulator Photos library with a single real image before running.
}
