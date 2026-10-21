import XCTest

extension EditorUITests {
    func testPhotoEditingWorkflow() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let compare = app.buttons["editor.compare"]

        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.isEnabled)
        let reset = app.buttons["adjustment.reset"]
        if reset.isEnabled { reset.tap() }
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.00 EV")
        dragRuler(ruler)
        XCTAssertNotEqual(app.buttons["tool.exposure"].value as? String, "+0.00 EV")
        app.buttons["重置曝光"].tap()
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.00 EV")
        tapTool("film", in: app)
        revealFilm("ETERNA", in: app)
        app.buttons["ETERNA"].tap()
        XCTAssertTrue(hasRedArtwork(app.buttons["ETERNA"].screenshot().image),
                      "ETERNA must render its red and gold package, not a blank image")
        XCTAssertEqual(app.buttons["tool.film"].value as? String, "ETERNA")
        app.buttons["editor.histogram"].tap()
        capture("photo-film-portrait")
        compare.tap()
        XCTAssertEqual(compare.value as? String, "中性显影")
        compare.tap()
        app.buttons["editor.adjustments"].tap()
        XCTAssertFalse(app.buttons["tool.film"].exists)
        app.buttons["editor.adjustments"].tap()
        XCTAssertEqual(app.buttons["tool.film"].value as? String, "ETERNA")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertLessThan(app.buttons["ETERNA"].frame.maxY, app.frame.maxY - 20,
                          "Landscape film choices stay above the home indicator")
        capture("photo-film-landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        tapTool("exposure", in: app)
        XCTAssertTrue(app.buttons["tool.exposure"].isSelected)
        capture("photo-adjustment-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        revealRuler(ruler, in: app)
        XCTAssertTrue(ruler.isHittable)
        let panel = app.scrollViews["editor.panel"]
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(app.frame.contains(panel.frame), "Landscape parameters remain inside the window")
        XCTAssertFalse(photo.frame.intersects(panel.frame), "Landscape parameters leave the photo area unobscured")
        capture("photo-adjustment-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        XCTAssertTrue(app.buttons["editor.export.confirm"].waitForExistence(timeout: 5))
        app.buttons["editor.export.confirm"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout: 60))
        app.alerts.buttons["关闭"].tap()
    }

    func testLargeText() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.import.empty"].waitForExistence(timeout: 10))
        capture("large-text-empty")
        importPhoto(in: app)
        XCTAssertTrue(app.buttons["tool.film"].waitForExistence(timeout: 10))
        capture("large-text-portrait")
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        revealRuler(ruler, in: app)
        XCTAssertTrue(ruler.isHittable)
        XCTAssertLessThan(app.buttons["adjustment.value"].frame.maxX, app.frame.maxX)
        capture("large-text-ruler")
        XCUIDevice.shared.orientation = .landscapeLeft
        revealRuler(ruler, in: app)
        XCTAssertTrue(ruler.isHittable)
        capture("large-text-landscape")
    }

    func testAllBuiltInFilmsAreAvailable() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.film"].tap()
        for name in ["ACROS", "ASTIA", "CLASSIC CHROME", "CLASSIC Neg.", "ETERNA", "ETERNA BB",
                     "PRO Neg.Std", "PROVIA", "REALA ACE", "Velvia"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing built-in LUT: \(name)")
        }
        XCTAssertFalse(app.buttons["WDR"].exists)
        XCTAssertFalse(app.buttons["FLog2 709"].exists)
        capture("complete-film-list")
    }

    func testPreviewZoomGestures() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let canvas = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.pinch(withScale: 3, velocity: 1)
        XCTAssertFalse(isFittedPhoto(canvas))
        canvas.swipeLeft()
        capture("photo-pinched-and-panned")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        app.buttons["editor.adjustments"].tap()
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        app.buttons["editor.adjustments"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels-resized")
        importPhoto(in: app)
        XCTAssertTrue(isFittedPhoto(canvas))
    }

}
