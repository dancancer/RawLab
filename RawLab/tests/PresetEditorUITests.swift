import CoreFoundation
import XCTest

extension ViewingEditorUITests {
    private func presets(_ app: XCUIApplication) -> [[String: Any]] { receipt(app)["presets"] as? [[String: Any]] ?? [] }

    private func presetName(_ name: String, app: XCUIApplication) {
        let field = app.textFields["preset.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + name + "\n")
    }

    private func createPreset(_ name: String, exposureOnly: Bool = false, app: XCUIApplication) {
        let create = app.buttons["preset.create"]
        revealFormControl(create, app: app); create.tap()
        presetName(name, app: app)
        if exposureOnly {
            let clear = app.buttons["preset.save.clear"]
            revealFormControl(clear, app: app); clear.tap()
            let light = app.descendants(matching: .any).matching(identifier: "preset.group.light").firstMatch
            revealFormControl(light, app: app); light.tap()
            let exposure = app.switches["preset.field.light.exposure"]
            revealFormControl(exposure, app: app); toggleField(exposure)
        }
        let save = app.buttons["preset.save.confirm"]
        revealFormControl(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
    }

    private func openPresets(_ app: XCUIApplication) {
        openAdjustmentAction("preset.library.open", app: app)
        XCTAssertTrue(app.buttons["preset.create"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func managePreset(_ id: String, action: String, app: XCUIApplication) {
        let manage = app.buttons["preset.manage.\(id)"]
        revealFormControl(manage, app: app); manage.tap()
        let item = app.buttons["preset.\(action).\(id)"]
        let fallback = app.buttons[action == "rename" ? "Rename" : "Delete"].firstMatch
        let button = item.exists ? item : fallback
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription); button.tap()
    }

    private func presetFault(_ fault: String, app: XCUIApplication) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.rawlab.iter04.preset.\(fault)" as CFString), nil, nil, true)
        wait(app) { $0["presetFault"] as? String == fault }
    }

    func testPresetRejectsExternalPhotoRevisionWhileSaveFormIsOpen() {
        let app = launch(language: "en", presetFixtures: true)
        openPresets(app)
        app.buttons["preset.create"].tap()
        presetName("Stale source", app: app)
        let history = receipt(app)["historyCount"] as? Int
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.rawlab.iter03.external-edit" as CFString), nil, nil, true)
        wait(app) { $0["sourceStoredExposure"] as? Double == 1.3 }
        let save = app.buttons["preset.save.confirm"]
        revealFormControl(save, app: app); save.tap()
        wait(app) { ($0["saveState"] as? String ?? "").contains("failed") }
        let message = app.staticTexts["preset.message"]
        revealFormControl(message, app: app); XCTAssertTrue(message.exists)
        XCTAssertTrue(presets(app).isEmpty)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, history)
        XCTAssertEqual(receipt(app)["sourceStoredExposure"] as? Double, 1.3)
        capture(app, "preset-external-revision-blocked")
    }

    func testPresetScopeRenameApplyHistoryAndRestart() {
        let app = launch(language: "en", presetFixtures: true)
        app.buttons["editor.group.light"].tap(); setExposure("+0.75", app: app)
        openAdjustmentAction("adjustment.copy.open", app: app)
        app.buttons["adjustment.copy.clear"].tap()
        app.descendants(matching: .any).matching(identifier: "adjustment.group.light").firstMatch.tap()
        toggleField(app.switches["adjustment.field.light.exposure"])
        let copy = app.buttons["adjustment.copy.confirm"]
        revealFormControl(copy, app: app); copy.tap()
        wait(app) { $0["clipboard"] is [String: Any] }
        let clipboard = receipt(app)["clipboard"] as! NSDictionary
        let before = receipt(app)["historyCount"] as! Int
        app.buttons["editor.group.looks"].tap()
        let library = app.buttons["preset.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        createPreset("Portrait exposure", exposureOnly: true, app: app)
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        let original = presets(app)[0], id = original["id"] as! String
        let payload = original["payload"] as! [String: Any]
        let values = payload["values"] as! [String: Any]
        XCTAssertEqual(Set(values.keys), ["light.exposure"]); XCTAssertEqual(values["light.exposure"] as? Double, 0.75)
        XCTAssertEqual(receipt(app)["clipboard"] as? NSDictionary, clipboard)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, before)
        managePreset(id, action: "rename", app: app)
        presetName("Portrait – Morning Light", app: app)
        app.buttons["preset.save.confirm"].tap()
        wait(app) { ($0["presets"] as? [[String: Any]])?.first?["name"] as? String == "Portrait – Morning Light" }
        XCTAssertEqual(presets(app)[0]["id"] as? String, id)
        XCTAssertEqual(presets(app)[0]["payload"] as? NSDictionary, payload as NSDictionary)
        app.buttons["preset.close"].tap()
        app.buttons["editor.group.light"].tap(); setExposure("+1.00", app: app)
        openPresets(app); app.buttons["preset.apply.\(id)"].tap()
        XCTAssertTrue(app.buttons["adjustment.paste.preflight"].waitForExistence(timeout: 10))
        app.buttons["adjustment.paste.preflight"].tap()
        let apply = app.buttons["adjustment.paste.apply"]
        revealFormControl(apply, app: app)
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed); apply.tap()
        wait(app) { $0["exposure"] as? Double == 0.75 && $0["sourceStoredExposure"] as? Double == 0.75 }
        XCTAssertEqual((receipt(app)["history"] as! [[String: Any]]).last?["action"] as? String, "preset")
        XCTAssertEqual(receipt(app)["clipboard"] as? NSDictionary, clipboard)
        capture(app, "preset-apply-native-history")
        let done = app.buttons["adjustment.paste.done"]; revealFormControl(done, app: app); done.tap()
        XCTAssertTrue(app.buttons["preset.create"].waitForExistence(timeout: 10), "Completing application returns to the library")
        app.buttons["preset.close"].tap()
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["sourceStoredExposure"] as? Double == 1.0 }
        openAdjustmentAction("adjustment.history.redo", app: app)
        wait(app) { $0["ready"] as? Bool == true && $0["sourceStoredExposure"] as? Double == 0.75 }
        app.terminate(); app.launchArguments.append("-RawLab.presetResume"); app.launch()
        wait(app, timeout: 30) { $0["ready"] as? Bool == true }
        openPresets(app)
        XCTAssertEqual(presets(app).first?["id"] as? String, id)
        XCTAssertEqual(presets(app).first?["name"] as? String, "Portrait – Morning Light")
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
        capture(app, "preset-persisted-after-restart")
    }

    func testPresetDuplicateOverwriteAndDelete() {
        let app = launch(language: "en", presetFixtures: true)
        openPresets(app); createPreset("Preset A", exposureOnly: true, app: app)
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        let original = presets(app)[0], id = original["id"] as! String
        createPreset("Preset A", app: app)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Save As"].tap()
        presetName("Preset B", app: app)
        let save = app.buttons["preset.save.confirm"]; revealFormControl(save, app: app); save.tap()
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 2 }
        let secondID = presets(app)[1]["id"] as! String
        XCTAssertNotEqual(id, secondID)
        managePreset(secondID, action: "delete", app: app)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Preset B"].exists); app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(presets(app).count, 2)
        managePreset(secondID, action: "delete", app: app); app.alerts.buttons["Delete"].tap()
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        XCTAssertEqual(presets(app)[0]["id"] as? String, id)
        createPreset("Preset A", app: app)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["Overwrite"].tap()
        XCTAssertTrue(app.buttons["preset.create"].waitForExistence(timeout: 5))
        let overwritten = presets(app)[0]
        XCTAssertEqual(overwritten["id"] as? String, id)
        XCTAssertEqual(overwritten["created_at"] as? NSNumber, original["created_at"] as? NSNumber)
        XCTAssertEqual(((overwritten["payload"] as! [String: Any])["values"] as! [String: Any]).count, 49)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
        capture(app, "preset-explicit-overwrite-delete")
    }

    func testPresetFailureRecoveryAndDraftGuard() {
        let app = launch(language: "en", presetFixtures: true)
        openPresets(app); createPreset("Retained", app: app)
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        let retained = presets(app) as NSArray
        presetFault("readonly", app: app)
        createPreset("Retry", app: app)
        let error = app.staticTexts["preset.message"]
        revealFormControl(error, app: app); XCTAssertTrue(error.exists)
        XCTAssertEqual(presets(app) as NSArray, retained)
        capture(app, "preset-io-failure-retains-library")
        presetFault("restore", app: app)
        let save = app.buttons["preset.save.confirm"]; revealFormControl(save, app: app); save.tap()
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 2 }
        app.buttons["preset.close"].tap()
        presetFault("future", app: app); openPresets(app)
        XCTAssertTrue(app.staticTexts["preset.libraryError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["preset.create"].isEnabled)
        presetFault("restore", app: app); app.buttons["preset.reload"].tap()
        XCTAssertTrue(app.buttons["preset.create"].isEnabled)
        XCTAssertEqual(presets(app).count, 2)
        app.buttons["preset.close"].tap()
        selectGeometry(app)
        let corner = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        openPresets(app)
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool, "Managing the library leaves the photo draft intact")
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 0)
        app.buttons["preset.create"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        openPresets(app); app.buttons["preset.create"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        let applyDraft = app.alerts.buttons["Apply"]
        let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            applyDraft.exists && applyDraft.isEnabled && applyDraft.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 20), .completed)
        applyDraft.tap()
        let resumed = app.textFields["preset.name"].waitForExistence(timeout: 10)
        capture(app, "preset-after-draft-apply")
        XCTAssertTrue(resumed, "\(receipt(app))\n\(app.debugDescription)")
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, 1, "Draft application is one independent photo history entry")
        app.buttons["preset.close"].tap(); app.buttons["preset.close"].tap()
        XCTAssertFalse(receipt(app)["draftActive"] as! Bool)
        capture(app, "preset-draft-preflight-and-cancellation")
    }

    func testPresetLocalizedLargeTextLayouts() {
        for language in ["en", "zh-Hans", "de", "fr", "ja", "es"] {
            let app = launch(language: language, textCategory: "UICTContentSizeCategoryAccessibilityXXXL", presetFixtures: true)
            if receipt(app)["group"] as? String != "looks" || receipt(app)["expanded"] as? Bool != true {
                app.buttons["editor.group.looks"].tap()
            }
            let library = app.buttons["preset.library"]
            for _ in 0..<3 where !library.isHittable { app.scrollViews["editor.tools"].swipeLeft() }
            XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
            let create = app.buttons["preset.create"]; revealFormControl(create, app: app); create.tap()
            presetName("晨光 · Portrait / Sehr langer benutzerdefinierter Vorgabenname", app: app)
            let clear = app.buttons["preset.save.clear"]; revealFormControl(clear, app: app); clear.tap()
            let light = app.descendants(matching: .any).matching(identifier: "preset.group.light").firstMatch
            revealFormControl(light, app: app); light.tap()
            let exposure = app.switches["preset.field.light.exposure"]
            revealFormControl(exposure, app: app); XCTAssertGreaterThanOrEqual(exposure.frame.height, 44); toggleField(exposure)
            capture(app, "preset-scope-large-\(language)")
            let save = app.buttons["preset.save.confirm"]; revealFormControl(save, app: app)
            let titles = ["en": "Save Preset", "zh-Hans": "保存预设", "de": "Vorgabe speichern",
                          "fr": "Enregistrer le préréglage", "ja": "プリセットを保存", "es": "Guardar ajuste preestablecido"]
            XCTAssertEqual(save.label, titles[language], "The native action uses the requested language")
            capture(app, "preset-save-action-large-\(language)")
            XCTAssertGreaterThanOrEqual(save.frame.height, 44); save.tap()
            wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
            let id = presets(app)[0]["id"] as! String
            let apply = app.buttons["preset.apply.\(id)"]; revealFormControl(apply, app: app)
            XCTAssertGreaterThanOrEqual(apply.frame.height, 44)
            capture(app, "preset-library-large-\(language)")
            app.terminate()
        }
    }
}
