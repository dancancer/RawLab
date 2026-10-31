import CoreFoundation
import XCTest

extension ViewingEditorUITests {
    private func presets(_ app: XCUIApplication) -> [[String: Any]] { receipt(app)["presets"] as? [[String: Any]] ?? [] }

    func testLookPresetAndCollectionExportTogether() {
        let app = launch(language: "en", presetFixtures: true, looksFixtures: true)
        openPresets(app); createPreset("Combined exposure", exposureOnly: true, app: app)
        let id = presets(app)[0]["id"] as! String
        app.buttons["preset.close"].tap()
        let film = app.buttons["tool.film"]
        if !film.exists { app.buttons["editor.group.looks"].tap() }
        film.tap()
        let search = app.textFields["looks.search"]
        search.tap(); search.typeText("ACROS\n")
        let acros = app.buttons["ACROS"]
        for _ in 0..<4 { if acros.isHittable { break }; app.scrollViews["editor.panel"].swipeUp() }
        acros.tap()
        wait(app) { $0["ready"] as? Bool == true && ($0["recentLookIDs"] as? [String])?.first?.contains("ACROS") == true }
        let look = receipt(app)["selectedLookID"] as! String
        app.buttons["editor.group.light"].tap(); setExposure("+1.00", app: app)
        openAdjustmentAction("preset.library.open", app: app)
        let apply = app.buttons["preset.quick.apply.\(id)"]; revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["ready"] as? Bool == true && $0["sourceStoredExposure"] as? Double == 0.5 }
        XCTAssertEqual(receipt(app)["selectedLookID"] as? String, look)
        XCTAssertEqual((receipt(app)["recentLookIDs"] as? [String])?.first, look)
        openAdjustmentAction("collection.open", app: app)
        XCTAssertTrue(app.buttons["collection.export"].waitForExistence(timeout: 10));app.buttons["collection.export"].tap()
        let start = app.buttons["collection.export.start"];revealFormControl(start, app: app);start.tap()
        wait(app, timeout: 120) { $0["batchStatus"] as? String == "completed" && $0["batchCompleted"] as? Int == 1 }
        XCTAssertEqual(receipt(app)["batchFrozenExposure"] as? [Double], [0.5])
        capture(app, "look-preset-collection-completed")
        app.buttons["Task Actions"].tap();app.buttons["Discard Task"].tap();app.buttons["Discard Task"].tap()
        wait(app) { $0["batchMode"] as? String == "" }
    }


    func testQuickPresetEntryStaysVisible() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "de"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(language: language, presetFixtures: true)
            let entry = app.buttons["preset.library"]
            if language == "en" { openAdjustmentAction("preset.library.open", app: app) }
            else {
                for _ in 0..<8 {
                    if entry.exists && app.scrollViews["editor.tools"].frame.contains(entry.frame) { break }
                    app.scrollViews["editor.tools"].swipeLeft()
                }
                XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            }
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            XCTAssertTrue(app.scrollViews["editor.tools"].frame.contains(entry.frame), "The selected preset entry must remain fully visible")
            capture(app, "quick-preset-entry-visible-\(language)")
            XCUIDevice.shared.orientation = .landscapeLeft
            wait(app) { $0["ready"] as? Bool == true }
            XCTAssertTrue(app.scrollViews["editor.tools"].frame.contains(entry.frame), "The selected preset entry remains visible after rotation")
            let photo = (receipt(app)["nativePhotoRects"] as! [[Double]]).first!
            let canvas = app.descendants(matching: .any).matching(identifier: "editor.photo").firstMatch.frame
            XCTAssertGreaterThanOrEqual(canvas.width, 44); XCTAssertGreaterThanOrEqual(canvas.height, 44)
            // 44pt 约束的是画布叠层触点；按宽高比缩放的照片不使用控件命中尺寸作为下限。
            XCTAssertGreaterThan(photo[2], 0); XCTAssertGreaterThan(photo[3], 0)
            capture(app, "quick-preset-landscape-\(language)")
            app.terminate()
        }
    }

    func testQuickPresetApplyCancelUndoAndFailure() {
        let app = launch(language: "en", presetFixtures: true)
        openPresets(app); createPreset("Quick exposure", exposureOnly: true, app: app)
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        let id = presets(app)[0]["id"] as! String
        app.buttons["preset.close"].tap()
        app.buttons["editor.group.light"].tap(); setExposure("+1.00", app: app)
        openAdjustmentAction("preset.library.open", app: app)
        let apply = app.buttons["preset.quick.apply.\(id)"]
        revealFormControl(apply, app: app)
        let before = receipt(app)
        func notify(_ name: String) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        }
        notify("com.rawlab.quick-preset.hold")
        wait(app) { $0["quickPreparationHeld"] as? Bool == true }
        apply.tap()
        wait(app) { $0["quickPreparing"] as? Bool == true }
        let cancel = app.buttons["preset.quick.cancel"]; revealFormControl(cancel, app: app); cancel.tap()
        notify("com.rawlab.quick-preset.release")
        wait(app) { $0["quickPreparationHeld"] as? Bool == false && $0["quickPreparing"] as? Bool == false }
        XCTAssertEqual(receipt(app)["sourceStoredRevision"] as? String, before["sourceStoredRevision"] as? String)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, before["historyCount"] as? Int)
        capture(app, "quick-preset-cancel")
        notify("com.rawlab.s3.fail-next-save")
        wait(app) { $0["failNextSave"] as? Bool == true }
        revealFormControl(apply, app: app); apply.tap()
        let retry = app.buttons["preset.quick.retry"]
        revealFormControl(retry, app: app); XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertEqual(receipt(app)["sourceStoredRevision"] as? String, before["sourceStoredRevision"] as? String)
        retry.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 0.5 && $0["exposure"] as? Double == 0.5 }
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, (before["historyCount"] as! Int) + 1)
        XCTAssertEqual((receipt(app)["history"] as! [[String: Any]]).last?["action"] as? String, "preset")
        XCTAssertFalse(app.buttons["adjustment.paste.preflight"].exists)
        let photo = (receipt(app)["nativePhotoRects"] as! [[Double]]).first!
        XCTAssertGreaterThan(photo[2], 44); XCTAssertGreaterThan(photo[3], 44)
        capture(app, "quick-preset-saved")
        openAdjustmentAction("adjustment.history.undo", app: app)
        wait(app) { $0["sourceStoredExposure"] as? Double == 1.0 && $0["exposure"] as? Double == 1.0 }
        XCTAssertFalse(app.staticTexts["preset.quick.status"].exists)
        XCTAssertTrue(app.buttons["preset.quick.manage"].exists)
        revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 0.5 }
        let undo = app.buttons["preset.quick.undo"]; revealFormControl(undo, app: app); undo.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 1.0 && $0["exposure"] as? Double == 1.0 }
        revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["sourceStoredExposure"] as? Double == 0.5 }
        let saved = receipt(app)
        revealFormControl(apply, app: app); apply.tap()
        wait(app) { $0["quickPreparing"] as? Bool == false }
        XCTAssertEqual(receipt(app)["sourceStoredRevision"] as? String, saved["sourceStoredRevision"] as? String)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, saved["historyCount"] as? Int)
        let status = app.staticTexts["preset.quick.status"]; revealFormControl(status, app: app)
        XCTAssertTrue(status.label.contains("Unchanged"), status.label)
        app.buttons["editor.group.light"].tap()
        XCTAssertTrue(app.buttons["adjustment.value"].waitForExistence(timeout: 5), "Leaving presets opens the requested tool without collapsing its panel")
    }

    func testScopeSummaryMatchesCaptureWithoutSaving() {
        let app = launch(language: "en", presetFixtures: true)
        let initial = receipt(app)
        openPresets(app)
        app.buttons["preset.create"].tap()
        presetName("Scope summary", app: app)
        func chooseScope(_ title: String) {
            let picker = app.descendants(matching: .any).matching(identifier: "preset.save.scope").firstMatch
            revealFormControl(picker, app: app); picker.tap()
            app.buttons[title].firstMatch.tap()
        }
        chooseScope("Modified only")
        let count = app.staticTexts["preset.save.summary.count"]
        revealFormControl(count, app: app)
        XCTAssertTrue(count.label.contains("Adjustments to overwrite: 1."), count.label)
        let light = app.descendants(matching: .any).matching(identifier: "preset.save.summary.group.light").firstMatch
        revealFormControl(light, app: app); light.tap()
        let exposure = app.descendants(matching: .any).matching(identifier: "preset.save.summary.value.light.exposure").firstMatch
        revealFormControl(exposure, app: app)
        XCTAssertTrue(exposure.label.contains("+0.50 EV"), app.debugDescription)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, initial["historyCount"] as? Int)
        XCTAssertEqual(receipt(app)["sourceStoredRevision"] as? String, initial["sourceStoredRevision"] as? String)
        XCTAssertTrue(receipt(app)["clipboard"] is NSNull)
        capture(app, "scope-summary-modified")
        chooseScope("Custom")
        let clear = app.buttons["preset.save.clear"]
        revealFormControl(clear, app: app); clear.tap()
        let empty = app.staticTexts["preset.save.summary.empty"]
        revealFormControl(empty, app: app); XCTAssertTrue(empty.exists)
        let save = app.buttons["preset.save.confirm"]
        revealFormControl(save, app: app); XCTAssertFalse(save.isEnabled)
        capture(app, "scope-summary-empty-custom")
        chooseScope("Modified only")
        revealFormControl(save, app: app); XCTAssertTrue(save.isEnabled); save.tap()
        wait(app) { ($0["presets"] as? [[String: Any]])?.count == 1 }
        let payload = presets(app)[0]["payload"] as! [String: Any]
        let values = payload["values"] as! [String: Any]
        XCTAssertEqual(Set(values.keys), ["light.exposure"])
        XCTAssertEqual(values["light.exposure"] as? Double, 0.5)
        XCTAssertEqual(receipt(app)["historyCount"] as? Int, initial["historyCount"] as? Int)
    }

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
        let manage = app.buttons["preset.quick.manage"]
        revealFormControl(manage, app: app); XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
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
        app.buttons["preset.quick.manage"].tap()
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
        wait(app) { $0["exposure"] as? Double == 0.75 && $0["sourceStoredExposure"] as? Double == 0.75 }
        XCTAssertEqual((receipt(app)["history"] as! [[String: Any]]).last?["action"] as? String, "preset")
        XCTAssertEqual(receipt(app)["clipboard"] as? NSDictionary, clipboard)
        capture(app, "preset-apply-native-history")
        XCTAssertTrue(app.buttons["preset.quick.undo"].waitForExistence(timeout: 10), "Current-photo application returns to the inline list")
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
            // 屏幕外的 SwiftUI 按钮在部分 Simulator 上查询 isHittable 会报错；先把其完整 frame 滚入视口。
            for _ in 0..<8 {
                if library.exists && !library.frame.isEmpty && app.frame.contains(library.frame) { break }
                app.scrollViews["editor.tools"].swipeLeft()
            }
            XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
            let manage = app.buttons["preset.quick.manage"]; revealFormControl(manage, app: app); manage.tap()
            let create = app.buttons["preset.create"]; revealFormControl(create, app: app); create.tap()
            presetName("晨光 · Portrait / Sehr langer benutzerdefinierter Vorgabenname", app: app)
            let clear = app.buttons["preset.save.clear"]; revealFormControl(clear, app: app); clear.tap()
            let light = app.descendants(matching: .any).matching(identifier: "preset.group.light").firstMatch
            revealFormControl(light, app: app); light.tap()
            let exposure = app.switches["preset.field.light.exposure"]
            revealFormControl(exposure, app: app); XCTAssertGreaterThanOrEqual(exposure.frame.height, 44)
            let nativeSwitch = exposure.switches.firstMatch
            if nativeSwitch.exists { nativeSwitch.tap() } else { exposure.tap() }
            // 空摘要变为覆盖说明后，超大字号可能将当前行推到视口外；重新滚到字段再验证状态。
            revealFormControl(exposure, app: app); XCTAssertEqual(exposure.value as? String, "1")
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
            app.buttons["preset.close"].tap()
            let quickApply = app.buttons["preset.quick.apply.\(id)"]; revealFormControl(quickApply, app: app)
            XCTAssertGreaterThanOrEqual(quickApply.frame.height, 44)
            let photo = (receipt(app)["nativePhotoRects"] as! [[Double]]).first!
            XCTAssertGreaterThan(photo[2], 44); XCTAssertGreaterThan(photo[3], 44)
            capture(app, "quick-preset-large-\(language)")
            app.terminate()
        }
    }
}
