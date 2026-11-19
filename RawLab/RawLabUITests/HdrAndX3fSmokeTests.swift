import XCTest

@MainActor
final class HdrAndX3fSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testHdrOpenLookAndRenditionSliderSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator fixture required")
        }
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.importFirstSeededPhoto()
        let editor = EditorRobot(app: importer.app)
        editor.openTool("hdrSDRExposure", in: "hdrRendition")
        editor.dragRuler()
        editor.applyDraft()
    }

    func testHdrExportAndSdrFallbackSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_HDR_UI"] == "1" else {
            throw XCTSkip("Dedicated HDR simulator fixture required")
        }
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.importFirstSeededPhoto()
        let editor = EditorRobot(app: importer.app)
        editor.openExportMenu()
        XCTAssertTrue(editor.app.buttons["保存当前照片"].waitForExistence(timeout: 5))
        XCTAssertTrue(editor.app.buttons["保存 SDR JPEG"].waitForExistence(timeout: 5))
        editor.app.buttons["保存当前照片"].tap()
        XCTAssertTrue(editor.app.buttons["editor.export.confirm"].waitForExistence(timeout: 10))
        editor.app.buttons["取消"].firstMatch.tap()
    }

    private func waitForEditorReady(_ editor: EditorRobot, timeout: TimeInterval = 45) {
        let compare = editor.app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "editor.compare", ["对比", "Comparison"]
        )).firstMatch
        editor.waitForCondition(timeout: timeout) {
            editor.app.buttons["editor.export"].isEnabled && compare.exists && compare.isEnabled
        }
    }

    private func toggleSwitch(_ toggle: XCUIElement, on editor: EditorRobot, expectedValue: String, timeout: TimeInterval) {
        let inner = toggle.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        editor.waitForCondition(timeout: timeout) { toggle.value as? String == expectedValue }
    }

    func testProRawStreamAndDecodeVersionSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] == "1" else {
            throw XCTSkip("Dedicated ProRAW fixture required")
        }
        let stem = ProcessInfo.processInfo.environment["RAWLAB_PRORAW_STEM"] ?? "ProRAW12Fixture"
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.importFileFromRawLabFolder(stem)
        let editor = EditorRobot(app: importer.app)
        waitForEditorReady(editor, timeout: 30)
        XCTAssertFalse(editor.app.buttons["editor.group.hdrRendition"].exists, "ProRAW opens in SDR mode initially")

        editor.selectGroup("light")
        let sdrExposure = editor.app.buttons["tool.exposure"].value as? String

        editor.openProcessingSettings()
        let hdrSwitch = editor.app.switches["hdr.editMode"].firstMatch
        XCTAssertTrue(hdrSwitch.waitForExistence(timeout: 10), editor.app.debugDescription)
        XCTAssertEqual(hdrSwitch.value as? String, "0")
        toggleSwitch(hdrSwitch, on: editor, expectedValue: "1", timeout: 20)
        editor.closeProcessingSettings()

        // activateHDRMode opens the exposure draft tool directly
        let adjustmentValue = editor.app.buttons["adjustment.value"]
        XCTAssertTrue(adjustmentValue.waitForExistence(timeout: 15), editor.app.debugDescription)
        let hdrBefore = adjustmentValue.value as? String
        editor.dragRuler(increasing: true)
        let hdrEdited = adjustmentValue.value as? String
        XCTAssertNotEqual(hdrEdited, hdrBefore)
        editor.applyDraft()
        XCTAssertTrue(editor.app.buttons["editor.group.hdrRendition"].waitForExistence(timeout: 15), editor.app.debugDescription)
        editor.selectGroup("light")
        let hdrEditedTool = editor.app.buttons["tool.exposure"].value as? String
        XCTAssertNotEqual(hdrEditedTool, sdrExposure)

        editor.openProcessingSettings()
        XCTAssertEqual(hdrSwitch.value as? String, "1")
        toggleSwitch(hdrSwitch, on: editor, expectedValue: "0", timeout: 15)
        editor.closeProcessingSettings()
        XCTAssertTrue(adjustmentValue.waitForExistence(timeout: 15), editor.app.debugDescription)
        editor.cancelDraft()
        XCTAssertFalse(editor.app.buttons["editor.group.hdrRendition"].exists)
        editor.selectGroup("light")
        XCTAssertEqual(editor.app.buttons["tool.exposure"].value as? String, sdrExposure)

        editor.openProcessingSettings()
        toggleSwitch(hdrSwitch, on: editor, expectedValue: "1", timeout: 20)
        editor.closeProcessingSettings()
        XCTAssertTrue(adjustmentValue.waitForExistence(timeout: 15), editor.app.debugDescription)
        editor.cancelDraft()
        XCTAssertTrue(editor.app.buttons["editor.group.hdrRendition"].waitForExistence(timeout: 15), editor.app.debugDescription)
        editor.selectGroup("light")
        XCTAssertEqual(editor.app.buttons["tool.exposure"].value as? String, hdrEditedTool)

        importer.app.terminate()
        importer.app.launch()
        importer.importFileFromRawLabFolder(stem)
        waitForEditorReady(editor, timeout: 30)
        XCTAssertTrue(editor.app.buttons["editor.group.hdrRendition"].waitForExistence(timeout: 15),
                      "ProRAW HDR mode and decode version must persist across restart")
        editor.selectGroup("light")
        XCTAssertEqual(editor.app.buttons["tool.exposure"].value as? String, hdrEditedTool)

        editor.openExportMenu()
        XCTAssertTrue(editor.app.buttons["保存当前照片"].waitForExistence(timeout: 5))
        XCTAssertTrue(editor.app.buttons["保存 SDR JPEG"].waitForExistence(timeout: 5))
        editor.app.buttons["保存当前照片"].tap()
        XCTAssertTrue(editor.app.buttons["editor.export.confirm"].waitForExistence(timeout: 10))
        editor.app.buttons["取消"].firstMatch.tap()
    }

    func testX3fModeSwitchAndLensLockSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_X3F_UI"] == "1" else {
            throw XCTSkip("Dedicated X3F fixture required")
        }
        let defaultStem = ProcessInfo.processInfo.environment["RAWLAB_X3F_UI_RUN_ID"].map { "X3F-Normal-\($0)" } ?? "X3F-Normal"
        let stem = ProcessInfo.processInfo.environment["RAWLAB_X3F_STEM"] ?? defaultStem
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.importFileFromRawLabFolder(stem)
        let editor = EditorRobot(app: importer.app)
        waitForEditorReady(editor, timeout: 45)

        func currentX3fModeText() -> String {
            let mode = editor.app.descendants(matching: .any).matching(identifier: "x3f.mode").firstMatch
            XCTAssertTrue(mode.waitForExistence(timeout: 10), editor.app.debugDescription)
            return "\(mode.label) \(mode.value as? String ?? "")"
        }

        func selectX3fMode(_ title: String) {
            let mode = editor.app.descendants(matching: .any).matching(identifier: "x3f.mode").firstMatch
            XCTAssertTrue(mode.waitForExistence(timeout: 10), editor.app.debugDescription)
            mode.tap()
            let option = editor.app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 10), editor.app.debugDescription)
            option.tap()
        }

        editor.openProcessingSettings()
        XCTAssertTrue(currentX3fModeText().contains("正常显影"), editor.app.debugDescription)
        editor.closeProcessingSettings()

        editor.selectGroup("geometry")
        let lensButton = editor.app.buttons["tool.lens"]
        XCTAssertTrue(lensButton.waitForExistence(timeout: 10), editor.app.debugDescription)
        XCTAssertFalse(lensButton.isEnabled, "Normal X3F mode must lock lens corrections")

        editor.openProcessingSettings()
        selectX3fMode("伪红外（旧版）")
        editor.closeProcessingSettings()
        waitForEditorReady(editor, timeout: 45)

        editor.selectGroup("geometry")
        XCTAssertTrue(lensButton.waitForExistence(timeout: 10), editor.app.debugDescription)
        XCTAssertTrue(lensButton.isEnabled, "Legacy X3F mode must unlock lens corrections")

        editor.openProcessingSettings()
        selectX3fMode("正常显影")
        editor.closeProcessingSettings()
        waitForEditorReady(editor, timeout: 45)

        editor.selectGroup("geometry")
        XCTAssertFalse(lensButton.isEnabled, "Switching back to normal X3F mode must re-lock lens corrections")

        importer.app.terminate()
        importer.app.launch()
        importer.importFileFromRawLabFolder(stem)
        waitForEditorReady(editor, timeout: 45)
        editor.openProcessingSettings()
        XCTAssertTrue(currentX3fModeText().contains("正常显影"), editor.app.debugDescription)
        editor.closeProcessingSettings()
        editor.selectGroup("geometry")
        XCTAssertFalse(lensButton.isEnabled, "Normal X3F lens lock must persist across restart")
    }
}
