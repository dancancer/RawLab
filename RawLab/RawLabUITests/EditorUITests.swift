import XCTest

final class EditorUITests: XCTestCase {
    func testEditMemoryAndBatchWorkflow() {
        let app = XCUIApplication()
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        app.buttons["重置曝光"].tap()
        app.sliders["adjustment.slider"].adjust(toNormalizedSliderPosition: 0.6)
        let savedExposure = app.buttons["tool.exposure"].value as? String
        XCTAssertNotEqual(savedExposure, "+0.0 EV")
        XCTAssertTrue(app.staticTexts["调整已保存"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        importPhoto(in: app)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, savedExposure)
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["editor.batchExport"].isEnabled, "Seed the simulator with a RAW photo, not an earlier JPEG export")
        app.buttons["使用当前调整批量导出…"].tap()
        XCTAssertTrue(app.buttons["batch.pick"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["batch.export"].isEnabled)
        app.buttons["batch.pick"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        expectation(for: NSPredicate { _, _ in app.buttons["batch.export"].isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        capture("batch-confirm-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("batch-confirm-landscape")
        XCTAssertTrue(app.buttons["batch.export"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["batch.export"].tap()
        XCTAssertTrue(app.staticTexts["已保存 1 张到照片图库"].waitForExistence(timeout: 180), app.debugDescription)
        capture("batch-result")
        app.buttons["完成"].tap()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testEmptyEditorAndPanelVisibility() {
        let app = XCUIApplication()
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

    // Seed the simulator Photos library with a single real image before running.
    func testPhotoEditingWorkflow() {
        let app = XCUIApplication()
        app.launch()
        importPhoto(in: app)
        let compare = app.buttons["editor.compare"]

        let slider = app.sliders["adjustment.slider"]
        XCTAssertTrue(slider.isEnabled)
        slider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(app.buttons["tool.exposure"].value as? String, "+0.0 EV")
        app.buttons["重置曝光"].tap()
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, "+0.0 EV")
        app.buttons["tool.film"].tap()
        revealFilm("ETERNA", in: app)
        app.buttons["ETERNA"].tap()
        XCTAssertTrue(hasRedArtwork(app.buttons["ETERNA"].screenshot().image),
                      "ETERNA must render its red and gold package, not a blank image")
        XCTAssertEqual(app.buttons["tool.film"].value as? String, "ETERNA")
        app.buttons["editor.histogram"].tap()
        capture("photo-film-portrait")
        compare.tap()
        XCTAssertEqual(compare.value as? String, "调整前")
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
        app.buttons["tool.exposure"].tap()
        capture("photo-adjustment-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(slider.isHittable)
        XCTAssertGreaterThan(slider.frame.minX, app.frame.width * 0.5,
                             "Landscape adjustments leave room for the photo")
        capture("photo-adjustment-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout: 60))
        app.alerts.buttons["关闭"].tap()
    }

    func testLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.import.empty"].waitForExistence(timeout: 10))
        capture("large-text-empty")
        importPhoto(in: app)
        XCTAssertTrue(app.buttons["tool.film"].waitForExistence(timeout: 10))
        capture("large-text-portrait")
        for _ in 0..<3 where !app.sliders["adjustment.slider"].isHittable {
            app.scrollViews["editor.panel"].swipeUp()
        }
        XCTAssertTrue(app.sliders["adjustment.slider"].isHittable)
        XCTAssertLessThan(app.staticTexts["adjustment.value"].frame.maxX, app.frame.maxX)
        capture("large-text-slider")
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<3 where !app.sliders["adjustment.slider"].isHittable {
            app.scrollViews["editor.panel"].swipeUp()
        }
        XCTAssertTrue(app.sliders["adjustment.slider"].isHittable)
        capture("large-text-landscape")
    }

    func testAllBuiltInFilmsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.film"].tap()
        for name in ["ACROS", "ASTIA", "CLASSIC CHROME", "CLASSIC Neg.", "ETERNA", "ETERNA BB",
                     "PRO Neg.Std", "PROVIA", "REALA ACE", "Velvia", "WDR"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing built-in LUT: \(name)")
        }
        XCTAssertFalse(app.buttons["FLog2 709"].exists)
        capture("complete-film-list")
    }

    func testPreviewZoomGestures() {
        let app = XCUIApplication()
        app.launch()
        importPhoto(in: app)
        let canvas = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Fit") == true)
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        canvas.doubleTap()
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Fit") == true)
        canvas.pinch(withScale: 3, velocity: 1)
        XCTAssertFalse((canvas.value as? String)?.hasPrefix("Fit") == true)
        canvas.swipeLeft()
        capture("photo-pinched-and-panned")
        canvas.doubleTap()
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Fit") == true)
        app.buttons["editor.adjustments"].tap()
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Fit") == true)
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        app.buttons["editor.adjustments"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels-resized")
        importPhoto(in: app)
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Fit") == true)
    }

    private func importPhoto(in app: XCUIApplication) {
        app.buttons["editor.import"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
        if photo.frame.midY > app.frame.maxY - 100 {
            app.scrollViews["photosView_content_scroll_view"].swipeUp()
        }
        // The system Photos grid can report no AX hit point for a visible image.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate { _, _ in
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons.matching(NSPredicate(format: "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
            if allow.exists { allow.tap() }
            return app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists
        }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.alerts.debugDescription)
    }

    private func revealFilm(_ name: String, in app: XCUIApplication) {
        let choices = app.scrollViews["film.choices"]
        for _ in 0..<12 {
            let frame = app.buttons[name].frame
            let viewport = choices.frame.insetBy(dx: 16, dy: 0)
            if frame.width > 0 && frame.midX >= viewport.minX && frame.midX <= viewport.maxX { return }
            let startX = frame.midX < viewport.minX ? 0.25 : 0.75
            let endX = frame.midX < viewport.minX ? 0.65 : 0.35
            choices.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: choices.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5)))
        }
        XCTFail("Could not reveal \(name): \(app.buttons[name].frame), viewport: \(choices.frame)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hasRedArtwork(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let redPixels = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let pixels = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { offset in
                Double(pixels[offset]) > 100 && Double(pixels[offset]) > Double(pixels[offset + 1]) * 1.8 &&
                    Double(pixels[offset]) > Double(pixels[offset + 2]) * 1.8
            }.count
        }
        return redPixels > 4
    }
}
