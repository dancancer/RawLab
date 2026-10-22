import XCTest

extension EditorUITests {
    func checkSaveNoticeLayout(orientation: UIDeviceOrientation, contentSizeCategory: String? = nil) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        let importer = app.buttons["editor.import.empty"]
        XCTAssertTrue(importer.waitForExistence(timeout: 10))
        importer.tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "Seed one photo with simctl addmedia before running")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForImportedPhoto(in: app)
        let panel = app.scrollViews["editor.panel"]
        let reset = app.buttons["Reset Adjustments"]
        let tool = app.buttons["tool.exposure"]
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        let value = app.buttons["adjustment.value"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        XCTAssertTrue(tool.isSelected, "The save regression must exercise the selected native exposure control")
        XCTAssertTrue(ruler.isHittable, "The native ruler must be reachable at every text size")
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Adjustments Saved")).firstMatch
        let scalarReset = app.buttons["adjustment.reset"]
        if scalarReset.isEnabled {
            scalarReset.tap()
            XCTAssertTrue(notice.waitForExistence(timeout: 5))
        }
        let transientNotice = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@", "Adjustments Saved", "Previous Adjustments Restored"
        )).firstMatch
        expectation(for: NSPredicate { _, _ in !transientNotice.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertGreaterThanOrEqual(reset.frame.width, 44)
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        XCTAssertTrue(panel.frame.contains(reset.frame), "The reset target must remain inside the panel at every text size")
        let controls = [panel, tool, ruler, reset]
        let beforeFrames = controls.map(\.frame)
        let originalValue = value.value as? String
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        XCTAssertNotEqual(value.value as? String, originalValue, "An actual native ruler drag must commit an adjustment")
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        let savedFrames = controls.map(\.frame)
        XCTAssertTrue(reset.isEnabled)
        XCTAssertTrue(reset.isHittable, "Save feedback must preserve the reset target")
        assertSaveNoticeFrames(beforeFrames, equalTo: savedFrames)
        capture("save-notice-\(orientation.rawValue)-\(contentSizeCategory ?? "default")")
        expectation(for: NSPredicate { _, _ in !notice.exists }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        let idleFrames = controls.map(\.frame)
        assertSaveNoticeFrames(beforeFrames, equalTo: idleFrames)
        XCTAssertTrue(reset.isHittable)
        print("SAVE_NOTICE_FRAMES orientation=\(orientation.rawValue) category=\(contentSizeCategory ?? "default") before=\(beforeFrames) saved=\(savedFrames) idle=\(idleFrames)")
        capture("save-notice-dismissed-\(orientation.rawValue)-\(contentSizeCategory ?? "default")")
    }

    func assertSaveNoticeFrames(_ expected: [CGRect], equalTo actual: [CGRect]) {
        for (before, after) in zip(expected, actual) {
            XCTAssertEqual(before.origin.x, after.origin.x, accuracy: 0.5, "Save feedback must not move editing controls horizontally")
            XCTAssertEqual(before.origin.y, after.origin.y, accuracy: 0.5, "Save feedback must not move editing controls vertically")
            XCTAssertEqual(before.width, after.width, accuracy: 0.5, "Save feedback must not resize editing controls horizontally")
            XCTAssertEqual(before.height, after.height, accuracy: 0.5, "Save feedback must not resize editing controls vertically")
        }
    }

    func dragRuler(_ ruler: XCUIElement, increasing: Bool = true) {
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        XCTAssertTrue(ruler.isHittable)
        ruler.coordinate(withNormalizedOffset: CGVector(dx: increasing ? 0.7 : 0.4, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: ruler.coordinate(
                withNormalizedOffset: CGVector(dx: increasing ? 0.4 : 0.7, dy: 0.5)))
    }

    func revealRuler(_ ruler: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(ruler.waitForExistence(timeout: 5), app.debugDescription)
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<12 {
            let frame = ruler.frame
            let visible = panel.frame.insetBy(dx: 0, dy: min(40, panel.frame.height * 0.2))
            if visible.contains(CGPoint(x: frame.midX, y: frame.midY)) && ruler.isHittable { return }
            let up = frame.isEmpty || frame.midY > visible.midY
            let distance = frame.isEmpty ? panel.frame.height * 0.6 : abs(frame.midY - panel.frame.midY)
            let amount = min(0.6, max(0.12, distance / max(1, panel.frame.height)))
            let startY: CGFloat = up ? 0.82 : 0.18
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: startY))
                .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.12, dy: startY + (up ? -amount : amount))),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("Could not reveal \(ruler.identifier): ruler \(ruler.frame), panel \(panel.frame)")
    }

    func tapTool(_ name: String, in app: XCUIApplication) {
        let group: String
        switch name {
        case "film", "masterRecipe", "strength": group = "looks"
        case "exposure", "highlights", "shadows", "contrast", "toneCurve": group = "light"
        case "temperature", "tint", "saturation", "hsl": group = "color"
        case "vignette", "grain": group = "effects"
        case "noiseReduction", "sharpening": group = "detail"
        default: group = "geometry"
        }
        let groupButton = app.buttons["editor.group." + group]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in groupButton.exists && groupButton.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        if !groupButton.isSelected || !app.buttons["tool." + name].exists {
            let groups = app.scrollViews["editor.groups"]
            for _ in 0..<12 {
                if groupButton.isHittable && groups.frame.contains(CGPoint(x: groupButton.frame.midX, y: groupButton.frame.midY)) { break }
                if groupButton.frame.midX < groups.frame.midX { groups.swipeRight() } else { groups.swipeLeft() }
            }
            groupButton.tap()
        }
        let button = app.buttons["tool." + name]
        let strip = app.scrollViews.containing(.button, identifier: "tool." + name)
            .allElementsBoundByIndex.min { $0.frame.height < $1.frame.height }!
        for _ in 0..<12 {
            let frame = button.frame
            let viewport = strip.frame.intersection(CGRect(origin: .zero, size: app.frame.size)).insetBy(dx: 8, dy: 0)
            if frame.width > 0 && viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                return
            }
            if frame.midX < strip.frame.midX { strip.swipeRight() } else { strip.swipeLeft() }
        }
        XCTFail("Could not reveal tool: " + name)
    }

    func isFittedPhoto(_ canvas: XCUIElement) -> Bool {
        guard let value = canvas.value as? String else { return false }
        let parts = value.split(separator: " ")
        guard parts.count > 1, let percentage = parts.last, percentage.hasSuffix("%"),
              let number = Int(percentage.dropLast()), number >= 0 else { return false }
        return parts.dropLast().joined(separator: " ").rangeOfCharacter(from: .letters) != nil
    }

    func importPhoto(in app: XCUIApplication) {
        var attemptedIndices: Set<Int> = []
        for attempt in 0..<12 {
            let emptyImport = app.buttons["editor.import.empty"]
            if emptyImport.isHittable { emptyImport.tap() }
            else { app.buttons["editor.import"].tap() }
            let photos = app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            let candidates = photos.allElementsBoundByIndex
            let labels = candidates.map(\.label)
            let orderedIndices = candidates.indices.sorted { lhs, rhs in
                let leftIsSeedDate = labels[lhs].contains(seedPhotoDate)
                let rightIsSeedDate = labels[rhs].contains(seedPhotoDate)
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

    func waitForImportedPhoto(in app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons.matching(NSPredicate(format: "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
            if allow.exists { allow.tap() }
            return app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists
        }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.alerts.debugDescription)
        tapTool("exposure", in: app)
    }

    func importedPhotoFileName(in app: XCUIApplication) -> String {
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

    func revealFilm(_ name: String, in app: XCUIApplication) {
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

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func hasRedArtwork(_ image: UIImage) -> Bool {
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
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                return red > 100 && red > green * 1.8 && red > blue * 1.8
            }.count
        }
        return redPixels > 4
    }
}
