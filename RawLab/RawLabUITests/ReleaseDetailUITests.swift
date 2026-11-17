import XCTest

// ----------------------------------------------------------------------------
//  发布前细节回归：标题、重置按钮、面板对齐与滚动位置
//  模拟器图库里放任意一张照片即可（RAW 或普通图片都行）
// ----------------------------------------------------------------------------
final class ReleaseDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // 导航栏标题要么完整显示，要么不显示：不能被两侧按钮挤成"…"
    func testNavigationTitleIsNeverSqueezedIntoAnEllipsis() {
        let app = launch()
        let title = app.navigationBars.staticTexts["RawLab"]
        XCTAssertTrue(!title.exists || title.frame.width >= 50,
                      "navigation title squeezed to \(title.frame.width) pt")
    }

    // 标题行的重置菜单（含"全部重置"）和参数自己的重置按钮紧挨着，两者不能长得一模一样
    func testHeaderResetMenuLooksDifferentFromTheParameterReset() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        // v0.8 两级工作台：总览标题行是重置菜单（editor.reset，双段字形带下拉角标），
        // 工具页的重置改在工具工作区工具栏（editor.draft.reset，单字形按钮）。
        // 两处重置入口仍需一眼可辨：截图差异必须大于 1。
        let header = app.buttons["editor.reset"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        let headerShot = header.screenshot()
        try selectTool("geometry", in: app)
        let parameter = app.buttons["editor.draft.reset"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 10), app.debugDescription)
        // 同一图标、同一状态时两张截图逐像素相同（差为 0）
        let difference = meanDifference(headerShot.image, parameter.screenshot().image)
        XCTAssertGreaterThan(difference, 1, "overview reset and workspace reset render the same glyph")
    }

    // 工具页标题行（草稿操作行）与两侧的放弃/应用图标垂直居中对齐
    func testGeometryResetIsCenteredOnItsTitle() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        // v0.8: 按工具重置移入工作区工具栏；标题行即草稿操作行，
        // 工具名夹在放弃与应用图标之间，三者必须垂直居中对齐。
        let cancel = app.buttons["editor.draft.cancel"]
        let apply = app.buttons["editor.draft.apply"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10) && apply.exists, app.debugDescription)
        let titles = app.staticTexts.matching(NSPredicate(format: "label == %@", "Geometry")).allElementsBoundByIndex
        let rowTitle = try XCTUnwrap(titles.first { abs($0.frame.midY - cancel.frame.midY) < 12 },
                                     "标题行应显示工具名：\(app.debugDescription)")
        XCTAssertEqual(rowTitle.frame.midY, cancel.frame.midY, accuracy: 3)
        XCTAssertEqual(rowTitle.frame.midY, apply.frame.midY, accuracy: 3)
    }

    // 两级导航烟测：离开已滚动的工具页后，新面板的首行应贴顶可见
    func testSwitchingToolsShowsTheNewPanelFromTheTop() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        // 原 v0.4 同容器跨工具的 .id 回归锁因 v0.8 两级导航重建滚动容器而退役。
        // 现保留导航贴顶烟测：展开暗角面板并真实滚动，再经总览进入曝光验证首行贴顶可见；
        // 不要求暗角首行离框，也不声称移除产品 .id 会使该测失败。
        try selectTool("vignette", in: app)
        let panel = app.scrollViews["editor.panel"]
        let advanced = app.buttons["effects.vignette.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), app.debugDescription)
        advanced.tap()
        // adjustment.title 是曝光类面板专有 id；vignette 页的标题是草稿行静态文本。
        let vignetteHeader = app.staticTexts.matching(NSPredicate(format: "label == %@", "Vignette")).firstMatch
        XCTAssertTrue(vignetteHeader.waitForExistence(timeout: 10), app.debugDescription)
        let topRow = app.buttons["effects.vignette.vignetteAmount.value"]
        XCTAssertTrue(topRow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(panel.frame.contains(topRow.frame), "the amount row starts the expanded vignette content")
        // 滚动驱动复刻 revealRuler 的已验证手势（左缘 press-drag，避开标尺热区），
        // 为导航烟测建立真实滚动前置；滚动幅度按下方实测范围断言，不要求首行离开面板。
        let deep = app.descendants(matching: .any)["effects.vignette.vignetteHighlights.ruler"]
        XCTAssertTrue(deep.waitForExistence(timeout: 5), app.debugDescription)
        let panel0 = app.scrollViews["editor.panel"]
        let initialY = topRow.frame.minY
        var lastY = initialY
        for _ in 0..<3 {
            // 左缘 press-drag（避开标尺热区）逐次推进，直到内容到达自身最大偏移（行不再移动）。
            panel0.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: panel0.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.35)))
            let y = topRow.frame.minY
            if y == lastY { break }
            lastY = y
        }
        // 面板 376pt 装 418pt 内容：可滚距离约 42pt，首行不会完全离开视口；
        // 这里只验证导航烟测的真实滚动前置，不充当旧 .id 修复的回归锁。
        XCTAssertLessThanOrEqual(lastY, initialY - 40,
                                 "the expanded vignette panel must really scroll: \(initialY) -> \(lastY)")
        try selectTool("exposure", in: app)
        let header = app.staticTexts["adjustment.title"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(header.label, "Exposure", "the panel must switch to the new tool")
        XCTAssertTrue(panel.frame.contains(header.frame), "header \(header.frame) outside panel \(panel.frame)")
        XCTAssertLessThanOrEqual(header.frame.minY, panel.frame.minY + 36,
                                 "the new panel must render from its top, not an old scroll offset")
    }

    // 两个旋转按钮并排时一样高：英文"Rotate left 90°"折成多行，不能把左边按钮撑得比右边高
    func testRotationButtonsShareOneHeight() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        // v0.8：左右旋转按钮在几何面板的"旋转"页签内，先进页签才看得到它们
        let rotateTab = app.buttons["geometry.tab.1"]
        XCTAssertTrue(rotateTab.waitForExistence(timeout: 10), app.debugDescription)
        rotateTab.tap()
        let left = app.buttons["geometry.rotateLeft"], right = app.buttons["geometry.rotateRight"]
        XCTAssertTrue(left.waitForExistence(timeout: 10) && right.exists, app.debugDescription)
        XCTAssertEqual(left.frame.height, right.frame.height, accuracy: 1)
        XCTAssertEqual(left.frame.minY, right.frame.minY, accuracy: 1)
    }

    // 未裁切时"裁切左侧/顶部"没有可调范围（0–0）：控件停用，也不同时宣称"已到下限""已到上限"
    func testEmptyCropOffsetRangeIsInactive() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        // v0.8：裁切偏移/尺寸行移入几何面板"位置与尺寸"表单（GeometryControls 的 sheet），
        // 空范围直接停用控件；v0.4 参考行的下限/上限文案在 v0.8 面板上已不存在，改按停用断言。
        XCTAssertTrue(app.buttons["geometry.aspectRatio"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["geometry.aspectRatio"].tap()
        let dimensions = app.buttons["geometry.dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 5), app.debugDescription)
        dimensions.tap()
        let value = app.buttons["geometry.cropY.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(value.isEnabled, "a 0–0 range has nothing to choose")
    }

    // 自定义尺寸输入框有读屏名称：填了数字后 VoiceOver 不能只读出"70000"
    func testCustomExportSizeFieldHasAName() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        app.buttons["editor.export"].tap()
        app.buttons["Save Current Photo"].tap()
        let size = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export Size'")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 10), app.debugDescription)
        size.tap()
        app.buttons["Specify long edge"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(field.label, "Export Long Edge (Pixels)")
        XCTAssertTrue(app.staticTexts["Enter a pixel count from 1 to 65,535"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "export-size-custom-en"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].tap()
    }

    // 导出面板标题完整显示：德语"Aktuelles Foto sichern"夹在两侧按钮之间时曾被截成"Aktuelles F..."
    func testExportSheetTitleIsNotTruncated() throws {
        let app = launch("de")
        try importFirstVisiblePhoto(in: app)
        app.buttons["editor.export"].tap()
        app.buttons["Aktuelles Foto sichern"].tap()
        XCTAssertTrue(app.buttons["editor.export.confirm"].waitForExistence(timeout: 10), app.debugDescription)
        let titles = app.staticTexts.matching(NSPredicate(format: "label == %@", "Aktuelles Foto sichern"))
            .allElementsBoundByIndex.filter { $0.frame.width > 0 }
        XCTAssertFalse(titles.isEmpty, app.debugDescription)
        let font = UIFont.preferredFont(forTextStyle: .headline)
        let full = ("Aktuelles Foto sichern" as NSString).size(withAttributes: [.font: font]).width
        // 折行后每行宽度乘以行数，至少要放得下整句
        let room = titles.map { $0.frame.width * max(1, ($0.frame.height / font.lineHeight).rounded(.down)) }.max() ?? 0
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "export-sheet-title-de"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertGreaterThanOrEqual(room, full * 0.95, "titles \(titles.map(\.frame)) need \(full) pt")
    }

    // 空批量任务只说"尚未选择照片"，不再重复一行"已选 0 张照片"
    func testEmptyBatchStatesTheSelectionOnce() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try openBatch(in: app)
        XCTAssertTrue(app.staticTexts["No Photos Selected"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["0 selected"].exists, "the empty batch repeats its selection count")
        discardBatch(in: app)
    }

    // 同时只有一个批量任务：已有任务时导出菜单只给"查看批量任务…"，不再并列一个同样打开旧任务的新建入口
    func testExportMenuOffersOneEntryForAPendingBatch() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try openBatch(in: app)
        app.buttons["Back"].tap()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["View Batch Task…"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["editor.batchExport"].exists, "a second entry opens the same pending task")
        app.buttons["View Batch Task…"].tap()
        discardBatch(in: app)
    }

    // ------------------------------------------------------------------------
    //  工具函数
    // ------------------------------------------------------------------------
    private func launch(_ language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-RawLab.language", language]
        app.launch()
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 30))
        return app
    }

    private func importFirstVisiblePhoto(in app: XCUIApplication) throws {
        let empty = app.buttons["editor.import.empty"]
        if empty.isHittable { empty.tap() } else { app.buttons["editor.import"].tap() }
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let photo = try XCTUnwrap(photos.allElementsBoundByIndex.first { element in
            element.frame.width > 0 && app.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }, "The Photos picker needs a visible seeded image")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow Full Access' OR label == '允许完全访问'")).firstMatch
            if allow.exists { allow.tap() }
            // v0.8: the workbench overview grid is the imported-ready anchor; the compare
            // entry collapsed into the overflow menu and no longer sits in the toolbar.
            return app.scrollViews["editor.tools"].exists && !app.descendants(matching: .any)["editor.preview.updating"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 120), .completed, app.debugDescription)
    }

    private func selectTool(_ name: String, in app: XCUIApplication) throws {
        // v0.8 two-level workbench: from the tool page go back to the overview first
        // (these cases never edit values, so a dirty-draft guard only discards).
        if app.buttons["editor.tool.back"].exists {
            app.buttons["editor.tool.back"].tap()
            if app.alerts.buttons["Discard Changes"].waitForExistence(timeout: 2) {
                app.alerts.buttons["Discard Changes"].tap()
            }
        }
        let group: String
        switch name {
        case "exposure", "highlights", "shadows", "contrast", "toneCurve": group = "light"
        case "temperature", "tint", "saturation", "hsl": group = "color"
        case "clarity", "dehaze", "vignette", "grain": group = "effects"
        case "noiseReduction", "sharpening": group = "detail"
        default: group = "geometry"
        }
        let groupButton = app.buttons["editor.group." + group]
        XCTAssertTrue(groupButton.waitForExistence(timeout: 10), app.debugDescription)
        if !groupButton.isSelected || !app.buttons["tool." + name].exists { groupButton.tap() }
        let tool = app.buttons["tool." + name]
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        let strip = app.scrollViews["editor.tools"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !tool.isHittable {
            strip.swipeLeft()
        }
        XCTAssertTrue(tool.isHittable, tool.debugDescription)
        let frame = tool.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.scrollViews["editor.panel"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func openBatch(in app: XCUIApplication) throws {
        app.buttons["editor.export"].tap()
        let create = app.buttons["editor.batchExport"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), app.debugDescription)
        create.tap()
        XCTAssertTrue(app.buttons["batch.pick"].waitForExistence(timeout: 30), app.debugDescription)
    }

    // 放弃任务，免得留下的批量任务影响之后的用例
    private func discardBatch(in app: XCUIApplication) {
        let actions = app.buttons["Task Actions"]
        guard actions.waitForExistence(timeout: 10) else { return }
        actions.tap()
        app.buttons["Discard Task"].firstMatch.tap()
        // 菜单项和确认框按钮同名：菜单收起后再点确认框里的那个
        let confirm = app.buttons["Discard Task"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    // 两张截图缩到同一尺寸后的平均灰度差（0–255）
    private func meanDifference(_ a: UIImage, _ b: UIImage) -> Double {
        let lhs = gray(a), rhs = gray(b)
        return zip(lhs, rhs).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }

    private func gray(_ image: UIImage, side: Int = 32) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let cgImage = image.cgImage,
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }
}
