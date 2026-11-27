import Foundation
import XCTest
@testable import RawLabKit

final class MacAdjustmentPresetApplicationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetApply-\(UUID())")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testPresetSourceIndependenceClipboardIsolationEqualityPersistenceAndSharedHistory() throws {
        let root = tempRoot!
        let source = root.appendingPathComponent("source.ARW")
        let target = root.appendingPathComponent("target.ARW")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6]).write(to: target)

        let edits = try MacEditPersistence(directory: root.appendingPathComponent("edits"))
        let session = AdjustmentTransferSession(store: edits)
        let presets = AdjustmentPresetStore(directory: root.appendingPathComponent("presets"))

        var settings = Adjustments()
        settings.exposure = 1.25
        settings.contrast = 1.35
        settings.blackPoint = -32.75
        settings.whitePoint = 46.5
        settings.vibrance = 21.25
        settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        settings.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        settings.hsl = HSLSettings()
        settings.hsl!.setExact(.hue, channel: 0, value: 37.25)

        let state = MacPhotoEditState(settings: settings, filmID: "")
        let context = MacAdjustmentTransferContext(identifier: source.path, isRaw: true)
        let clipboard = try session.copy(scope: .custom([.contrast]), snapshot: state, context: context)

        let preview = try MacAdjustmentTransfer.previewCapture(scope: .modified, snapshot: state, committed: state, context: context)
        XCTAssertTrue(
            preview.fields.contains(.exposure) && !preview.fields.contains(.cropWidth),
            "Scope preview captures actual modified fields and excludes geometry"
        )

        let geometry = try MacAdjustmentTransfer.previewCapture(scope: .custom([.cropWidth]), snapshot: state, committed: state, context: context)
        XCTAssertTrue(
            geometry.fields == [.cropWidth] && geometry[.cropWidth] == .number(1),
            "Custom scope preview preserves the captured value"
        )

        XCTAssertThrowsError(
            try MacAdjustmentTransfer.previewCapture(
                scope: .modified,
                snapshot: MacPhotoEditState(settings: Adjustments(), filmID: ""),
                committed: nil,
                context: context
            ),
            "Neutral modified preview must be empty"
        ) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .emptyScope, "Neutral modified preview reports an empty scope")
        }

        var changed = state
        changed.settings.exposure += 0.1
        XCTAssertThrowsError(
            try MacAdjustmentTransfer.previewCapture(scope: .all, snapshot: changed, committed: state, context: context),
            "Stale preview must fail"
        ) { error in
            XCTAssertEqual(error as? AdjustmentTransferError, .draftRequiresPreflight, "Uncommitted live changes cannot display a stale summary")
        }

        var hydrated = state
        hydrated.settings.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 14))
        let metadataPreview = try MacAdjustmentTransfer.previewCapture(
            scope: .custom([.temperature, .tint]),
            snapshot: hydrated,
            committed: state,
            context: context
        )
        XCTAssertTrue(
            metadataPreview[.temperature] == .null && metadataPreview[.tint] == .null,
            "Camera metadata hydration preserves target-resolved white-balance preview"
        )

        var hdr = Adjustments()
        hdr.hdr = HDRSettings()
        hdr.exposureMode = .sensor
        let hdrState = MacPhotoEditState(settings: hdr, filmID: "")
        let hdrPreview = try MacAdjustmentTransfer.previewCapture(
            scope: .standard(isHDR: true),
            snapshot: hdrState,
            committed: nil,
            context: .init(identifier: "hdr.jpg", isRaw: false, sourceIsHDR: true)
        )
        XCTAssertTrue(
            hdrPreview.fields == AdjustmentTransferField.hdrCommon && hdrPreview.source.isHDR,
            "Default HDR scope preview captures the seven supported fields"
        )
        XCTAssertTrue(
            try session.clipboard == clipboard && session.transactions.isEmpty && edits.state(for: source) == nil,
            "Scope preview does not change clipboard, history or saved photo records"
        )

        let captured = try MacAdjustmentTransfer.capture(
            scope: .custom([.exposure, .hslHueRed, .blackPoint, .whitePoint, .vibrance, .gradingShadows, .gradingMidtones]),
            snapshot: state,
            context: context
        )
        let preset = try presets.create(name: "Source-independent", payload: captured)
        XCTAssertTrue(
            session.clipboard == clipboard && session.transactions.isEmpty,
            "Saving a preset does not change clipboard or photo history"
        )

        try FileManager.default.removeItem(at: source)
        var initial = Adjustments()
        initial.contrast = 0.9
        initial.saturation = 1.25
        let before = MacPhotoEditState(settings: initial, filmID: "")
        try edits.save(target, state: before)

        let targetContext = MacAdjustmentTransferContext(identifier: target.path, isRaw: true)
        let direct = try MacAdjustmentTransfer.prepare(payload: captured, target: before, context: targetContext)
        let restored = try XCTUnwrap(try AdjustmentPresetStore(directory: presets.directory).list().first)
        XCTAssertTrue(
            restored.payload[.blackPoint] == .number(-32.75) && restored.payload[.whitePoint] == .number(46.5) &&
                restored.payload[.vibrance] == .number(21.25),
            "Preset registry keeps exact tone fields"
        )
        let fromPreset = try MacAdjustmentTransfer.prepare(payload: restored.payload, target: before, context: targetContext)
        XCTAssertEqual(
            fromPreset.settings.gradingSettings,
            settings.gradingSettings,
            "Preset preserves complete grading zones including pending hue"
        )
        XCTAssertEqual(direct, fromPreset, "Preset and clipboard payloads produce identical selected and unselected native values")

        let targets = [AdjustmentTransferTarget(url: target, defaultState: before, context: targetContext)]
        let prepared = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        XCTAssertEqual(
            session.apply(prepared).first?.status,
            .applied,
            "A stored preset applies after its original photo is deleted"
        )
        XCTAssertTrue(
            try edits.state(for: target) == fromPreset && session.clipboard == clipboard,
            "Preset application persists through the common conditional store without replacing clipboard"
        )
        XCTAssertTrue(
            session.transactions.count == 1 && session.transactions[0].action == .preset,
            "Preset application has its own source label in the shared transaction ledger"
        )

        let unchanged = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        XCTAssertTrue(
            session.apply(unchanged).first?.status == .unchanged && session.transactions.count == 1,
            "Repeated preset application is unchanged and creates no second history"
        )
        XCTAssertTrue(
            try session.undoPhoto(target).first?.status == .applied && edits.state(for: target) == before,
            "Single-photo Undo restores the pre-preset state"
        )

        let originalPayload = try MacAdjustmentTransfer.capture(
            scope: .custom([.exposure, .hslHueRed, .blackPoint, .whitePoint, .vibrance, .gradingShadows, .gradingMidtones]),
            snapshot: before,
            context: targetContext
        )
        let noChange = try session.prepare(payload: originalPayload, targets: targets, action: .preset)
        XCTAssertTrue(
            session.apply(noChange).first?.status == .unchanged && session.canRedoPhoto(target),
            "An unchanged preset does not invalidate another transaction's redo"
        )
        XCTAssertTrue(
            try session.redoPhoto(target).first?.status == .applied && edits.state(for: target) == fromPreset,
            "Redo reuses the same successful preset component"
        )

        try presets.delete(preset)
        XCTAssertEqual(try edits.state(for: target), fromPreset, "Deleting a preset never changes a photo that already used it")

        let frozen = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        XCTAssertEqual(
            session.apply(frozen).first?.status,
            .unchanged,
            "An already frozen apply operation does not depend on the preset registry remaining present"
        )

        let missingLook = try AdjustmentTransferPayload(
            source: captured.source,
            values: ["looks.reference": .object(["kind": .string("managed"), "id": .string("missing-look")])]
        )
        let missing = try presets.create(name: "Missing look", payload: missingLook)
        let previous = try edits.readState(for: target)
        let blocked = try session.prepare(payload: missing.payload, targets: targets, action: .preset)
        XCTAssertTrue(
            blocked.targets.first?.error != nil && session.apply(blocked).first?.status == .blocked,
            "Missing preset look is reported by the existing preflight instead of replaced with neutral"
        )
        XCTAssertEqual(try edits.readState(for: target), previous, "Blocked preset application leaves the photo untouched")
    }
}
