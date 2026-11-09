import AppKit
import SwiftUI

@main struct ProcessingMigrationInputTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }

    static func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(condition(), "Migration callback completed within its test deadline")
    }

    static func model(root: URL, photo: URL, name: String) throws -> EditorModel {
        let directory = root.appendingPathComponent(name)
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"))
        var old = Adjustments(); old.processing = .c5
        model.updatingMetadata = true
        model.file = photo; model.settings = old
        model.updatingMetadata = false
        try model.editStore!.save(photo, state: PhotoEditState(settings: old, filmID: ""))
        model.committedEdit = try model.editStore!.readState(for: photo)
        model.result = try RenderEngine().render(photo, settings: old, lut: nil, edge: nil)
        model.dirty = false
        return model
    }

    static func draft(_ model: EditorModel) -> (ParameterValueField, NumericTextField, ParameterValueField.Coordinator) {
        let parent = ParameterValueField(value: Binding(get: { model.settings.contrast }, set: { model.settings.contrast = $0 }),
            range: -100...100, precision: .standard, title: "Contrast", unit: "%", identifier: "value.contrast")
        let field = NumericTextField()
        field.cell = NumericTextFieldCell(textCell: "")
        let coordinator = ParameterValueField.Coordinator(parent)
        coordinator.field = field
        coordinator.update(parent, isEnabled: true)
        coordinator.editing = true
        field.stringValue = "+37"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        return (parent, field, coordinator)
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        let pixels = Data(repeating: 128, count: 8 * 6 * 3)
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Created a deterministic raster fixture")

        let control = try model(root: root, photo: photo, name: "control")
        control.startProcessingMigrationIfNeeded()
        try check(control.matchingProcessing, "Eligible old edit starts migration without a draft")
        try wait { !control.matchingProcessing && !control.busy }
        try check(control.settings.processing == .current, "The fixture completes a real accepted migration")

        if CommandLine.arguments.last != "completion" {
            let entry = try model(root: root, photo: photo, name: "entry")
            let (_, field, coordinator) = draft(entry)
            defer { coordinator.cancel() }
            try check(ParameterValueField.hasPendingInputs && !entry.dirty && !entry.scheduler.interacting,
                "Uncommitted text exists without a model edit or adjustment gesture")
            entry.startProcessingMigrationIfNeeded()
            let started = entry.matchingProcessing
            entry.cancelProcessingMigration()
            try check(!started && field.stringValue == "+37" && coordinator.dirty,
                "Pending numeric text prevents automatic migration from starting")
        }

        if CommandLine.arguments.last != "entry" {
            let completing = try model(root: root, photo: photo, name: "completion")
            let expected = completing.committedEdit
            EditorModel.processingMigrationQueue.suspend()
            completing.startProcessingMigrationIfNeeded()
            let started = completing.matchingProcessing
            let (parent, field, coordinator) = draft(completing)
            EditorModel.processingMigrationQueue.resume()
            defer { coordinator.cancel() }
            try check(started, "Migration was queued before the numeric draft began")
            try wait { !completing.matchingProcessing }
            coordinator.update(parent, isEnabled: true)
            try check(completing.settings.processing == .c5 && completing.committedEdit == expected &&
                completing.editStore!.readState(for: photo) == expected &&
                completing.editStore!.processingMigration(for: photo) == nil,
                "A draft entered during fitting prevents candidate and receipt publication")
            try check(field.stringValue == "+37" && coordinator.dirty,
                "Completing background work preserves uncommitted numeric text")
        }
    }
}
