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
        let header = app.buttons["Reset Adjustments"]
        let parameter = app.buttons["adjustment.reset"]
        XCTAssertTrue(header.waitForExistence(timeout: 10) && parameter.exists, app.debugDescription)
        XCTAssertEqual(header.isEnabled, parameter.isEnabled, "compare both in the same state")
        // 同一图标、同一状态时两张截图逐像素相同（差为 0）
        let difference = meanDifference(header.screenshot().image, parameter.screenshot().image)
        XCTAssertGreaterThan(difference, 1, "header reset and parameter reset render the same glyph")
    }

    // 几何面板标题与右侧重置按钮垂直居中对齐
    func testGeometryResetIsCenteredOnItsTitle() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        let title = app.staticTexts["Crop and Rotate"]
        let reset = app.buttons["geometry.reset"]
        XCTAssertTrue(title.waitForExistence(timeout: 10) && reset.exists, app.debugDescription)
        XCTAssertEqual(title.frame.midY, reset.frame.midY, accuracy: 3)
    }

    // 换工具后面板回到顶部：不能沿用上一个面板的滚动位置，把新面板的标题行藏起来
    func testSwitchingToolsShowsTheNewPanelFromTheTop() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        let panel = app.scrollViews["editor.panel"]
        for _ in 0..<3 {
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.85))
                .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.15)))
        }
        XCTAssertFalse(panel.frame.contains(app.buttons["geometry.reset"].frame), "the geometry panel must be scrolled first")
        try selectTool("hsl", in: app)
        let header = app.buttons["Reset Adjustments"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(panel.frame.contains(header.frame), "header \(header.frame) outside panel \(panel.frame)")
    }

    // 两个旋转按钮并排时一样高：英文"90° Counterclockwise"折成多行，不能把左边按钮撑得比右边高
    func testRotationButtonsShareOneHeight() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try selectTool("geometry", in: app)
        let left = app.buttons["geometry.rotateLeft"], right = app.buttons["geometry.rotateRight"]
        XCTAssertTrue(left.waitForExistence(timeout: 10) && right.exists, app.debugDescription)
        XCTAssertEqual(left.frame.height, right.frame.height, accuracy: 1)
        XCTAssertEqual(left.frame.minY, right.frame.minY, accuracy: 1)
    }

    // 空批量任务只说"尚未选择照片"，不再重复一行"已选 0 张照片"
    func testEmptyBatchStatesTheSelectionOnce() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try openBatch(in: app)
        XCTAssertTrue(app.staticTexts["No Photos Selected"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["0 Photos Selected"].exists, "the empty batch repeats its selection count")
        discardBatch(in: app)
    }

    // 同时只有一个批量任务：已有任务时导出菜单只给"查看批量任务"，不再并列一个同样打开旧任务的新建入口
    func testExportMenuOffersOneEntryForAPendingBatch() throws {
        let app = launch()
        try importFirstVisiblePhoto(in: app)
        try openBatch(in: app)
        app.buttons["Back"].tap()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["View Batch Task"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["editor.batchExport"].exists, "a second entry opens the same pending task")
        app.buttons["View Batch Task"].tap()
        discardBatch(in: app)
    }

    // ------------------------------------------------------------------------
    //  工具函数
    // ------------------------------------------------------------------------
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
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
            return app.buttons["editor.compare"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 120), .completed, app.debugDescription)
    }

    private func selectTool(_ name: String, in app: XCUIApplication) throws {
        let tool = app.buttons["tool." + name]
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        let strips = app.scrollViews.containing(.button, identifier: "tool." + name).allElementsBoundByIndex
        let strip = try XCTUnwrap(strips.min { $0.frame.height < $1.frame.height })
        for _ in 0..<18 {
            let frame = tool.frame
            if strip.frame.insetBy(dx: 8, dy: 0).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
            let right = frame.midX < strip.frame.midX
            strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.25 : 0.75, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.70 : 0.30, dy: 0.5)))
        }
        let frame = tool.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
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
