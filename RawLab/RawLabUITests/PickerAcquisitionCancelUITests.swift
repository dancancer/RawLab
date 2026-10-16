import XCTest

/// Real system selection and transferable acquisition, followed by a test-only
/// return gate and an actual hosting-controller disappearance. This is not an
/// iCloud/provider-in-flight cancellation test or a shipping cancel-button flow.
final class PickerAcquisitionCancelUITests: XCTestCase {
    private let preservedKeys = ["sourceIdentity", "sourceRevision", "image", "histogram", "settings",
                                 "geometryDraft", "lensDraft", "geometrySelected", "lensSelected"]

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RAWLAB_PICKER_CANCEL_HARNESS"] == "1" else {
            throw XCTSkip("Run RawLab/tests/picker-cancel-ui.sh to build and enable the separate lifecycle harness.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testFirstAcquisitionCancellationKeepsEmptyEditorAndReleasesLateFile() throws {
        let app = try launchHarness()
        app.buttons["picker.arm.success"].tap()
        try selectFixture("B", in: app)
        let held = try waitForHeldFile("B", in: app)
        XCTAssertEqual(held["hasImage"], "false")
        XCTAssertFalse(app.buttons["editor.import"].isEnabled)
        try leaveAndReturn(in: app)
        XCTAssertTrue(app.buttons["editor.import.empty"].isEnabled)
        app.buttons["picker.release"].tap()
        try waitForReleasedFile("Success", in: app)
        let cancelled = try probe(in: app)
        XCTAssertEqual(cancelled["hasImage"], "false")
        XCTAssertEqual(cancelled["image"], "nil")
        XCTAssertEqual(cancelled["sourceIdentity"], "nil")
        XCTAssertEqual(cancelled["status"], "nil")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("picker-empty-after-late-success")
        try selectFixture("C", in: app)
        try waitForImportedFixture("C", in: app)
        app.terminate()
    }

    func testReplacementCancellationPreservesEditedPhotoAndDraftThenSamePhotoCanImport() throws {
        let app = try launchHarness()
        try selectFixture("A", in: app)
        try waitForImportedFixture("A", in: app)
        try setExposure(in: app)
        try selectGeometry(in: app)
        let flip = app.switches["geometry.flipHorizontal"]
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        flip.tap()
        XCTAssertFalse(app.buttons["editor.import"].isEnabled, "A changed draft cannot start an import")
        flip.tap()
        try waitForPreview(in: app)
        XCTAssertTrue(app.buttons["editor.import"].isEnabled)
        let before = try probe(in: app)
        XCTAssertNotEqual(before["geometryDraft"], "nil")
        XCTAssertEqual(before["geometrySelected"], "true")

        app.buttons["picker.arm.success"].tap()
        try selectFixture("B", in: app)
        let held = try waitForHeldFile("B", in: app)
        assertPreserved(before, comparedWith: held)
        XCTAssertFalse(app.buttons["tool.geometry"].isEnabled)
        XCTAssertFalse(flip.isEnabled)
        capture("picker-old-photo-locked-during-acquisition")
        try leaveAndReturn(in: app)
        assertPreserved(before, comparedWith: try probe(in: app))
        XCTAssertTrue(app.buttons["editor.import"].isEnabled)
        XCTAssertTrue(flip.isEnabled)
        app.buttons["picker.release"].tap()
        try waitForReleasedFile("Success", in: app)
        assertPreserved(before, comparedWith: try probe(in: app))
        capture("picker-old-photo-draft-after-cancel")

        let acquisitions = Int(try probe(in: app)["acquisitionCount"] ?? "") ?? -1
        try selectFixture("B", in: app)
        try waitForImportedFixture("B", in: app)
        XCTAssertEqual(Int(try probe(in: app)["acquisitionCount"] ?? ""), acquisitions + 1,
                       "Reselecting the same cancelled item must start another real acquisition")
        app.terminate()
    }

    func testLateAcquisitionSuccessAndInjectedFailureCannotOverwriteNewImport() throws {
        for mode in ["Success", "Failure"] {
            let app = try launchHarness()
            try selectFixture("A", in: app)
            try waitForImportedFixture("A", in: app)
            app.buttons["picker.arm." + mode.lowercased()].tap()
            try selectFixture("B", in: app)
            _ = try waitForHeldFile("B", in: app)
            try leaveAndReturn(in: app)
            try selectFixture("C", in: app)
            try waitForImportedFixture("C", in: app)
            let current = try probe(in: app)
            app.buttons["picker.release"].tap()
            try waitForReleasedFile(mode, in: app)
            let after = try probe(in: app)
            assertPreserved(current, comparedWith: after)
            XCTAssertEqual(after["status"], "nil")
            XCTAssertEqual(after["isImporting"], "false")
            XCTAssertEqual(after["vmBusy"], "false")
            XCTAssertEqual(after["request"], "nil")
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertTrue(app.buttons["editor.import"].isEnabled)
            capture("picker-new-photo-after-late-" + mode.lowercased())
            app.terminate()
        }
    }

    private func launchHarness() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.rawlab.tests.picker-cancel")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-RawLab.language", "en"]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons.matching(NSPredicate(format:
            "label == 'Allow Full Access' OR label == 'Allow Access to All Photos' OR label == '允许完全访问'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        try waitProbe(in: app, timeout: 30) { $0["seeded"] == "true" }
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 10))
        return app
    }

    private func selectFixture(_ name: String, in app: XCUIApplication) throws {
        let empty = app.buttons["editor.import.empty"]
        if empty.exists && empty.isHittable { empty.tap() }
        else { app.buttons["editor.import"].tap() }
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertGreaterThanOrEqual(photos.count, 3, "The dedicated fixture assets must be present")
        let index = try XCTUnwrap(["C": 0, "B": 1, "A": 2][name])
        print("Selecting actual Photos asset \(name), visible index \(index): \(photos.allElementsBoundByIndex.map(\.label))")
        photos.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func waitForImportedFixture(_ name: String, in app: XCUIApplication) throws {
        try waitProbe(in: app, timeout: 40) {
            $0["hasImage"] == "true" && $0["sourceIdentity"] == $0["seed" + name]
                && $0["isImporting"] == "false" && $0["vmBusy"] == "false"
        }
        try waitForPreview(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists)
    }

    private func waitForHeldFile(_ name: String, in app: XCUIApplication) throws -> [String: String] {
        try waitProbe(in: app, timeout: 30) { $0["gatePhase"] == "acquired" }
        let held = try probe(in: app)
        XCTAssertEqual(held["heldItem"], held["seed" + name], "The system picker must return the intended asset")
        XCTAssertEqual(held["gateFileExists"], "true", "The real transferable returned retained bytes")
        XCTAssertEqual(held["isImporting"], "true")
        XCTAssertEqual(held["editorBusy"], "true")
        XCTAssertEqual(held["vmBusy"], "false", "This gate is before decoding, during source acquisition")
        XCTAssertNotEqual(held["request"], "nil")
        return held
    }

    private func leaveAndReturn(in app: XCUIApplication) throws {
        let before = Int(try probe(in: app)["disappearances"] ?? "") ?? 0
        app.buttons["picker.leave"].tap()
        try waitProbe(in: app) {
            (Int($0["disappearances"] ?? "") ?? 0) > before && $0["request"] == "nil"
                && $0["task"] == "false" && $0["isImporting"] == "false"
        }
        XCTAssertEqual(try probe(in: app)["selectedPhoto"], "nil", "Cancellation must reset the system picker's selection")
        XCTAssertEqual(try probe(in: app)["gateFileExists"], "true", "Cancellation does not pretend the pending provider already returned")
        app.buttons["picker.return"].tap()
        XCTAssertTrue(app.buttons["editor.import"].waitForExistence(timeout: 5))
    }

    private func waitForReleasedFile(_ mode: String, in app: XCUIApplication) throws {
        try waitProbe(in: app) {
            $0["gatePhase"] == "released" + mode && $0["resumedCancelled"] == "true"
                && $0["gateFileExists"] == "false"
        }
    }

    private func waitForPreview(in app: XCUIApplication) throws {
        try waitProbe(in: app) { $0["previewRendering"] == "false" && $0["previewResizePending"] == "false" }
    }

    private func assertPreserved(_ before: [String: String], comparedWith after: [String: String],
                                 file: StaticString = #filePath, line: UInt = #line) {
        for key in preservedKeys {
            XCTAssertNotNil(before[key], "Missing probe field \(key)", file: file, line: line)
            XCTAssertEqual(after[key], before[key], "Cancellation/late delivery changed \(key)", file: file, line: line)
        }
    }

    private func setExposure(in app: XCUIApplication) throws {
        let value = app.buttons["adjustment.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        let picker = app.descendants(matching: .any)["adjustment.wheel"]
        let wheel = picker.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let current = try XCTUnwrap(wheel.value as? String)
        let title = picker.label.isEmpty ? "Exposure" : picker.label
        let target = current.contains(title + ",") ? title + ", +0.50 EV" : current.contains(" EV") ? "+0.50 EV" : "+0.50"
        wheel.adjust(toPickerWheelValue: target)
        app.buttons["adjustment.wheel.apply"].tap()
        try waitForPreview(in: app)
        XCTAssertTrue((value.value as? String)?.contains("+0.50") == true)
    }

    private func selectGeometry(in app: XCUIApplication) throws {
        let tool = app.buttons["tool.geometry"]
        let strip = try XCTUnwrap(app.scrollViews.containing(.button, identifier: "tool.geometry")
            .allElementsBoundByIndex.min { $0.frame.height < $1.frame.height })
        for _ in 0..<8 where !tool.isHittable { strip.swipeRight() }
        XCTAssertTrue(tool.isHittable)
        tool.tap()
        try waitProbe(in: app) { $0["geometrySelected"] == "true" }
        try waitForPreview(in: app)
    }

    private func probe(in app: XCUIApplication) throws -> [String: String] {
        let element = app.descendants(matching: .any)["picker.probe"].firstMatch
        let value = try XCTUnwrap(element.value as? String, app.debugDescription)
        return try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    }

    private func waitProbe(in app: XCUIApplication, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping ([String: String]) -> Bool) throws {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let snapshot = try? self.probe(in: app) else { return false }
            return condition(snapshot)
        }, object: nil)
        let result = XCTWaiter.wait(for: [expected], timeout: timeout)
        if result != .completed { print("Last import probe: \((try? probe(in: app)) ?? [:])") }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
