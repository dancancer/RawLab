import XCTest

final class HDRPhotoUITests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["已选 7 项"].waitForExistence(timeout:10),app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["已选 7 项"].waitForExistence(timeout:10),app.debugDescription)
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
        let originalValue=app.buttons["tool.exposure"].value as? String
        app.buttons["editor.privacy"].tap()
        let undoBefore=app.buttons["撤销"].isEnabled
        app.buttons["照片处理设置"].tap()
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
        app.buttons["撤销"].tap()
        wait { app.buttons["tool.exposure"].value as? String == originalValue }
        XCTAssertFalse(app.buttons["editor.group.looks"].isEnabled,"Undo changed the HDR source default mode")
        app.buttons["editor.privacy"].tap(); app.buttons["重做"].tap()
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
            app.buttons["editor.export"].tap(); app.buttons[action].tap()
            let confirm=app.buttons["editor.export.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout:10))
            confirm.tap()
            XCTAssertTrue(app.alerts.staticTexts["已保存到照片。"].waitForExistence(timeout:90),app.debugDescription)
            capture(action=="保存当前照片" ? "hdr-saved-to-photos" : "sdr-saved-to-photos",app)
            app.alerts.buttons["关闭"].tap()
        }
        app.buttons["editor.privacy"].tap(); app.buttons["照片处理设置"].tap()
        XCTAssertTrue(app.switches["hdr.editMode"].isEnabled)
        app.switches["hdr.editMode"].coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        wait { app.switches["hdr.editMode"].value as? String=="0" }
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["editor.group.looks"].isEnabled,"SDR mode did not restore existing tools")
        app.buttons["editor.privacy"].tap(); app.buttons["撤销"].tap()
        wait { !app.buttons["editor.group.looks"].isEnabled }
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
