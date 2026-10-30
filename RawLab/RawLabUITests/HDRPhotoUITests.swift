import XCTest
import Photos
import ImageIO

final class HDRPhotoUITests: XCTestCase {
    override func record(_ issue: XCTIssue) {
        if ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" {
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

    func testFreshHDRPresetAndCollectionScope() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"]=="1" else { throw XCTSkip("Dedicated HDR simulator only") }
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication(); app.launchArguments=["-RawLab.language","zh-Hans"]; app.launch()
        var selected: Int?
        for index in 0..<3 {
            let importer=app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
            XCTAssertTrue(importer.waitForExistence(timeout:15)); importer.tap()
            let grid=app.images.matching(identifier:"PXGGridLayout-Info")
            XCTAssertTrue(grid.firstMatch.waitForExistence(timeout:20))
            grid.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            wait { app.buttons["editor.compare"].isEnabled }
            if !app.buttons["editor.group.looks"].isEnabled { selected=index; break }
        }
        let sourceIndex=try XCTUnwrap(selected)
        app.buttons["editor.privacy"].tap(); app.buttons["我的预设"].tap()
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
        app.buttons["editor.privacy"].tap(); app.buttons["collection.open"].tap()
        XCTAssertTrue(app.buttons["collection.photos"].waitForExistence(timeout:10)); app.buttons["collection.photos"].tap()
        let grid=app.images.matching(identifier:"PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout:20))
        grid.element(boundBy:(sourceIndex+1)%3).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        app.buttons["Add"].tap()
        let synchronize=app.buttons["collection.synchronize"]
        wait { synchronize.isEnabled }; synchronize.tap()
        let count = app.staticTexts["adjustment.copy.summary.count"]
        XCTAssertTrue(count.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(count.label.contains("7 项调整"),count.label)
        XCTAssertFalse(app.buttons["adjustment.group.looks"].exists)
        app.buttons["adjustment.group.color"].tap()
        XCTAssertTrue(app.switches["adjustment.field.hdr.relative_temperature"].exists)
        XCTAssertTrue(app.switches["adjustment.field.hdr.relative_tint"].exists)
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
        var hdrIndex: Int?
        for index in 0..<3 {
            let importer=app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
            XCTAssertTrue(importer.waitForExistence(timeout:15)); importer.tap()
            let grid=app.images.matching(identifier:"PXGGridLayout-Info")
            XCTAssertTrue(grid.firstMatch.waitForExistence(timeout:20))
            grid.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            wait { app.buttons["editor.compare"].isEnabled }
            if !app.buttons["editor.group.looks"].isEnabled { hdrIndex=index; break }
        }
        let index=try XCTUnwrap(hdrIndex,"No HDR source in the task-only library")
        app.buttons["editor.privacy"].tap(); app.buttons["复制调整"].tap()
        let count = app.staticTexts["adjustment.copy.summary.count"]
        XCTAssertTrue(count.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(count.label.contains("7 项调整"),count.label)
        let color=app.buttons["adjustment.group.color"]
        XCTAssertTrue(color.exists,app.debugDescription); color.tap()
        XCTAssertTrue(app.switches["adjustment.field.hdr.relative_temperature"].exists,app.debugDescription)
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
        let grid=app.images.matching(identifier:"PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout:20))
        grid.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
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
        var found=false
        for index in 0..<3 {
            let importer=app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
            XCTAssertTrue(importer.waitForExistence(timeout:15)); importer.tap()
            let grid=app.images.matching(identifier:"PXGGridLayout-Info")
            XCTAssertTrue(grid.firstMatch.waitForExistence(timeout:20))
            grid.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            wait { app.buttons["editor.compare"].isEnabled }
            if !app.buttons["editor.group.looks"].isEnabled { found=true; break }
        }
        XCTAssertTrue(found,"No HDR source in the task-only library")
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
        var foundHDR=false
        for index in 0..<3 {
            let importer=app.buttons["editor.import.empty"].exists ? app.buttons["editor.import.empty"] : app.buttons["editor.import"]
            XCTAssertTrue(importer.waitForExistence(timeout:15),app.debugDescription); importer.tap()
            let photos=app.images.matching(identifier:"PXGGridLayout-Info")
            XCTAssertTrue(photos.firstMatch.waitForExistence(timeout:20),"Seed a public HDR original in the dedicated simulator")
            photos.element(boundBy:index).coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            wait {
                let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
                let allow=springboard.buttons.matching(NSPredicate(format:"label IN %@",["允许完全访问","允许访问所有照片","Allow Full Access"])).firstMatch
                if allow.exists { allow.tap() }
                return app.buttons["editor.compare"].isEnabled
            }
            if !app.buttons["editor.group.looks"].isEnabled { foundHDR=true; break }
        }
        XCTAssertTrue(foundHDR,"No HDR source among the task-only library's recent photos")
        XCTAssertTrue(app.buttons["tool.exposure"].isSelected,"New HDR import opens an available basic control")
        XCTAssertFalse(app.buttons["editor.group.looks"].isEnabled,"HDR-incompatible looks are disabled")
        XCTAssertFalse(app.buttons["exposure.auto"].isEnabled,"HDR mode must keep SDR automatic exposure disabled")
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
        let ruler=app.descendants(matching:.any)["adjustment.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout:10))
        XCTAssertTrue(ruler.isHittable,"The More menu must be dismissed before editing")
        ruler.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.5))
            .press(forDuration:0.1,thenDragTo:ruler.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.5)))
        wait { app.buttons["tool.exposure"].value as? String != originalValue }
        let edited=app.buttons["tool.exposure"].value as? String
        print("HDR exposure original=\(String(describing:originalValue)) edited=\(String(describing:edited))")
        app.buttons["editor.privacy"].tap()
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        app.buttons["撤销"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        wait { app.buttons["tool.exposure"].value as? String == originalValue }
        XCTAssertFalse(app.buttons["editor.group.looks"].isEnabled,"Undo changed the HDR source default mode")
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
            app.buttons["editor.export"].tap()
            let item=app.buttons[action]
            wait { item.isEnabled && item.isHittable }
            item.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            let confirm=app.buttons["editor.export.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout:10))
            confirm.tap()
            XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout:90),app.debugDescription)
            capture(action=="保存当前照片" ? "hdr-saved-to-photos" : "sdr-saved-to-photos",app)
            app.alerts.buttons["关闭"].tap()
        }
        app.buttons["editor.privacy"].tap(); app.buttons["照片处理设置"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.switches["hdr.editMode"].isEnabled)
        app.switches["hdr.editMode"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        wait { app.switches["hdr.editMode"].value as? String=="0" }
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["editor.group.looks"].isEnabled,"SDR mode did not restore existing tools")
        app.buttons["editor.privacy"].tap(); app.buttons["撤销"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        wait { !app.buttons["editor.group.looks"].isEnabled }
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
            let photos=app.images.matching(identifier:"PXGGridLayout-Info")
            XCTAssertTrue(photos.firstMatch.waitForExistence(timeout:20)); XCTAssertGreaterThan(photos.count,index)
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
        wait { app.buttons["editor.group.looks"].isEnabled }
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
        wait { !confirm.exists && app.buttons["editor.group.looks"].isEnabled }
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
        wait { imported.isSelected && app.buttons["editor.group.looks"].isEnabled }
    }
    func testDeviceJPEGCompatibilityAndPhotos() throws {
        try deviceCompatibilityAndPhotos(name: "Android", source: "RawLabHDRDevice-Android.jpg", width: 4080, height: 3072)
    }

    func testDeviceHEICCompatibilityAndPhotos() throws {
        try deviceCompatibilityAndPhotos(name: "iPhone", source: "RawLabHDRDevice-iPhone.HEIC", width: 3024, height: 4032)
    }

    private func deviceCompatibilityAndPhotos(name: String, source: String, width: Int, height: Int) throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_UI"] == "1" else {
            throw XCTSkip("Use the explicit physical-device runner and its private fixture app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical Photos verification requires a real device")
        #else
        continueAfterFailure = false
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
        chooseDeviceFile(app, name: source)
        wait { app.buttons["editor.compare"].isEnabled }
        deviceEditingMode(app, hdr: false)
        wait { app.buttons["editor.group.looks"].isEnabled }
        deviceMenu(app, item: "editor.import.look")
        let tag = try XCTUnwrap(ProcessInfo.processInfo.environment["RAWLAB_HDR_DEVICE_FIXTURE_TAG"])
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
        wait { !confirm.exists && app.buttons["editor.group.looks"].isEnabled }
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
        wait { !app.buttons["editor.group.looks"].isEnabled }
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

    private func chooseDeviceFile(_ app: XCUIApplication, name: String) {
        deviceDismissNetworkPrompt()
        let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), app.debugDescription); browse.tap()
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "iPhone")).firstMatch
        if !local.waitForExistence(timeout: 3) { browse.tap() }
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription); local.tap()
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        // 真机位置列表可能有大量用户文件，按唯一测试文件名搜索，不遍历既有内容。
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription); search.tap()
        if let text = search.value as? String, text != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        deviceDismissNetworkPrompt()
        search.typeText(stem)
        wait { (search.value as? String)?.contains(stem) == true }
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", stem + ",", stem)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), app.debugDescription); file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func deviceDismissNetworkPrompt() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.exists && alert.label.contains("RawLab HDR UI") && alert.label.contains("无线数据") {
            alert.buttons["不允许"].tap()
            wait { !alert.exists }
        }
    }

    private func deviceEditingMode(_ app: XCUIApplication, hdr: Bool) {
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

    private func authorizeDevicePhotoAudit() {
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
        XCTAssertEqual(status, .authorized, "Physical audit needs access to the exact assets created by the tested app")
    }

    private func devicePhotoIDs() -> Set<String> {
        // 只比较标识符，不读取用户既有照片的内容，也不记录它们的标识符。
        var result = Set<String>()
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
        return result
    }

    private func deviceSaveAndAudit(_ app: XCUIApplication, name: String, width: Int, height: Int) throws {
        let before = devicePhotoIDs()
        saveCurrentToPhotos(app, screenshot: "device-\(name)-photos-saved")
        let created = devicePhotoIDs().subtracting(before)
        XCTAssertEqual(created.count, 1, "Cannot uniquely identify this UI export; no unrelated photo will be read")
        guard created.count == 1, let asset = PHAsset.fetchAssets(withLocalIdentifiers: Array(created), options: nil).firstObject else { return }
        XCTAssertEqual(asset.pixelWidth, width); XCTAssertEqual(asset.pixelHeight, height)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
        let downloaded = expectation(description: "Read back the exact UI-created Photos original")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        var failure: Error?
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in failure = error; downloaded.fulfill() }
        wait(for: [downloaded], timeout: 30)
        XCTAssertNil(failure)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8]); XCTAssertEqual(Array(data.suffix(2)), [0xff, 0xd9])
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
        attachment.name = "device-\(name)-photos-original.jpg"; attachment.lifetime = .keepAlways
        add(attachment)
        print("PHOTOS_UI_EXPORT \(name) \(width)x\(height) \(data.count) bytes resource=\(resource.uniformTypeIdentifier)")
    }

    private func saveCurrentToPhotos(_ app: XCUIApplication, screenshot: String) {
        app.buttons["editor.export"].tap()
        let save = app.buttons["保存当前照片"]
        wait { save.isEnabled && save.isHittable }
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirm = app.buttons["editor.export.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription); confirm.tap()
        let saved = app.alerts.staticTexts["已保存到照片。"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["允许添加照片", "允许添加", "允许", "Allow Add Photos", "Allow"])).firstMatch
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if allow.exists { allow.tap() }
            return saved.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 120), .completed, app.debugDescription)
        capture(screenshot, app)
        app.alerts.buttons["关闭"].tap()
        wait { !saved.exists }
    }

    private func wait(_ predicate: @escaping () -> Bool) {
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in predicate() },object:nil)
        let result=XCTWaiter.wait(for:[expectation],timeout:60)
        if result != .completed { XCTFail("Timed out waiting for HDR UI state: \(XCUIApplication().debugDescription)") }
    }
    private func capture(_ name: String,_ app: XCUIApplication) {
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); attachment.name=name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
