import XCTest
import CoreFoundation

final class ViewingEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    func testHSLTargetPhotoDragHistoryAndPinchCancellation() {
        let app = launch(language: "en")
        app.buttons["editor.group.color"].tap(); app.buttons["tool.hsl"].tap()
        let toggle = app.buttons["hsl.target"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        app.buttons["Lightness"].tap()
        wait(app) { $0["hslTargetEnabled"] as? Bool == true && $0["hslTargetAxis"] as? String == "lightness" }
        let before = receipt(app)
        let history = before["historyCount"] as! Int
        let values = before["hslValues"] as! [Double]
        let photo = app.images["editor.photo"]
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -45)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        wait(app) { $0["ready"] as? Bool == true && $0["hslTargetWaiting"] as? Bool == false && $0["historyCount"] as? Int == history + 1 }
        let adjusted = receipt(app)["hslValues"] as! [Double]
        XCTAssertEqual(Array(adjusted.prefix(16)), Array(values.prefix(16)), "Target only changes the selected axis")
        XCTAssertNotEqual(adjusted, values)
        capture(app, "hsl-target-drag")
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["hslValues"] as? [Double] == values }
        openAdjustmentAction("adjustment.history.redo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["hslValues"] as? [Double] == adjusted }
        photo.pinch(withScale: 1.5, velocity: 1)
        wait(app) { $0["ready"] as? Bool == true && $0["hslTargetWaiting"] as? Bool == false }
        XCTAssertEqual(receipt(app)["hslValues"] as? [Double], adjusted, "A second finger cancels target input before zoom")
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, history + 1)
    }

    func openAdjustmentAction(_ id: String, app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        let labels = ["adjustment.history.undo": "Undo", "adjustment.history.redo": "Redo",
                      "adjustment.copy.open": "Copy Adjustments", "adjustment.paste.open": "Paste Adjustments",
                      "adjustment.history.open": "Session History", "preset.library.open": "My Presets"]
        let identified = app.buttons.matching(identifier: id).firstMatch
        let action = identified.exists ? identified : app.collectionViews.buttons.matching(identifier: labels[id] ?? id).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
    }

    func revealFormControl(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Unreachable form control: \(element.identifier)\n\(app.debugDescription)")
    }

    func toggleField(_ element: XCUIElement) {
        let previous = element.value as? String
        let nativeSwitch = element.switches.firstMatch
        if nativeSwitch.exists { nativeSwitch.tap() } else { element.tap() }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.value as? String != previous }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    func setExposure(_ value: String, app: XCUIApplication) {
        app.buttons["adjustment.value"].tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        wheel.adjust(toPickerWheelValue: "Exposure, \(value) EV")
        app.buttons["adjustment.wheel.apply"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["gestureActive"] as? Bool == false }
    }

    func testAdjustmentGestureHistoryAndFrozenPaste() {
        let app = launch(language: "en")
        app.buttons["editor.group.light"].tap()
        let ruler = app.descendants(matching: .any).matching(identifier: "adjustment.ruler").firstMatch
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        let original = receipt(app)["exposure"] as! Double
        let before = (receipt(app)["saves"] as! [[String: Any]]).count
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.8)
        wait(app) { $0["ready"] as? Bool == true && $0["historyCount"] as? Int == 1 }
        let dragged = receipt(app)["exposure"] as! Double
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a ruler drag must not summon the text keyboard")
        XCTAssertNotEqual(dragged, original)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, before + 1,
                       "a real long native drag creates one successful save")
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["exposure"] as? Double == original }
        openAdjustmentAction("adjustment.history.redo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["exposure"] as? Double == dragged }
        setExposure("+0.75", app: app)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 2)
        openAdjustmentAction("adjustment.copy.open", app: app)
        XCTAssertTrue(app.buttons["adjustment.copy.clear"].waitForExistence(timeout: 5))
        app.buttons["adjustment.copy.clear"].tap()
        app.descendants(matching: .any).matching(identifier: "adjustment.group.light").firstMatch.tap()
        let exposureField = app.switches["adjustment.field.light.exposure"]
        XCTAssertTrue(exposureField.waitForExistence(timeout: 5)); toggleField(exposureField)
        let colorGroup = app.descendants(matching: .any).matching(identifier: "adjustment.group.color").firstMatch
        revealFormControl(colorGroup, app: app); colorGroup.tap()
        let hueGroup = app.descendants(matching: .any).matching(identifier: "adjustment.axis.hue").firstMatch
        revealFormControl(hueGroup, app: app); hueGroup.tap()
        let red = app.switches["adjustment.field.color.hsl.hue.red"]
        revealFormControl(red, app: app); toggleField(red)
        let copy = app.buttons["adjustment.copy.confirm"]
        revealFormControl(copy, app: app)
        XCTAssertTrue(copy.isEnabled, app.debugDescription)
        capture(app, "adjustment-selected-copy-fields")
        copy.tap()
        wait(app) { $0["ready"] as? Bool == true }
        guard let clipboard = receipt(app)["clipboard"] as? [String: Any] else {
            capture(app, "adjustment-copy-failed")
            XCTFail("Copy did not produce a payload. \(receipt(app))\n\(app.debugDescription)")
            return
        }
        let values = clipboard["values"] as! [String: Any]
        XCTAssertEqual(Set(values.keys), ["light.exposure", "color.hsl.hue.red"])
        XCTAssertEqual(values["light.exposure"] as? Double, 0.75)
        let historyAfterCopy = receipt(app)["historyCount"] as! Int
        XCTAssertEqual(historyAfterCopy, 2, "copy and range selection never create edit history")
        setExposure("+0.90", app: app)
        openAdjustmentAction("adjustment.paste.open", app: app)
        app.buttons["adjustment.paste.preflight"].tap()
        let apply = app.buttons["adjustment.paste.apply"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in apply.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
        revealFormControl(apply, app: app); apply.tap()
        app.buttons["adjustment.transfer.close"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["exposure"] as? Double == 0.75 }
        XCTAssertEqual(receipt(app)["crop"] as? Double, 0.8, "unselected crop survives a custom paste")
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, historyAfterCopy + 2)
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["ready"] as? Bool == true && abs(($0["exposure"] as? Double ?? -99) - 0.9) < 1e-9 }
        openAdjustmentAction("adjustment.history.redo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["exposure"] as? Double == 0.75 }
        capture(app, "adjustment-native-gesture-custom-copy-paste-history")
    }

    private func copyExposure(_ app: XCUIApplication) {
        openAdjustmentAction("adjustment.copy.open", app: app)
        XCTAssertTrue(app.buttons["adjustment.copy.clear"].waitForExistence(timeout: 5))
        app.buttons["adjustment.copy.clear"].tap()
        app.descendants(matching: .any).matching(identifier: "adjustment.group.light").firstMatch.tap()
        toggleField(app.switches["adjustment.field.light.exposure"])
        let copy = app.buttons["adjustment.copy.confirm"]
        revealFormControl(copy, app: app); copy.tap()
        wait(app) { $0["ready"] as? Bool == true }
    }

    func testAdjustmentFileTargetsPartialRetryAndHistory() {
        let app = launch(language: "en", adjustmentFixtures: true)
        app.buttons["editor.group.light"].tap()
        copyExposure(app)
        setExposure("+0.90", app: app)
        openAdjustmentAction("adjustment.paste.open", app: app)
        app.buttons["adjustment.paste.chooseFiles"].tap()
        let appFolder = app.cells["RawLab, Container"]
        let local = app.cells["DOC.sidebar.item.On My iPhone"]
        if !appFolder.waitForExistence(timeout: 3) && !local.exists {
            let browse = app.buttons["Browse"]
            if browse.exists { browse.tap() }
        }
        if local.exists { local.tap() }
        if appFolder.waitForExistence(timeout: 5) { appFolder.tap() }
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ITER03-target-B")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 10), app.debugDescription)
        fixture.tap()
        if app.buttons["Open"].waitForExistence(timeout: 3) { app.buttons["Open"].tap() }
        XCTAssertTrue(app.buttons["adjustment.paste.preflight"].waitForExistence(timeout: 10))
        app.buttons["adjustment.paste.preflight"].tap()
        let apply = app.buttons["adjustment.paste.apply"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in apply.isEnabled }, object: nil)], timeout: 30), .completed)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.iter03.fail-target" as CFString), nil, nil, true)
        wait(app) { ($0["failingTarget"] as? String ?? "").hasPrefix("content:") }
        revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 0.5 && $0["targetStoredExposure"] as? Double == -0.2 }
        let undo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "adjustment.transaction.undo.")).firstMatch
        revealFormControl(undo, app: app); undo.tap()
        wait(app) { abs(($0["sourceStoredExposure"] as? Double ?? -99) - 0.9) < 1e-9 }
        let revisionAfterUndo = receipt(app)["sourceStoredRevision"] as! String
        revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["targetStoredExposure"] as? Double == 0.5 }
        XCTAssertEqual(receipt(app)["sourceStoredRevision"] as? String, revisionAfterUndo,
                       "retrying B does not replay the cached successful A receipt after A was undone")
        XCTAssertEqual(receipt(app)["sourceStoredExposure"] as! Double, 0.9, accuracy: 1e-9)
        XCTAssertEqual(receipt(app)["targetStoredCrop"] as? Double, 0.6)
        capture(app, "adjustment-multiple-target-partial-failure-undo-retry")
        revealFormControl(undo, app: app); undo.tap()
        wait(app) { $0["targetStoredExposure"] as? Double == -0.2 && abs(($0["sourceStoredExposure"] as? Double ?? -99) - 0.9) < 1e-9 }
        let redo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "adjustment.transaction.redo.")).firstMatch
        revealFormControl(redo, app: app); redo.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 0.5 && $0["targetStoredExposure"] as? Double == 0.5 }
        capture(app, "adjustment-multiple-target-redo")
    }

    func testAdjustmentConflictReloadAndDraftCopyGuard() {
        let app = launch(language: "en")
        app.buttons["editor.group.light"].tap()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.iter03.external-edit" as CFString), nil, nil, true)
        wait(app) { $0["sourceStoredExposure"] as? Double == 1.3 }
        setExposure("+0.75", app: app)
        wait(app) { ($0["saveState"] as? String ?? "").contains("failed") }
        XCTAssertEqual(receipt(app)["sourceStoredExposure"] as? Double, 1.3)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
        let retry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "not saved")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Reload Saved Adjustments"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["exposure"] as? Double == 1.3 }
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0, "reload is navigation, not an editing transaction")
        selectGeometry(app)
        let corner = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        openAdjustmentAction("adjustment.copy.open", app: app)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
        openAdjustmentAction("adjustment.copy.open", app: app)
        app.alerts.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["adjustment.copy.clear"].waitForExistence(timeout: 10))
        app.buttons["adjustment.transfer.close"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == false }
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 1)
        XCTAssertLessThan(receipt(app)["crop"] as! Double, 0.8)
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["crop"] as? Double == 0.8 }
        capture(app, "adjustment-conflict-reload-draft-copy-guard")
    }

    func testAdjustmentCopyGermanLargeText() {
        let app = launch(language: "de", textCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        app.buttons["editor.privacy"].tap()
        let copyAction = app.buttons["Anpassungen kopieren"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5)); copyAction.tap()
        let clear = app.buttons["adjustment.copy.clear"]
        revealFormControl(clear, app: app); clear.tap()
        let light = app.descendants(matching: .any).matching(identifier: "adjustment.group.light").firstMatch
        revealFormControl(light, app: app); light.tap()
        let exposure = app.switches["adjustment.field.light.exposure"]
        revealFormControl(exposure, app: app)
        XCTAssertGreaterThanOrEqual(exposure.frame.height, 44)
        toggleField(exposure)
        capture(app, "adjustment-copy-german-large-field-selection")
        let copy = app.buttons["adjustment.copy.confirm"]
        revealFormControl(copy, app: app)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertTrue(copy.isEnabled); copy.tap()
        wait(app) { $0["clipboard"] is [String: Any] }
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
    }
    func launch(language requestedLanguage: String? = nil, textCategory: String? = nil, adjustmentFixtures: Bool = false,
                presetFixtures: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.viewing-editor")
        let language = requestedLanguage ?? ProcessInfo.processInfo.environment["S3_VIEWING_LANGUAGE"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language, "-RawLab.language", language]
        if adjustmentFixtures { app.launchArguments.append("-RawLab.adjustmentTransferUI") }
        if presetFixtures { app.launchArguments.append("-RawLab.presetUI") }
        if let category = textCategory ?? ProcessInfo.processInfo.environment["S3_VIEWING_TEXT"], !category.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launch()
        wait(app) { $0["ready"] as? Bool == true }
        return app
    }
    func receipt(_ app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["viewing.editor.receipt"]
        guard element.exists else { return [:] }
        guard let value = element.value as? String, let data = value.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    func wait(_ app: XCUIApplication, timeout: TimeInterval = 20, _ predicate: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate(self.receipt(app)) }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Receipt: \(receipt(app))")
    }
    func capture(_ app: XCUIApplication, _ name: String) {
        print("VIEWING_EDITOR \(name) \(receipt(app))")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        var snapshot = receipt(app)
        var bounds: [String: [Double]] = [:]
        for id in ["editor.photo", "editor.photo.before", "editor.compare.before", "editor.compare.after", "editor.compare.mode", "editor.preview.exit", "editor.panel", "editor.compare", "editor.reset", "editor.histogram"] {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if element.exists {
                let frame = element.frame
                bounds[id] = [frame.minX, frame.minY, frame.width, frame.height]
            }
        }
        snapshot["uiBounds"] = bounds
        snapshot["window"] = [app.frame.minX, app.frame.minY, app.frame.width, app.frame.height]
        let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); json.name = name + "-receipt"; json.lifetime = .keepAlways; add(json)
    }
    func selectGeometry(_ app: XCUIApplication) {
        for _ in 0..<10 {
            if app.frame.insetBy(dx: -1, dy: -1).contains(app.buttons["editor.group.geometry"].frame) { break }
            app.scrollViews["editor.groups"].swipeLeft()
        }
        app.buttons["editor.group.geometry"].tap()
        if !app.buttons["tool.geometry"].isSelected { app.buttons["tool.geometry"].tap() }
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == true }
    }
    func revealCompactControl(_ element: XCUIElement, in app: XCUIApplication) {
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<12 {
            let frame = element.exists ? element.frame : .zero
            let bounds = panel.frame
            if element.exists && element.isHittable && bounds.insetBy(dx: -1, dy: -1).contains(frame) { return }
            let up = frame.isEmpty || frame.midY > bounds.midY
            let distance = frame.isEmpty ? bounds.height * 0.6 : abs(frame.midY - bounds.midY)
            if bounds.height < 120 && distance > bounds.height * 2 {
                if up { panel.swipeUp(velocity: .fast) } else { panel.swipeDown(velocity: .fast) }
                continue
            }
            let amount = min(0.6, max(0.08, distance / max(1, bounds.height)))
            let startY: CGFloat = up ? 0.82 : 0.18
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: startY))
                .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.12, dy: startY + (up ? -amount : amount))),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture(app, "compact-unreachable-" + element.identifier)
        XCTFail("Control remains reachable: \(element.identifier), frame=\(element.frame), panel=\(panel.frame)\n\(app.debugDescription)")
    }
    func testCompactGermanLargeLandscapeControls() {
        let app = launch(language: "de", textCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { $0["ready"] as? Bool == true }
        selectGeometry(app)
        let dimensions = app.buttons["geometry.dimensions"]
        revealCompactControl(dimensions, in: app); dimensions.tap()
        let width = app.buttons["geometry.cropWidth.value"]
        revealCompactControl(width, in: app)
        XCTAssertTrue(app.scrollViews["editor.panel"].frame.insetBy(dx: -1, dy: -1)
            .contains(app.staticTexts["geometry.cropWidth.title"].frame),
            "The complete large-text crop label and value are visible together")
        capture(app, "compact-german-large-landscape-numbers")
        width.tap()
        XCTAssertTrue(app.buttons["adjustment.wheel.cancel"].waitForExistence(timeout: 5))
        app.buttons["adjustment.wheel.cancel"].tap()
        app.buttons["editor.draft.cancel"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["ready"] as? Bool == true }
    }
    func testCompactCropPrecisionAndResponsiveNavigation() {
        let app = launch(language: "en")
        app.buttons["editor.group.color"].tap()
        app.buttons["tool.hsl"].tap()
        for channel in 0..<8 {
            let button = app.buttons["hsl.channel.\(channel)"]
            if !button.isHittable { app.scrollViews["editor.panel"].swipeLeft() }
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
            wait(app) { $0["hslChannel"] as? Int == channel }
        }
        capture(app, "compact-hsl-portrait")
        selectGeometry(app)
        let corner = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch
        let origin = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: -23, dy: -17)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        let original = receipt(app)["draftCrop"] as! Double
        let dimensions = app.descendants(matching: .any).matching(identifier: "geometry.dimensions").firstMatch
        revealCompactControl(dimensions, in: app); dimensions.tap()
        let width = app.buttons["geometry.cropWidth.value"]
        revealCompactControl(width, in: app); width.tap()
        XCTAssertTrue(app.buttons["adjustment.wheel.apply"].waitForExistence(timeout: 5))
        app.buttons["adjustment.wheel.apply"].tap()
        wait(app) { $0["ready"] as? Bool == true }
        XCTAssertEqual(receipt(app)["draftCrop"] as! Double, original,
                       "Opening and confirming the rounded crop wheel preserves its full precision")
        revealCompactControl(width, in: app); width.tap()
        let picker = app.descendants(matching: .any).matching(identifier: "adjustment.wheel").firstMatch
        let wheel = picker.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let current = wheel.value as? String ?? ""
        let text = "50.01"
        let target = current.contains(picker.label + ",") ? picker.label + ", " + text + " %"
            : current.contains(" %") ? text + " %" : text
        wheel.adjust(toPickerWheelValue: target)
        app.buttons["adjustment.wheel.apply"].tap()
        wait(app) { abs(($0["draftCrop"] as? Double ?? 0) - 0.5001) < 1e-10 && $0["ready"] as? Bool == true }
        capture(app, "compact-crop-exact-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { $0["ready"] as? Bool == true }
        for id in ["editor.draft.cancel", "editor.draft.apply"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable && app.frame.contains(button.frame), "Fixed action remains visible in landscape")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        capture(app, "compact-crop-landscape")
        app.buttons["editor.draft.apply"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["ready"] as? Bool == true }
        XCTAssertEqual(receipt(app)["crop"] as! Double, 0.5001, accuracy: 1e-10)
        capture(app, "compact-crop-applied")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let german = launch(language: "de", textCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        selectGeometry(german)
        for id in ["editor.draft.cancel", "editor.draft.apply"] {
            let button = german.buttons[id]
            XCTAssertTrue(button.exists && german.frame.contains(button.frame), "Large German text retains fixed draft actions")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        capture(german, "compact-german-large-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(german) { $0["ready"] as? Bool == true }
        capture(german, "compact-german-large-landscape")
        XCTAssertTrue(german.buttons["editor.draft.cancel"].isHittable)
        german.buttons["editor.draft.cancel"].tap()
        wait(german) { $0["draftActive"] as? Bool == false && $0["ready"] as? Bool == true }
    }
    func histogramPlot(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "editor.histogram.plot").firstMatch
    }
    func assertVisibleHistogram(_ app: XCUIApplication) {
        let plot = histogramPlot(app)
        XCTAssertTrue(plot.waitForExistence(timeout: 5))
        let popover = app.descendants(matching: .any).matching(identifier: "editor.histogram.popover").firstMatch
        if popover.exists {
            if !popover.frame.contains(plot.frame) {
                let frame = app.scrollViews["editor.histogram.scroll"].frame
                XCTAssertTrue(app.frame.contains(frame) && frame.height >= 80)
                // 部分系统 SwiftUI popover 的 AX 包装层为零尺寸；以实际 ScrollView frame 派发触摸。
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 20)).press(forDuration: 0.05,
                    thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 20)))
            }
            XCTAssertTrue(app.frame.contains(popover.frame), "Histogram popover stays inside the window")
            XCTAssertTrue(popover.frame.contains(plot.frame), "Complete plot/status remains reachable inside its popover")
            XCTAssertTrue(app.buttons["editor.histogram.close"].isHittable)
        } else {
            XCTAssertTrue(app.images["editor.photo"].frame.contains(plot.frame), "Inline RGB plot must not be clipped by the parameter panel")
        }
    }
    func testRGBHistogramSourcesAndUnavailableState() {
        let app = launch(language: "en")
        wait(app) { !($0["afterHistogram"] as! [String: Any]).isEmpty }
        let initial = receipt(app)
        let after = initial["afterHistogram"] as! [String: Any]
        let before = initial["beforeHistogram"] as! [String: Any]
        XCTAssertNotEqual(after["hash"] as? String, before["hash"] as? String)
        for (histogram, key) in [(after, "previewSize"), (before, "referenceSize")] {
            XCTAssertEqual(histogram["size"] as? [Int], (initial[key] as! [Double]).map(Int.init))
            let size = histogram["size"] as! [Int]
            XCTAssertEqual(histogram["sums"] as? [Int], Array(repeating: size[0] * size[1], count: 3))
        }
        let drawing = initial["histogramDrawing"] as! [String: [Int]]
        for (bin, expected) in ["10": [255, 0, 0], "20": [0, 255, 0], "30": [0, 0, 255],
                                "40": [255, 255, 0], "50": [255, 0, 255], "60": [0, 255, 255], "70": [191, 191, 191]] {
            let actual = drawing[bin] ?? []
            XCTAssertEqual(actual.count, 4, "Actual SwiftUI Canvas sample for bin \(bin)")
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 2) }
            XCTAssertEqual(actual[3], 255)
        }
        let histogram = app.buttons["editor.histogram"]
        XCTAssertEqual(histogram.label, "RGB Histogram")
        histogram.tap()
        wait(app) { $0["histogramExpanded"] as? Bool == true }
        assertVisibleHistogram(app)
        XCTAssertTrue((histogram.value as? String ?? "").contains("After"))
        capture(app, "rgb-after")
        app.images["editor.photo"].press(forDuration: 0.8)
        let transitions = receipt(app)["histogramTransitions"] as! [[String: Any]]
        XCTAssertTrue(transitions.contains { $0["before"] as? Bool == true && $0["hash"] as? String == before["hash"] as? String })
        XCTAssertEqual(transitions.last?["before"] as? Bool, false)
        XCTAssertEqual(transitions.last?["hash"] as? String, after["hash"] as? String)
        app.buttons["editor.compare"].tap()
        wait(app) { $0["compare"] as? Bool == true && $0["ready"] as? Bool == true }
        XCTAssertEqual((receipt(app)["shownHistogram"] as! [String: Any])["hash"] as? String,
                       (receipt(app)["afterHistogram"] as! [String: Any])["hash"] as? String)
        app.buttons["editor.compare"].tap()
        app.images["editor.photo"].tap()
        wait(app) { $0["previewOnly"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.histogram"].exists)
        app.buttons["editor.preview.exit"].tap()
        wait(app) { $0["previewOnly"] as? Bool == false && $0["ready"] as? Bool == true }
        XCTAssertEqual(receipt(app)["histogramExpanded"] as? Bool, true)
        assertVisibleHistogram(app)
        histogram.tap()
        wait(app) { $0["histogramExpanded"] as? Bool == false }
        app.images["editor.photo"].tap()
        wait(app) { $0["previewOnly"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.histogram"].exists)
        app.buttons["editor.preview.exit"].tap()
        wait(app) { $0["previewOnly"] as? Bool == false && $0["ready"] as? Bool == true }
        XCTAssertEqual(receipt(app)["histogramExpanded"] as? Bool, false)
        histogram.tap()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s4.clear-statistics" as CFString), nil, nil, true)
        wait(app) { ($0["shownHistogram"] as! [String: Any]).isEmpty }
        XCTAssertTrue((histogram.value as? String ?? "").contains("Statistics unavailable"))
        XCTAssertTrue(app.images["editor.photo"].exists)
        XCTAssertFalse(receipt(app)["previewFailed"] as! Bool)
        capture(app, "rgb-unavailable")
        XCTAssertEqual(receipt(app)["settings"] as? String, initial["settings"] as? String)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, (initial["saves"] as! [[String: Any]]).count)
    }

    func testRGBHistogramAcrossSixLanguagesAndLargeText() {
        checkRGBHistogramLanguages()
    }
    func testRGBHistogramGermanLargeText() {
        checkRGBHistogramLanguages(only: "de")
    }
    func testRGBHistogramRotationAndExpansion() {
        checkRGBHistogramLanguages(only: "en")
    }
    private func checkRGBHistogramLanguages(only requestedLanguage: String? = nil) {
        for (language, title, after, unavailable) in [
            ("zh-Hans", "RGB 直方图", "调整后", "统计不可用"),
            ("en", "RGB Histogram", "After", "Statistics unavailable"),
            ("de", "RGB-Histogramm", "Nachher", "Statistik nicht verfügbar"),
            ("fr", "Histogramme RVB", "Après", "Statistiques indisponibles"),
            ("ja", "RGB ヒストグラム", "補正後", "統計を利用できません"),
            ("es", "Histograma RGB", "Después", "Estadísticas no disponibles")
        ] {
            if let requestedLanguage, language != requestedLanguage { continue }
            let app = launch(language: language, textCategory: language == "de" ? "UICTContentSizeCategoryAccessibilityXXXL" : nil)
            wait(app) { !($0["afterHistogram"] as! [String: Any]).isEmpty }
            let initial = receipt(app)
            let histogram = app.buttons["editor.histogram"]
            XCTAssertEqual(histogram.label, title)
            XCTAssertGreaterThanOrEqual(histogram.frame.height, 44)
            XCTAssertGreaterThanOrEqual(histogram.frame.width, 44)
            histogram.tap()
            wait(app) { $0["histogramExpanded"] as? Bool == true }
            assertVisibleHistogram(app)
            XCTAssertEqual(histogramPlot(app).label, after)
            capture(app, "rgb-\(language)-expanded")
            XCUIDevice.shared.orientation = .landscapeLeft
            wait(app) { $0["ready"] as? Bool == true && app.frame.width > app.frame.height }
            assertVisibleHistogram(app)
            capture(app, "rgb-\(language)-landscape")
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s4.clear-statistics" as CFString), nil, nil, true)
            wait(app) { ($0["shownHistogram"] as! [String: Any]).isEmpty }
            assertVisibleHistogram(app)
            XCTAssertEqual(histogramPlot(app).value as? String, unavailable)
            capture(app, "rgb-\(language)-unavailable")
            XCUIDevice.shared.orientation = .portrait
            wait(app) { $0["ready"] as? Bool == true && app.frame.width < app.frame.height }
            XCTAssertEqual(receipt(app)["histogramExpanded"] as? Bool, true,
                           "Rotation between inline and popover must preserve the expanded preference")
            assertVisibleHistogram(app)
            if app.buttons["editor.histogram.close"].exists {
                app.buttons["editor.histogram.close"].tap()
                wait(app) { $0["histogramExpanded"] as? Bool == false }
                XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "editor.histogram.popover").firstMatch.exists)
            }
            XCTAssertEqual(receipt(app)["settings"] as? String, initial["settings"] as? String)
            XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, (initial["saves"] as! [[String: Any]]).count)
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }
    func testNewViewingControlsAcrossSixLanguages() {
        let samples = [
            ("zh-Hans", "开启对比", "关闭对比", "调整前", "调整后", "并排", "分割线", "缩放与显示", "照片四周留白"),
            ("en", "Turn on comparison", "Turn off comparison", "Before", "After", "Side by side", "Wipe", "Zoom and display", "Space around photo"),
            ("de", "Vergleich einschalten", "Vergleich ausschalten", "Vorher", "Nachher", "Nebeneinander", "Trennlinie", "Zoom und Anzeige", "Abstand um das Foto"),
            ("fr", "Activer la comparaison", "Désactiver la comparaison", "Avant", "Après", "Côte à côte", "Ligne de séparation", "Zoom et affichage", "Marge autour de la photo"),
            ("ja", "比較をオン", "比較をオフ", "補正前", "補正後", "並べて表示", "分割線", "ズームと表示", "写真の周囲に余白"),
            ("es", "Activar comparación", "Desactivar comparación", "Antes", "Después", "En paralelo", "Línea divisoria", "Zoom y visualización", "Espacio alrededor de la foto")
        ]
        for (language, enabled, disabled, before, after, side, wipe, display, margin) in samples {
            let app = launch(language: language, textCategory: language == "de" ? "UICTContentSizeCategoryAccessibilityXXXL" : nil)
            let original = receipt(app)
            XCTAssertEqual(app.buttons["editor.compare"].label, enabled)
            app.buttons["editor.compare"].tap()
            wait(app) { $0["compare"] as? Bool == true && $0["ready"] as? Bool == true }
            XCTAssertEqual(app.buttons["editor.compare"].label, disabled)
            for (id, expected, photoID) in [("editor.compare.before", before, "editor.photo.before"), ("editor.compare.after", after, "editor.photo")] {
                let text = app.staticTexts[id]
                XCTAssertEqual(text.label, expected)
                XCTAssertTrue(app.images[photoID].frame.contains(text.frame))
            }
            let mode = app.buttons["editor.compare.mode"]
            XCTAssertGreaterThanOrEqual(mode.frame.width, 44)
            XCTAssertGreaterThanOrEqual(mode.frame.height, 44)
            capture(app, "locale-\(language)-labels")
            mode.tap()
            XCTAssertEqual(app.buttons["editor.compare.sideBySide"].label, side)
            XCTAssertEqual(app.buttons["editor.compare.wipe"].label, wipe)
            for id in ["editor.compare.sideBySide", "editor.compare.wipe"] {
                XCTAssertTrue(app.frame.contains(app.buttons[id].frame), "localized menu item must fit the window")
            }
            capture(app, "locale-\(language)-compare-menu")
            app.buttons["editor.compare.close"].tap()
            app.buttons["editor.privacy"].tap()
            app.buttons[display].tap()
            XCTAssertTrue(app.buttons[margin].isHittable)
            XCTAssertTrue(app.frame.contains(app.buttons[margin].frame))
            capture(app, "locale-\(language)-display-menu")
            XCTAssertEqual(receipt(app)["settings"] as? String, original["settings"] as? String)
            XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, (original["saves"] as! [[String: Any]]).count)
            app.terminate()
        }
    }
    func assertCompleteViewingLabels(_ app: XCUIApplication) {
        let labels = receipt(app)["comparisonLabelMetrics"] as! [[String: Any]]
        XCTAssertEqual(labels.count, 2)
        let frames = labels.map { value -> CGRect in
            let rect = value["rect"] as! [Double]
            return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        XCTAssertFalse(frames[0].intersects(frames[1]), "before/after labels must not cover one another")
        for label in labels {
            let rect = label["rect"] as! [Double]
            XCTAssertGreaterThanOrEqual(rect[2], label["fullTextWidth"] as! Double)
            XCTAssertGreaterThanOrEqual(rect[3], label["lineHeight"] as! Double)
            XCTAssertGreaterThanOrEqual(label["pointSize"] as! Double, 13)
            XCTAssertLessThanOrEqual(label["pointSize"] as! Double, 17)
            XCTAssertFalse(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]).intersects(app.buttons["editor.compare.mode"].frame))
        }
    }
    func testLargeViewingLabelsAndModeStayComplete() {
        let app = launch(language: "de", textCategory: "UICTContentSizeCategoryAccessibilityXXXL")
        app.buttons["editor.compare"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["compare"] as? Bool == true }
        XCTAssertEqual(receipt(app)["preferredContentSizeCategory"] as? String, "UICTContentSizeCategoryAccessibilityXXXL")
        capture(app, "de-xxxl-side-text-metrics")
        assertCompleteViewingLabels(app)
        XCTAssertEqual(app.staticTexts["editor.compare.before"].label, "Vorher")
        XCTAssertEqual(app.staticTexts["editor.compare.after"].label, "Nachher")
        XCTAssertEqual(app.buttons["editor.compare.mode"].frame.width, 44)
        XCTAssertEqual(app.buttons["editor.compare.mode"].frame.height, 44)
        capture(app, "de-xxxl-complete-side-labels")
        app.buttons["editor.compare.mode"].tap()
        app.buttons["editor.compare.wipe"].tap()
        wait(app) { $0["mode"] as? String == "wipe" && $0["ready"] as? Bool == true }
        assertCompleteViewingLabels(app)
        capture(app, "de-xxxl-complete-wipe-labels")
    }
    func testWipeLabelAvoidsModeControlInsideActualPhoto() {
        let app = launch()
        app.buttons["editor.compare"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["compare"] as? Bool == true }
        app.buttons["editor.compare.mode"].tap()
        app.buttons["editor.compare.wipe"].tap()
        wait(app) { $0["mode"] as? String == "wipe" && $0["ready"] as? Bool == true }
        let label = app.staticTexts["editor.compare.after"]
        let mode = app.buttons["editor.compare.mode"]
        XCTAssertTrue(app.images["editor.photo"].frame.contains(label.frame))
        XCTAssertFalse(label.frame.intersects(mode.frame))
        XCTAssertGreaterThanOrEqual(mode.frame.width, 44)
        XCTAssertGreaterThanOrEqual(mode.frame.height, 44)
        assertCompleteViewingLabels(app)
        capture(app, "wipe-label-avoids-mode")
    }
    func testActualPinchUsesCommonViewport() {
        let app = launch()
        capture(app, "pinch-initial")
        app.images["editor.photo"].pinch(withScale: 3, velocity: 1)
        wait(app) { ($0["relativeScale"] as? Double ?? 1) > 1.2 && $0["ready"] as? Bool == true }
        capture(app, "pinch-actual-zoom")
    }
    func testEnteringGeometryFromZoomUsesCropCanvasViewport() {
        let app = launch()
        app.images["editor.photo"].pinch(withScale: 2, velocity: 1)
        wait(app) { ($0["relativeScale"] as? Double ?? 1) > 1.5 }
        capture(app, "zoom-before-geometry")
        selectGeometry(app)
        let rect = (receipt(app)["nativePhotoRects"] as! [[Double]])[0]
        let handle = app.descendants(matching: .any).matching(identifier: "geometry.crop.topLeft").firstMatch
        capture(app, "zoom-to-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, rect[0], accuracy: 0.5)
        XCTAssertEqual(handle.frame.midY, rect[1], accuracy: 0.5)
    }
    func testActualCropHandlesAlignWithNativePhotoMargin() {
        let app = launch()
        selectGeometry(app)
        let data = receipt(app)
        let rect = (data["nativePhotoRects"] as! [[Double]])[0]
        let handle = app.descendants(matching: .any).matching(identifier: "geometry.crop.topLeft").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        capture(app, "margin-on-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, rect[0], accuracy: 0.5, "crop handle must align with actual UIKit photo, including view margin")
        XCTAssertEqual(handle.frame.midY, rect[1], accuracy: 0.5)
        let bottomRight = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch
        let corner = bottomRight.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.draft.apply"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == false }
        capture(app, "margin-on-applied")
        XCTAssertEqual(receipt(app)["referenceSize"] as? [Double], receipt(app)["previewSize"] as? [Double], "Apply must publish a neutral reference with the newly committed composition")
        let committed = receipt(app)["settings"] as! String
        app.buttons["editor.privacy"].tap()
        app.buttons["Zoom and display"].tap()
        app.buttons["Space around photo"].tap()
        wait(app) { $0["margin"] as? Bool == false }
        selectGeometry(app)
        let noMargin = (receipt(app)["nativePhotoRects"] as! [[Double]])[0]
        capture(app, "margin-off-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, noMargin[0], accuracy: 0.5)
        XCTAssertEqual(handle.frame.midY, noMargin[1], accuracy: 0.5)
        let movedCorner = bottomRight.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        movedCorner.press(forDuration: 0.05, thenDragTo: movedCorner.withOffset(CGVector(dx: -12, dy: -8)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.draft.cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == false }
        XCTAssertEqual(receipt(app)["settings"] as? String, committed)
        capture(app, "margin-off-discarded")
    }
    func testActualImportGuardKeepsDraftOnSaveFailureAndResumesAfterRetry() {
        let app = launch()
        selectGeometry(app)
        let initial = receipt(app)
        let original = initial["settings"] as! String
        let saves = (initial["saves"] as! [[String: Any]]).count
        let corner = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.compare"].isEnabled)
        app.buttons["editor.import"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertTrue(receipt(app)["draftActive"] as! Bool)
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        XCTAssertEqual(receipt(app)["settings"] as? String, original)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s3.fail-next-save" as CFString), nil, nil, true)
        wait(app) { $0["failNextSave"] as? Bool == true }
        app.buttons["editor.import"].tap()
        app.alerts.buttons["Apply"].tap()
        wait(app) { ($0["saveState"] as? String ?? "").contains("failed") }
        XCTAssertTrue(receipt(app)["draftActive"] as! Bool)
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        XCTAssertFalse(receipt(app)["photoPicker"] as! Bool)
        XCTAssertEqual(receipt(app)["settings"] as? String, original)
        let attempts = receipt(app)["saves"] as! [[String: Any]]
        XCTAssertEqual(attempts.count, saves + 1)
        XCTAssertTrue(attempts.last!["failed"] as! Bool)
        capture(app, "draft-import-save-failed")
        let retry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "not saved")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15), "the system Photos picker must finish loading before cancellation")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture(app, "draft-import-retried-picker")
        app.buttons["Cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["photoPicker"] as? Bool == false }
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves + 2)
        let committed = receipt(app)["settings"] as! String
        XCTAssertNotEqual(committed, original)
        selectGeometry(app)
        let next = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        next.press(forDuration: 0.05, thenDragTo: next.withOffset(CGVector(dx: -12, dy: -8)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.import"].tap()
        app.alerts.buttons["Discard Changes"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["photoPicker"] as? Bool == false }
        XCTAssertEqual(receipt(app)["settings"] as? String, committed)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves + 2)
        selectGeometry(app)
        app.buttons["editor.import"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        capture(app, "draft-import-discard-and-unchanged")
    }
    func testUnavailableNeutralKeepsAfterAndBlocksBeforeEntry() {
        let app = launch()
        let before = receipt(app)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s3.clear-reference" as CFString), nil, nil, true)
        wait(app) { $0["referenceAvailable"] as? Bool == false }
        XCTAssertFalse(app.buttons["editor.compare"].isEnabled)
        app.images["editor.photo"].press(forDuration: 0.7)
        XCTAssertFalse(receipt(app)["hold"] as! Bool)
        XCTAssertTrue(app.images["editor.photo"].exists)
        XCTAssertFalse(app.images["editor.photo.before"].exists)
        XCTAssertEqual(receipt(app)["previewSize"] as? [Double], before["previewSize"] as? [Double])
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, (before["saves"] as! [[String: Any]]).count)
        capture(app, "nil-neutral-retains-after")
    }
    func testViewingActionsPreserveEditingSessionAndSettings() {
        let app = launch()
        app.buttons["editor.group.color"].tap()
        app.buttons["tool.hsl"].tap()
        wait(app) { $0["ready"] as? Bool == true }
        let switches = receipt(app)["nativeSwitchRects"] as! [[Double]]
        XCTAssertEqual(switches.count, 1)
        let fineRect = switches[0]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fineRect[0] + fineRect[2] / 2, dy: fineRect[1] + fineRect[3] / 2)).tap()
        wait(app) { $0["fine"] as? Bool == true }
        XCTAssertTrue(app.buttons["hsl.channel.6"].exists)
        app.buttons["hsl.channel.6"].tap()
        app.images["editor.photo"].pinch(withScale: 3, velocity: 1)
        wait(app) { ($0["relativeScale"] as? Double ?? 1) > 1.2 && $0["ready"] as? Bool == true }
        let initial = receipt(app)
        let saves = (initial["saves"] as! [[String: Any]]).count
        let settings = initial["settings"] as! String
        let photo = app.images["editor.photo"]
        photo.tap()
        wait(app) { $0["previewOnly"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.compare"].isHittable)
        XCTAssertTrue(app.buttons["editor.preview.exit"].isHittable)
        capture(app, "pure-preview")
        app.buttons["editor.preview.exit"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["previewOnly"] as? Bool == false }
        XCTAssertEqual(receipt(app)["tool"] as? String, "hsl")
        XCTAssertEqual(receipt(app)["fine"] as? Bool, initial["fine"] as? Bool)
        XCTAssertEqual(receipt(app)["hslChannel"] as? Int, initial["hslChannel"] as? Int)
        XCTAssertEqual(receipt(app)["focus"] as? [Double], initial["focus"] as? [Double])
        XCTAssertEqual(receipt(app)["relativeScale"] as? Double, initial["relativeScale"] as? Double)
        photo.doubleTap()
        XCTAssertFalse(receipt(app)["previewOnly"] as! Bool)
        photo.press(forDuration: 0.7)
        XCTAssertFalse(receipt(app)["hold"] as! Bool)
        app.buttons["editor.compare"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["compare"] as? Bool == true }
        XCTAssertTrue(app.images["editor.photo.before"].exists)
        for (label, photoID) in [("editor.compare.before", "editor.photo.before"), ("editor.compare.after", "editor.photo")] {
            let text = app.staticTexts[label]
            XCTAssertTrue(text.exists)
            XCTAssertTrue(app.images[photoID].frame.contains(text.frame), "comparison labels must remain inside their actual visible pane")
        }
        XCTAssertGreaterThanOrEqual(app.buttons["editor.compare.mode"].frame.width, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["editor.compare.mode"].frame.height, 44)
        capture(app, "comparison-side-by-side")
        app.buttons["editor.compare.mode"].tap()
        app.buttons["editor.compare.wipe"].tap()
        wait(app) { $0["mode"] as? String == "wipe" }
        XCTAssertFalse(app.staticTexts["editor.compare.after"].frame.intersects(app.buttons["editor.compare.mode"].frame), "wipe label must avoid the actual SwiftUI mode button")
        XCTAssertTrue(app.images["editor.photo"].frame.contains(app.staticTexts["editor.compare.after"].frame))
        capture(app, "comparison-wipe")
        app.buttons["editor.compare"].tap()
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(receipt(app)["mode"] as? String, "wipe")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { $0["ready"] as? Bool == true }
        capture(app, "comparison-landscape")
        let final = receipt(app)
        XCTAssertEqual(final["settings"] as? String, settings)
        XCTAssertEqual((final["saves"] as! [[String: Any]]).count, saves)
        for request in final["previews"] as! [[String: Any]] {
            XCTAssertEqual(request["settings"] as? String, settings, "viewing must never submit edited parameters")
        }
    }
}
