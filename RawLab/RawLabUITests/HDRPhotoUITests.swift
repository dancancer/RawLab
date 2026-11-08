import XCTest
import Photos
import ImageIO
import UniformTypeIdentifiers

final class HDRPhotoUITests: XCTestCase {
    private var selectingDeviceFixture = false

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1",
              ProcessInfo.processInfo.environment["RAWLAB_CAMERA_HDR_UI"] != "1",
              ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] != "1" else { return }
        continueAfterFailure = false
        authorizeDevicePhotoAudit()
        let url = try XCTUnwrap(Bundle(for: HDRPhotoUITests.self).url(forResource: "HDRUIFixture", withExtension: "jpg"),
                               "hdr-ui.sh must stage the generated HDR JPEG in the test bundle")
        let data = try Data(contentsOf: url)
        let tag = UUID().uuidString
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 2
        let latest = PHAsset.fetchAssets(with: .image, options: options).firstObject?.creationDate ?? .distantPast
        let date = max(Date().addingTimeInterval(3600), latest.addingTimeInterval(1))
        var identifiers: [String] = []
        // 每个用例创建独立的来源和目标，避免恢复前一用例的调整或把其 SDR 导出误当作原片。
        // 同时控制创建顺序和拍摄时间，使 Photos 的最近项目首两张始终是本用例的来源、目标。
        try PHPhotoLibrary.shared().performChangesAndWait {
            for (index, role) in ["target", "source"].enumerated() {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = date.addingTimeInterval(Double(index))
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "HDRUI-\(tag)-\(role).jpg"
                request.addResource(with: .photo, data: data, options: options)
                if let identifier = request.placeholderForCreatedAsset?.localIdentifier { identifiers.append(identifier) }
            }
        }
        XCTAssertEqual(identifiers.count, 2)
        let recent = PHAsset.fetchAssets(with: .image, options: options)
        XCTAssertEqual((0..<recent.count).map { recent.object(at: $0).localIdentifier }, identifiers.reversed().map { $0 },
                       "Use a dedicated simulator; the current test must own the two most recent photos")
    }

    override func record(_ issue: XCTIssue) {
        if (ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" ||
            ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1"), !selectingDeviceFixture {
            capture("device-failure-screen", XCUIApplication())
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.exists {
                let attachment = XCTAttachment(string: alert.debugDescription)
                attachment.name = "device-system-alert"; attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        super.record(issue)
    }

    func testCameraRawHDRModePersistenceAndExports() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_CAMERA_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated camera RAW HDR simulator only")
        }
        try rawModePersistenceAndExports(stem: "CameraHDRFixture", width: 128, height: 96, restricted: false)
    }

    func testProRAW12ModePersistenceAndPhotos() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] == "1" else {
            throw XCTSkip("Dedicated ProRAW fixture app required")
        }
        #if targetEnvironment(simulator)
        let restricted = true
        #else
        let restricted = false
        #endif
        try rawModePersistenceAndExports(stem: "ProRAW12Fixture", width: 3024, height: 4032, restricted: restricted)
    }

    func testProRAW48ModePersistenceAndPhotos() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] == "1" else {
            throw XCTSkip("Dedicated ProRAW fixture app required")
        }
        #if targetEnvironment(simulator)
        let restricted = true
        #else
        let restricted = false
        #endif
        try rawModePersistenceAndExports(stem: "ProRAW48Fixture", width: 8064, height: 6048, restricted: restricted)
    }

    private func rawModePersistenceAndExports(stem: String, width: Int, height: Int, restricted: Bool) throws {
        continueAfterFailure = false
        if !restricted { authorizeDevicePhotoAudit() }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        app.launch()
        app.buttons["editor.import.file"].tap()
        chooseCameraRawFixture(app, stem: stem)
        wait { app.buttons["editor.compare"].isEnabled || app.alerts.firstMatch.exists }
        XCTAssertTrue(app.buttons["editor.compare"].isEnabled, app.debugDescription)
        XCTAssertFalse(self.showsHDRHistogram(app), "Camera RAW must initially use SDR editing")

        app.buttons["editor.group.light"].tap()
        let exposure = app.buttons["tool.exposure"]
        let sdrExposure = exposure.value as? String
        deviceEditingMode(app, hdr: true)
        XCTAssertTrue(self.showsHDRHistogram(app))
        let neutralHDR = exposure.value as? String
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { exposure.value as? String != neutralHDR }
        let hdrExposure = exposure.value as? String
        if stem.hasPrefix("ProRAW") { verifyProRAWTransfer(app) }
        if stem == "CameraHDRFixture" {
            cameraFBDD(app, select: true)
            verifyCameraTransfer(app)
        }

        deviceEditingMode(app, hdr: false)
        XCTAssertEqual(exposure.value as? String, sdrExposure)
        deviceEditingMode(app, hdr: true)
        XCTAssertEqual(exposure.value as? String, hdrExposure)
        app.terminate()
        app.launch()
        app.buttons["editor.import.file"].tap()
        chooseCameraRawFixture(app, stem: stem)
        wait { app.buttons["editor.compare"].isEnabled && exposure.value as? String == hdrExposure }
        if stem == "CameraHDRFixture" { cameraFBDD(app, select: false) }

        capture(stem + "-restored-hdr", app)
        if restricted {
            app.buttons["editor.export"].tap()
            XCTAssertTrue(app.buttons["此设备暂不支持导出 HDR 模式下的 ProRAW 照片。"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["保存当前照片"].isEnabled)
            XCTAssertFalse(app.buttons["保存 SDR JPEG"].isEnabled)
            capture(stem + "-export-restricted", app)
            return
        }
        var hdr = Data(), sdr = Data()
        let save = {
            hdr = try self.deviceSaveAndAudit(app, name: stem + "-hdr", width: width, height: height)
            sdr = try self.deviceSaveAndAudit(app, name: stem + "-sdr", width: width, height: height, menuItem: "保存 SDR JPEG")
        }
        if stem == "ProRAW48Fixture" {
            let options = XCTMeasureOptions(); options.iterationCount = 1
            measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
                do { try save() } catch { XCTFail("48 MP Photos export failed: \(error)") }
            }
        } else { try save() }
        let iso = Data("urn:iso:std:iso:ts:21496:-1".utf8)
        XCTAssertNotNil(hdr.range(of: iso))
        XCTAssertNil(sdr.range(of: iso))
        if stem == "CameraHDRFixture" {
            #if targetEnvironment(simulator)
            app.buttons["editor.export"].tap()
            XCTAssertTrue(app.buttons["保存 SDR JPEG"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["HDR HEIF"].exists, "This simulator cannot read its encoded ISO HEIF gain map")
            capture("camera-hdr-heif-capability", app)
            #else
            _ = try deviceSaveAndAudit(app, name: stem + "-heif", width: width, height: height,
                                       menuItem: "HDR HEIF", heif: true)
            #endif
        }
        if stem.hasPrefix("ProRAW") {
            for data in [hdr, sdr] {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
                XCTAssertGreaterThan((exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue ?? 0, 0)
                XCTAssertFalse((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] ?? []).isEmpty)
                XCTAssertNil(exif[kCGImagePropertyExifMakerNote])
            }
        }
    }

    private func cameraFBDD(_ app: XCUIApplication, select: Bool, level: Int = 2) {
        deviceMenu(app, item: "照片处理设置")
        let camera = app.buttons["HDR RAW"]
        for _ in 0..<4 where !camera.isHittable { app.swipeUp() }
        XCTAssertTrue(camera.isHittable, app.debugDescription)
        camera.tap()
        let denoise = app.buttons["hdr.camera.fbdd"]
        for _ in 0..<4 where !denoise.isHittable { app.swipeUp() }
        XCTAssertTrue(denoise.isHittable, app.debugDescription)
        if select {
            denoise.tap()
            app.buttons["FBDD \(level)"].tap()
            let apply = app.buttons["hdr.camera.apply"]
            for _ in 0..<4 where !apply.isHittable { app.swipeUp() }
            XCTAssertTrue(apply.isEnabled)
            apply.tap()
            wait { !apply.isEnabled }
        } else {
            XCTAssertTrue(denoise.label.contains("FBDD \(level)") || denoise.value as? String == "FBDD \(level)")
        }
        app.buttons["关闭"].tap()
        wait { app.buttons["editor.compare"].isEnabled && !app.staticTexts["editor.preview.updating"].exists }
    }

    private func verifyCameraTransfer(_ app: XCUIApplication) {
        deviceMenu(app, item: "复制调整")
        let clear = app.buttons["adjustment.copy.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap()
        let detail = app.buttons["adjustment.group.detail"]
        for _ in 0..<3 where !detail.isHittable { app.swipeUp() }
        XCTAssertTrue(detail.isHittable); detail.tap()
        let camera = app.switches["adjustment.field.hdr.camera_development"]
        for _ in 0..<3 where !camera.isHittable { app.swipeUp() }
        XCTAssertTrue(camera.isHittable)
        camera.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(camera.value as? String, "1", app.debugDescription)
        let copy = app.buttons["adjustment.copy.confirm"]
        for _ in 0..<3 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isEnabled, app.debugDescription); copy.tap()
        wait { !copy.exists }
        cameraFBDD(app, select: true, level: 1)
        deviceMenu(app, item: "粘贴调整")
        let apply = app.buttons["adjustment.paste.apply"]
        wait { apply.isEnabled && apply.isHittable }; apply.tap()
        let done = app.buttons["adjustment.paste.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap()
        cameraFBDD(app, select: false)
    }

    private func verifyProRAWTransfer(_ app: XCUIApplication) {
        deviceMenu(app, item: "复制调整")
        let copy = app.buttons["adjustment.copy.confirm"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        wait { copy.isEnabled }; copy.tap()
        wait { !copy.exists }
        app.buttons["editor.group.looks"].tap()
        let saveCurrent = app.buttons["保存当前调整为预设…"]
        XCTAssertTrue(saveCurrent.waitForExistence(timeout: 10)); saveCurrent.tap()
        let name = app.textFields["preset.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap()
        if let existing = name.value as? String {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let presetName = "ProRAW \(UUID().uuidString.prefix(8))"
        name.typeText(presetName + "\n")
        let save = app.buttons["preset.save.confirm"]
        for _ in 0..<3 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts[presetName].waitForExistence(timeout: 15))
        app.buttons["preset.close"].tap()
        app.buttons["editor.group.light"].tap()
        let original = app.buttons["tool.exposure"].value as? String
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { app.buttons["tool.exposure"].value as? String != original }
        app.buttons["editor.group.looks"].tap()
        let label = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "preset.quick.name.", presetName)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let id = String(label.identifier.dropFirst("preset.quick.name.".count))
        let apply = app.buttons["preset.quick.apply." + id]
        for _ in 0..<8 where !apply.isHittable { app.scrollViews["editor.panel"].swipeUp() }
        XCTAssertTrue(apply.isHittable); apply.tap()
        let status = app.staticTexts["preset.quick.status"]
        wait { status.exists && status.label.contains("已保存") }
        capture("proraw-preset-applied", app)
        app.buttons["editor.group.light"].tap()
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, original)
    }

    func testFreshHDRPresetAndCollectionScope() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else { throw XCTSkip("Dedicated HDR simulator only") }
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication(); app.launchArguments=["-RawLab.language","zh-Hans"]; app.launch()
        openRecentHDROriginal(app)
        XCTAssertTrue(app.buttons["editor.group.looks"].isEnabled)
        app.buttons["editor.group.looks"].tap()
        XCTAssertFalse(app.buttons["tool.film"].isEnabled)
        XCTAssertFalse(app.buttons["tool.masterRecipe"].isEnabled)
        XCTAssertFalse(app.buttons["tool.strength"].isEnabled)
        XCTAssertTrue(app.buttons["preset.quick.create"].waitForExistence(timeout:10))
        let saveCurrent=app.buttons["保存当前调整为预设…"]
        XCTAssertTrue(saveCurrent.waitForExistence(timeout:10)); saveCurrent.tap()
        let name=app.textFields["preset.name"]
        XCTAssertTrue(name.waitForExistence(timeout:10)); name.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        if let existing=name.value as? String { name.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:existing.count)) }
        let presetName="Fresh HDR \(UUID().uuidString.prefix(8))"
        name.typeText(presetName+"\n")
        let save=app.buttons["preset.save.confirm"]
        for _ in 0..<3 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts[presetName].waitForExistence(timeout:15),app.debugDescription)
        capture("hdr-fresh-preset-saved",app)
        app.buttons["preset.close"].tap()
        app.buttons["editor.group.light"].tap()
        let originalExposure = app.buttons["tool.exposure"].value as? String
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { app.buttons["tool.exposure"].value as? String != originalExposure }
        let editedExposure = app.buttons["tool.exposure"].value as? String
        app.buttons["editor.group.looks"].tap()
        let label = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "preset.quick.name.", presetName)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        let id = String(label.identifier.dropFirst("preset.quick.name.".count))
        let quickApply = app.buttons["preset.quick.apply." + id]
        for _ in 0..<8 where !quickApply.isHittable { app.scrollViews["editor.panel"].swipeUp() }
        XCTAssertTrue(quickApply.isHittable); quickApply.tap()
        let status = app.staticTexts["preset.quick.status"]
        wait { status.exists && status.label.contains("已保存") }
        let quickUndo = app.buttons["preset.quick.undo"]
        for _ in 0..<8 where !quickUndo.isHittable { app.scrollViews["editor.panel"].swipeDown() }
        capture("hdr-quick-preset-applied", app)
        quickUndo.tap()
        wait { status.label.contains("已撤销") }
        app.buttons["editor.group.light"].tap()
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, editedExposure)
        app.buttons["editor.privacy"].tap(); app.buttons["collection.open"].tap()
        XCTAssertTrue(app.buttons["collection.photos"].waitForExistence(timeout:10)); app.buttons["collection.photos"].tap()
        let grid = photoGrid(app)
        XCTAssertGreaterThanOrEqual(grid.count, 2, "The current test must create its own synchronization target")
        grid.element(boundBy:1).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        app.buttons["Add"].tap()
        let synchronize=app.buttons["collection.synchronize"]
        wait { synchronize.isEnabled }; synchronize.tap()
        let count = app.staticTexts["adjustment.copy.summary.count"]
        XCTAssertTrue(count.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(count.label.contains("7 项调整"),count.label)
        let looks = app.buttons["adjustment.group.looks"]
        XCTAssertTrue(looks.exists && looks.label.hasSuffix("0/1"), app.debugDescription)
        looks.tap()
        // HDR 外观已支持单独传递；默认七项不能包含它，也不能暴露 SDR 胶片和强度字段。
        let hdrLook = app.switches["adjustment.field.hdr.look"]
        XCTAssertTrue(hdrLook.waitForExistence(timeout: 10))
        XCTAssertEqual(hdrLook.value as? String, "0")
        XCTAssertFalse(app.switches["adjustment.field.looks.reference"].exists)
        XCTAssertFalse(app.switches["adjustment.field.looks.strength"].exists)
        looks.tap()
        app.buttons["adjustment.group.color"].tap()
        assertHDRWhiteBalanceScope(app)
        capture("hdr-collection-common-scope",app)
        let prepare=app.buttons["collection.sync.prepare"]
        for _ in 0..<3 where !prepare.isHittable { app.swipeUp() }
        prepare.tap()
        XCTAssertTrue(app.buttons["adjustment.paste.apply"].waitForExistence(timeout:60),app.debugDescription)
        XCTAssertFalse(app.staticTexts["请先应用或放弃未完成的输入和几何草稿。"].exists)
        capture("hdr-collection-preflight",app)
    }

    func testHDRCopyAndBatchInspection() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else { throw XCTSkip("Dedicated HDR simulator only") }
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication(); app.launchArguments=["-RawLab.language","zh-Hans"]; app.launch()
        openRecentHDROriginal(app)
        app.buttons["editor.privacy"].tap(); app.buttons["复制调整"].tap()
        let count = app.staticTexts["adjustment.copy.summary.count"]
        XCTAssertTrue(count.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(count.label.contains("7 项调整"),count.label)
        let color=app.buttons["adjustment.group.color"]
        XCTAssertTrue(color.exists,app.debugDescription); color.tap()
        assertHDRWhiteBalanceScope(app)
        XCTAssertFalse(app.staticTexts["hdr.relative_temperature"].exists)
        capture("hdr-copy-scope",app)
        app.buttons["adjustment.transfer.close"].tap()
        app.buttons["editor.histogram"].tap()
        capture("hdr-histogram-reference-white",app)
        app.buttons["editor.export"].tap()
        if app.buttons["查看批量任务…"].exists {
            app.buttons["查看批量任务…"].tap()
            XCTAssertTrue(app.buttons["任务操作"].waitForExistence(timeout:10))
            app.buttons["任务操作"].tap(); app.buttons["放弃任务"].tap()
            let discard=app.buttons["放弃任务"].firstMatch
            XCTAssertTrue(discard.waitForExistence(timeout:5)); discard.tap()
            wait { app.buttons["editor.export"].isHittable }
            app.buttons["editor.export"].tap()
        }
        app.buttons["使用当前调整批量导出…"].tap()
        XCTAssertTrue(app.buttons["batch.pick"].waitForExistence(timeout:10),app.debugDescription)
        app.buttons["batch.pick"].tap()
        let grid = photoGrid(app)
        grid.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let add=app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout:5),app.debugDescription); add.tap()
        wait { app.buttons["batch.export"].isEnabled }
        let inspect=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@ AND label ENDSWITH %@","检查 "," 的效果")).firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout:10),app.debugDescription); inspect.tap()
        XCTAssertTrue(app.segmentedControls["hdr.previewMode"].waitForExistence(timeout:30),app.debugDescription)
        capture("hdr-batch-float-inspection",app)
        app.buttons["完成"].tap()
        app.buttons["batch.export"].tap()
        XCTAssertTrue(app.staticTexts["已保存 1 张到照片图库"].waitForExistence(timeout:120),app.debugDescription)
        capture("hdr-batch-saved",app)
        app.buttons["完成"].tap()
    }
    func testLandscapeCapture() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else { throw XCTSkip("Dedicated HDR simulator only") }
        continueAfterFailure=false
        let app=XCUIApplication(); app.launchArguments=["-RawLab.language","zh-Hans"]; app.launch()
        openRecentHDROriginal(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { app.frame.width>app.frame.height && app.buttons["editor.histogram"].isHittable }
        app.buttons["editor.histogram"].tap()
        app.buttons["editor.histogram"].tap()
        capture("hdr-landscape-screen",app)
        XCUIDevice.shared.orientation = .portrait
    }
    func testOriginalImportDisplayIsolationAndHistory() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else {
            throw XCTSkip("Use hdr-ui.sh with a dedicated simulator seeded with one public Android HDR original")
        }
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-RawLab.language","zh-Hans"]
        app.launch()
        openRecentHDROriginal(app)
        XCTAssertTrue(app.buttons["tool.exposure"].isSelected,"New HDR import opens an available basic control")
        XCTAssertTrue(app.buttons["editor.group.looks"].isEnabled,"HDR presets remain reachable")
        XCTAssertTrue(app.buttons["exposure.auto"].isEnabled,"HDR mode offers automatic exposure")
        let originalValue=app.buttons["tool.exposure"].value as? String
        app.buttons["editor.privacy"].tap()
        let undoBefore=app.buttons["撤销"].isEnabled
        app.buttons["照片处理设置"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let mode=app.switches["hdr.editMode"]
        XCTAssertTrue(mode.waitForExistence(timeout:10),"Photos import preserved the HDR original container")
        XCTAssertEqual(mode.value as? String,"1")
        app.switches["hdr.falseColor"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        XCTAssertEqual(app.switches["hdr.falseColor"].value as? String,"1")
        app.buttons["SDR 兼容预览"].tap()
        XCTAssertEqual(mode.value as? String,"1","SDR preview changed editing mode")
        app.switches["hdr.falseColor"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        capture("hdr-monitoring-sdr-preview",app)
        app.buttons["关闭"].tap()
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String,originalValue)
        app.buttons["editor.privacy"].tap()
        XCTAssertEqual(app.buttons["撤销"].isEnabled,undoBefore,"Display controls created an editing transaction")
        app.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        wait { app.buttons["exposure.auto"].isHittable && app.buttons["exposure.auto"].isEnabled }
        app.buttons["exposure.auto"].tap()
        wait { app.buttons["tool.exposure"].value as? String != originalValue }
        let edited=app.buttons["tool.exposure"].value as? String
        print("HDR exposure original=\(String(describing:originalValue)) edited=\(String(describing:edited))")
        app.buttons["editor.privacy"].tap()
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        app.buttons["撤销"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        wait { app.buttons["tool.exposure"].value as? String == originalValue }
        XCTAssertTrue(self.showsHDRHistogram(app),"Undo changed the HDR source default mode")
        app.buttons["editor.privacy"].tap(); app.buttons["重做"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        wait { app.buttons["tool.exposure"].value as? String == edited }
        app.buttons["editor.compare"].tap()
        capture("hdr-edited-comparison",app)
        app.buttons["editor.compare"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { app.frame.width>app.frame.height && app.buttons["editor.histogram"].isHittable }
        app.buttons["editor.histogram"].tap()
        capture("hdr-landscape",app)
        app.buttons["editor.histogram"].tap()
        XCUIDevice.shared.orientation = .portrait
        wait { app.frame.height>app.frame.width && app.buttons["editor.export"].isHittable }
        for action in ["保存当前照片","保存 SDR JPEG"] {
            saveCurrentToPhotos(app, screenshot: action == "保存当前照片" ? "hdr-saved-to-photos" : "sdr-saved-to-photos",
                                menuItem: action, timeout: 90)
        }
        app.buttons["editor.privacy"].tap(); app.buttons["照片处理设置"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.switches["hdr.editMode"].isEnabled)
        app.switches["hdr.editMode"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        wait { app.switches["hdr.editMode"].value as? String=="0" }
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["editor.group.looks"].isEnabled,"SDR mode did not restore existing tools")
        app.buttons["editor.privacy"].tap(); app.buttons["撤销"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        wait { self.showsHDRHistogram(app) }
    }
    func testHDRToneControlsPreserveBothModes() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        func select(_ name: String) -> XCUIElement {
            let tool = app.buttons["tool." + name]
            if !app.buttons["tool.exposure"].exists { app.buttons["editor.group.light"].tap() }
            XCTAssertTrue(tool.waitForExistence(timeout: 10) && tool.isEnabled, app.debugDescription)
            if !tool.isSelected {
                if name == "toneCurve" { app.scrollViews["editor.tools"].swipeLeft() }
                tool.tap()
            }
            return tool
        }

        app.launch()
        openRecentHDROriginal(app)
        for name in ["blackPoint", "whitePoint"] {
            let tool = select(name)
            let before = tool.value as? String
            let ruler = app.descendants(matching: .any)["adjustment.ruler"]
            XCTAssertTrue(ruler.waitForExistence(timeout: 10))
            ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
            wait { tool.value as? String != before }
        }
        _ = select("toneCurve")
        app.buttons["curve.switch"].tap()
        app.alerts.firstMatch.buttons["切换"].tap()
        let canvas = app.descendants(matching: .any)["curve.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["curve.point.2"].waitForExistence(timeout: 10))
        let output = app.descendants(matching: .any)["curve.y.value"].firstMatch
        let before = try XCTUnwrap(output.value as? String)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
        wait { output.value as? String != before }
        let edited = try XCTUnwrap(output.value as? String)
        XCTAssertTrue(edited.contains("EV"))
        XCTAssertTrue(app.descendants(matching: .any)["curve.hdr.ev-axis"].firstMatch.exists)
        capture("hdr-tone-edited", app)
        deviceMenu(app, item: "撤销")
        _ = select("toneCurve")
        app.buttons["curve.point.1"].tap()
        wait { output.exists && output.value as? String == before }
        deviceMenu(app, item: "重做")
        _ = select("toneCurve")
        app.buttons["curve.point.1"].tap()
        wait { output.exists && output.value as? String == edited }

        deviceEditingMode(app, hdr: false)
        _ = select("toneCurve")
        XCTAssertFalse(canvas.exists, "SDR has its own neutral S curve")
        deviceEditingMode(app, hdr: true)
        _ = select("toneCurve")
        XCTAssertTrue(app.buttons["curve.point.2"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        openRecentHDROriginal(app)
        _ = select("toneCurve")
        XCTAssertTrue(app.buttons["curve.point.2"].waitForExistence(timeout: 10), "Reopening lost the HDR control points")
        app.buttons["curve.point.1"].tap()
        wait { output.exists && output.value as? String == edited }
        capture("hdr-tone-reopened", app)
    }

    func testHDRColorControlsAndTargetDrag() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        func select(_ name: String) -> XCUIElement {
            let tool = app.buttons["tool." + name]
            if !app.buttons["tool.saturation"].exists { app.buttons["editor.group.color"].tap() }
            XCTAssertTrue(tool.waitForExistence(timeout: 10) && tool.isEnabled, app.debugDescription)
            if !tool.isSelected {
                if !tool.isHittable { app.scrollViews["editor.tools"].swipeLeft() }
                if !tool.isHittable { app.scrollViews["editor.tools"].swipeRight() }
                tool.tap()
            }
            return tool
        }
        app.launch()
        openRecentHDROriginal(app)
        let vibrance = select("vibrance")
        let neutralVibrance = vibrance.value as? String
        let ruler = app.descendants(matching: .any)["adjustment.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        wait { vibrance.value as? String != neutralVibrance && !app.staticTexts["editor.preview.updating"].exists }
        let editedVibrance = vibrance.value as? String

        _ = select("hsl")
        app.buttons["hsl.target"].tap()
        let photo = app.images["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55)).press(forDuration: 0.12,
            thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.32)))
        let status = app.staticTexts["hsl.target.status"]
        wait { status.label.contains("蓝") }
        let blue = app.buttons["hsl.channel.5"]
        let hue = app.buttons["hsl.hue.value"]
        capture("hdr-color-target-drag", app)
        blue.tap()
        wait { hue.value as? String != "0" }
        let editedHSL = try XCTUnwrap(hue.value as? String)
        deviceMenu(app, item: "撤销")
        _ = select("hsl")
        blue.tap()
        wait { hue.value as? String == "0" }
        deviceMenu(app, item: "重做")
        _ = select("hsl")
        blue.tap()
        wait { hue.value as? String == editedHSL }

        _ = select("colorGrading")
        let highlights = app.buttons["grading.zone.highlights"]
        highlights.tap()
        let wheel = app.descendants(matching: .any)["grading.wheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 10))
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
        wait { highlights.value as? String == "已调整" }
        capture("hdr-color-grading", app)

        deviceEditingMode(app, hdr: false)
        _ = select("vibrance")
        wait { vibrance.value as? String == neutralVibrance }
        _ = select("hsl")
        blue.tap()
        wait { hue.value as? String == "0" }
        deviceEditingMode(app, hdr: true)
        app.terminate(); app.launch()
        openRecentHDROriginal(app)
        _ = select("vibrance")
        wait { vibrance.value as? String == editedVibrance }
        _ = select("hsl")
        blue.tap()
        wait { hue.value as? String == editedHSL }
        _ = select("colorGrading")
        XCTAssertEqual(highlights.value as? String, "已调整")
    }

    func testHDRRenditionControlsKeepTheSDREditIndependent() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        let section = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "hdr.rendition", "HDR 输出与 SDR 底图")).firstMatch
        let peak = app.sliders["hdr.rendition.peakLimit"]
        let exposure = app.sliders["hdr.rendition.sdrExposure"]
        let close = app.buttons["关闭"]
        func openRendition(compatibilityPreview: Bool = false) {
            deviceMenu(app, item: "照片处理设置")
            if compatibilityPreview { app.buttons["SDR 兼容预览"].tap() }
            if !peak.exists {
                XCTAssertTrue(section.waitForExistence(timeout: 10), app.debugDescription)
                section.tap()
            }
            XCTAssertTrue(peak.waitForExistence(timeout: 10) && exposure.exists, app.debugDescription)
        }
        app.launch()
        openRecentHDROriginal(app)
        openRendition(compatibilityPreview: true)
        XCTAssertEqual(peak.value as? String, "不限")
        let baseExposure = exposure.value as? String
        let form = app.collectionViews.containing(.slider, identifier: "hdr.rendition.sdrExposure").firstMatch
        for _ in 0..<3 where !exposure.isHittable { form.swipeUp() }
        XCTAssertTrue(peak.isHittable && exposure.isHittable, app.debugDescription)
        peak.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: peak.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { peak.value as? String != "不限" }
        let editedPeak = try XCTUnwrap(peak.value as? String)
        exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        wait { exposure.value as? String != baseExposure }
        let editedExposure = try XCTUnwrap(exposure.value as? String)
        capture("hdr-rendition-controls", app)
        close.tap()
        wait { !app.staticTexts["editor.preview.updating"].exists }
        capture("hdr-rendition-sdr-base", app)

        deviceMenu(app, item: "撤销")
        openRendition()
        XCTAssertEqual(peak.value as? String, editedPeak)
        XCTAssertEqual(exposure.value as? String, baseExposure)
        close.tap()
        deviceMenu(app, item: "重做")
        openRendition()
        XCTAssertEqual(exposure.value as? String, editedExposure)
        close.tap()

        let ordinaryExposure = app.buttons["tool.exposure"].value as? String
        deviceEditingMode(app, hdr: false)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, ordinaryExposure)
        deviceMenu(app, item: "照片处理设置")
        XCTAssertFalse(section.exists)
        close.tap()
        deviceEditingMode(app, hdr: true)
        app.terminate()
        app.launch()
        openRecentHDROriginal(app)
        openRendition()
        XCTAssertEqual(peak.value as? String, editedPeak)
        XCTAssertEqual(exposure.value as? String, editedExposure)
    }

    func testHDREffectsPersistWithoutChangingOrdinarySDR() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        func select(_ name: String) -> XCUIElement {
            let tool = app.buttons["tool."+name]
            if !tool.exists { app.buttons["editor.group.effects"].tap() }
            XCTAssertTrue(tool.waitForExistence(timeout: 10) && tool.isEnabled, app.debugDescription)
            if !tool.isSelected {
                if !tool.isHittable { app.scrollViews["editor.tools"].swipeLeft() }
                tool.tap()
            }
            return tool
        }
        func drag(_ control: String, to offset: CGFloat) {
            let ruler = app.descendants(matching: .any)["effects."+control+".ruler"].firstMatch
            XCTAssertTrue(ruler.waitForExistence(timeout: 10) && ruler.isHittable, app.debugDescription)
            ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)))
        }
        app.launch()
        openRecentHDROriginal(app)
        _ = select("vignette")
        let vignette = app.buttons["effects.vignette.vignetteAmount.value"]
        let grain = app.buttons["effects.grain.grainAmount.value"]
        let originalVignette = vignette.value as? String
        drag("vignette.vignetteAmount", to: 0.85)
        wait { vignette.value as? String != originalVignette }
        let editedVignette = try XCTUnwrap(vignette.value as? String)
        _ = select("grain")
        let originalGrain = grain.value as? String
        drag("grain.grainAmount", to: 0.15)
        wait { grain.value as? String != originalGrain && !app.staticTexts["editor.preview.updating"].exists }
        let editedGrain = try XCTUnwrap(grain.value as? String)
        capture("hdr-vignette-and-grain", app)
        deviceMenu(app, item: "撤销")
        _ = select("grain")
        XCTAssertEqual(grain.value as? String, originalGrain)
        deviceMenu(app, item: "重做")
        _ = select("grain")
        XCTAssertEqual(grain.value as? String, editedGrain)
        deviceEditingMode(app, hdr: false)
        _ = select("vignette")
        XCTAssertEqual(vignette.value as? String, originalVignette)
        _ = select("grain")
        XCTAssertEqual(grain.value as? String, originalGrain)
        deviceEditingMode(app, hdr: true)
        app.terminate()
        app.launch()
        openRecentHDROriginal(app)
        _ = select("vignette")
        XCTAssertEqual(vignette.value as? String, editedVignette)
        _ = select("grain")
        XCTAssertEqual(grain.value as? String, editedGrain)
    }

    func testHDRDetailPersistsWithoutChangingOrdinarySDR() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        func select(_ name: String, in group: String) {
            let tool = app.buttons["tool." + name]
            if !tool.exists { app.buttons["editor.group." + group].tap() }
            XCTAssertTrue(tool.waitForExistence(timeout: 10) && tool.isEnabled, app.debugDescription)
            if !tool.isSelected { tool.tap() }
        }
        let value = app.buttons["adjustment.value"]
        let ruler = app.descendants(matching: .any)["adjustment.ruler"].firstMatch
        var edits: [String: String] = [:]
        let controls = [("clarity", "effects", 0.15), ("dehaze", "effects", 0.85),
                        ("sharpening", "detail", 0.15), ("noiseReduction", "detail", 0.15)]
        app.launch()
        openRecentHDROriginal(app)
        for (tool, group, offset) in controls {
            select(tool, in: group)
            XCTAssertTrue(ruler.waitForExistence(timeout: 10))
            let before = value.value as? String
            ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)))
            wait { value.value as? String != before && !app.staticTexts["editor.preview.updating"].exists }
            edits[tool] = try XCTUnwrap(value.value as? String)
        }
        capture("hdr-detail-denoise", app)
        deviceMenu(app, item: "撤销")
        select("noiseReduction", in: "detail")
        XCTAssertNotEqual(value.value as? String, edits["noiseReduction"])
        deviceMenu(app, item: "重做")
        select("noiseReduction", in: "detail")
        XCTAssertEqual(value.value as? String, edits["noiseReduction"])
        deviceEditingMode(app, hdr: false)
        select("sharpening", in: "detail")
        XCTAssertNotEqual(value.value as? String, edits["sharpening"])
        deviceEditingMode(app, hdr: true)
        app.terminate()
        app.launch()
        openRecentHDROriginal(app)
        for (tool, group, _) in controls {
            select(tool, in: group)
            XCTAssertEqual(value.value as? String, edits[tool])
        }
    }

    func testHDRLookImportAndReopen() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        let importLook = app.buttons["hdr.look.import"]
        let name = app.staticTexts["hdr.look.name"]
        let strength = app.sliders["hdr.look.strength"]
        func openLookPanel() {
            if !importLook.exists { app.buttons["editor.group.looks"].tap() }
            XCTAssertTrue(importLook.waitForExistence(timeout: 10) && importLook.isEnabled, app.debugDescription)
        }
        app.launch()
        openRecentHDROriginal(app)
        openLookPanel()
        app.buttons["hdr.look.silver-master"].tap()
        wait { name.label == "HDR Silver" && strength.value as? String == "100%" &&
            !app.staticTexts["editor.preview.updating"].exists }
        deviceMenu(app, item: "撤销")
        openLookPanel()
        wait { !strength.exists }
        importLook.tap()
        chooseLocalFixture(app, stem: "HDRLookFixture")
        wait { name.exists && name.label == "HDRLookFixture" && !app.staticTexts["editor.preview.updating"].exists }
        XCTAssertTrue(strength.waitForExistence(timeout: 10), app.debugDescription)
        strength.adjust(toNormalizedSliderPosition: 0.35)
        wait { strength.value as? String != "100%" && !app.staticTexts["editor.preview.updating"].exists }
        let value = try XCTUnwrap(strength.value as? String)
        capture("hdr-look-imported", app)
        deviceEditingMode(app, hdr: false)
        XCTAssertFalse(importLook.exists)
        deviceEditingMode(app, hdr: true)
        app.terminate()
        app.launch()
        openRecentHDROriginal(app)
        openLookPanel()
        XCTAssertEqual(name.label, "HDRLookFixture")
        XCTAssertEqual(strength.value as? String, value)
        app.buttons["hdr.look.clear"].tap()
        wait { !strength.exists }
        deviceMenu(app, item: "撤销")
        openLookPanel()
        XCTAssertEqual(name.label, "HDRLookFixture")
    }

    private func openRecentHDROriginal(_ app: XCUIApplication) {
        let importer = app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
        XCTAssertTrue(importer.waitForExistence(timeout: 15))
        importer.tap()
        let photo = photoGrid(app).firstMatch
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        wait {
            self.dismissPhotoPermissionAlert()
            return app.buttons["editor.compare"].isEnabled && self.showsHDRHistogram(app)
        }
    }

    private func photoGrid(_ app: XCUIApplication) -> XCUIElementQuery {
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        wait {
            self.dismissPhotoPermissionAlert()
            return photos.firstMatch.exists
        }
        return photos
    }

    private func dismissPhotoPermissionAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists, alert.label.localizedCaseInsensitiveContains("photos") || alert.label.contains("照片") else { return }
        let allow = alert.buttons.matching(NSPredicate(format: "label IN %@",
            ["允许完全访问", "允许访问所有照片", "Allow Full Access", "Allow Access to All Photos",
             "允许添加照片", "允许添加", "允许", "Allow Add Photos", "Allow"])).firstMatch
        if allow.exists { allow.tap() }
    }

    private func assertHDRWhiteBalanceScope(_ app: XCUIApplication) {
        // Form 只为可见区域创建行；HDR 白平衡在颜色分级之后，展开组不代表开关已经生成。
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.exists, app.debugDescription)
        for field in ["hdr.relative_temperature", "hdr.relative_tint"] {
            let toggle = app.switches["adjustment.field." + field]
            for _ in 0..<12 where !toggle.isHittable { form.swipeUp() }
            XCTAssertTrue(toggle.exists && toggle.isHittable, app.debugDescription)
            XCTAssertEqual(toggle.value as? String, "1", "HDR common scope must include \(field)")
        }
    }

    private func showsHDRHistogram(_ app: XCUIApplication) -> Bool {
        let histogram = app.buttons["editor.histogram"]
        return histogram.exists && histogram.label == "HDR 亮度直方图"
    }

    func testSDRHDRSourceLUTCompatibility() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else { throw XCTSkip("Dedicated HDR simulator only") }
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication(); app.launchArguments=["-RawLab.language","zh-Hans"]; app.launch()
        var foundHDR=false
        for index in 0..<3 {
            let importer=app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
            XCTAssertTrue(importer.waitForExistence(timeout:15)); importer.tap()
            let photos = photoGrid(app)
            XCTAssertGreaterThan(photos.count,index)
            photos.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            wait {
                let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
                let allow=springboard.buttons.matching(NSPredicate(format:"label IN %@",["允许完全访问","允许访问所有照片","Allow Full Access"])).firstMatch
                if allow.exists { allow.tap() }
                return app.buttons["editor.compare"].isEnabled
            }
            let close=app.buttons["关闭"]
            for _ in 0..<2 where !close.exists {
                if !app.buttons["照片处理设置"].exists { app.buttons["editor.privacy"].tap() }
                let processing=app.buttons["照片处理设置"]
                XCTAssertTrue(processing.waitForExistence(timeout:5),app.debugDescription)
                processing.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
                _ = close.waitForExistence(timeout:5)
            }
            XCTAssertTrue(close.exists,app.debugDescription)
            let mode=app.switches["hdr.editMode"]
            if mode.waitForExistence(timeout:3) {
                if mode.value as? String=="1" { mode.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap() }
                wait { mode.value as? String=="0" }
                app.buttons["关闭"].tap(); foundHDR=true; break
            }
            app.buttons["关闭"].tap()
        }
        XCTAssertTrue(foundHDR,"No HDR original among the task-only library's recent photos")
        wait { !self.showsHDRHistogram(app) }
        app.buttons["editor.privacy"].tap()
        let importLook=app.buttons["editor.import.look"]
        wait { importLook.isEnabled }; importLook.tap()
        let file=app.cells.matching(NSPredicate(format:"identifier BEGINSWITH %@ OR label CONTAINS %@",
            "HDRCompatibilityUnknown,","HDRCompatibilityUnknown")).firstMatch
        let folder=app.cells.matching(NSPredicate(format:"identifier == %@ OR label BEGINSWITH %@","RawLab","RawLab")).firstMatch
        // Files 会记住上次目录，先回到位置列表，再按固定路径进入测试文件。
        let browse=app.tabBars.buttons.matching(NSPredicate(format:"label IN %@",["Browse","浏览"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout:10),app.debugDescription); browse.tap()
        let local=app.cells.matching(NSPredicate(format:"label CONTAINS[c] %@ OR label CONTAINS[c] %@","iPhone","iPad")).firstMatch
        if !local.waitForExistence(timeout:3) { browse.tap() }
        XCTAssertTrue(local.waitForExistence(timeout:10),app.debugDescription); local.tap()
        XCTAssertTrue(folder.waitForExistence(timeout:10),app.debugDescription); folder.tap()
        XCTAssertTrue(file.waitForExistence(timeout:15),app.debugDescription); file.tap()
        let open=app.buttons.matching(NSPredicate(format:"label IN %@",["Open","打开"])).firstMatch
        if open.waitForExistence(timeout:3) { open.tap() }
        let confirm=app.buttons["look.compatibility.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(confirm.isEnabled,"Untagged LUT must require an explicit candidate selection")
        let first=app.buttons["look.compatibility.candidate-1"], second=app.buttons["look.compatibility.candidate-2"]
        wait { first.isEnabled && second.isEnabled }
        first.tap(); wait { first.isSelected && confirm.isEnabled }
        capture("hdr-sdr-lut-first-candidate",app)
        second.tap(); wait { second.isSelected && !first.isSelected && confirm.isEnabled }
        XCTAssertTrue(app.staticTexts["未应用 LUT"].exists && app.staticTexts["所选方案"].exists,
                      "Current HDR original did not populate both preview panes")
        for _ in 0..<3 where !app.staticTexts["所选方案"].isHittable { app.swipeUp() }
        capture("hdr-sdr-lut-second-candidate",app)
        confirm.tap()
        wait { !confirm.exists && !self.showsHDRHistogram(app) }
        let film=app.buttons["tool.film"]
        if !film.exists { app.buttons["editor.group.looks"].tap() }
        XCTAssertTrue(film.waitForExistence(timeout:10),app.debugDescription)
        if !film.isSelected { film.tap() }
        let imported=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","HDRCompatibilityUnknown")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout:15),app.debugDescription)
        wait { imported.isSelected }
        XCTAssertTrue(imported.label.contains("兼容导入"))
        capture("hdr-sdr-lut-imported",app)
        saveCurrentToPhotos(app, screenshot: "hdr-sdr-lut-photos-saved")
        wait { imported.isSelected && !self.showsHDRHistogram(app) }
    }
    func testDeviceJPEGCompatibilityAndPhotos() throws {
        try deviceCompatibilityAndPhotos(name: "Android", fileExtension: "jpg", width: 4080, height: 3072)
    }

    func testDeviceHEICCompatibilityAndPhotos() throws {
        try deviceCompatibilityAndPhotos(name: "iPhone", fileExtension: "HEIC", width: 3024, height: 4032)
    }

    func testDeviceHDRHEIFPreviewAndPhotos() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" else {
            throw XCTSkip("Use the explicit physical-device runner and its private fixture app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical EDR and HEIF verification requires a real device")
        #else
        continueAfterFailure = false
        let tag = try XCTUnwrap(ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_FIXTURE_TAG"])
        authorizeDevicePhotoAudit()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        app.launch()
        deviceDismissNetworkPrompt()
        if app.buttons["editor.import.empty"].exists {
            app.buttons["editor.import.file"].tap()
        } else {
            deviceMenu(app, item: "editor.import.file")
        }
        chooseDeviceFile(app, name: "RawLabHDRDevice-Android-\(tag).jpg")
        wait { app.buttons["editor.compare"].isEnabled && self.showsHDRHistogram(app) }

        deviceMenu(app, item: "照片处理设置")
        let mode = app.switches["hdr.editMode"]
        let capacity = app.staticTexts["hdr.displayStatus"]
        let compatible = app.staticTexts["当前显示 SDR 兼容预览。"]
        app.buttons["自动 HDR"].tap()
        wait {
            guard capacity.exists,
                  let value = capacity.label.split(separator: " ").dropLast().last.flatMap({ Double($0) }) else { return false }
            return value > 0 && !compatible.exists
        }
        print("DEVICE_EDR \(capacity.label)")
        capture("device-heif-edr-preview", app)
        app.buttons["SDR 兼容预览"].tap()
        wait { compatible.exists && mode.value as? String == "1" }
        capture("device-heif-sdr-preview", app)
        app.buttons["关闭"].tap()

        try deviceSaveAndAudit(app, name: "Android-heif", width: 4080, height: 3072,
                               menuItem: "HDR HEIF", heif: true)
        #endif
    }

    private func deviceCompatibilityAndPhotos(name: String, fileExtension: String, width: Int, height: Int) throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" else {
            throw XCTSkip("Use the explicit physical-device runner and its private fixture app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical Photos verification requires a real device")
        #else
        continueAfterFailure = false
        let tag = try XCTUnwrap(ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_FIXTURE_TAG"])
        authorizeDevicePhotoAudit()
        XCUIDevice.shared.orientation = .portrait
        let networkPrompt = addUIInterruptionMonitor(withDescription: "Offline fixture app network prompt") { alert in
            guard alert.label.contains("RawLab HDR UI"), alert.label.contains("无线数据"), alert.buttons["不允许"].exists else { return false }
            alert.buttons["不允许"].tap()
            return true
        }
        defer { removeUIInterruptionMonitor(networkPrompt) }
        let app = XCUIApplication()
        app.launchArguments = ["-RawLab.language", "zh-Hans"]
        app.launch()
        deviceDismissNetworkPrompt()
        if app.buttons["editor.import.empty"].exists {
            app.buttons["editor.import.file"].tap()
        } else {
            deviceMenu(app, item: "editor.import.file")
        }
        chooseDeviceFile(app, name: "RawLabHDRDevice-\(name)-\(tag).\(fileExtension)")
        wait { app.buttons["editor.compare"].isEnabled }
        deviceEditingMode(app, hdr: false)
        wait { !self.showsHDRHistogram(app) }
        deviceMenu(app, item: "editor.import.look")
        let look = "DeviceHDRCompatibility-\(name)-\(tag)"
        chooseDeviceFile(app, name: look + ".cube")
        let confirm = app.buttons["look.compatibility.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(confirm.isEnabled)
        let first = app.buttons["look.compatibility.candidate-1"]
        let second = app.buttons["look.compatibility.candidate-2"]
        wait { first.isEnabled && second.isEnabled }
        first.tap(); wait { first.isSelected && confirm.isEnabled }
        capture("device-\(name)-lut-first", app)
        second.tap(); wait { second.isSelected && !first.isSelected && confirm.isEnabled }
        XCTAssertTrue(app.staticTexts["未应用 LUT"].exists && app.staticTexts["所选方案"].exists)
        for _ in 0..<3 where !app.staticTexts["所选方案"].isHittable { app.swipeUp() }
        capture("device-\(name)-lut-comparison", app)
        confirm.tap()
        wait { !confirm.exists && !self.showsHDRHistogram(app) }
        let film = app.buttons["tool.film"]
        if !film.exists { app.buttons["editor.group.looks"].tap() }
        XCTAssertTrue(film.waitForExistence(timeout: 10), app.debugDescription)
        if !film.isSelected { film.tap() }
        let selected = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", look)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        wait { selected.isSelected }
        XCTAssertTrue(selected.label.contains("兼容导入"))
        capture("device-\(name)-sdr-look-selected", app)
        try deviceSaveAndAudit(app, name: name + "-sdr", width: width, height: height)
        app.buttons["editor.reset"].tap()
        let resetLook = app.buttons["重置胶片"]
        XCTAssertTrue(resetLook.waitForExistence(timeout: 10), app.debugDescription)
        resetLook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        wait { app.buttons["tool.film"].value as? String == "中性" }
        deviceEditingMode(app, hdr: true)
        wait { self.showsHDRHistogram(app) }
        try deviceSaveAndAudit(app, name: name + "-hdr", width: width, height: height)
        #endif
    }

    private func deviceMenu(_ app: XCUIApplication, item: String) {
        deviceDismissNetworkPrompt()
        app.buttons["editor.privacy"].tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        let menu = app.collectionViews.containing(.button, identifier: item).firstMatch
        for _ in 0..<3 where !button.isHittable {
            // 系统菜单有两页；手势留在已显示的菜单区域，不能从其屏幕外 frame 底部起滑。
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 0.1,
                thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        wait { button.isEnabled && button.isHittable }
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func chooseCameraRawFixture(_ app: XCUIApplication, stem: String) {
        #if targetEnvironment(simulator)
        chooseLocalFixture(app, stem: stem)
        #else
        chooseDeviceFile(app, name: stem + ".dng")
        #endif
    }

    private func chooseLocalFixture(_ app: XCUIApplication, stem: String) {
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", stem)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
            browse.tap()
            let local = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "iPhone")).firstMatch
            if !local.waitForExistence(timeout: 3) { browse.tap() }
            XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
            local.tap()
            let folder = app.cells.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "RawLab", "RawLab")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func chooseDeviceFile(_ app: XCUIApplication, name: String) {
        selectingDeviceFixture = true
        defer { selectingDeviceFixture = false }
        deviceDismissNetworkPrompt()
        let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "The Files picker did not show Browse")
        browse.tap()
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "iPhone")).firstMatch
        if !local.waitForExistence(timeout: 3) { browse.tap() }
        XCTAssertTrue(local.waitForExistence(timeout: 15), "The Files picker did not show local storage")
        local.tap()
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        // 真机位置列表可能有大量用户文件，按唯一测试文件名搜索，不遍历既有内容。
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The Files picker did not show Search")
        search.tap()
        if deviceDismissNetworkPrompt() { search.tap() }
        if let text = search.value as? String, text != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        search.typeText(stem)
        wait { (search.value as? String)?.contains(stem) == true }
        let files = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", stem + ",", stem))
        XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 30), "Missing test fixture \(name) in Files")
        XCTAssertEqual(files.count, 1, "The test fixture name must identify one file")
        files.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(browse.waitForNonExistence(timeout: 15), "The Files picker did not close after opening \(name)")
    }

    @discardableResult
    private func deviceDismissNetworkPrompt() -> Bool {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.exists, alert.label.contains("RawLab HDR UI"), alert.label.contains("无线数据") else { return false }
        alert.buttons["不允许"].tap()
        wait { !alert.exists }
        return true
    }

    func deviceEditingMode(_ app: XCUIApplication, hdr: Bool) {
        deviceMenu(app, item: "照片处理设置")
        let mode = app.switches["hdr.editMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15), "Files import did not preserve the HDR original: \(app.debugDescription)")
        let expected = hdr ? "1" : "0"
        if mode.value as? String != expected {
            mode.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        wait { mode.value as? String == expected }
        app.buttons["关闭"].tap()
    }

    func authorizeDevicePhotoAudit() {
        let authorization = expectation(description: "Read only newly created Photos resources")
        var status = PHAuthorizationStatus.notDetermined
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { value in
            status = value; authorization.fulfill()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@",
            ["允许完全访问", "允许访问所有照片", "Allow Full Access"])).firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        wait(for: [authorization], timeout: 30)
        XCTAssertEqual(status, .authorized, "Fixture preparation and export audit need access to the exact test assets")
    }

    func devicePhotoIDs() -> Set<String> {
        // 只比较标识符，不读取用户既有照片的内容，也不记录它们的标识符。
        var result = Set<String>()
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
        return result
    }

    @discardableResult
    func deviceSaveAndAudit(_ app: XCUIApplication, name: String, width: Int, height: Int,
                           menuItem: String = "保存当前照片", longEdge: Int? = nil, heif: Bool = false) throws -> Data {
        let before = devicePhotoIDs()
        saveCurrentToPhotos(app, screenshot: "device-\(name)-photos-saved", menuItem: menuItem, longEdge: longEdge)
        let created = devicePhotoIDs().subtracting(before)
        XCTAssertEqual(created.count, 1, "Cannot uniquely identify this UI export")
        let identifier = try XCTUnwrap(created.count == 1 ? created.first : nil)
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
        return try deviceAuditPhoto(asset, name: name, width: width, height: height, heif: heif)
    }

    func deviceAuditPhoto(_ asset: PHAsset, name: String, width: Int, height: Int, heif: Bool = false) throws -> Data {
        XCTAssertEqual(asset.pixelWidth, width); XCTAssertEqual(asset.pixelHeight, height)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
        let downloaded = expectation(description: "Read back the exact UI-created Photos original")
        let suffix = heif ? "heic" : "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
        defer { try? FileManager.default.removeItem(at: url) }
        var failure: Error?
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in failure = error; downloaded.fulfill() }
        wait(for: [downloaded], timeout: 30)
        XCTAssertNil(failure)
        let data = try Data(contentsOf: url)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        if heif {
            XCTAssertEqual(resource.uniformTypeIdentifier, UTType.heic.identifier)
            XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.heic.identifier)
            if #available(iOS 18.0, *) {
                XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap))
            }
        } else {
            XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8]); XCTAssertEqual(Array(data.suffix(2)), [0xff, 0xd9])
        }
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
        attachment.name = "device-\(name)-photos-original.\(suffix)"; attachment.lifetime = .keepAlways
        add(attachment)
        print("PHOTOS_UI_EXPORT \(name) \(width)x\(height) \(data.count) bytes resource=\(resource.uniformTypeIdentifier)")
        return data
    }

    private func saveCurrentToPhotos(_ app: XCUIApplication, screenshot: String, menuItem: String = "保存当前照片", longEdge: Int? = nil,
                                     timeout: TimeInterval = 120) {
        app.buttons["editor.export"].tap()
        let save = app.buttons[menuItem]
        wait { save.isEnabled && save.isHittable }
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        if let longEdge {
            let size = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "原始尺寸")).firstMatch
            XCTAssertTrue(size.waitForExistence(timeout: 5), app.debugDescription); size.tap()
            app.buttons["长边 \(longEdge) px"].tap()
        }
        confirm.tap()
        let saved = app.alerts.staticTexts["已保存到照片。"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["允许添加照片", "允许添加", "允许", "Allow Add Photos", "Allow"])).firstMatch
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if allow.exists { allow.tap() }
            return saved.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: timeout), .completed, app.debugDescription)
        capture(screenshot, app)
        app.alerts.buttons["关闭"].tap()
        wait { !saved.exists }
    }

    func wait(_ predicate: @escaping () -> Bool) {
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in predicate() },object:nil)
        let result=XCTWaiter.wait(for:[expectation],timeout:60)
        if result != .completed {
            let details = selectingDeviceFixture ? "test asset picker" : XCUIApplication().debugDescription
            XCTFail("Timed out waiting for HDR UI state: \(details)")
        }
    }
    func capture(_ name: String,_ app: XCUIApplication) {
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); attachment.name=name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
