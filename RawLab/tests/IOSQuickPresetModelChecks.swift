import Foundation
import UIKit

enum IOSQuickPresetModelChecks {
    static func run(directory: URL) throws {
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw NSError(domain: message, code: 1) }
            print("PASS: quick preset \(message)")
        }
        func wait(_ predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            try check(predicate(), "asynchronous operation completed")
        }
        let file = directory.appendingPathComponent("quick-preset.png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        try image.pngData()!.write(to: file)
        var rejectWrite = false
        let store = try EditPersistence(directory: directory.appendingPathComponent("quick-store"), writeData: { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let model = RawEditorViewModel(editPersistence: store)
        let identity = PhotoIdentity(resourceIdentifier: "quick-preset-source")
        model.sourceFile = .externallyManaged(file); model.sourceIdentity = identity
        model.sourceKind = .raster; model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: identity), settings: .default)
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "fixture", isRaw: false,
            processingVersion: 2, recipe: nil), values: ["light.exposure": .number(0.7)])
        let presets = AdjustmentPresetStore(directory: directory.appendingPathComponent("quick-presets"))
        let preset = try presets.create(name: "Quick exposure", payload: payload)
        model.quickPresetsVisible = true
        model.applyPresetToCurrentPhoto(preset, settings: .default)
        try wait { !model.quickPresetState.isPreparing }
        guard case .saved(_, let transaction) = model.quickPresetState else { throw NSError(domain: "quick preset did not save: \(String(describing: model.quickPresetState))", code: 1) }
        try check(store.state(for: identity)?.settings.exposure == 0.7, "one click saves the prepared value")
        try check(model.adjustmentSession?.transactions.count == 1 && model.adjustmentSession?.transactions.first?.action == .preset,
                  "exactly one transaction uses the preset action")
        _ = model.performAdjustmentHistory(undo: true)
        guard case .idle = model.quickPresetState else { throw NSError(domain: "global undo must dismiss the previous quick preset result", code: 1) }
        try check(model.quickPresetsVisible && store.state(for: identity) == nil, "global undo preserves preset browsing and restores the photo")
        _ = model.performAdjustmentHistory(undo: false)
        let saved = try store.versionedState(for: identity)
        model.applyPresetToCurrentPhoto(preset, settings: saved.state!.settings)
        try wait { !model.quickPresetState.isPreparing }
        guard case .unchanged = model.quickPresetState else { throw NSError(domain: "unchanged not reported", code: 1) }
        try check(try store.versionedState(for: identity) == saved && model.adjustmentSession?.transactions.count == 1,
                  "unchanged preserves the receipt and history")
        model.quickPresetState = .saved(preset, transaction)
        model.undoQuickPreset(settings: saved.state!.settings)
        guard case .undone = model.quickPresetState else { throw NSError(domain: "undo not reported", code: 1) }
        try check(store.state(for: identity) == nil && model.canRedoAdjustment, "undo restores record absence")
        let zero = try presets.create(name: "No change", payload: AdjustmentTransferPayload(source: payload.source, values: ["light.exposure": .number(0)]))
        model.applyPresetToCurrentPhoto(zero, settings: .default)
        try wait { !model.quickPresetState.isPreparing }
        try check(model.canRedoAdjustment, "no change preserves existing redo")

        func lateRequest(_ invalidate: () throws -> Void, _ message: String) throws {
            let before = try store.versionedState(for: identity)
            let count = model.adjustmentSession!.transactions.count
            model.quickPresetsVisible = true
            model.adjustmentQueue.suspend()
            model.applyPresetToCurrentPhoto(preset, settings: before.state?.settings ?? .default)
            try check(model.quickPresetState.isPreparing, "enters checking before \(message)")
            model.applyPresetToCurrentPhoto(preset, settings: before.state?.settings ?? .default)
            try invalidate()
            let drained = DispatchSemaphore(value: 0)
            model.adjustmentQueue.async { drained.signal() }
            model.adjustmentQueue.resume()
            var complete = false
            try wait { if !complete { complete = drained.wait(timeout: .now()) == .success }; return complete }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try check(try store.versionedState(for: identity) == before && model.adjustmentSession!.transactions.count == count,
                      "\(message) discards late preparation without writing")
        }
        try lateRequest({ model.cancelQuickPreset() }, "cancel")
        try lateRequest({ model.closeQuickPresets() }, "close panel")
        try lateRequest({ model.sourceRevision = UUID() }, "source revision change")
        try lateRequest({ model.queueSettingsSave(.default) }, "later ordinary input")
        _ = model.saveCurrentSettings(.default)
        model.quickPresetsVisible = true
        rejectWrite = true
        model.applyPresetToCurrentPhoto(preset, settings: .default)
        try wait { !model.quickPresetState.isPreparing }
        guard case .failed = model.quickPresetState else { throw NSError(domain: "failed save reported success", code: 1) }
        try check(store.state(for: identity) == nil, "save failure preserves original")
        rejectWrite = false
        model.applyPresetToCurrentPhoto(preset, settings: .default)
        try wait { !model.quickPresetState.isPreparing }
        guard case .saved(_, let latest) = model.quickPresetState else { throw NSError(domain: "retry did not save", code: 1) }
        var later = store.state(for: identity)!.settings; later.contrast = 0.4
        model.queueSettingsSave(later); try check(model.saveCurrentSettings(later), "ordinary edit after preset saves")
        let ordinary = try store.versionedState(for: identity)
        model.quickPresetState = .saved(preset, latest)
        model.undoQuickPreset(settings: later)
        guard case .undoFailed = model.quickPresetState else { throw NSError(domain: "stale undo not reported", code: 1) }
        try check(try store.versionedState(for: identity) == ordinary, "stale undo cannot undo unrelated editing")

        model.adjustmentQueue.suspend()
        model.applyPresetToCurrentPhoto(zero, settings: later)
        var external = later; external.exposure = 1.2
        try store.save(identity, state: PhotoEditState(settings: external))
        model.adjustmentQueue.resume()
        try wait { !model.quickPresetState.isPreparing }
        guard case .failed = model.quickPresetState else { throw NSError(domain: "external edit not rejected", code: 1) }
        try check(store.state(for: identity)?.settings == external, "external edits cannot be overwritten")
    }
}
