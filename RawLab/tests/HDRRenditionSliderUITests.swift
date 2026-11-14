import XCTest

final class HDRRenditionSliderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchHarness(initialPeak: String = "2.5", voiceOver: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.hdr-rendition-slider")
        app.launchEnvironment = [
            "RAWLAB_SLIDER_UI_MODE": "1",
            "PROBE_INITIAL_PEAK": initialPeak,
            "PROBE_VO": voiceOver ? "1" : "0"
        ]
        app.launch()
        let slider = app.sliders["hdr.rendition.peakLimit"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "peakLimit slider should exist")
        return app
    }

    func testThumbDoubleTapResetsToDefault() {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.417, dy: 0.5)).doubleTap()
        let status = app.staticTexts["probe.status"].label
        XCTAssertTrue(status.contains("peak=0.0"), "Expected peak=0.0, got \(status)")
        XCTAssertTrue(status.contains("writes=1 "), "Expected writes=1 without tap-1 jump, got \(status)")
        XCTAssertTrue(status.contains("editing= cancelled=0"), "Expected clean editing/cancel state, got \(status)")
    }

    func testTrackDoubleTapResetsToDefault() {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).doubleTap()
        let status = app.staticTexts["probe.status"].label
        XCTAssertTrue(status.contains("peak=0.0"), "Expected peak=0.0, got \(status)")
        XCTAssertTrue(status.contains("writes=1 "), "Expected writes=1, got \(status)")
        XCTAssertTrue(status.contains("editing= cancelled=0"), "Expected clean editing/cancel state, got \(status)")
    }

    func testDoubleTapWithMicroSlideStaysSingleWrite() {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let wobbled = start.withOffset(CGVector(dx: 6, dy: 0))
        start.press(forDuration: 0.02, thenDragTo: wobbled)
        wobbled.tap()
        let status = app.staticTexts["probe.status"].label
        XCTAssertTrue(status.contains("peak=0.0"), "Expected micro-slide double-tap to reset cleanly, got \(status)")
        XCTAssertTrue(status.contains("writes=1 "), "Expected micro-slide double-tap not to split history writes, got \(status)")
        XCTAssertTrue(status.contains("editing= cancelled=0"), "Expected no split editing transitions, got \(status)")
    }

    func testEdgeDragMovesSlider() {
        let app = launchHarness(initialPeak: "0.0")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
        let status = app.staticTexts["probe.status"].label
        XCTAssertFalse(status.contains("peak=0.0"), "Expected drag to move off 0.0, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0 cancelled=0"), "Expected editing=1,0, got \(status)")
    }

    func testThumbDragMovesSlider() {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.417, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
        let status = app.staticTexts["probe.status"].label
        XCTAssertFalse(status.contains("peak=2.5"), "Expected thumb drag to change peak, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0 cancelled=0"), "Expected editing=1,0, got \(status)")
    }

    func testVoiceOverDisablesDoubleTapAndClosesNormalizedAdjustment() {
        let app = launchHarness(initialPeak: "2.5", voiceOver: true)
        let slider = app.sliders["hdr.rendition.peakLimit"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).doubleTap()
        var status = app.staticTexts["probe.status"].label
        XCTAssertTrue(status.contains("peak=2.5"), "VoiceOver must disable double-tap reset, got \(status)")

        slider.adjust(toNormalizedSliderPosition: 0.8)
        status = app.staticTexts["probe.status"].label
        XCTAssertFalse(status.contains("peak=2.5"), "Expected adjust under VoiceOver to update peak, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0") && status.hasSuffix("cancelled=0"),
                      "Expected non-touch adjust to close editing state cleanly, got \(status)")
    }
}
