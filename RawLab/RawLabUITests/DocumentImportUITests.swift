import XCTest

final class DocumentImportUITests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_UI"] == "1" else {
            throw XCTSkip("Use document-import-ui.sh with a dedicated simulator")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFilesPickerCanBeCancelledAndReopened() {
        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        cancelPicker(in: app)
        openMenuImport("Import from Files", in: app)
        cancelPicker(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openMenuImport("Import from Files", in: app)
        cancelPicker(in: app)
        XCTAssertTrue(app.buttons["editor.import.empty"].exists)
    }

    func testLookPickerCanBeCancelledAndReopened() {
        let app = launchEditor()
        openMenuImport("Import Look", in: app)
        cancelPicker(in: app)
        openMenuImport("Import from Files", in: app)
        cancelPicker(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openMenuImport("Import Look", in: app)
        cancelPicker(in: app)
    }

    func testFilesImportUsesPhotoContents() {
        if ProcessInfo.processInfo.environment["RAWLAB_DOCUMENT_IMPORT_RAW"] == "1" {
            assertPhotoImports("RawLabRawAsJPEG.jpeg")
        }
        assertPhotoImports("RawLabRasterAsRaw.arw")
        assertPhotoImports("RawLabPhotoWithoutExtension")

        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        selectFile("RawLabTextAsJPEG.jpeg", in: app)
        let unsupported = app.alerts["RawLab"].firstMatch.staticTexts["Selected Item Is Not a Supported Image."].firstMatch
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["editor.photo"].exists)
    }

    private func assertPhotoImports(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = launchEditor()
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertFalse(photo.exists, file: file, line: line)
        app.buttons["editor.import.file"].tap()
        selectFile(name, in: app)
        let alert = app.alerts["RawLab"].firstMatch
        waitUntil(timeout: 60, file: file, line: line) { photo.exists || alert.exists }
        XCTAssertTrue(photo.exists, "\(name) did not reach the editor. \(app.debugDescription)", file: file, line: line)
    }

    func testPhotoAndLookSelectionsReachTheirOwnImports() {
        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        selectFile("RawLabImportFixture.png", in: app)
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 60), app.debugDescription)
        waitUntil { app.buttons["tool.film"].isEnabled }
        app.buttons["tool.film"].tap()
        let addLook = app.buttons["looks.import"]
        XCTAssertTrue(addLook.waitForExistence(timeout: 10), app.debugDescription)
        addLook.tap()
        selectFile("RawLabImportFixture.cube", in: app)
        let film = app.buttons["tool.film"]
        waitUntil { film.value as? String == "RawLabImportFixture" }
        XCTAssertEqual(film.value as? String, "RawLabImportFixture", "The selected LUT must reach the look handler")
        XCTAssertTrue(photo.exists, "Importing a LUT must preserve the current photo")
        openMenuImport("Import from Files", in: app)
        cancelPicker(in: app)
        XCTAssertEqual(film.value as? String, "RawLabImportFixture")
        XCTAssertTrue(photo.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "photo-and-lut-imported"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPadJPEGPreviewResolvesFineDetailAfterZoom() {
        let app = launchEditor()
        app.buttons["editor.import.file"].tap()
        selectFile("RawLabDetailFixture.jpeg", in: app)
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 60), app.debugDescription)
        waitUntil { app.buttons["tool.film"].isEnabled }
        photo.pinch(withScale: 3, velocity: 2)

        // In the center of the JPEG, black and white bars each span three source pixels.
        // Count the resolved edges on screen; enlarging the 1280 px bitmap aliases the bars.
        let scanCenter = CGPoint(x: photo.frame.midX, y: photo.frame.midY)
        let screen = app.frame
        let deadline = Date().addingTimeInterval(12)
        var screenshot = app.screenshot()
        var transitions = resolvedBarEdges(in: screenshot, at: scanCenter, screen: screen)
        while transitions < 55 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            screenshot = app.screenshot()
            transitions = resolvedBarEdges(in: screenshot, at: scanCenter, screen: screen)
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "zoomed-jpeg-detail"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(transitions, 55, "The zoomed preview should resolve the JPEG's fine bars")
    }

    private func resolvedBarEdges(in screenshot: XCUIScreenshot, at point: CGPoint, screen: CGRect) -> Int {
        guard let image = screenshot.image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / screen.width
        let width = 384
        let row = CGRect(x: Int((point.x - screen.minX) * scale) - width / 2,
                         y: Int((point.y - screen.minY) * scale), width: width, height: 1)
        guard let scan = image.cropping(to: row),
              let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.draw(scan, in: CGRect(x: 0, y: 0, width: width, height: 1))
        var lastLight: Bool?
        var transitions = 0
        for x in 0..<width where pixels[x] <= 96 || pixels[x] >= 160 {
            let light = pixels[x] >= 160
            if let lastLight, light != lastLight { transitions += 1 }
            lastLight = light
        }
        return transitions
    }

    func testCompatibilityCancellationAllowsAnotherLookImport() {
        let app = launchEditor()
        openMenuImport("Import Look", in: app)
        selectFile("RawLabUnknownLook.cube", in: app)
        let confirm = app.buttons["look.compatibility.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["Cancel"].firstMatch.tap()
        waitUntil { !confirm.exists }
        openMenuImport("Import Look", in: app)
        cancelPicker(in: app)
    }

    func testTargetSelectionErrorsAreExported() {
        let app = launchEditor()
        let rejectedFile = "RawLabTextAsJPEG.jpeg"
        let unsupported = app.staticTexts["Selected Item Is Not a Supported Image."].firstMatch

        openMenuImport("Batch editing", in: app)
        app.buttons["collection.files"].tap()
        selectFile(rejectedFile, in: app)
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Close"].firstMatch.tap()

        app.buttons["editor.import.file"].firstMatch.tap()
        selectFile("RawLabImportFixture.png", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: 60))
        waitUntil { app.buttons["editor.export"].isEnabled }
        openMenuImport("Copy Adjustments", in: app)
        let copy = app.buttons["adjustment.copy.confirm"]
        for _ in 0..<6 where !copy.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(copy.isHittable && copy.isEnabled, app.debugDescription)
        copy.tap()
        waitUntil { !copy.exists }
        openMenuImport("Paste Adjustments", in: app)
        app.buttons["adjustment.paste.chooseFiles"].tap()
        selectFile(rejectedFile, in: app)
        XCTAssertTrue(unsupported.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["adjustment.transfer.close"].tap()

        openMenuImport("Export Error Log", in: app)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 12), app.debugDescription)
        openLocalAppFolder(in: app)
        save.tap()
        waitUntil { !save.exists }
    }

    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.privacy"].waitForExistence(timeout: 20), app.debugDescription)
        waitUntil { app.buttons["editor.import"].isEnabled }
        return app
    }

    private func openMenuImport(_ label: String, in app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        // 部分系统菜单行不暴露 identifier；本组固定英文，按本地化标签匹配。
        let predicate = NSPredicate(format: "label == %@", label)
        let anchor = NSPredicate(format: "identifier == %@ OR label == %@", "collection.open", "Batch editing")
        var menuShown = app.collectionViews.containing(anchor).firstMatch.waitForExistence(timeout: 5)
        if !menuShown {
            // 旋转后的第一次点击可能落在布局动画中，菜单不会弹出；重试一次。
            app.buttons["editor.privacy"].tap()
            menuShown = app.collectionViews.containing(anchor).firstMatch.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(menuShown, app.debugDescription)
        // 横屏时未滚到的行不在树中；按首行定位容器，再固定索引，避免首行滚出后查询失效。
        guard let menu = app.collectionViews.allElementsBoundByIndex.first(where: {
            $0.buttons.matching(anchor).firstMatch.exists
        }) else {
            XCTFail(app.debugDescription)
            return
        }
        let item = menu.buttons.matching(predicate).firstMatch
        let width = menu.frame.width
        let viewport = (app.otherElements.containing(anchor).allElementsBoundByIndex
            .map(\.frame)
            .filter { abs($0.width - width) < 1 && $0.height > 44 }
            .min { $0.height < $1.height } ?? menu.frame).intersection(app.frame)
        let visible = viewport.insetBy(dx: 0, dy: 8)
        // 原生菜单会把滚动区域外的行也报为可点击，必须先确认实际可见范围。
        for _ in 0..<4 {
            if item.exists && visible.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) { break }
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.75))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.25))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(item.exists, app.debugDescription)
        waitUntil { item.isEnabled }
        XCTAssertTrue(visible.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)), app.debugDescription)
        XCTAssertTrue(item.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "menu-before-" + label
        screenshot.lifetime = .keepAlways
        add(screenshot)
        item.tap()
    }

    private func cancelPicker(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
        cancel.tap()
        waitUntil { !cancel.exists }
    }

    private func selectFile(_ name: String, in app: XCUIApplication) {
        openLocalAppFolder(in: app)
        let url = URL(fileURLWithPath: name)
        let identifiers = ["\(url.deletingPathExtension().lastPathComponent), \(url.pathExtension)",
                           "\(name), \(url.pathExtension)"]
        let predicate = url.pathExtension.isEmpty
            ? NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", name, name + ", ")
            : NSPredicate(format: "identifier IN %@", identifiers)
        let file = app.cells.matching(predicate).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "The selected file type must be accepted by the picker")
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 2) { open.tap() }
        waitUntil { !file.exists }
    }

    private func openLocalAppFolder(in app: XCUIApplication) {
        // 保存窗口在 iOS 27 不暴露 Cancel 按钮，以实际的 Save 操作确认窗口已打开。
        let action = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Save"])).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 12), app.debugDescription)
        let folder = app.cells.matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@",
                                                   "RawLab", "RawLab, ")).firstMatch
        let local = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My ")).firstMatch
        let location = app.buttons.matching(NSPredicate(format: "label IN %@", ["On My iPad", "On My iPhone"])).firstMatch
        if !folder.exists && !local.exists {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
        }
        // Browse 可能恢复到本地根目录，此时位置名只是标题，RawLab 文件夹已可直接打开。
        let destination = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            folder.exists || local.exists || location.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [destination], timeout: 10), .completed, app.debugDescription)
        if !folder.exists {
            if local.exists {
                local.tap()
            } else {
                XCTAssertTrue(location.exists, app.debugDescription)
                location.tap()
            }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
    }

    private func waitUntil(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }
}
