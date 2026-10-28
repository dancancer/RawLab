import Foundation

private func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: \(label)")
}

@main struct AdjustmentPresetApplicationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetApply-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ARW"), target = root.appendingPathComponent("target.ARW")
        try Data([1, 2, 3]).write(to: source); try Data([4, 5, 6]).write(to: target)
        let edits = try EditPersistence(directory: root.appendingPathComponent("edits"))
        let session = AdjustmentTransferSession(store: edits)
        let presets = AdjustmentPresetStore(directory: root.appendingPathComponent("presets"))
        var settings = Adjustments(); settings.exposure = 1.25; settings.contrast = 35
        settings.blackPoint = -32.75; settings.whitePoint = 46.5; settings.vibrance = 21.25
        settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        settings.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        settings.hsl = HSLSettings(); settings.hsl!.setExact(.hue, channel: 0, value: 37.25)
        let state = PhotoEditState(settings: settings, filmID: "")
        let context = MacAdjustmentTransferContext(identifier: source.path, isRaw: true)
        let clipboard = try session.copy(scope: .custom([.contrast]), snapshot: state, context: context)
        let captured = try MacAdjustmentTransfer.capture(scope: .custom([.exposure, .hslHueRed, .blackPoint, .whitePoint, .vibrance, .gradingShadows, .gradingMidtones]), snapshot: state, context: context)
        let preset = try presets.create(name: "Source-independent", payload: captured)
        try check(session.clipboard == clipboard && session.transactions.isEmpty, "Saving a preset does not change clipboard or photo history")
        try FileManager.default.removeItem(at: source)
        var initial = Adjustments(); initial.contrast = -10; initial.saturation = 25
        let before = PhotoEditState(settings: initial, filmID: "")
        try edits.save(target, state: before)
        let targetContext = MacAdjustmentTransferContext(identifier: target.path, isRaw: true)
        let direct = try MacAdjustmentTransfer.prepare(payload: captured, target: before, context: targetContext)
        let restored = try AdjustmentPresetStore(directory: presets.directory).list().first!
        try check(restored.payload[.blackPoint] == .number(-32.75) && restored.payload[.whitePoint] == .number(46.5)
            && restored.payload[.vibrance] == .number(21.25), "Preset registry keeps exact tone fields")
        let fromPreset = try MacAdjustmentTransfer.prepare(payload: restored.payload, target: before, context: targetContext)
        try check(fromPreset.settings.gradingSettings == settings.gradingSettings, "Preset preserves complete grading zones including pending hue")
        try check(direct == fromPreset, "Preset and clipboard payloads produce identical selected and unselected native values")
        let targets = [AdjustmentTransferTarget(url: target, defaultState: before, context: targetContext)]
        let prepared = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        try check(session.apply(prepared).first?.status == .applied, "A stored preset applies after its original photo is deleted")
        try check(edits.state(for: target) == fromPreset && session.clipboard == clipboard, "Preset application persists through the common conditional store without replacing clipboard")
        try check(session.transactions.count == 1 && session.transactions[0].action == .preset, "Preset application has its own source label in the shared transaction ledger")
        let unchanged = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        try check(session.apply(unchanged).first?.status == .unchanged && session.transactions.count == 1, "Repeated preset application is unchanged and creates no second history")
        try check(session.undoPhoto(target).first?.status == .applied && edits.state(for: target) == before, "Single-photo Undo restores the pre-preset state")
        let originalPayload = try MacAdjustmentTransfer.capture(scope: .custom([.exposure, .hslHueRed, .blackPoint, .whitePoint, .vibrance, .gradingShadows, .gradingMidtones]), snapshot: before, context: targetContext)
        let noChange = try session.prepare(payload: originalPayload, targets: targets, action: .preset)
        try check(session.apply(noChange).first?.status == .unchanged && session.canRedoPhoto(target), "An unchanged preset does not invalidate another transaction's redo")
        try check(session.redoPhoto(target).first?.status == .applied && edits.state(for: target) == fromPreset, "Redo reuses the same successful preset component")
        try presets.delete(preset)
        try check(edits.state(for: target) == fromPreset, "Deleting a preset never changes a photo that already used it")
        let frozen = try session.prepare(payload: restored.payload, targets: targets, action: .preset)
        try check(session.apply(frozen).first?.status == .unchanged, "An already frozen apply operation does not depend on the preset registry remaining present")
        let missingLook = try AdjustmentTransferPayload(source: captured.source,
            values: ["looks.reference": .object(["kind": .string("managed"), "id": .string("missing-look")])])
        let missing = try presets.create(name: "Missing look", payload: missingLook)
        let previous = try edits.versionedState(for: target)
        let blocked = try session.prepare(payload: missing.payload, targets: targets, action: .preset)
        try check(blocked.targets.first?.error != nil && session.apply(blocked).first?.status == .blocked,
            "Missing preset look is reported by the existing preflight instead of replaced with neutral")
        try check(edits.versionedState(for: target) == previous, "Blocked preset application leaves the photo untouched")
        print("PASS: preset source independence, clipboard isolation, equality, persistence and shared history")
    }
}
