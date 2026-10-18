import XCTest

final class EditorUITests: XCTestCase {
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

    private let seedPhotoDate = "2025年6月02日, 16:45"
    private let seedPhotoBase = "DJI_20250602164503_0444_D"
    private var verifiedSeedPickerIndex: Int?

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

    private func checkSaveNoticeLayout(orientation: UIDeviceOrientation, contentSizeCategory: String? = nil) {
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

    private func assertSaveNoticeFrames(_ expected: [CGRect], equalTo actual: [CGRect]) {
        for (before, after) in zip(expected, actual) {
            XCTAssertEqual(before.origin.x, after.origin.x, accuracy: 0.5, "Save feedback must not move editing controls horizontally")
            XCTAssertEqual(before.origin.y, after.origin.y, accuracy: 0.5, "Save feedback must not move editing controls vertically")
            XCTAssertEqual(before.width, after.width, accuracy: 0.5, "Save feedback must not resize editing controls horizontally")
            XCTAssertEqual(before.height, after.height, accuracy: 0.5, "Save feedback must not resize editing controls vertically")
        }
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
        app.buttons["Custom…"].tap()
        let longEdge = app.textFields["Long Edge (1–65535 px)"]
        XCTAssertTrue(longEdge.waitForExistence(timeout: 5), app.debugDescription)
        longEdge.tap()
        longEdge.typeText("128")
        app.buttons["Back"].tap()

        let cases = [
            ("简体中文", "自动", "手动", "DNG · 渲染型", "RawLab 文件", "查看批量任务", "返回"),
            ("English", "Auto", "Manual", "DNG · Rendered", "RawLab Files", "View Batch Task", "Back"),
            ("Deutsch", "Automatisch", "Manuell", "DNG · Entwickelt", "RawLab-Dateien", "Stapelauftrag anzeigen", "Zurück"),
            ("Français", "Auto", "Manuel", "DNG · Développé", "Fichiers RawLab", "Afficher la tâche par lots", "Retour"),
            ("日本語", "自動", "手動", "DNG · 現像済み", "RawLabファイル", "一括タスクを表示", "戻る"),
            ("Español", "Automático", "Manual", "DNG · Revelado", "Archivos RawLab", "Ver tarea por lotes", "Volver")
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
        app.buttons["Ver tarea por lotes"].tap()
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

    func testSixLanguageNativePickerAndBatchWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        importPhoto(in: app)
        let names = ["简体中文", "English", "Deutsch", "Français", "日本語", "Español"]
        let copies: [[String]] = [
            ["语言", "标准显影", "匹配内嵌预览", "传感器基准", "拍摄时", "自定义", "细节优先", "去噪优先", "原始分辨率", "自定义…", "长边 %@ px", "取消", "保存当前照片", "返回", "查看批量任务", "调整来源", "已选 %@ 张照片", "导出尺寸", "已保存 %@ 张到照片图库", "完成", "跟随系统"],
            ["Language", "Standard Development", "Match Embedded Preview", "Sensor Reference", "As Shot", "Custom", "Detail Priority", "Noise Reduction Priority", "Original Resolution", "Custom…", "Long Edge %@ px", "Cancel", "Save Current Photo", "Back", "View Batch Task", "Adjustment Source", "Photos Selected: %@", "Export Size", "Saved to Photos: %@", "Done", "Follow system"],
            ["Sprache", "Standardentwicklung", "Eingebettete Vorschau abgleichen", "Sensorreferenz", "Wie aufgenommen", "Benutzerdefiniert", "Detailpriorität", "Rauschunterdrückung priorisieren", "Originalauflösung", "Benutzerdefiniert…", "Lange Kante %@ px", "Abbrechen", "Aktuelles Foto sichern", "Zurück", "Stapelauftrag anzeigen", "Anpassungsquelle", "Ausgewählte Fotos: %@", "Exportgröße", "In Fotos gespeichert: %@", "Fertig", "Systemsprache verwenden"],
            ["Langue", "Développement standard", "Faire correspondre l’aperçu intégré", "Référence du capteur", "Selon la prise", "Personnalisé", "Priorité aux détails", "Priorité à la réduction du bruit", "Résolution originale", "Personnalisé…", "Bord long %@ px", "Annuler", "Enregistrer la photo actuelle", "Retour", "Afficher la tâche par lots", "Source des réglages", "Photos sélectionnées : %@", "Taille d’exportation", "Enregistrées dans Photos : %@", "Terminé", "Suivre le système"],
            ["言語", "標準現像", "埋め込みプレビューに一致", "センサー基準", "撮影時", "カスタム", "ディテール優先", "ノイズ低減優先", "元の解像度", "カスタム…", "長辺 %@ px", "キャンセル", "現在の写真を保存", "戻る", "一括タスクを表示", "調整元", "%@枚の写真を選択", "書き出しサイズ", "写真に%@枚保存しました", "完了", "システムに従う"],
            ["Idioma", "Revelado estándar", "Coincidir con la vista previa incrustada", "Referencia del sensor", "Según la toma", "Personalizado", "Prioridad al detalle", "Prioridad a la reducción de ruido", "Resolución original", "Personalizado…", "Borde largo %@ px", "Cancelar", "Guardar foto actual", "Volver", "Ver tarea por lotes", "Origen de los ajustes", "Fotos seleccionadas: %@", "Tamaño de exportación", "Guardadas en Fotos: %@", "Listo", "Seguir el sistema"]
        ]
        func tapTool(_ id: String) {
            let button = app.buttons["tool." + id]
            let strips = app.scrollViews.containing(.button, identifier: "tool." + id).allElementsBoundByIndex
            guard let strip = strips.min(by: { $0.frame.height < $1.frame.height }) else {
                XCTFail("Tool strip missing: " + id); return
            }
            for _ in 0..<10 {
                let frame = button.frame
                if frame.width > 0 && strip.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    return
                }
                if frame.midX < strip.frame.midX { strip.swipeRight() } else { strip.swipeLeft() }
            }
            XCTFail("Could not reveal tool: " + id)
        }
        tapTool("exposure")
        app.sliders["adjustment.slider"].adjust(toNormalizedSliderPosition: 0.6)
        guard let exposure = app.buttons["tool.exposure"].value as? String else {
            XCTFail("Exposure control did not expose its value")
            return
        }
        XCTAssertNotEqual(exposure, "+0.0 EV")
        var batchCreated = app.buttons["batch.resume"].exists
        for index in names.indices {
            let c = copies[index]
            let language = app.buttons["settings.language"]
            language.tap()
            app.buttons[names[index]].tap()
            expectation(for: NSPredicate { _, _ in language.label == c[0] }, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            tapTool("exposure")
            XCTAssertEqual(app.buttons["tool.exposure"].value as? String, exposure)
            app.buttons["editor.export"].tap()
            if batchCreated { app.buttons[c[14]].tap() } else { app.buttons["editor.batchExport"].tap() }
            XCTAssertTrue(app.buttons["batch.pick"].waitForExistence(timeout: 10), app.debugDescription)
            if !batchCreated {
                app.buttons["batch.pick"].tap()
                let photos = app.images.matching(identifier: "PXGGridLayout-Info")
                XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
                guard let chosen = verifiedSeedPickerIndex else { XCTFail("Seed photo index missing"); return }
                photos.element(boundBy: chosen).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let add = app.buttons["Add"]
                XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
                add.tap()
                expectation(for: NSPredicate { _, _ in app.buttons["batch.export"].isEnabled }, evaluatedWith: app)
                waitForExpectations(timeout: 90)
                batchCreated = true
            }
            XCTAssertTrue(app.staticTexts[c[15]].exists, app.debugDescription)
            let selected = c[16].replacingOccurrences(of: "%@", with: "1")
            XCTAssertTrue(app.staticTexts[selected].exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts[seedPhotoBase + ".DNG"].firstMatch.exists, app.debugDescription)
            let scroll = app.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height })!
            scroll.swipeUp()
            let batchSize = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", c[17])).firstMatch
            XCTAssertTrue(batchSize.waitForExistence(timeout: 5), app.debugDescription)
            if index > 0 { XCTAssertTrue(batchSize.label.contains("2048"), batchSize.label) }
            batchSize.tap()
            XCTAssertTrue(app.buttons[c[8]].exists && app.buttons[c[9]].exists, app.debugDescription)
            capture("extra-" + names[index] + "-batch-picker")
            let edge = c[10].replacingOccurrences(of: "%@", with: "2048")
            app.buttons[edge].tap()
            capture("extra-" + names[index] + "-batch-state")
            if index == names.count - 1 {
                app.buttons["batch.export"].tap()
                let saved = c[18].replacingOccurrences(of: "%@", with: "1")
                XCTAssertTrue(app.staticTexts[saved].waitForExistence(timeout: 180), app.debugDescription)
                capture("extra-batch-completed-spanish")
                app.buttons[c[19]].tap()
            } else { app.buttons[c[13]].tap() }
            XCTAssertEqual(app.buttons["tool.exposure"].value as? String, exposure)
        }

        // 先完成批量任务，避免恢复任务横幅改变编辑控件的位置。
        for index in names.indices {
            let c = copies[index]
            app.buttons["settings.language"].tap()
            app.buttons[names[index]].tap()
            XCTAssertEqual(app.buttons["settings.language"].label, c[0])
            tapTool("exposure")
            XCTAssertEqual(app.buttons["tool.exposure"].value as? String, exposure)
            let mode = app.buttons["exposure.mode"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
            mode.tap()
            for option in c[1...3] { XCTAssertTrue(app.buttons[option].exists, app.debugDescription) }
            capture("extra-" + names[index] + "-exposure-picker")
            app.buttons[c[1]].tap()
            XCTAssertTrue(mode.label.contains(c[1]), mode.label)

            tapTool("temperature")
            XCTAssertTrue(app.buttons["tool.temperature"].isSelected)
            XCTAssertFalse(app.buttons["tool.tint"].exists,
                           "White balance keeps tint as a parameter rather than a second tool")
            let wb = app.segmentedControls["whiteBalance.mode"]
            XCTAssertTrue(wb.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(wb.buttons[c[4]].exists && wb.buttons[c[5]].exists, app.debugDescription)
            wb.buttons[c[5]].tap()
            XCTAssertTrue(wb.buttons[c[5]].isSelected)
            wb.buttons[c[4]].tap()
            XCTAssertTrue(wb.buttons[c[4]].isSelected)
            tapTool("noiseReduction")
            app.scrollViews["editor.panel"].swipeDown()
            let preset = app.buttons["denoise.preset"]
            XCTAssertTrue(preset.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertLessThanOrEqual(preset.frame.height, 60, preset.debugDescription)
            capture("extra-" + names[index] + "-denoise-layout")
            preset.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons[c[6]].exists && app.buttons[c[7]].exists, app.debugDescription)
            capture("extra-" + names[index] + "-denoise-picker")
            app.buttons[c[7]].tap()
            XCTAssertTrue(preset.label.contains(c[7]), preset.label)
            XCTAssertLessThanOrEqual(preset.frame.height, 60, preset.debugDescription)
            preset.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons[c[6]].tap()
            XCTAssertTrue(preset.label.contains(c[6]), preset.label)

            app.buttons["editor.export"].tap()
            app.buttons[c[12]].tap()
            let exportSize = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", c[17])).firstMatch
            XCTAssertTrue(exportSize.waitForExistence(timeout: 5), app.debugDescription)
            exportSize.tap()
            XCTAssertTrue(app.buttons[c[8]].exists && app.buttons[c[9]].exists, app.debugDescription)
            let edge = c[10].replacingOccurrences(of: "%@", with: "2048")
            XCTAssertTrue(app.buttons[edge].exists, app.debugDescription)
            capture("extra-" + names[index] + "-export-picker")
            app.buttons[edge].tap()
            XCTAssertTrue(exportSize.label.contains("2048"), exportSize.label)
            app.buttons[c[11]].tap()

            XCTAssertEqual(app.buttons["tool.exposure"].value as? String, exposure)
        }
        app.buttons["settings.language"].tap()
        app.buttons[copies.last![20]].tap()
    }
    func testLanguageSelectionPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let language = app.buttons["settings.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        language.tap()
        app.buttons["Deutsch"].tap()
        XCTAssertTrue(app.staticTexts["RAW-Foto"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(language.label, "Sprache")
        let german = XCTAttachment(screenshot: app.screenshot())
        german.name = "localization-german"
        german.lifetime = .keepAlways
        add(german)
        language.tap()
        app.buttons["Français"].tap()
        XCTAssertTrue(app.staticTexts["Photo RAW"].waitForExistence(timeout: 5), app.debugDescription)
        let french = XCTAttachment(screenshot: app.screenshot())
        french.name = "localization-french"
        french.lifetime = .keepAlways
        add(french)
        app.terminate()
        app.launch()
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        XCTAssertEqual(language.label, "Langue")
        language.tap()
        app.buttons["Suivre le système"].tap()
        XCTAssertTrue(app.staticTexts["RAW Photo"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testLensControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let toolbar = app.scrollViews.containing(.button, identifier: "tool.lens").allElementsBoundByIndex.min { $0.frame.height < $1.frame.height }!
        for _ in 0..<5 where !app.buttons["tool.lens"].isHittable { toolbar.swipeRight() }
        app.buttons["tool.lens"].tap()
        XCTAssertTrue(app.switches["lens.distortion"].waitForExistence(timeout: 10))
        for id in ["lens.distortion", "lens.tca", "lens.crop"] { XCTAssertTrue(app.switches[id].isHittable) }
        app.switches["lens.distortion"].tap()
        app.segmentedControls["lens.mode"].buttons["手动"].tap()
        let profile = app.buttons["lens.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        app.searchFields.firstMatch.tap(); app.searchFields.firstMatch.typeText("Tamron")
        let candidate = app.buttons["lens.candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10)); candidate.tap()
        capture("lens-controls-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.switches["lens.crop"].waitForExistence(timeout: 10))
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<3 where !profile.isHittable { panel.swipeUp() }
        XCTAssertTrue(profile.isHittable, "Lens selection remains reachable in landscape")
        capture("lens-controls-landscape")
        panel.swipeDown()
        app.buttons["lens.reset"].tap()
        XCTAssertEqual(app.switches["lens.distortion"].value as? String, "0")
        XCUIDevice.shared.orientation = .portrait
    }

    func testMasterRecipeControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let toolbar = app.scrollViews.containing(.button, identifier: "tool.masterRecipe").allElementsBoundByIndex.min { $0.frame.height < $1.frame.height }!
        // 工具栏默认滚到选中的"曝光"，配方按钮在左侧屏外；屏外元素查询可点击性会直接报错，改看位置
        for _ in 0..<3 where app.buttons["tool.masterRecipe"].frame.minX < toolbar.frame.minX { toolbar.swipeRight() }
        app.buttons["tool.masterRecipe"].tap()
        XCTAssertTrue(app.buttons["recipe.hamada_daylight_v2"].waitForExistence(timeout: 10))
        // 有插图的配方卡只显示插图，替代图标只给没有插图的"无配方"卡：两种卡的图片区等高，整卡高度相近
        let neutralTile = app.buttons["recipe.neutral"].frame, artworkTile = app.buttons["recipe.hamada_daylight_v2"].frame
        XCTAssertLessThan(abs(artworkTile.height - neutralTile.height), 30,
                          "artwork tile \(artworkTile.height) vs neutral \(neutralTile.height): no second icon under the artwork")
        XCTAssertFalse(app.buttons["向左滚动大师配方"].exists)
        XCTAssertFalse(app.buttons["向右滚动大师配方"].exists)
        let recipes = app.scrollViews["masterRecipe.choices"]
        func visible(_ id: String) -> Bool {
            let frame = app.buttons[id].frame
            return frame.width > 0 && recipes.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0..<10 {
            if visible("recipe.jungraphy_neon") { break }
            recipes.swipeLeft()
        }
        XCTAssertTrue(visible("recipe.jungraphy_neon"))
        for _ in 0..<10 {
            if visible("recipe.hamada_daylight_v2") { break }
            recipes.swipeRight()
        }
        XCTAssertTrue(visible("recipe.hamada_daylight_v2"))
        let recipeFrame = app.buttons["recipe.hamada_daylight_v2"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: recipeFrame.midX, dy: recipeFrame.midY)).tap()
        XCTAssertEqual(app.buttons["tool.masterRecipe"].value as? String, "滨田英明")
        // 面板标题行已显示当前配方名，面板内只留说明，不再重复一遍名字（配方卡自身的名字不算）
        let recipeName = NSPredicate(format: "label == %@", "滨田英明")
        XCTAssertEqual(app.staticTexts.matching(recipeName).count - recipes.staticTexts.matching(recipeName).count, 1)
        capture("master-recipes-portrait")
        for _ in 0..<8 {
            let frame = app.buttons["tool.hsl"].frame
            if frame.width > 0 && toolbar.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
            let start = toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            let end = toolbar.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let hsl = app.buttons["tool.hsl"]
        let hslFrame = hsl.frame
        XCTAssertTrue(toolbar.frame.contains(CGPoint(x: hslFrame.midX, y: hslFrame.midY)))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: hslFrame.midX, dy: hslFrame.midY)).tap()
        XCTAssertTrue(app.buttons["hsl.channel.4"].waitForExistence(timeout: 10))
        app.buttons["hsl.channel.4"].tap()
        // 数值显示在可点按输入的数值按钮上，不再是独立文字
        XCTAssertEqual(app.buttons["hsl.saturation.value"].value as? String, "+4")
        XCTAssertEqual(app.buttons["hsl.lightness.value"].value as? String, "-1")
        capture("master-recipe-hsl-portrait")
    }

    func testEditMemoryAndBatchWorkflow() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        app.buttons["重置曝光"].tap()
        app.sliders["adjustment.slider"].adjust(toNormalizedSliderPosition: 0.6)
        let savedExposure = app.buttons["tool.exposure"].value as? String
        XCTAssertNotEqual(savedExposure, "+0.0 EV")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "调整已保存")).firstMatch.waitForExistence(timeout: 10))
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

    func testHSLAndAutoExposureAdaptiveLayout() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        let auto = app.buttons["exposure.auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        auto.tap()
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        let first = app.buttons["tool.exposure"].value as? String
        auto.tap()
        expectation(for: NSPredicate { _, _ in auto.isEnabled }, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, first, "Auto assigns an absolute EV")
        capture("auto-exposure-portrait")
        let strips = app.scrollViews.containing(.button, identifier: "tool.hsl").allElementsBoundByIndex
        let strip = strips.min { $0.frame.height < $1.frame.height }!
        for _ in 0..<8 {
            let frame = app.buttons["tool.hsl"].frame
            if frame.width > 0 && strip.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
            let left = frame.midX > strip.frame.midX
            let start = strip.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.2, dy: 0.5))
            let end = strip.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.4 : 0.6, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let hslFrame = app.buttons["tool.hsl"].frame
        XCTAssertTrue(strip.frame.contains(CGPoint(x: hslFrame.midX, y: hslFrame.midY)), app.debugDescription)
        // SwiftUI's clipped tool strip can omit an AX activation point for a visible button.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: hslFrame.midX, dy: hslFrame.midY)).tap()
        let saturation = app.sliders["hsl.saturation"]
        XCTAssertTrue(saturation.waitForExistence(timeout: 10))
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<3 where !saturation.isHittable { panel.swipeUp() }
        XCTAssertTrue(saturation.isHittable)
        saturation.adjust(toNormalizedSliderPosition: 0.2)
        capture("hsl-portrait")
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let visibleTools = app.scrollViews.containing(.button, identifier: "tool.hsl").allElementsBoundByIndex
        let rotatedStrip = visibleTools.min { $0.frame.height < $1.frame.height }!
        let selectedTool = app.buttons["tool.hsl"].frame
        XCTAssertTrue(rotatedStrip.frame.contains(CGPoint(x: selectedTool.midX, y: selectedTool.midY)),
                      "Rotation keeps the selected tool visible")
        capture("hsl-landscape")
        for _ in 0..<3 where !saturation.isHittable { panel.swipeUp() }
        XCTAssertTrue(saturation.isHittable)
        XCTAssertTrue(app.buttons["editor.export"].exists)
    }

    func testPhotoEffectsControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
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
        XCTAssertFalse(app.buttons["effects.vignette.reset"].exists,
                       "Collapsed vignette does not expose the group reset")
        app.buttons["effects.vignette.advanced"].tap()
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
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
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.film"].tap()
        for name in ["ACROS", "ASTIA", "CLASSIC CHROME", "CLASSIC Neg.", "ETERNA", "ETERNA BB",
                     "PRO Neg.Std", "PROVIA", "REALA ACE", "Velvia"] {
            XCTAssertTrue(app.buttons[name].exists, "Missing built-in LUT: \(name)")
        }
        XCTAssertFalse(app.buttons["WDR"].exists)
        XCTAssertFalse(app.buttons["FLog2 709"].exists)
        capture("complete-film-list")
    }

    func testPreviewZoomGestures() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        let canvas = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.pinch(withScale: 3, velocity: 1)
        XCTAssertFalse(isFittedPhoto(canvas))
        canvas.swipeLeft()
        capture("photo-pinched-and-panned")
        canvas.doubleTap()
        XCTAssertTrue(isFittedPhoto(canvas))
        app.buttons["editor.adjustments"].tap()
        XCTAssertTrue(isFittedPhoto(canvas))
        canvas.doubleTap()
        XCTAssertEqual(canvas.value as? String, "100%")
        app.buttons["editor.adjustments"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        capture("photo-actual-pixels-resized")
        importPhoto(in: app)
        XCTAssertTrue(isFittedPhoto(canvas))
    }

    private func isFittedPhoto(_ canvas: XCUIElement) -> Bool {
        guard let value = canvas.value as? String else { return false }
        let parts = value.split(separator: " ")
        guard parts.count > 1, let percentage = parts.last, percentage.hasSuffix("%"),
              let number = Int(percentage.dropLast()), number >= 0 else { return false }
        return parts.dropLast().joined(separator: " ").rangeOfCharacter(from: .letters) != nil
    }

    private func importPhoto(in app: XCUIApplication) {
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
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                return red > 100 && red > green * 1.8 && red > blue * 1.8
            }.count
        }
        return redPixels > 4
    }
}
