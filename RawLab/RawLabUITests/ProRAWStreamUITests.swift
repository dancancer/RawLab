import XCTest
import Photos
import ImageIO

extension HDRPhotoUITests {
    private func requireProRAWDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Streamed 48 MP product exports require the admitted physical iPhone")
        #else
        guard ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] == "1",
              ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" else {
            throw XCTSkip("Dedicated physical ProRAW fixture app required")
        }
        #endif
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        authorizeDevicePhotoAudit()
    }

    @objc func testProRAW48StreamedGeometryAndCancellation() throws {
        try requireProRAWDevice()
        let app = XCUIApplication(); app.launchArguments = ["-RawLab.language", "zh-Hans"]; app.launch()
        openStreamFixture(app, stem: "ProRAW48Fixture")
        resetStreamGeometry(app)
        let before = devicePhotoIDs()
        app.buttons["editor.export"].tap(); app.buttons["保存当前照片"].tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        let cancel = app.buttons["editor.cancelExport"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription); cancel.tap()
        let cancelled = app.alerts.staticTexts["导出已取消"]
        XCTAssertTrue(cancelled.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(devicePhotoIDs(), before, "Cancelled single export must not add a Photos asset")
        capture("proraw-48-cancelled", app)
        app.alerts.buttons["关闭"].tap()
        wait { app.buttons["editor.export"].isEnabled }

        openStreamGeometry(app)
        app.buttons["geometry.rotateRight"].tap()
        app.buttons["geometry.flipHorizontal"].tap()
        setStreamGeometryValue(app, identifier: "geometry.straighten", value: "7.0", unit: "°")
        let dimensions = app.buttons["geometry.dimensions"]
        revealStreamControl(dimensions, app: app); dimensions.tap()
        setStreamGeometryValue(app, identifier: "geometry.cropWidth", value: "50", unit: "%")
        applyStreamGeometry(app)
        openStreamGeometry(app, perspective: true)
        setStreamGeometryValue(app, identifier: "geometry.perspectiveHorizontal", value: "12", unit: "")
        applyStreamGeometry(app)
        capture("proraw-48-geometry-applied", app)
        let hdr = try deviceSaveAndAudit(app, name: "ProRAW48-geometry-hdr", width: 768, height: 2048, longEdge: 2048)
        let sdr = try deviceSaveAndAudit(app, name: "ProRAW48-geometry-sdr", width: 768, height: 2048,
            menuItem: "保存 SDR JPEG", longEdge: 2048)
        try checkStreamPhoto(hdr, hdr: true)
        try checkStreamPhoto(sdr, hdr: false)
        resetStreamGeometry(app)
    }

    @objc func testProRAWStreamedBatchPhotosAndCancellation() throws {
        try requireProRAWDevice()
        let app = XCUIApplication(); app.launchArguments = ["-RawLab.language", "zh-Hans"]; app.launch()
        // 批量沿用每个目标已有的 HDR 模式，先通过真实编辑器保存两张原片的模式。
        for stem in ["ProRAW12Fixture", "ProRAW48Fixture"] {
            openStreamFixture(app, stem: stem); resetStreamGeometry(app)
        }
        let options = XCTMeasureOptions(); options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            do {
                for hdr in [true, false] {
                    openStreamBatch(app)
                    for stem in ["ProRAW48Fixture", "ProRAW12Fixture"] {
                        let pick = app.buttons["batch.filePick"]
                        XCTAssertTrue(pick.waitForExistence(timeout: 15)); wait { pick.isEnabled }; pick.tap()
                        chooseCameraRawFixture(app, stem: stem)
                        wait { app.buttons["batch.export"].exists && app.buttons["batch.export"].isEnabled }
                    }
                    let format = app.segmentedControls["batch.format"]
                    revealStreamControl(format, app: app)
                    format.buttons[hdr ? "HDR JPEG" : "JPEG"].tap()
                    wait { format.buttons[hdr ? "HDR JPEG" : "JPEG"].isSelected }
                    wait { app.buttons["batch.export"].exists && app.buttons["batch.export"].isEnabled }
                    let before = devicePhotoIDs()
                    app.buttons["batch.export"].tap()
                    if hdr {
                        let cancel = app.buttons["取消导出"]
                        XCTAssertTrue(cancel.waitForExistence(timeout: 20)); cancel.tap()
                        wait { app.navigationBars["导出已取消"].exists && app.buttons["batch.export"].isEnabled }
                        XCTAssertEqual(devicePhotoIDs(), before, "Cancelled first batch target reached Photos publication")
                        capture("proraw-batch-cancelled", app)
                        app.buttons["batch.export"].tap()
                    }
                    XCTAssertTrue(app.staticTexts["已保存 2 张到照片图库"].waitForExistence(timeout: 180), app.debugDescription)
                    capture(hdr ? "proraw-batch-hdr-saved" : "proraw-batch-sdr-saved", app)
                    let created = devicePhotoIDs().subtracting(before)
                    XCTAssertEqual(created.count, 2, "Batch must publish exactly its two completed targets")
                    guard created.count == 2 else { return }
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(created), options: nil)
                    var dimensions = Set<String>()
                    for index in 0..<assets.count {
                        let asset = assets.object(at: index)
                        let resolution = asset.pixelWidth == 8064 ? "48" : "12"
                        let width = resolution == "48" ? 8064 : 3024, height = resolution == "48" ? 6048 : 4032
                        dimensions.insert("\(asset.pixelWidth)x\(asset.pixelHeight)")
                        let data = try deviceAuditPhoto(asset, name: "ProRAW-batch-\(hdr ? "hdr" : "sdr")-\(resolution)", width: width, height: height)
                        try checkStreamPhoto(data, hdr: hdr)
                    }
                    XCTAssertEqual(dimensions, Set(["8064x6048", "3024x4032"]))
                    app.buttons["完成"].tap()
                    wait { app.buttons["editor.export"].isHittable }
                }
            } catch { XCTFail("Stream batch Photos audit failed: \(error)") }
        }
    }

    private func openStreamFixture(_ app: XCUIApplication, stem: String) {
        let importer = app.buttons["editor.import.file"]
        if !importer.exists { app.buttons["editor.privacy"].tap() }
        XCTAssertTrue(importer.waitForExistence(timeout: 15)); wait { importer.isEnabled }; importer.tap()
        chooseCameraRawFixture(app, stem: stem)
        wait { app.buttons["editor.compare"].isEnabled }
        deviceEditingMode(app, hdr: true)
        wait { app.buttons["editor.export"].isEnabled }
    }

    private func openStreamGeometry(_ app: XCUIApplication, perspective: Bool = false) {
        let group = app.buttons["editor.group.geometry"]
        for _ in 0..<6 where !group.isHittable { app.scrollViews["editor.groups"].swipeLeft() }
        XCTAssertTrue(group.isHittable, app.debugDescription); group.tap()
        let tool = app.buttons[perspective ? "tool.perspective" : "tool.geometry"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10)); tool.tap()
        XCTAssertTrue(app.buttons["editor.draft.cancel"].waitForExistence(timeout: 10))
    }

    private func resetStreamGeometry(_ app: XCUIApplication) {
        openStreamGeometry(app)
        let reset = app.buttons["geometry.reset"]
        revealStreamControl(reset, app: app)
        if reset.isEnabled { reset.tap(); applyStreamGeometry(app) }
        else { app.buttons["editor.draft.cancel"].tap() }
        wait { !app.buttons["editor.draft.apply"].exists && app.buttons["editor.export"].isEnabled }
    }

    private func revealStreamControl(_ control: XCUIElement, app: XCUIApplication) {
        let batch = app.scrollViews.containing(.segmentedControl, identifier: "batch.format").firstMatch
        let isBatch = batch.exists
        let panel = isBatch ? batch : app.scrollViews["editor.panel"].exists ? app.scrollViews["editor.panel"] : app.scrollViews.firstMatch
        // 分段控件部分露在固定底栏下方时 isHittable 仍可能为真，先滚到安全可见区域。
        for _ in 0..<8 where !control.isHittable || (isBatch && control.frame.maxY > app.frame.height * 0.7) {
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85))
                .press(forDuration: 0.1, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2)))
        }
        XCTAssertTrue(control.isHittable, app.debugDescription)
    }

    private func setStreamGeometryValue(_ app: XCUIApplication, identifier: String, value: String, unit: String) {
        let button = app.buttons[identifier + ".value"]
        revealStreamControl(button, app: app); button.tap()
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let wheel = picker.pickerWheels.firstMatch
        let current = wheel.value as? String ?? ""
        let suffix = unit.isEmpty ? "" : " " + unit
        let target = current.contains(picker.label + ",") ? picker.label + ", " + value + suffix
            : current.contains(suffix) && !unit.isEmpty ? value + suffix : value
        wheel.adjust(toPickerWheelValue: target)
        app.buttons["adjustment.wheel.apply"].tap()
        wait { !picker.exists }
    }

    private func applyStreamGeometry(_ app: XCUIApplication) {
        let apply = app.buttons["editor.draft.apply"]
        wait { apply.isEnabled && apply.isHittable }; apply.tap()
        wait { !apply.exists && app.buttons["editor.export"].isEnabled }
    }

    private func openStreamBatch(_ app: XCUIApplication) {
        app.buttons["editor.export"].tap()
        if app.buttons["查看批量任务…"].exists {
            app.buttons["查看批量任务…"].tap()
            let menu = app.buttons["任务操作"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
            app.buttons["放弃任务"].tap()
            let confirm = app.buttons["放弃任务"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
            wait { app.buttons["editor.export"].isHittable }; app.buttons["editor.export"].tap()
        }
        app.buttons["使用当前调整批量导出…"].tap()
        XCTAssertTrue(app.buttons["batch.filePick"].waitForExistence(timeout: 15))
    }

    private func checkStreamPhoto(_ data: Data, hdr: Bool) throws {
        let iso = Data("urn:iso:std:iso:ts:21496:-1".utf8)
        XCTAssertEqual(data.range(of: iso) != nil, hdr)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(values[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(values[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertNotNil(values[kCGImagePropertyProfileName])
        XCTAssertFalse((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] ?? []).isEmpty)
        XCTAssertGreaterThan((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertNil(exif[kCGImagePropertyExifMakerNote])
    }
}
