import XCTest

extension EditorUITests {
    func testPhotoLibraryEntriesKeepLibraryIdentity() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        // 编辑器 V4 没有单项重置按钮；专用模拟器可能保留旧调整，只要求本次拖动产生新值。
        let before = app.buttons["tool.exposure"].value as? String
        dragRuler(app.descendants(matching: .any)["adjustment.ruler"])
        let saved = app.buttons["tool.exposure"].value as? String
        XCTAssertNotNil(saved)
        XCTAssertNotEqual(saved, before)
        // 编辑区只显示保存失败；工具栏导入前会同步保存，下面的恢复断言验证持久化结果。
        XCTAssertFalse(app.buttons["调整未保存 · 重试"].exists, app.debugDescription)
        importPhoto(in: app)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, saved,
                       "The toolbar picker must restore edits saved through the empty-state picker")

        app.buttons["editor.privacy"].tap()
        app.buttons["collection.open"].tap()
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.edit.photo:")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.debugDescription)
        let originalID = original.identifier
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除 ")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 0 张"].waitForExistence(timeout: 5))
        app.buttons["collection.photos"].tap()
        chooseOtherLibraryTarget(in: app)
        let added = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.edit.photo:")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 30), app.debugDescription)
        let targetID = String(added.identifier.dropFirst("collection.edit.".count))
        XCTAssertNotEqual(added.identifier, originalID, "The newly selected photo must differ from the preloaded source")
        XCTAssertTrue(app.staticTexts["已选 1 张"].exists)
        app.buttons["关闭"].tap()

        tapEditorMenuItem("复制调整", in: app)
        let copy = app.buttons["adjustment.copy.confirm"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !copy.isHittable { app.collectionViews.firstMatch.swipeUp() }
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 10), app.debugDescription)
        tapEditorMenuItem("粘贴调整", in: app)
        app.buttons["adjustment.paste.chooseTargets"].tap()
        chooseOtherLibraryTarget(in: app)
        let target = app.descendants(matching: .any)["adjustment.target.skip.\(targetID)"]
        XCTAssertTrue(target.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["目标：2 张照片"].exists, "Paste must load the new photo with the same library identity as the collection")
        capture("photo-library-entry-identities")
    }

    // 系统菜单项不暴露 accessibilityIdentifier，按显示文字查找；复制和粘贴都在菜单首页。
    private func tapEditorMenuItem(_ label: String, in app: XCUIApplication) {
        app.buttons["editor.privacy"].tap()
        let item = app.buttons[label]
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
        item.tap()
    }

    private func chooseOtherLibraryTarget(in app: XCUIApplication) {
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let candidates = photos.allElementsBoundByIndex
        guard let seed = verifiedSeedPickerIndex, candidates.indices.contains(seed),
              let index = candidates.indices.first(where: { $0 != seed }) else {
            XCTFail("Seed both the original DNG and a distinct generated photo on the dedicated simulator")
            return
        }
        candidates[index].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
    }

    func testCollectionHDRJPEGRequiresHDREdits() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["editor.privacy"].tap()
        app.buttons["collection.open"].tap()
        let export = app.buttons["collection.export"]
        for _ in 0..<3 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        export.tap()
        let format = app.buttons["collection.export.format"]
        XCTAssertTrue(format.waitForExistence(timeout: 10), app.debugDescription)
        format.tap()
        XCTAssertTrue(app.buttons["HDR JPEG"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["HDR JPEG"].tap()
        app.buttons["collection.export.start"].tap()
        XCTAssertTrue(app.staticTexts["HDR JPEG 需要启用 HDR 编辑。"].waitForExistence(timeout: 30), app.debugDescription)
        capture("collection-hdr-jpeg-sdr-preflight")
    }

    func testCollectionMicroEditAndFrozenConfirmation() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["editor.privacy"].tap()
        app.buttons["collection.open"].tap()
        XCTAssertTrue(app.staticTexts["已选 1 张"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["collection.synchronize"].isEnabled, "The checked source is excluded from synchronization")
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
        edit.tap()
        XCTAssertTrue(app.buttons["collection.return"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["tool.exposure"].tap()
        dragRuler(app.descendants(matching: .any)["adjustment.ruler"])
        let exposure = app.buttons["tool.exposure"].value as? String
        app.buttons["collection.return"].tap()
        XCTAssertTrue(app.staticTexts["已选 1 张"].waitForExistence(timeout: 10), app.debugDescription)
        let export = app.buttons["collection.export"]
        for _ in 0..<3 where !export.isHittable { app.swipeUp() }
        export.tap()
        let start = app.buttons["collection.export.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["collection.export.freeze"].exists)
        capture("collection-export-configuration")
        start.tap()
        XCTAssertTrue(app.staticTexts["已保存 1 张到照片图库"].waitForExistence(timeout: 180), app.debugDescription)
        XCTAssertTrue(app.staticTexts["每张照片使用确认时冻结的独立调整。"].exists)
        XCTAssertFalse(app.buttons["batch.pick"].exists)
        capture("collection-one-action-export")
        app.buttons["任务操作"].tap()
        app.buttons["放弃任务"].tap()
        let discard = app.buttons["放弃任务"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        discard.tap()
        XCTAssertTrue(app.buttons["tool.exposure"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["tool.exposure"].value as? String, exposure, "Finishing the export task preserves the photo edit")
    }

    func testEditMemoryAndBatchWorkflow() {
        let app = XCUIApplication()
        app.launchArguments += ["-RawLab.language", "zh-Hans"]
        app.launch()
        importPhoto(in: app)
        app.buttons["tool.exposure"].tap()
        app.buttons["重置曝光"].tap()
        dragRuler(app.descendants(matching: .any)["adjustment.ruler"])
        let savedExposure = app.buttons["tool.exposure"].value as? String
        XCTAssertNotEqual(savedExposure, "+0.00 EV")
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
        XCTAssertTrue(app.buttons["长边 2048 px"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["长边 2048 px"].tap()
        XCTAssertTrue(batchSizePicker.label.contains("长边 2048 px"))
        batchSizePicker.tap()
        app.buttons["指定长边"].tap()
        let batchCustom = app.textFields["导出长边像素"]
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

}
