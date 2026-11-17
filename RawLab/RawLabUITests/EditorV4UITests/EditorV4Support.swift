import XCTest

extension EditorV4UITests {
    func assertFunctionalEmptyEditor(in app: XCUIApplication, importLabel: String) {
        let emptyImport = app.buttons["editor.import.empty"]
        XCTAssertTrue(emptyImport.waitForExistence(timeout: 5))
        XCTAssertEqual(emptyImport.label, importLabel)
        XCTAssertTrue(emptyImport.isEnabled && emptyImport.isHittable)
        XCTAssertGreaterThanOrEqual(emptyImport.frame.height, 44)
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(emptyImport.frame))
        XCTAssertTrue(app.buttons["editor.import"].isEnabled && app.buttons["editor.import"].isHittable)
        XCTAssertFalse(app.buttons["editor.export"].isEnabled)
        XCTAssertFalse(app.buttons["editor.adjustments"].exists,
                       "The collapsed v0.8 overview keeps the adjustment bar entry inside the overflow menu until a photo is loaded")
        XCTAssertFalse(app.buttons["tool.film"].exists)
        let labels = Set(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })
        XCTAssertTrue(labels.isSubset(of: Set(["RawLab", importLabel])), "The empty editor must show only functional copy and its optional navigation title")
    }

    @discardableResult
    private func waitTrue(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    /// v0.8: overflow menus are short popovers; SwiftUI may not expose rows below the
    /// fold, so scroll the menu container until the row is hittable.
    func revealOverflowItem(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !item.isHittable {
            let container = app.collectionViews.firstMatch
            if container.exists {
                container.swipeUp()
            } else if item.exists {
                item.swipeUp()
            } else {
                break
            }
        }
    }

    private func dismissOverflowMenu(_ privacy: XCUIElement, _ probe: XCUIElement, in app: XCUIApplication) {
        // The anchored popover swallows taps that land inside it, and while the busy
        // editor flickers its toolbar the privacy anchor is not immediately hittable;
        // dismiss from the photo area and wait for a stable anchor before a re-tap.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        if !waitTrue(3, { !probe.exists }) {
            XCTAssertTrue(waitTrue(10, { privacy.isHittable }),
                          "The privacy anchor must return once the popover closes: \(app.debugDescription)")
            privacy.tap()
        }
        waitUntil { !probe.exists }
    }

    /// Opens the overview overflow menu. The busy editor re-renders its toolbar, so wait
    /// for a stable hittable state before tapping (otherwise the tap races the flicker).
    @discardableResult
    func openOverflowMenu(in app: XCUIApplication) -> XCUIElement {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(waitTrue(15, { privacy.exists && privacy.isHittable }), app.debugDescription)
        privacy.tap()
        return privacy
    }

    func assertFileImportItem(enabled: Bool, in app: XCUIApplication) {
        let privacy = openOverflowMenu(in: app)
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(file.isEnabled, enabled, "File import must follow editor draft/busy lock")
        dismissOverflowMenu(privacy, file, in: app)
    }

    func cancelFileImporter(in app: XCUIApplication) {
        openOverflowMenu(in: app)
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The Files picker can only be opened from a clean editor state")
        revealOverflowItem(file, in: app)
        file.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        waitUntil(timeout: 10) { !cancel.exists && app.descendants(matching: .any)["editor.photo"].exists }
    }

    func selectSeededFilesImage(in app: XCUIApplication) throws {
        openOverflowMenu(in: app)
        let candidate = app.buttons.matching(identifier: "editor.import.file").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), app.debugDescription)
        revealOverflowItem(candidate, in: app)
        let filesItems = app.buttons.matching(identifier: "editor.import.file").allElementsBoundByIndex
        let file = filesItems.first { $0.exists && $0.isHittable }
        XCTAssertNotNil(file, app.debugDescription)
        guard let file else { return }
        XCTAssertTrue(file.isEnabled, "The Files picker can only be opened from a clean empty editor state")
        file.tap()

        let localStorage = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My ")).firstMatch
        if !localStorage.waitForExistence(timeout: 2) {
            let browse = app.buttons["Browse"].firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
            browse.tap()
        }

        let downloadsBeforeNavigation = app.cells.matching(identifier: "Downloads").firstMatch
        if !downloadsBeforeNavigation.waitForExistence(timeout: 2) {
            let location = app.cells.allElementsBoundByIndex.first {
                $0.label == "On My iPhone" || $0.label == "On My iPad"
                    || $0.identifier.hasPrefix("DOC.sidebar.item.On My ")
            }
            if let location {
                location.tap()
            } else {
                let locationButton = app.buttons.allElementsBoundByIndex.first {
                    $0.label == "On My iPhone" || $0.label == "On My iPad"
                }
                XCTAssertNotNil(locationButton, app.debugDescription)
                guard let locationButton else { return }
                locationButton.tap()
            }
        }

        // iOS 27 reports the folder row as identifier "Downloads, Folder"; the Files
        // sidebar/section labels localize ("下载项"), so keep the tolerant matcher
        // used by EditorSupport.importRAWFile.
        let downloads = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@",
                                                       "Downloads", "下载项")).firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
        downloads.tap()

        var fixture: XCUIElement?
        waitUntil(timeout: 15) {
            let candidate = app.cells.matching(identifier: "RawLabFilesFixture, png").firstMatch
            if candidate.exists {
                fixture = candidate
                return true
            }
            return false
        }
        XCTAssertNotNil(fixture, app.debugDescription)
        guard let fixture else { return }
        fixture.tap()
        waitUntil(timeout: 60) {
            app.descendants(matching: .any)["editor.photo"].exists
        }
    }

    func openAndCancelPhotoPicker(_ identifier: String, in app: XCUIApplication) {
        app.buttons[identifier].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        waitUntil { !cancel.exists && app.buttons["editor.import.empty"].isHittable }
    }

    func launchImportedEditor() throws -> XCUIApplication {
        let app = XCUIApplication()
        launchEnglish(app)
        try importFirstVisiblePhoto(in: app)
        return app
    }

    func launchEnglish(_ app: XCUIApplication, additionalArguments: [String] = []) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 10))
    }

    // The parent runner seeds a clean Photos library with one generated/public image.
    func importFirstVisiblePhoto(in app: XCUIApplication) throws {
        let empty = app.buttons["editor.import.empty"]
        if empty.isHittable { empty.tap() } else { app.buttons["editor.import"].tap() }
        let onboarding = app.staticTexts["Private Access to Photos"].firstMatch
        if onboarding.waitForExistence(timeout: 2) {
            let close = app.buttons["Close"].firstMatch
            if close.isHittable { close.tap() }
        }
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
            return (app.descendants(matching: .any)["editor.photo"].exists && !app.descendants(matching: .any)["editor.preview.updating"].exists) || app.alerts.firstMatch.exists
        }
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 10), app.debugDescription)
        try selectTool("exposure", in: app)
    }

    /// v0.8 two-level workbench (Android #455/#457 precedent): the group row and the tool
    /// grid only exist on the workbench overview; the tool page replaces them with
    /// `editor.panel`. Leaving a tool page with an uncommitted draft runs through the
    /// shared decision dialog (Apply / Discard Changes / Keep Editing), so a helper that
    /// navigates back to the grid must resolve that dialog explicitly instead of
    /// assuming the overview is already there. Committed-draft navigation uses Apply;
    /// tests that intentionally keep a draft uncommitted stay inside the workspace.
    @discardableResult
    func exitToOverviewIfNeeded(in app: XCUIApplication, commit: Bool = true) throws -> Bool {
        guard app.buttons["editor.tool.back"].exists else { return false }
        if commit, app.buttons["editor.draft.apply"].exists, app.buttons["editor.draft.apply"].isEnabled {
            applyDraft(in: app)
            XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 5), app.debugDescription)
            return true
        }
        app.buttons["editor.tool.back"].tap()
        if waitTrue(2, { app.alerts.firstMatch.exists }) {
            let decision = app.alerts.buttons[commit ? "Apply" : "Discard Changes"]
            XCTAssertTrue(decision.waitForExistence(timeout: 5), app.debugDescription)
            decision.tap()
        }
        XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 5), app.debugDescription)
        return true
    }

    /// Selects the owning group and reveals the requested tool tile in the overview grid.
    /// Returns the revealed (not yet tapped) tile so tests can assert tile state before
    /// entering the tool page.
    @discardableResult
    func revealTool(_ name: String, in app: XCUIApplication) throws -> XCUIElement {
        let group: String
        switch name {
        case "film", "masterRecipe", "strength": group = "looks"
        case "exposure", "highlights", "shadows", "contrast", "toneCurve": group = "light"
        case "temperature", "tint", "saturation", "hsl": group = "color"
        case "clarity", "dehaze", "vignette", "grain": group = "effects"
        case "noiseReduction", "sharpening": group = "detail"
        case "hdrPeakLimit", "hdrSDRExposure", "hdrSDRContrast", "hdrSDRSaturation": group = "hdrRendition"
        default: group = "geometry"
        }
        let groupButton = app.buttons["editor.group." + group]
        XCTAssertTrue(groupButton.waitForExistence(timeout: 15) && groupButton.isEnabled,
                      "The workbench overview must expose the group row: \(groupButton.debugDescription)")
        if !groupButton.isSelected || !app.buttons["tool." + name].exists {
            let groups = app.scrollViews["editor.groups"]
            try revealHorizontally(groupButton, in: groups, app: app)
            groupButton.tap()
        }
        let tool = app.buttons["tool." + name]
        let strip = app.scrollViews["editor.tools"]
        try revealHorizontally(tool, in: strip, app: app)
        return tool
    }

    func selectTool(_ name: String, in app: XCUIApplication) throws {
        try exitToOverviewIfNeeded(in: app)
        let tool = try revealTool(name, in: app)
        tapVisible(tool, in: app)
        // Wait for the tool page to become the active workspace (draftReady analogue):
        // the panel exists and carries the workspace draft actions.
        XCTAssertTrue(app.scrollViews["editor.panel"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["editor.draft.apply"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func revealHorizontally(_ element: XCUIElement, in strip: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(strip.waitForExistence(timeout: 5), app.debugDescription)
        for attempt in 0..<18 {
            // SwiftUI 可能不向 AX 暴露屏外项，先滚动真实工具行再读取目标。
            if !element.exists {
                if attempt < 6 { strip.swipeLeft() } else { strip.swipeRight() }
                continue
            }
            let frame = element.frame
            if frame.width > 0 && strip.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
            let right = frame.midX < strip.frame.midX
            strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.25 : 0.75, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.70 : 0.30, dy: 0.5)))
        }
        XCTFail("Could not reveal \(element.identifier) in \(strip.identifier)")
    }

    func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    func revealInPanel(_ element: XCUIElement, in app: XCUIApplication, fully: Bool = false) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<12 {
            let frame = element.frame
            let panelFrame = panel.frame
            let visible = panelFrame.insetBy(dx: 0, dy: min(40, panelFrame.height * 0.2))
            if element.isHittable && (fully ? panelFrame.insetBy(dx: -1, dy: -1).contains(frame) : visible.contains(CGPoint(x: frame.midX, y: frame.midY))) { return }
            let up = frame.isEmpty || frame.midY > visible.midY
            let distance = frame.isEmpty ? panelFrame.height * 0.6 : abs(frame.midY - panelFrame.midY)
            if panelFrame.height < 120 && distance > panelFrame.height * 2 {
                if up { panel.swipeUp(velocity: .fast) } else { panel.swipeDown(velocity: .fast) }
                continue
            }
            let amount = min(0.6, max(0.08, distance / max(1, panelFrame.height)))
            let startY: CGFloat = up ? 0.82 : 0.18
            let endY = startY + (up ? -amount : amount)
            // 从参数区右侧留白拖动，避免原生菜单把按住后拖动识别为菜单交互。
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: startY))
                .press(forDuration: 0.1,
                       thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: endY)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture("v4-unreachable-" + element.identifier, in: app)
        XCTFail("Could not reveal \(element.identifier): element \(element.frame), panel \(panel.frame)")
    }

    func openWheel(_ identifier: String, in app: XCUIApplication) throws {
        if identifier.hasPrefix("geometry.") {
            if !app.buttons["geometry.tab.0"].exists { try selectTool("geometry", in: app) }
            if !app.buttons[identifier].exists {
                app.buttons[identifier.hasPrefix("geometry.perspective") ? "geometry.tab.2" : "geometry.tab.0"].tap()
                if identifier.hasPrefix("geometry.crop") { try expandCropDimensions(in: app) }
            }
        }
        let button = app.buttons[identifier]
        if !button.isHittable { try revealInPanel(button, in: app, fully: true) }
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

    func expandCropDimensions(in app: XCUIApplication) throws {
        guard !app.buttons["geometry.cropWidth.value"].exists else { return }
        app.buttons["geometry.aspectRatio"].tap()
        let dimensions = app.buttons["geometry.dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 5))
        dimensions.tap()
    }

    func selectWheelValue(_ formatted: String, title: String, unit: String = "", in app: XCUIApplication) throws {
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

    func setValue(_ formatted: String, title: String, unit: String = "", control: String, in app: XCUIApplication) throws {
        try openWheel(control + ".value", in: app)
        try selectWheelValue(formatted, title: title, unit: unit, in: app)
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { !app.descendants(matching: .any)["adjustment.wheel"].exists }
    }

    /// Leaves the workspace back to the overview grid. `editor.draft.cancel` only exits while a
    /// draft is dirty (the button is disabled on a clean draft), so prefer the back button and
    /// answer the localized guard by discarding — the product cancel path itself discards
    /// directly (EditorDrafts.cancelEditorDraft) without an alert.
    func cancelToolWorkspace(in app: XCUIApplication) {
        if app.buttons["editor.tool.back"].exists {
            app.buttons["editor.tool.back"].tap()
            let labels = ["Discard Changes", "放弃修改", "Änderungen verwerfen",
                          "Abandonner les modifications", "変更を破棄", "Descartar cambios"]
            let decision = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if decision.waitForExistence(timeout: 2) { decision.tap() }
        } else {
            app.buttons["editor.draft.cancel"].tap()
        }
        XCTAssertTrue(app.scrollViews["editor.tools"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func applyDraft(in app: XCUIApplication) {
        let apply = app.buttons["editor.draft.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        waitUntil(timeout: 60) { apply.isEnabled && apply.isHittable }
        apply.tap()
        waitUntil { app.scrollViews["editor.tools"].exists && !apply.exists }
    }

    func resetParameterDefault(_ identifier: String, in app: XCUIApplication) throws {
        try openWheel("\(identifier).value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { !app.buttons["adjustment.wheel.apply"].exists }
    }

    func resetIfEnabled(_ identifier: String, in app: XCUIApplication) {
        let reset = app.buttons[identifier]
        if reset.exists && reset.isEnabled {
            try? revealInPanel(reset, in: app)
            reset.tap()
        }
    }

    func dragRuler(_ ruler: XCUIElement, from start: CGFloat, to end: CGFloat) {
        ruler.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.4)))
    }

    func number(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let value = try XCTUnwrap(element.value as? String, "Value missing for \(element.identifier)", file: file, line: line)
        let token = value.split(separator: " ").first.map(String.init) ?? value
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return try XCTUnwrap(Double(token) ?? formatter.number(from: token)?.doubleValue,
                             "Non-numeric value: \(value)", file: file, line: line)
    }

    func assertExposureGrid(_ value: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(value, -4, file: file, line: line)
        XCTAssertLessThanOrEqual(value, 4, file: file, line: line)
        XCTAssertEqual(value / 0.05, (value / 0.05).rounded(), accuracy: 0.0001, file: file, line: line)
    }

    func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, file: file, line: line)
    }

    func waitForLandscapeSidePanel(in app: XCUIApplication) {
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

    func assertNativeWheelVisible(in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        let wheel = picker.pickerWheels.firstMatch
        let standardIPad = min(app.frame.width, app.frame.height) >= 700
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

    func assertWheelContextVisible(in app: XCUIApplication) {
        for identifier in ["adjustment.wheel.title", "adjustment.wheel.draft", "adjustment.wheel.range", "adjustment.wheel.default"] {
            let element = app.descendants(matching: .any)[identifier]
            waitUntil { element.isHittable && app.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
            XCTAssertTrue(element.isHittable, "Wheel context must be visible when opened: \(identifier)")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(element.frame), "Complete wheel context must fit in the window")
        }
    }

    func capture(_ name: String, in app: XCUIApplication) {
        capture(name, screenshot: XCUIScreen.main.screenshot())
    }

    func capture(_ name: String, screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
