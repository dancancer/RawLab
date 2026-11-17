import XCTest

extension EditorUITests {
    func testPhotoEditingWorkflow() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        // v0.8: import lands on the exposure tool page; the tile no longer covers the screen, so the
        // EV assertions read the panel's own value control instead of the overview tile.
        let compare = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       "editor.compare", "对比")).firstMatch

        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.isEnabled)
        resetParameterDefault("adjustment", expectedValue: "0.00 EV", in: app)
        let zeroValue = app.buttons["adjustment.value"].value as? String
        XCTAssertNotNil(zeroValue)
        XCTAssertTrue(zeroValue!.hasSuffix("0.00 EV"), "reset must read zero: \(zeroValue ?? "nil")")
        dragRuler(ruler)
        XCTAssertNotEqual(app.buttons["adjustment.value"].value as? String, zeroValue)
        app.staticTexts["adjustment.title"].doubleTap()
        let resetBack = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", zeroValue!),
                                                  object: app.buttons["adjustment.value"])
        XCTAssertEqual(XCTWaiter.wait(for: [resetBack], timeout: 10), .completed,
                       app.buttons["adjustment.value"].debugDescription)
        tapTool("film", in: app)
        revealFilm("ETERNA", in: app)
        app.buttons["ETERNA"].tap()
        XCTAssertTrue(hasRedArtwork(app.buttons["ETERNA"].screenshot().image),
                      "ETERNA must render its red and gold package, not a blank image")
        // v0.8: the tool page has no film tile; the panel row's selection state is the
        // observable memory of the chosen LUT (the tile value appears back on the overview).
        XCTAssertTrue(app.buttons["ETERNA"].isSelected, "the film panel must mark the chosen LUT as selected")
        // v0.8: the histogram chrome lives on the overview only (tool page has back/more);
        // the compare chrome and the histogram check both move to the overview tail (撤牙齿记位:
        // 工具页 histogram/compare 断言迁移到总览).
        capture("photo-film-portrait")
        // v0.8: the compare chrome lives in the workspace actions row (product HStack), i.e.
        // still on the tool page; only its accessibility id was dropped, so it is matched by
        // id-OR-label (撤牙齿记位: editor.compare 固定 id 退役为 id-OR-label 匹配).
        // The workspace button has a fixed label; the rendered before pane is the comparison state.
        let before = app.descendants(matching: .any)["editor.photo.before"]
        XCTAssertFalse(before.exists)
        compare.tap()
        XCTAssertTrue(before.waitForExistence(timeout: 5), "Comparison must display the actual before pane")
        XCTAssertFalse(before.frame.isEmpty)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists)
        compare.tap()
        XCTAssertTrue(before.waitForNonExistence(timeout: 5), "Turning comparison off must remove the before pane")
        // v0.8: the v0.4 panel-collapse toggle is retired; the overview film tile after a
        // draft apply carries the committed LUT name (撤牙齿记位: 折叠态瓦片消失断言随之退役).
        applyEditorTool(in: app)
        XCTAssertEqual(app.buttons["tool.film"].value as? String, "ETERNA")
        // v0.8 exposes histogram visibility through the overview menu. At ordinary
        // portrait size the expanded histogram is inline, not a forced popover.
        app.buttons["editor.privacy"].tap()
        let histogramToggle = app.switches["直方图"].firstMatch
        let histogramButton = app.buttons["直方图"].firstMatch
        let histogramAction = histogramToggle.exists ? histogramToggle : histogramButton
        XCTAssertTrue(histogramAction.waitForExistence(timeout: 5), app.debugDescription)
        histogramAction.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.9)).tap()
        let histogram = app.buttons["editor.histogram"]
        XCTAssertTrue(histogram.waitForExistence(timeout: 5), "The overview menu must expose the actual histogram")
        XCTAssertTrue(app.descendants(matching: .any)["editor.histogram.plot"].waitForExistence(timeout: 5),
                      "The expanded histogram must contain a rendered plot, not just its chrome")
        capture("photo-film-histogram-overview")
        histogram.tap()
        XCTAssertTrue(histogram.waitForNonExistence(timeout: 5), "Collapsing the histogram removes its overlay")
        XCUIDevice.shared.orientation = .landscapeLeft
        tapTool("film", in: app)
        let eterna = app.buttons["ETERNA"]
        for _ in 0..<6 where !eterna.isHittable { app.scrollViews["editor.panel"].swipeUp() }
        XCTAssertLessThan(eterna.frame.maxY, app.frame.maxY - 20,
                          "Landscape film choices stay above the home indicator")
        capture("photo-film-landscape")
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        tapTool("exposure", in: app)
        // v0.8: on the tool page the panel title identifies the open tool (no tile isSelected).
        XCTAssertEqual(app.staticTexts["adjustment.title"].label, "曝光", "the exposure tool page must be open")
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
        // v0.8: export opens from the overview toolbar; applying commits the exposure draft and returns.
        applyEditorTool(in: app)
        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        XCTAssertTrue(app.buttons["editor.export.confirm"].waitForExistence(timeout: 5))
        app.buttons["editor.export.confirm"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout: 60))
        app.alerts.buttons["关闭"].tap()
    }

    func testAllBuiltInFilmsAreAvailable() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        tapTool("film", in: app)
        let lutNames = ["ACROS", "ASTIA", "CLASSIC CHROME", "CLASSIC Neg.", "ETERNA", "ETERNA BB",
                        "PRO Neg.Std", "PROVIA", "REALA ACE", "Velvia"]
        // FilmGroup order is not alphabetical. Revisit both ends so availability also
        // proves a chip can be reached again after scrolling past it.
        let strip = app.scrollViews["film.choices"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        for name in lutNames + Array(lutNames.reversed()) {
            revealFilm(name, in: app)
            let lut = app.buttons[name]
            // AX frames are quantized independently at @3x. One point covers rounding,
            // not a clipped chip; the shared helper only brings its center into view.
            let visible = strip.frame.insetBy(dx: -1, dy: -1)
            for _ in 0..<8 where !(visible.contains(lut.frame) && lut.isHittable) {
                let left = lut.frame.midX < strip.frame.midX
                strip.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.25 : 0.75, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset:
                        CGVector(dx: left ? 0.65 : 0.35, dy: 0.5)))
            }
            XCTAssertTrue(lut.exists && lut.isHittable && visible.contains(lut.frame),
                          "Built-in LUT must be fully reachable in both directions: \(name)")
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
        cancelEditorTool(in: app)
        let canvas = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels")
        tapEditorMenuAction("editor.compare", in: app)
        XCTAssertEqual(canvas.value as? String, "100%")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.pinch(withScale: 3, velocity: 1)
        XCTAssertFalse(isFittedPhoto(canvas))
        canvas.swipeLeft()
        capture("photo-pinched-and-panned")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        tapEditorMenuAction("editor.adjustments", in: app)
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        tapEditorMenuAction("editor.adjustments", in: app)
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels-resized")
        importPhoto(in: app)
        XCTAssertTrue(isFittedPhoto(canvas))
    }

}
