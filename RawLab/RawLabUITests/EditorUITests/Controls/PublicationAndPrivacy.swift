import XCTest

extension EditorUITests {
    func testUsagePrivacyDefaultsOn() {
        // 英文界面下隐私设置整页都是英文：入口、标题、开关与状态说明
        // 从未选择过时统计默认开启；调试构建不带 SDK，状态行说明未配置
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        app.launch()
        let menu = app.buttons["editor.privacy"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.label, "More")
        menu.tap()
        let open = app.buttons["editor.privacy.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        open.tap()
        let toggle = app.switches["usage.consent"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(toggle.isEnabled, "a saved or default consent stays withdrawable")
        XCTAssertEqual(toggle.label, "Allow usage analytics")
        XCTAssertTrue(app.navigationBars["Privacy settings"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Usage analytics is not configured in this build; nothing is collected or reported."].exists)
        // 按文字查询最长 128 个字符，长句用前缀匹配
        let installID = NSPredicate(format: "label BEGINSWITH %@", "To count active devices, the app stores a randomly generated installation ID")
        XCTAssertTrue(app.staticTexts.matching(installID).firstMatch.exists, app.debugDescription)
        capture("usage-privacy-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["usage.done"].isHittable)
        capture("usage-privacy-landscape")
        app.buttons["usage.done"].tap()
        XCTAssertTrue(app.buttons["editor.import"].exists)
    }

    func testSaveNoticeKeepsPortraitControlsInPlace() {
        checkSaveNoticeLayout(orientation: .portrait)
    }

    func testSaveNoticeKeepsLandscapeControlsInPlace() {
        checkSaveNoticeLayout(orientation: .landscapeLeft)
    }

    func testSaveNoticeKeepsLargeTextControlsInPlace() {
        checkSaveNoticeLayout(orientation: .portrait, contentSizeCategory: "UICTContentSizeCategoryAccessibilityM")
    }

    func testSaveNoticeKeepsSmallTextControlsInPlace() {
        checkSaveNoticeLayout(orientation: .portrait, contentSizeCategory: "UICTContentSizeCategoryXS")
    }

    func testSixLanguageLensAndDngBatchControlsPreserveState() {
        print("Six-language Lens/DNG integration: native Photos completion and Files save v7")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["settings.language"].tap()
        app.buttons["English"].tap()
        if app.buttons["batch.resume"].exists {
            app.buttons["batch.resume"].tap()
            app.buttons["Task Actions"].tap()
            app.buttons["Discard Task"].tap()
            app.sheets.buttons["Discard Task"].tap()
        }
        importPhoto(in: app)
        let lensTool = app.buttons["tool.lens"]
        let strip = app.scrollViews.containing(.button, identifier: "tool.lens").allElementsBoundByIndex
            .min { $0.frame.height < $1.frame.height }!
        for _ in 0..<8 where !lensTool.isHittable { strip.swipeRight() }
        lensTool.tap()
        let manual = app.segmentedControls["lens.mode"].buttons["Manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), app.debugDescription)
        if app.buttons["lens.reset"].isEnabled { app.buttons["lens.reset"].tap() }
        manual.tap()
        let profile = app.buttons["lens.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
        profile.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Tamron")
        let candidate = app.buttons["lens.candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10), app.debugDescription)
        candidate.tap()
        for id in ["lens.distortion", "lens.tca"] {
            let toggle = app.switches[id]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if toggle.value as? String != "1" { toggle.tap() }
        }
        guard let selectedProfile = profile.value as? String, !selectedProfile.isEmpty else {
            XCTFail("Selected native Lens profile value missing"); return
        }
        app.buttons["editor.export"].tap()
        app.buttons["editor.batchExport"].tap()
        XCTAssertTrue(app.buttons["batch.pick"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["batch.pick"].tap()
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        guard let chosen = verifiedSeedPickerIndex else { XCTFail("Seed photo index missing"); return }
        photos.element(boundBy: chosen).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons.matching(NSPredicate(format: "identifier == 'Add' AND label == 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        done.tap()
        expectation(for: NSPredicate { _, _ in app.buttons["batch.export"].isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 90)
        let scroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height }!
        scroll.swipeUp()
        app.segmentedControls["batch.format"].buttons["DNG · Rendered"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export Size'")).firstMatch.tap()
        app.buttons["Specify long edge"].tap()
        let longEdge = app.textFields["Long Edge (1–65535 px)"]
        XCTAssertTrue(longEdge.waitForExistence(timeout: 5), app.debugDescription)
        longEdge.tap()
        longEdge.typeText("128")
        app.buttons["Back"].tap()

        let cases = [
            ("简体中文", "自动", "手动", "DNG · 渲染型", "RawLab 文件", "查看批量任务…", "返回"),
            ("English", "Auto", "Manual", "DNG · Rendered", "RawLab Files", "View Batch Task…", "Back"),
            ("Deutsch", "Automatisch", "Manuell", "DNG · Entwickelt", "RawLab-Dateien", "Stapel-Export anzeigen…", "Zurück"),
            ("Français", "Auto", "Manuel", "DNG · Développé", "Fichiers RawLab", "Afficher la tâche par lots…", "Retour"),
            ("日本語", "自動", "手動", "DNG · 現像済み", "RawLabファイル", "一括書き出しを表示…", "戻る"),
            ("Español", "Automático", "Manual", "DNG · Revelado", "Archivos RawLab", "Ver tarea por lotes…", "Volver")
        ]
        for c in cases {
            app.buttons["settings.language"].tap()
            app.buttons[c.0].tap()
            let mode = app.segmentedControls["lens.mode"]
            XCTAssertTrue(mode.buttons[c.1].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(mode.buttons[c.2].isSelected, app.debugDescription)
            XCTAssertEqual(app.buttons["lens.profile"].value as? String, selectedProfile)
            XCTAssertEqual(app.switches["lens.distortion"].value as? String, "1")
            XCTAssertEqual(app.switches["lens.tca"].value as? String, "1")
            XCTAssertFalse(app.staticTexts["lens.status"].label.isEmpty)
            capture("integrated-lens-" + c.0)
            app.buttons["editor.export"].tap()
            app.buttons[c.5].tap()
            XCTAssertTrue(app.staticTexts[seedPhotoBase + ".DNG"].firstMatch.waitForExistence(timeout: 10))
            app.scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height }!.swipeUp()
            let format = app.segmentedControls["batch.format"]
            XCTAssertTrue(format.buttons[c.3].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(format.buttons[c.3].isSelected)
            XCTAssertEqual(app.textFields.firstMatch.value as? String, "128")
            XCTAssertTrue(app.staticTexts[c.4].exists, app.debugDescription)
            capture("integrated-dng-batch-" + c.0)
            app.buttons[c.6].tap()
        }
        app.buttons["editor.export"].tap()
        app.buttons["Ver tarea por lotes…"].tap()
        app.buttons["batch.export"].tap()
        let save = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 180), app.debugDescription)
        capture("integrated-dng-files-save")
        save.tap()
        let exported = "1 archivos DNG revelados exportados"
        XCTAssertTrue(app.staticTexts[exported].waitForExistence(timeout: 15), app.debugDescription)
        capture("integrated-dng-exported-es")
        app.buttons["Listo"].tap()
        app.buttons["settings.language"].tap()
        app.buttons["Seguir el sistema"].tap()
    }

}
