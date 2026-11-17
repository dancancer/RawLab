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
        // v0.8: the tool page replaces the overview tiles; reset lives in the workspace draft control.
        let reset = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                     "editor.draft.reset", "Reset Adjustments")).firstMatch
        let workspace = app.buttons["editor.tool.back"]
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        let value = app.buttons["adjustment.value"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        XCTAssertTrue(workspace.waitForExistence(timeout: 10),
                      "The save regression must exercise the selected native exposure tool page")
        XCTAssertTrue(ruler.isHittable, "The native ruler must be reachable at every text size")
        resetParameterDefault("adjustment", expectedValue: "0.00 EV", in: app)
        let rowAnchor = app.buttons["editor.tool.more"]
        func assertResetTarget() {
            XCTAssertGreaterThanOrEqual(reset.frame.width, 44)
            XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
            XCTAssertTrue(reset.isHittable, "Draft editing and Apply must preserve the reset hit target")
            XCTAssertTrue(app.frame.contains(reset.frame), "The reset target must stay fully on screen")
            XCTAssertTrue(rowAnchor.waitForExistence(timeout: 5))
            XCTAssertEqual(reset.frame.midY, rowAnchor.frame.midY, accuracy: 8,
                           "Reset must stay in the workspace actions row")
            let overlap = reset.frame.intersection(panel.frame)
            XCTAssertTrue(overlap == .null || overlap.width <= 1 || overlap.height <= 1,
                          "Reset must not intrude into the parameter panel: \(overlap)")
        }
        // v0.8 keeps edits in a draft and shows Saved only in processing settings.
        // The old toast lock is retired; exercise real drag -> Apply -> reopen instead.
        assertResetTarget()
        let controls = [panel, workspace, ruler, reset]
        let beforeFrames = controls.map(\.frame)
        let originalValue = value.value as? String
        dragRuler(ruler)
        let draftValue = value.value as? String
        XCTAssertNotEqual(draftValue, originalValue, "An actual ruler drag must change the draft")
        XCTAssertTrue(app.buttons["editor.draft.undo"].isEnabled, "The draft must record the drag")
        let draftFrames = controls.map(\.frame)
        assertResetTarget()
        // The changing numeric readout may consume ruler width, not move its track or the other controls.
        assertSaveNoticeFrames([beforeFrames[0], beforeFrames[1], beforeFrames[3]],
                              equalTo: [draftFrames[0], draftFrames[1], draftFrames[3]])
        XCTAssertEqual(beforeFrames[2].minX, draftFrames[2].minX, accuracy: 0.5)
        XCTAssertEqual(beforeFrames[2].minY, draftFrames[2].minY, accuracy: 0.5)
        XCTAssertEqual(beforeFrames[2].height, draftFrames[2].height, accuracy: 0.5)
        capture("draft-layout-\(orientation.rawValue)-\(contentSizeCategory ?? "default")")
        applyEditorTool(in: app)
        XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, draftValue,
                       "Apply must commit the actual dragged value")
        tapTool("exposure", in: app)
        XCTAssertEqual(value.value as? String, draftValue, "Reopening must retain the committed value")
        XCTAssertFalse(app.buttons["editor.draft.undo"].isEnabled, "Apply starts a clean local history")
        assertResetTarget()
        let committedFrames = controls.map(\.frame)
        assertSaveNoticeFrames(draftFrames, equalTo: committedFrames)
        print("DRAFT_APPLY_FRAMES orientation=\(orientation.rawValue) category=\(contentSizeCategory ?? "default") before=\(beforeFrames) draft=\(draftFrames) committed=\(committedFrames)")
        capture("applied-layout-\(orientation.rawValue)-\(contentSizeCategory ?? "default")")
    }

    func assertSaveNoticeFrames(_ expected: [CGRect], equalTo actual: [CGRect]) {
        for (before, after) in zip(expected, actual) {
            XCTAssertEqual(before.origin.x, after.origin.x, accuracy: 0.5, "Save feedback must not move editing controls horizontally")
            XCTAssertEqual(before.origin.y, after.origin.y, accuracy: 0.5, "Save feedback must not move editing controls vertically")
            XCTAssertEqual(before.width, after.width, accuracy: 0.5, "Save feedback must not resize editing controls horizontally")
            XCTAssertEqual(before.height, after.height, accuracy: 0.5, "Save feedback must not resize editing controls vertically")
        }
    }

    func resetParameterDefault(_ identifier: String, expectedValue: String, in app: XCUIApplication) {
        let value = app.buttons["\(identifier).value"]
        revealRuler(value, in: app)
        value.tap()
        let action = app.buttons["adjustment.wheel.default"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); XCTAssertTrue(action.isHittable); action.tap()
        app.buttons["adjustment.wheel.apply"].tap()
        expectation(for: NSPredicate { _, _ in !app.buttons["adjustment.wheel.apply"].exists }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(value.value as? String, expectedValue)
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
            // 短面板的首行本来就靠近边缘；完整可点的控件无需再滚动居中。
            if !frame.isEmpty && panel.frame.contains(frame) && ruler.isHittable { return }
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

    /// The v0.8 draft-exit guard dialog follows the app language (ContentView's
    /// 应用/放弃修改/继续编辑 buttons): match both decisions by their localized labels and
    /// answer with the caller's intent instead of a hardcoded English literal.
    @discardableResult
    func resolveDraftGuard(commit: Bool, in app: XCUIApplication, timeout: TimeInterval = 2) -> Bool {
        let labels = commit
            ? ["Apply", "应用", "Anwenden", "Appliquer", "適用", "Aplicar"]
            : ["Discard Changes", "放弃修改", "Änderungen verwerfen", "Abandonner les modifications", "変更を破棄", "Descartar cambios"]
        let decision = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        guard decision.waitForExistence(timeout: timeout) else { return false }
        decision.tap()
        return true
    }

    func tapTool(_ name: String, in app: XCUIApplication, commitDraft: Bool = false) {
        // v0.8 two-level workbench: on a tool page, return to the overview grid first;
        // a leftover draft is discarded by default so the next tool opens a clean workspace.
        // Callers asserting committed results answer the guard with Apply via commitDraft: true.
        if app.buttons["editor.tool.back"].exists {
            app.buttons["editor.tool.back"].tap()
            resolveDraftGuard(commit: commitDraft, in: app)
        }
        let group: String
        switch name {
        case "film", "masterRecipe", "strength": group = "looks"
        case "exposure", "highlights", "shadows", "contrast", "toneCurve": group = "light"
        case "temperature", "tint", "saturation", "hsl": group = "color"
        case "clarity", "dehaze", "vignette", "grain": group = "effects"
        case "noiseReduction", "sharpening": group = "detail"
        default: group = "geometry"
        }
        let groupButton = app.buttons["editor.group." + group]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in groupButton.exists && groupButton.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, app.debugDescription)
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
                XCTAssertTrue(app.scrollViews["editor.panel"].waitForExistence(timeout: 15), app.debugDescription)
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

    func importRAWFile(in app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        let files = app.buttons.matching(identifier: "editor.import.file")
        XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 5))
        // v0.8: the overflow popover is short; the Files row sits below the fold until scrolled.
        for _ in 0..<6 where !files.allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            let container = app.collectionViews.firstMatch
            if container.exists { container.swipeUp() } else { break }
        }
        guard let file = files.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Files import menu item is not reachable"); return
        }
        file.tap()
        let local = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "DOC.sidebar.item.", "iPad", "iPhone")).firstMatch
        if !local.waitForExistence(timeout: 10) {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.exists && browse.isHittable { browse.tap() }
        }
        XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription); local.tap()
        let downloads = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", "Downloads", "下载项")).firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription); downloads.tap()
        let raw = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", seedPhotoBase, seedPhotoBase)).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10), app.debugDescription); raw.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        waitForImportedPhoto(in: app)
        XCTAssertTrue(importedPhotoFileName(in: app).localizedCaseInsensitiveContains(seedPhotoBase + ".DNG"))
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
            waitForImportedPhoto(in: app, openingExposure: false)
            let importedName = importedPhotoFileName(in: app)
            if importedName.localizedCaseInsensitiveContains(seedPhotoBase + ".DNG") {
                verifiedSeedPickerIndex = index
                if app.buttons["editor.draft.cancel"].exists { cancelEditorTool(in: app) }
                tapTool("exposure", in: app)
                return
            }
            if attempt == 11 || attemptedIndices.count == candidates.count {
                XCTFail("The seeded DNG was not selected; imported \(importedName)")
                return
            }
            if app.buttons["editor.draft.cancel"].exists {
                // 非目标照片可能恢复已有草稿；重启保留它，再从空编辑器继续选样片。
                app.terminate()
                app.launch()
                XCTAssertTrue(app.buttons["editor.import.empty"].waitForExistence(timeout: 10), app.debugDescription)
            }
        }
    }

    func waitForImportedPhoto(in app: XCUIApplication, openingExposure: Bool = true) {
        expectation(for: NSPredicate { _, _ in
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons.matching(NSPredicate(format: "label == '允许完全访问' OR label == 'Allow Full Access'")).firstMatch
            if allow.exists { allow.tap() }
            return (!app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.exists
                && app.descendants(matching: .any)["editor.photo"].exists
                && !app.descendants(matching: .any)["editor.preview.updating"].exists)
                || app.alerts.firstMatch.exists
        }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        let photo = app.descendants(matching: .any)["editor.photo"]
        if app.alerts.firstMatch.exists {
            let alert = app.alerts.firstMatch
            print("IMPORT_FAILURE_ALERT texts=\(alert.staticTexts.allElementsBoundByIndex.map(\.label)) buttons=\(alert.buttons.allElementsBoundByIndex.map(\.label))")
            capture("import-failure-alert")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "Photo import must finish without an error alert.\n" + app.alerts.debugDescription)
        XCTAssertTrue(photo.exists, app.debugDescription)
        if openingExposure { tapTool("exposure", in: app) }
    }

    func applyEditorTool(in app: XCUIApplication) {
        let apply = app.buttons["editor.draft.apply"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            apply.exists && apply.isEnabled && apply.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, app.debugDescription)
        apply.tap()
        let overview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let importer = app.buttons["editor.import"]
            return importer.exists && importer.isEnabled && !apply.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [overview], timeout: 90), .completed, app.debugDescription)
        XCTAssertFalse(apply.exists)
    }

    func cancelEditorTool(in app: XCUIApplication) {
        let cancel = app.buttons["editor.draft.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.tap()
        let overview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let importer = app.buttons["editor.import"]
            return importer.exists && importer.isEnabled && !cancel.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [overview], timeout: 90), .completed, app.debugDescription)
    }

    func tapEditorMenuAction(_ identifier: String, in app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
    }

    func importedPhotoFileName(in app: XCUIApplication) -> String {
        let info = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@",
            "editor.photoInfo", ["照片信息", "Photo Information"])).firstMatch
        func advancePhotoInfo() {
            let toolMore = app.buttons["editor.tool.more"]
            let more = toolMore.exists ? toolMore : app.buttons["editor.privacy"]
            XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
            more.tap()
            XCTAssertTrue(info.waitForExistence(timeout: 5), app.debugDescription)
            info.tap()
        }
        advancePhotoInfo()
        let overlay = app.descendants(matching: .any)["editor.photoInfo.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), app.debugDescription)
        let fileName = overlay.label
        advancePhotoInfo()
        advancePhotoInfo()
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
