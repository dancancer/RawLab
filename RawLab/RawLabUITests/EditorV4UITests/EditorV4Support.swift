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
        XCTAssertFalse(app.buttons["editor.adjustments"].isEnabled)
        XCTAssertFalse(app.buttons["tool.film"].exists)
        let labels = Set(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })
        XCTAssertTrue(labels.isSubset(of: Set(["RawLab", importLabel])), "The empty editor must show only functional copy and its optional navigation title")
    }

    func assertFileImportItem(enabled: Bool, in app: XCUIApplication) {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), app.debugDescription)
        privacy.tap()
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(file.isEnabled, enabled, "File import must follow editor draft/busy lock")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        waitUntil { !file.exists }
    }

    func cancelFileImporter(in app: XCUIApplication) {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), app.debugDescription)
        privacy.tap()
        let file = app.buttons["editor.import.file"]
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The Files picker can only be opened from a clean editor state")
        file.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        waitUntil(timeout: 10) { !cancel.exists && app.descendants(matching: .any)["editor.photo"].exists }
    }

    func selectSeededFilesImage(in app: XCUIApplication) throws {
        let privacy = app.buttons["editor.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), app.debugDescription)
        privacy.tap()
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

        let downloads = app.cells.matching(identifier: "Downloads").firstMatch
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
            return app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists
        }
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tool.film"].waitForExistence(timeout: 10))
        try selectTool("exposure", in: app)
    }

    func selectTool(_ name: String, in app: XCUIApplication) throws {
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
        waitUntil(timeout: 30) { groupButton.exists && groupButton.isEnabled }
        if groupButton.exists && (!groupButton.isSelected || !app.buttons["tool." + name].exists) {
            let groups = app.scrollViews["editor.groups"]
            try revealHorizontally(groupButton, in: groups, app: app)
            groupButton.tap()
        }
        let tool = app.buttons["tool." + name]
        let strips = app.scrollViews.containing(.button, identifier: "tool." + name).allElementsBoundByIndex
        let strip = try XCTUnwrap(strips.min { $0.frame.height < $1.frame.height }, "Editor tool strip missing")
        try revealHorizontally(tool, in: strip, app: app)
        tapVisible(tool, in: app)
    }

    func revealHorizontally(_ element: XCUIElement, in strip: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<18 {
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
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: startY))
                .press(forDuration: 0.1,
                       thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: endY)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture("v4-unreachable-" + element.identifier, in: app)
        XCTFail("Could not reveal \(element.identifier): element \(element.frame), panel \(panel.frame)")
    }

    func openWheel(_ identifier: String, in app: XCUIApplication) throws {
        if identifier.hasPrefix("geometry.perspective") {
            try selectTool("perspective", in: app)
        } else if identifier.hasPrefix("geometry.") {
            try selectTool("geometry", in: app)
            if identifier.hasPrefix("geometry.crop") { try expandCropDimensions(in: app) }
        }
        let button = app.buttons[identifier]
        try revealInPanel(button, in: app, fully: true)
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
        let dimensions = app.buttons["geometry.dimensions"]
        if !dimensions.isSelected {
            try revealInPanel(dimensions, in: app)
            dimensions.tap()
        }
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

    func applyDraft(in app: XCUIApplication) {
        let apply = app.buttons["editor.draft.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        waitUntil(timeout: 60) { apply.isEnabled && apply.isHittable }
        apply.tap()
        waitUntil { app.buttons["adjustment.value"].exists && !apply.exists }
    }

    func resetParameterDefault(_ identifier: String, in app: XCUIApplication) throws {
        try openWheel("\(identifier).value", in: app)
        app.buttons["adjustment.wheel.default"].tap()
        app.buttons["adjustment.wheel.apply"].tap()
        waitUntil { !app.buttons["adjustment.wheel.apply"].exists }
    }

    func resetIfEnabled(_ identifier: String, in app: XCUIApplication) {
        let reset = app.buttons[identifier]
        if reset.isEnabled {
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
            && !app.launchArguments.contains("UICTContentSizeCategoryAccessibilityXXXL")
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

    func assertLargeTextPhotoVisible(in app: XCUIApplication) {
        let photo = app.descendants(matching: .any)["editor.photo"]
        waitUntil {
            photo.frame.height >= 80 && app.frame.insetBy(dx: -1, dy: -1).contains(photo.frame)
        }
        XCTAssertGreaterThanOrEqual(photo.frame.height, 80, "Large text must preserve a visible photo region")
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
