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
        editor.openExportSheet()
        XCTAssertTrue(editor.app.buttons["editor.export.confirm"].waitForExistence(timeout: 10))
    }

    func testProRawStreamAndDecodeVersionSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_PRORAW_UI"] == "1" else {
            throw XCTSkip("Dedicated ProRAW fixture required")
        }
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.openFilesPickerFromEmptyOrMenu()
        importer.cancelSystemPicker()
    }

    func testX3fModeSwitchAndLensLockSmoke() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_X3F_UI"] == "1" else {
            throw XCTSkip("Dedicated X3F fixture required")
        }
        let importer = LibraryImportRobot.launch(language: "zh-Hans")
        importer.openFilesPickerFromEmptyOrMenu()
        importer.cancelSystemPicker()
    }
}
