import XCTest

final class EditorUITests: XCTestCase {
    private let seedPhotoDate = "2025年6月02日, 16:45"
    private let seedPhotoBase = "DJI_20250602164503_0444_D"
    private var verifiedSeedPickerIndex: Int?

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
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let candidates = photos.allElementsBoundByIndex
        guard let index = verifiedSeedPickerIndex, candidates.indices.contains(index) else {
            XCTFail("The original DNG has not been verified in the Photos picker")
            return
        }
        // 同日期的导出 JPEG 也在图库中，复用刚刚按完整文件名验证过的原图位置。
        let photo = candidates[index]
        XCTAssertTrue(photo.label.contains(seedPhotoDate), photo.label)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        XCTAssertTrue(app.staticTexts[seedPhotoBase + ".DNG"].waitForExistence(timeout: 5), app.debugDescription)
        expectation(for: NSPredicate { _, _ in app.buttons["batch.export"].isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        let batchSizePicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '导出尺寸'")).firstMatch
        let scrollCandidates = app.scrollViews.allElementsBoundByIndex
        XCTAssertFalse(scrollCandidates.isEmpty, app.debugDescription)
        let batchScroll = scrollCandidates.last(where: { $0.frame.height > app.frame.height * 0.7 }) ?? scrollCandidates[scrollCandidates.count - 1]
        XCTAssertTrue(batchScroll.waitForExistence(timeout: 5), app.debugDescription)
        // The fixed export bar overlaps the output row until the batch form is scrolled.
        for _ in 0..<2 {
            batchScroll.swipeUp()
        }
        XCTAssertTrue(batchSizePicker.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(batchSizePicker.isHittable, app.debugDescription)
        batchSizePicker.tap()
        XCTAssertTrue(app.buttons["长边 2,048 px"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["长边 2,048 px"].tap()
        XCTAssertTrue(batchSizePicker.label.contains("长边 2,048 px"))
        batchSizePicker.tap()
        app.buttons["自定义…"].tap()
        let batchCustom = app.textFields["长边（1–65535 px）"]
        XCTAssertTrue(batchCustom.waitForExistence(timeout: 5), app.debugDescription)
        batchCustom.tap()
        batchCustom.typeText("128")
        XCTAssertTrue(app.buttons["batch.export"].isEnabled)
        capture("batch-size-custom-128")
        batchScroll.swipeDown()
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

    func testPhotoEffectsControls() {
        let app = XCUIApplication()
        app.launch()
        importPhoto(in: app)
        let strips = app.scrollViews.containing(.button, identifier: "tool.grain").allElementsBoundByIndex
        let strip = strips.min { $0.frame.height < $1.frame.height }!
        for _ in 0..<8 {
            let frame = app.buttons["tool.vignette"].frame
            if frame.width > 0 && strip.frame.insetBy(dx: 12, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
            strip.swipeLeft()
        }
        app.buttons["tool.vignette"].tap()
        let amount = app.sliders["effects.vignette.slider.vignetteAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.adjust(toNormalizedSliderPosition: 0.3)
        let panel = app.scrollViews["editor.panel"]
        func scrollPanel(up: Bool) {
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: up ? 0.85 : 0.15))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: up ? 0.15 : 0.85))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        for parameter in ["vignetteAmount", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights"] {
            let slider = app.sliders["effects.vignette.slider.\(parameter)"]
            for _ in 0..<3 {
                if panel.frame.insetBy(dx: 0, dy: 12).contains(CGPoint(x: slider.frame.midX, y: slider.frame.midY)) { break }
                scrollPanel(up: true)
            }
            XCTAssertTrue(slider.isHittable, app.debugDescription)
        }
        capture("effects-vignette-portrait")
        scrollPanel(up: false)
        app.buttons["重置暗角"].tap()
        XCTAssertEqual(app.textFields["effects.vignette.value.vignetteAmount"].value as? String, "0")
        XCTAssertFalse(app.sliders["effects.vignette.slider.vignetteHighlights"].isEnabled)
        for _ in 0..<8 {
            let frame = app.buttons["tool.grain"].frame
            if frame.width > 0 && strip.frame.insetBy(dx: 12, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
            strip.swipeLeft()
        }
        app.buttons["tool.grain"].tap()
        let grain = app.sliders["effects.grain.slider.grainAmount"]
        XCTAssertTrue(grain.waitForExistence(timeout: 5))
        grain.adjust(toNormalizedSliderPosition: 0.6)
        for parameter in ["grainAmount", "grainSize", "grainRoughness"] {
            let slider = app.sliders["effects.grain.slider.\(parameter)"]
            for _ in 0..<3 {
                if panel.frame.insetBy(dx: 0, dy: 12).contains(CGPoint(x: slider.frame.midX, y: slider.frame.midY)) { break }
                scrollPanel(up: true)
            }
            XCTAssertTrue(slider.isHittable)
        }
        capture("effects-grain-portrait")
        scrollPanel(up: false)
        app.buttons["重置颗粒"].tap()
        XCTAssertEqual(app.textFields["effects.grain.value.grainAmount"].value as? String, "0")
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

    func testPhotoInfoOverlay() {
        let app = XCUIApplication()
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
        app.launch()
        importPhoto(in: app)

        app.buttons["editor.export"].tap()
        app.buttons["保存当前照片"].tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '导出尺寸'")).firstMatch
        let original = app.buttons["editor.export.confirm"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(original.isEnabled)
        XCTAssertTrue(picker.label.contains("原始分辨率"))
        capture("export-size-original")

        picker.tap()
        XCTAssertTrue(app.buttons["长边 2,048 px"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["长边 2,048 px"].tap()
        XCTAssertTrue(picker.label.contains("长边 2,048 px"))
        capture("export-size-2048")

        picker.tap()
        XCTAssertTrue(app.buttons["自定义…"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["自定义…"].tap()
        let invalid = app.textFields["长边（1–65535 px）"]
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
        app.buttons["自定义…"].tap()
        let valid = app.textFields["长边（1–65535 px）"]
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
        XCTAssertTrue(app.buttons["editor.export.confirm"].waitForExistence(timeout: 5))
        app.buttons["editor.export.confirm"].tap()
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
        var attemptedIndices: Set<Int> = []
        for attempt in 0..<12 {
            app.buttons["editor.import"].tap()
            let photos = app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            let candidates = photos.allElementsBoundByIndex
            let orderedIndices = candidates.indices.sorted { lhs, rhs in
                let leftIsSeedDate = candidates[lhs].label.contains(seedPhotoDate)
                let rightIsSeedDate = candidates[rhs].label.contains(seedPhotoDate)
                return leftIsSeedDate && !rightIsSeedDate
            }
            guard let index = orderedIndices.first(where: { !attemptedIndices.contains($0) }) else {
                XCTFail("The Photos picker did not expose the seeded DNG")
                return
            }
            attemptedIndices.insert(index)
            let photo = candidates[index]
            if photo.frame.midY > app.frame.maxY - 100 {
                app.scrollViews["photosView_content_scroll_view"].swipeUp()
            }
            // The system Photos grid can report no AX hit point for a visible image.
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            waitForImportedPhoto(in: app)
            let importedName = importedPhotoFileName(in: app)
            if importedName.localizedCaseInsensitiveContains(seedPhotoBase + ".DNG") {
                verifiedSeedPickerIndex = index
                return
            }
            if attempt == 11 || attemptedIndices.count == candidates.count {
                XCTFail("The seeded DNG was not selected; imported \(importedName)")
                return
            }
        }
    }

    private func waitForImportedPhoto(in app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons.matching(NSPredicate(format: "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
            if allow.exists { allow.tap() }
            return app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists
        }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.alerts.debugDescription)
    }

    private func importedPhotoFileName(in app: XCUIApplication) -> String {
        let info = app.buttons["editor.photoInfo"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), app.debugDescription)
        info.tap()
        let overlay = app.descendants(matching: .any)["editor.photoInfo.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), app.debugDescription)
        let fileName = overlay.label
        info.tap()
        info.tap()
        return fileName
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
