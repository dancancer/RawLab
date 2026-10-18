import XCTest

final class EditorUITests: XCTestCase {
    let seedPhotoDate = "2025年6月02日, 16:45"
    let seedPhotoBase = "DJI_20250602164503_0444_D"
    var verifiedSeedPickerIndex: Int?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

}
