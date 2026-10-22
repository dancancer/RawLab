import XCTest
import CoreFoundation

final class ViewingEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.viewing-editor")
        let language = ProcessInfo.processInfo.environment["S3_VIEWING_LANGUAGE"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language, "-RawLab.language", language]
        if let category = ProcessInfo.processInfo.environment["S3_VIEWING_TEXT"], !category.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launch()
        wait(app) { $0["ready"] as? Bool == true }
        return app
    }
    func receipt(_ app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["viewing.editor.receipt"]
        guard element.exists else { return [:] }
        guard let value = element.value as? String, let data = value.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    func wait(_ app: XCUIApplication, timeout: TimeInterval = 20, _ predicate: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate(self.receipt(app)) }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Receipt: \(receipt(app))")
    }
    func capture(_ app: XCUIApplication, _ name: String) {
        print("VIEWING_EDITOR \(name) \(receipt(app))")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        var snapshot = receipt(app)
        var bounds: [String: [Double]] = [:]
        for id in ["editor.photo", "editor.photo.before", "editor.compare.before", "editor.compare.after", "editor.compare.mode", "editor.preview.exit", "editor.panel", "editor.compare", "editor.reset"] {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if element.exists {
                let frame = element.frame
                bounds[id] = [frame.minX, frame.minY, frame.width, frame.height]
            }
        }
        snapshot["uiBounds"] = bounds
        snapshot["window"] = [app.frame.minX, app.frame.minY, app.frame.width, app.frame.height]
        let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); json.name = name + "-receipt"; json.lifetime = .keepAlways; add(json)
    }
    func selectGeometry(_ app: XCUIApplication) {
        app.buttons["editor.group.geometry"].tap()
        if !app.buttons["tool.geometry"].isSelected { app.buttons["tool.geometry"].tap() }
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == true }
    }
    func testEnteringGeometryFromZoomUsesCropCanvasViewport() {
        let app = launch()
        app.images["editor.photo"].pinch(withScale: 2, velocity: 1)
        wait(app) { ($0["relativeScale"] as? Double ?? 1) > 1.5 }
        capture(app, "zoom-before-geometry")
        selectGeometry(app)
        let rect = (receipt(app)["nativePhotoRects"] as! [[Double]])[0]
        let handle = app.descendants(matching: .any).matching(identifier: "geometry.crop.topLeft").firstMatch
        capture(app, "zoom-to-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, rect[0], accuracy: 0.5)
        XCTAssertEqual(handle.frame.midY, rect[1], accuracy: 0.5)
    }
    func testActualCropHandlesAlignWithNativePhotoMargin() {
        let app = launch()
        selectGeometry(app)
        let data = receipt(app)
        let rect = (data["nativePhotoRects"] as! [[Double]])[0]
        let handle = app.descendants(matching: .any).matching(identifier: "geometry.crop.topLeft").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        capture(app, "margin-on-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, rect[0], accuracy: 0.5, "crop handle must align with actual UIKit photo, including view margin")
        XCTAssertEqual(handle.frame.midY, rect[1], accuracy: 0.5)
        let bottomRight = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch
        let corner = bottomRight.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.draft.apply"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == false }
        capture(app, "margin-on-applied")
        XCTAssertEqual(receipt(app)["referenceSize"] as? [Double], receipt(app)["previewSize"] as? [Double], "Apply must publish a neutral reference with the newly committed composition")
        let committed = receipt(app)["settings"] as! String
        app.buttons["editor.privacy"].tap()
        app.buttons["Zoom and display"].tap()
        app.buttons["Space around photo"].tap()
        wait(app) { $0["margin"] as? Bool == false }
        selectGeometry(app)
        let noMargin = (receipt(app)["nativePhotoRects"] as! [[Double]])[0]
        capture(app, "margin-off-geometry-alignment")
        XCTAssertEqual(handle.frame.midX, noMargin[0], accuracy: 0.5)
        XCTAssertEqual(handle.frame.midY, noMargin[1], accuracy: 0.5)
        let movedCorner = bottomRight.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        movedCorner.press(forDuration: 0.05, thenDragTo: movedCorner.withOffset(CGVector(dx: -12, dy: -8)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.draft.cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["draftActive"] as? Bool == false }
        XCTAssertEqual(receipt(app)["settings"] as? String, committed)
        capture(app, "margin-off-discarded")
    }
    func testActualImportGuardKeepsDraftOnSaveFailureAndResumesAfterRetry() {
        let app = launch()
        selectGeometry(app)
        let initial = receipt(app)
        let original = initial["settings"] as! String
        let saves = (initial["saves"] as! [[String: Any]]).count
        let corner = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -16, dy: -12)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.compare"].isEnabled)
        app.buttons["editor.import"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertTrue(receipt(app)["draftActive"] as! Bool)
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        XCTAssertEqual(receipt(app)["settings"] as? String, original)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s3.fail-next-save" as CFString), nil, nil, true)
        wait(app) { $0["failNextSave"] as? Bool == true }
        app.buttons["editor.import"].tap()
        app.alerts.buttons["Apply"].tap()
        wait(app) { ($0["saveState"] as? String ?? "").contains("failed") }
        XCTAssertTrue(receipt(app)["draftActive"] as! Bool)
        XCTAssertTrue(receipt(app)["draftChanged"] as! Bool)
        XCTAssertFalse(receipt(app)["photoPicker"] as! Bool)
        XCTAssertEqual(receipt(app)["settings"] as? String, original)
        let attempts = receipt(app)["saves"] as! [[String: Any]]
        XCTAssertEqual(attempts.count, saves + 1)
        XCTAssertTrue(attempts.last!["failed"] as! Bool)
        capture(app, "draft-import-save-failed")
        let retry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "not saved")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15), "the system Photos picker must finish loading before cancellation")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture(app, "draft-import-retried-picker")
        app.buttons["Cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["photoPicker"] as? Bool == false }
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves + 2)
        let committed = receipt(app)["settings"] as! String
        XCTAssertNotEqual(committed, original)
        selectGeometry(app)
        let next = app.descendants(matching: .any).matching(identifier: "geometry.crop.bottomRight").firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        next.press(forDuration: 0.05, thenDragTo: next.withOffset(CGVector(dx: -12, dy: -8)))
        wait(app) { $0["ready"] as? Bool == true && $0["draftChanged"] as? Bool == true }
        app.buttons["editor.import"].tap()
        app.alerts.buttons["Discard Changes"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["photoPicker"] as? Bool == false }
        XCTAssertEqual(receipt(app)["settings"] as? String, committed)
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, saves + 2)
        selectGeometry(app)
        app.buttons["editor.import"].tap()
        wait(app) { $0["draftActive"] as? Bool == false && $0["photoPicker"] as? Bool == true }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        capture(app, "draft-import-discard-and-unchanged")
    }
    func testUnavailableNeutralKeepsAfterAndBlocksBeforeEntry() {
        let app = launch()
        let before = receipt(app)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.rawlab.s3.clear-reference" as CFString), nil, nil, true)
        wait(app) { $0["referenceAvailable"] as? Bool == false }
        XCTAssertFalse(app.buttons["editor.compare"].isEnabled)
        app.images["editor.photo"].press(forDuration: 0.7)
        XCTAssertFalse(receipt(app)["hold"] as! Bool)
        XCTAssertTrue(app.images["editor.photo"].exists)
        XCTAssertFalse(app.images["editor.photo.before"].exists)
        XCTAssertEqual(receipt(app)["previewSize"] as? [Double], before["previewSize"] as? [Double])
        XCTAssertEqual((receipt(app)["saves"] as! [[String: Any]]).count, (before["saves"] as! [[String: Any]]).count)
        capture(app, "nil-neutral-retains-after")
    }
    func testViewingActionsPreserveEditingSessionAndSettings() {
        let app = launch()
        app.buttons["editor.group.color"].tap()
        app.buttons["tool.hsl"].tap()
        wait(app) { $0["ready"] as? Bool == true }
        let switches = receipt(app)["nativeSwitchRects"] as! [[Double]]
        XCTAssertEqual(switches.count, 1)
        let fineRect = switches[0]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fineRect[0] + fineRect[2] / 2, dy: fineRect[1] + fineRect[3] / 2)).tap()
        wait(app) { $0["fine"] as? Bool == true }
        XCTAssertTrue(app.buttons["hsl.channel.6"].exists)
        app.buttons["hsl.channel.6"].tap()
        app.images["editor.photo"].pinch(withScale: 1.5, velocity: 1)
        wait(app) { ($0["relativeScale"] as? Double ?? 1) > 1.2 && $0["ready"] as? Bool == true }
        let initial = receipt(app)
        let saves = (initial["saves"] as! [[String: Any]]).count
        let settings = initial["settings"] as! String
        let photo = app.images["editor.photo"]
        photo.tap()
        wait(app) { $0["previewOnly"] as? Bool == true }
        XCTAssertFalse(app.buttons["editor.compare"].isHittable)
        XCTAssertTrue(app.buttons["editor.preview.exit"].isHittable)
        capture(app, "pure-preview")
        app.buttons["editor.preview.exit"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["previewOnly"] as? Bool == false }
        XCTAssertEqual(receipt(app)["tool"] as? String, "hsl")
        XCTAssertEqual(receipt(app)["fine"] as? Bool, initial["fine"] as? Bool)
        XCTAssertEqual(receipt(app)["hslChannel"] as? Int, initial["hslChannel"] as? Int)
        XCTAssertEqual(receipt(app)["focus"] as? [Double], initial["focus"] as? [Double])
        XCTAssertEqual(receipt(app)["relativeScale"] as? Double, initial["relativeScale"] as? Double)
        photo.doubleTap()
        XCTAssertFalse(receipt(app)["previewOnly"] as! Bool)
        photo.press(forDuration: 0.7)
        XCTAssertFalse(receipt(app)["hold"] as! Bool)
        app.buttons["editor.compare"].tap()
        wait(app) { $0["ready"] as? Bool == true && $0["compare"] as? Bool == true }
        XCTAssertTrue(app.images["editor.photo.before"].exists)
        for (label, photoID) in [("editor.compare.before", "editor.photo.before"), ("editor.compare.after", "editor.photo")] {
            let text = app.staticTexts[label]
            XCTAssertTrue(text.exists)
            XCTAssertTrue(app.images[photoID].frame.contains(text.frame), "comparison labels must remain inside their actual visible pane")
        }
        XCTAssertGreaterThanOrEqual(app.buttons["editor.compare.mode"].frame.width, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["editor.compare.mode"].frame.height, 44)
        capture(app, "comparison-side-by-side")
        app.buttons["editor.compare.mode"].tap()
        app.buttons["editor.compare.wipe"].tap()
        wait(app) { $0["mode"] as? String == "wipe" }
        capture(app, "comparison-wipe")
        app.buttons["editor.compare"].tap()
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(receipt(app)["mode"] as? String, "wipe")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(app) { $0["ready"] as? Bool == true }
        capture(app, "comparison-landscape")
        let final = receipt(app)
        XCTAssertEqual(final["settings"] as? String, settings)
        XCTAssertEqual((final["saves"] as! [[String: Any]]).count, saves)
        for request in final["previews"] as! [[String: Any]] {
            XCTAssertEqual(request["settings"] as? String, settings, "viewing must never submit edited parameters")
        }
    }
}
