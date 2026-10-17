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
