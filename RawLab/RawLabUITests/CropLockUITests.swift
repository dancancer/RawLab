import XCTest

/// Actual touches against the production crop overlay and a real loading VM.
/// The separate harness gates completed deliveries; it does not simulate gestures
/// through callbacks or exercise PhotosPicker's earlier asynchronous source load.
final class CropLockUITests: XCTestCase {
    private let aCrop = [0.1, 0.1, 0.8, 0.8]
    private let bCrop = [0.2, 0.15, 0.6, 0.7]
    private let handles = ["topLeft", "topRight", "bottomLeft", "bottomRight", "move"]

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_CROP_LOCK_HARNESS"] == "1" else {
            throw XCTSkip("Run RawLab/tests/crop-lock-ui.sh to install and explicitly enable the separate crop-lock harness.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testAllCornersAndMoveRemainUsableWithoutImportLock() throws {
        let app = launchHarness()
        for handle in handles {
            app.buttons["crop.harness.reset"].tap()
            assertCrop(try crop(in: app), equals: aCrop)
            let writes = try integer("writes", in: app)
            let point = visiblePoint(handle, in: app)
            drag(handle, from: point)
            waitForState("dragging", equals: "false", in: app)
            let changed = try crop(in: app)
            XCTAssertNotEqual(changed, aCrop, "\(handle) must change crop through a real gesture")
            assertLegalCrop(changed)
            XCTAssertGreaterThan(try integer("writes", in: app), writes)
            XCTAssertEqual(state("source", in: app).label, "A")
        }
    }

    func testCompletedBImportLocksEveryOldHandleAndRestoresItsOwnCrop() throws {
        let app = launchHarness()
        let points = Dictionary(uniqueKeysWithValues: handles.map { ($0, visiblePoint($0, in: app)) })
        let writes = try integer("writes", in: app)
        let starts = try integer("starts", in: app)
        app.buttons["crop.harness.beginB"].tap()
        waitForHeldImport(in: app)
        XCTAssertEqual(state("source", in: app).label, "A", "B decode is ready but publication remains held")
        for handle in handles {
            drag(handle, from: try XCTUnwrap(points[handle]))
            assertCrop(try crop(in: app), equals: aCrop)
            XCTAssertEqual(try integer("writes", in: app), writes, "Locked \(handle) cannot reach the binding setter")
            XCTAssertEqual(try integer("starts", in: app), starts, "Locked \(handle) cannot start crop editing")
            XCTAssertEqual(state("busy", in: app).label, "true")
            XCTAssertEqual(state("source", in: app).label, "A")
        }
        app.buttons["crop.harness.release"].tap()
        waitForState("source", equals: "B", in: app)
        waitForState("busy", equals: "false", in: app)
        assertCrop(try crop(in: app), equals: bCrop)
        XCTAssertEqual(try integer("restorations", in: app), 2, "B restores exactly its persisted geometry")
        XCTAssertEqual(state("dragging", in: app).label, "false")
        XCTAssertTrue(element("geometry.crop.move", in: app).isHittable)
        drag("move", from: visiblePoint("move", in: app))
        waitForState("dragging", equals: "false", in: app)
        let changed = try crop(in: app)
        XCTAssertNotEqual(changed, bCrop, "The newly published B overlay must accept a fresh gesture")
        assertLegalCrop(changed)
        XCTAssertEqual(state("source", in: app).label, "B")
    }

    func testCancelRejectsLateBResultAndAllowsANewGesture() throws {
        let app = launchHarness()
        app.buttons["crop.harness.beginB"].tap()
        waitForHeldImport(in: app)
        app.buttons["crop.harness.cancel"].tap()
        waitForState("busy", equals: "false", in: app)
        assertCrop(try crop(in: app), equals: aCrop)
        app.buttons["crop.harness.release"].tap()
        waitForState("queued", equals: "0", in: app)
        XCTAssertEqual(state("source", in: app).label, "A")
        XCTAssertEqual(try integer("restorations", in: app), 1, "Canceled B must not restore settings or source")
        assertCrop(try crop(in: app), equals: aCrop)
        drag("move", from: visiblePoint("move", in: app))
        waitForState("dragging", equals: "false", in: app)
        let changed = try crop(in: app)
        XCTAssertNotEqual(changed, aCrop, "A fresh gesture must work after cancellation")
        assertLegalCrop(changed)
        XCTAssertEqual(state("source", in: app).label, "A")
    }

    func testImportBeginningDuringEachHandleGestureCancelsThatTouch() throws {
        let app = launchHarness()
        for handle in handles {
            app.buttons["crop.harness.reset"].tap()
            let point = visiblePoint(handle, in: app)
            let writes = try integer("writes", in: app)
            let starts = try integer("starts", in: app)
            app.buttons["crop.harness.arm"].tap()
            waitForState("armed", equals: "true", in: app)
            drag(handle, from: point)
            waitForHeldImport(in: app)
            waitForState("dragging", equals: "false", in: app)
            XCTAssertEqual(try integer("starts", in: app), starts + 1, "\(handle) must trigger the import using its real gesture")
            XCTAssertGreaterThanOrEqual(try integer("ends", in: app), starts + 1, "\(handle) clears its editing state")
            XCTAssertEqual(try integer("writes", in: app), writes, "The same \(handle) touch cannot write after import takes the lock")
            assertCrop(try crop(in: app), equals: aCrop)
            app.buttons["crop.harness.cancel"].tap()
            waitForState("busy", equals: "false", in: app)
            app.buttons["crop.harness.release"].tap()
            waitForState("queued", equals: "0", in: app)
            XCTAssertEqual(state("source", in: app).label, "A")
            assertCrop(try crop(in: app), equals: aCrop)
        }
        drag("move", from: visiblePoint("move", in: app))
        waitForState("dragging", equals: "false", in: app)
        XCTAssertNotEqual(try crop(in: app), aCrop, "An independent touch works after all canceled in-flight gestures")
        XCTAssertEqual(try integer("restorations", in: app), 1)
    }

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.crop-lock")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(state("source", in: app).waitForExistence(timeout: 15), app.debugDescription)
        waitForState("source", equals: "A", in: app)
        waitForState("busy", equals: "false", in: app)
        XCTAssertFalse(app.staticTexts["crop.harness.failure"].exists)
        XCTAssertEqual(state("dragging", in: app).label, "false")
        return app
    }

    private func waitForHeldImport(in app: XCUIApplication) {
        waitForState("busy", equals: "true", in: app)
        let queued = state("queued", in: app)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '0'"), object: queued)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "Real decode must complete into the held delivery queue; \(app.debugDescription)")
        XCTAssertTrue(app.buttons["crop.harness.release"].isEnabled)
    }

    private func waitForState(_ id: String, equals value: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value),
                                                    object: state(id, in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "Expected \(id)=\(value), got \(state(id, in: app).label)")
    }

    private func state(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["crop.harness.\(id)"]
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func visiblePoint(_ handle: String, in app: XCUIApplication) -> XCUICoordinate {
        let target = element("geometry.crop.\(handle)", in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(target.isHittable, "The real \(handle) touch region must be visible and hittable")
        XCTAssertTrue(app.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)))
        // Store a screen coordinate before loading disables hit testing. XCTest
        // will still send a real touch to that old coordinate while the lock is held.
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.frame.midX - app.frame.minX, dy: target.frame.midY - app.frame.minY))
    }

    private func drag(_ handle: String, from point: XCUICoordinate) {
        let delta: CGVector
        switch handle {
        case "topLeft": delta = CGVector(dx: 30, dy: 24)
        case "topRight": delta = CGVector(dx: -30, dy: 24)
        case "bottomLeft": delta = CGVector(dx: 30, dy: -24)
        case "bottomRight": delta = CGVector(dx: -30, dy: -24)
        default: delta = CGVector(dx: 24, dy: 15)
        }
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(delta), withVelocity: .slow,
                    thenHoldForDuration: 0.2)
    }

    private func integer(_ id: String, in app: XCUIApplication) throws -> Int {
        try XCTUnwrap(Int(state(id, in: app).label))
    }

    private func crop(in app: XCUIApplication) throws -> [Double] {
        let values = state("geometry", in: app).label.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 4, "Crop must expose four normalized numeric fields")
        return values
    }

    private func assertCrop(_ actual: [Double], equals expected: [Double],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (value, target) in zip(actual, expected) {
            XCTAssertEqual(value, target, accuracy: 0.000001, file: file, line: line)
        }
    }

    private func assertLegalCrop(_ crop: [Double], file: StaticString = #filePath, line: UInt = #line) {
        guard crop.count == 4 else { return XCTFail("Missing crop fields", file: file, line: line) }
        XCTAssertTrue(crop.allSatisfy { $0.isFinite }, file: file, line: line)
        XCTAssertGreaterThanOrEqual(crop[0], 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(crop[1], 0, file: file, line: line)
        XCTAssertGreaterThan(crop[2], 0, file: file, line: line)
        XCTAssertGreaterThan(crop[3], 0, file: file, line: line)
        XCTAssertLessThanOrEqual(crop[0] + crop[2], 1.000001, file: file, line: line)
        XCTAssertLessThanOrEqual(crop[1] + crop[3], 1.000001, file: file, line: line)
    }
}
