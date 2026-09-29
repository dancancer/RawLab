import XCTest

final class EditorUITests: XCTestCase {
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
        app.buttons["editor.adjustments"].tap()
        XCTAssertFalse(app.buttons["tool.film"].exists)
        app.buttons["editor.adjustments"].tap()
        XCTAssertTrue(app.buttons["tool.film"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("empty-landscape")
    }

    // Seed the simulator Photos library with a single real image before running.
    func testPhotoEditingWorkflow() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["editor.import"].tap()
        let photo = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
        photo.tap()
        let compare = app.buttons["editor.compare"]
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: compare)
        waitForExpectations(timeout: 90)

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
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout: 60))
        app.alerts.buttons["关闭"].tap()
    }

    func testLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["tool.film"].waitForExistence(timeout: 10))
        capture("large-text-portrait")
    }

    func testAllBuiltInFilmsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["tool.film"].tap()
        for name in ["ACROS", "ASTIA", "CLASSIC CHROME", "CLASSIC Neg.", "ETERNA", "ETERNA BB",
                     "PRO Neg.Std", "PROVIA", "REALA ACE", "Velvia", "WDR"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing built-in LUT: \(name)")
        }
        XCTAssertFalse(app.buttons["FLog2 709"].exists)
        capture("complete-film-list")
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
