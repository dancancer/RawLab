import XCTest

extension EditorUITests {
    func testSixLanguageNativePickerAndBatchWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        importPhoto(in: app)
        let names = ["简体中文", "English", "Deutsch", "Français", "日本語", "Español"]
        let copies: [[String]] = [
            ["语言", "标准显影", "匹配内嵌预览", "传感器基准", "拍摄时设置", "自定义", "细节优先", "去噪优先", "原始尺寸", "指定长边", "长边 %@ px", "取消", "保存当前照片", "返回", "查看批量任务…", "调整来源", "已选 %@ 张", "导出尺寸", "已保存 %@ 张到照片图库", "完成", "跟随系统"],
            ["Language", "Standard development", "Match embedded preview", "Sensor reference", "As-Shot Setting", "Custom", "Detail Priority", "Noise Reduction Priority", "Original size", "Specify long edge", "Long Edge %@ px", "Cancel", "Save Current Photo", "Back", "View Batch Task…", "Adjustment Source", "%@ selected", "Export Size", "Saved to Photos: %@", "Done", "Follow system"],
            ["Sprache", "Standardentwicklung", "An eingebettete Vorschau anpassen", "Sensorreferenz", "Einstellung wie aufgenommen", "Benutzerdefiniert", "Detailpriorität", "Rauschreduzierung priorisieren", "Originalgröße", "Lange Seite festlegen", "Lange Seite %@ px", "Abbrechen", "Aktuelles Foto sichern", "Zurück", "Stapel-Export anzeigen…", "Anpassungsquelle", "%@ ausgewählt", "Exportgröße", "In Fotos gespeichert: %@", "Fertig", "Systemsprache verwenden"],
            ["Langue", "Développement standard", "Adapter à l'aperçu intégré", "Référence du capteur", "Réglage selon la prise", "Personnalisé", "Priorité aux détails", "Priorité à la réduction du bruit", "Taille d’origine", "Spécifier le bord long", "Bord long %@ px", "Annuler", "Enregistrer la photo actuelle", "Retour", "Afficher la tâche par lots…", "Source des réglages", "Sélection : %@", "Taille d’exportation", "Enregistrées dans Photos : %@", "Terminé", "Suivre le système"],
            ["言語", "標準現像", "埋め込みプレビューに合わせる", "センサー基準", "撮影時の設定", "カスタム", "ディテール優先", "ノイズ低減優先", "元のサイズ", "長辺を指定", "長辺 %@ px", "キャンセル", "現在の写真を保存", "戻る", "一括書き出しを表示…", "調整元", "%@ 枚を選択", "書き出しサイズ", "写真に%@枚保存しました", "完了", "システムに従う"],
            ["Idioma", "Revelado estándar", "Coincidir con la vista previa incrustada", "Referencia del sensor", "Ajuste según la toma", "Personalizado", "Prioridad al detalle", "Prioridad a la reducción de ruido", "Tamaño original", "Especificar borde largo", "Borde largo %@ px", "Cancelar", "Guardar foto actual", "Volver", "Ver tarea por lotes…", "Origen de los ajustes", "Seleccionadas: %@", "Tamaño de exportación", "Guardadas en Fotos: %@", "Listo", "Seguir el sistema"]
        ]
        func tapTool(_ id: String) { self.tapTool(id, in: app) }
        tapTool("exposure")
        dragRuler(app.descendants(matching: .any)["adjustment.ruler"])
        guard let exposure = app.buttons["tool.exposure"].value as? String else {
            XCTFail("Exposure control did not expose its value")
            return
        }
        XCTAssertNotEqual(exposure, "+0.00 EV")
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
            tapTool("exposure")
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

            tapTool("exposure")
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

    func testRAWRecipeSelectionAndLensCapabilityStates() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-RawLab.language", "zh-Hans"]
        app.launch(); importRAWFile(in: app)
        tapTool("masterRecipe", in: app)
        let recipe = app.buttons["recipe.hamada_daylight_v2"]
        XCTAssertTrue(recipe.waitForExistence(timeout: 10));recipe.tap()
        XCTAssertTrue(recipe.isSelected)
        let selected = XCTAttachment(screenshot: recipe.screenshot());selected.name="raw-recipe-selection-mark";selected.lifetime = .keepAlways;add(selected)
        tapTool("lens", in: app)
        XCTAssertTrue(app.staticTexts["lens.status"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["lens.status"].label.isEmpty)
        let manual=app.segmentedControls["lens.mode"].buttons["手动"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10));manual.tap()
        let profile=app.buttons["lens.profile"]
        XCTAssertTrue(profile.isEnabled);profile.tap()
        let search=app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10));search.tap();search.typeText("Tamron")
        let candidate=app.buttons["lens.candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10));candidate.tap()
        for id in ["lens.distortion","lens.tca"] {
            let toggle=app.switches[id]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            if toggle.isEnabled {
                if toggle.value as? String != "1" {toggle.tap()}
                XCTAssertEqual(toggle.value as? String,"1")
                toggle.tap();XCTAssertEqual(toggle.value as? String,"0")
            } else {XCTAssertEqual(toggle.value as? String,"0")}
        }
        capture("raw-lens-capability-states")
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

}
