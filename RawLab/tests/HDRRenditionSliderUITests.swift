import XCTest

final class HDRRenditionSliderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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

    private func synthesizeSlideThenTap(from start: CGPoint, to end: CGPoint,
                                        slideDuration: TimeInterval) throws {
        let record = XCSynthesizedEventRecord(name: "HDR rendition slide then taps")
        let slide = XCPointerEventPath(touchAt: start, offset: 0)
        for index in 1...4 {
            let fraction = CGFloat(index) / 4
            slide.move(to: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                   y: start.y + (end.y - start.y) * fraction),
                       at: slideDuration * Double(fraction))
        }
        slide.liftUp(at: slideDuration + 0.02)
        record.add(slide)
        let down = slideDuration + 0.08
        let tap = XCPointerEventPath(touchAt: end, offset: down)
        tap.liftUp(at: down + 0.02)
        record.add(tap)
        try record.synthesize()
    }

    func testDoubleTapWithMicroSlideStaysSingleWrite() throws {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let point = start.screenPoint
        try synthesizeSlideThenTap(from: point, to: CGPoint(x: point.x + 6, y: point.y),
                                   slideDuration: 0.02)
        let status = app.staticTexts["probe.status"].label
        print("CONTROLLED_MICRO_SLIDE_DOUBLE_TAP: \(status)")
        XCTAssertTrue(status.contains("peak=0.0"), "Expected micro-slide double-tap to reset cleanly, got \(status)")
        XCTAssertTrue(status.contains("writes=1 "), "Expected micro-slide double-tap not to split history writes, got \(status)")
        XCTAssertTrue(status.contains("editing= cancelled=0"), "Expected no split editing transitions, got \(status)")
    }

    func testDeliberateDragThenQuickSingleTapDoesNotReset() throws {
        let app = launchHarness()
        let point = app.sliders["hdr.rendition.peakLimit"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.417, dy: 0.5)).screenPoint
        try synthesizeSlideThenTap(from: point, to: CGPoint(x: point.x + 32, y: point.y),
                                   slideDuration: 0.15)
        let status = app.staticTexts["probe.status"].label
        print("DRAG_THEN_QUICK_SINGLE_TAP: \(status)")
        XCTAssertFalse(status.contains("peak=0.0") || status.contains("peak=2.5"), "Expected committed drag without reset, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0 cancelled=0"), "Expected one closed drag session, got \(status)")
    }

    func testFirstDoubleTapAfterDragResets() {
        let app = launchHarness()
        let slider = app.sliders["hdr.rendition.peakLimit"]
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.417, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: end)
        let afterDrag = app.staticTexts["probe.status"].label
        XCTAssertFalse(afterDrag.contains("peak=2.5"), "Expected committed drag, got \(afterDrag)")
        XCTAssertTrue(afterDrag.contains("editing=1,0 cancelled=0"), "Expected drag to finish before double-tap, got \(afterDrag)")
        end.doubleTap()
        let status = app.staticTexts["probe.status"].label
        print("DRAG_THEN_FIRST_DOUBLE_TAP: \(status)")
        XCTAssertTrue(status.contains("peak=0.0"), "Expected first complete double-tap after drag to reset, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0 cancelled=0"), "Expected drag editing to stay closed, got \(status)")
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

    private func assertFirstDoubleTapAfterDragResets(at position: CGFloat) throws {
        let app = launchHarness(initialPeak: "2.5")
        let slider = app.sliders["hdr.rendition.peakLimit"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.417, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        let afterDrag = app.staticTexts["probe.status"].label
        XCTAssertFalse(afterDrag.contains("peak=2.5"), "Expected drag to change peak, got \(afterDrag)")
        XCTAssertTrue(afterDrag.contains("editing=1,0 cancelled=0"), "Expected drag editing to close, got \(afterDrag)")

        app.buttons["probe.valueChanged"].tap()
        let afterValueChanged = app.staticTexts["probe.status"].label
        print("AFTER_DRAG_VALUE_CHANGED: \(afterValueChanged)")
        XCTAssertTrue(afterValueChanged.contains("peak=3.4"), "Expected programmatic .valueChanged to update peak, got \(afterValueChanged)")
        XCTAssertTrue(afterValueChanged.contains("editing=1,0,1,0 cancelled=0"),
                      "Expected programmatic .valueChanged editing to close after drag, got \(afterValueChanged)")
        let writesText = try XCTUnwrap(afterValueChanged.components(separatedBy: "writes=").last?.split(separator: " ").first)
        let writesBeforeReset = try XCTUnwrap(Int(writesText))

        slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).doubleTap()
        let status = app.staticTexts["probe.status"].label
        print("FIRST_DOUBLE_TAP_AFTER_DRAG: \(status)")
        XCTAssertTrue(status.contains("peak=0.0"), "First double-tap after drag must reset, got \(status)")
        XCTAssertTrue(status.contains("writes=\(writesBeforeReset + 1) "), "Expected exactly one reset write after drag, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0,1,0 cancelled=0"), "Reset must preserve closed editing state, got \(status)")
    }

    func testFirstTrackDoubleTapAfterDragAndValueChangedResets() throws {
        try assertFirstDoubleTapAfterDragResets(at: 0.25)
    }

    func testFirstThumbDoubleTapAfterDragAndValueChangedResets() throws {
        try assertFirstDoubleTapAfterDragResets(at: 3.4 / 6)
    }

    func testVoiceOverTouchDragHasSingleEditingSession() {
        let app = launchHarness(initialPeak: "0.0", voiceOver: true)
        let slider = app.sliders["hdr.rendition.peakLimit"]
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        let status = app.staticTexts["probe.status"].label
        print("VOICEOVER_TOUCH_DRAG: \(status)")
        XCTAssertFalse(status.contains("peak=0.0"), "Expected VoiceOver touch drag to update peak, got \(status)")
        XCTAssertTrue(status.contains("editing=1,0 cancelled=0"), "Expected one closed editing session, got \(status)")
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
