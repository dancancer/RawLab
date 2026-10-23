import Foundation
import UIKit

@main
struct AdjustmentHistoryModelTests {
    private static var checks = 0
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: message, code: 1) }
        checks += 1
        print("PASS: \(message)")
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = directory.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        var rejectWrite = false
        let store = try EditPersistence(directory: directory.appendingPathComponent("store"), writeData: { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let model = RawEditorViewModel(editPersistence: store)
        let identity = PhotoIdentity(resourceIdentifier: "native-history-a")
        model.sourceFile = .externallyManaged(source)
        model.sourceIdentity = identity
        model.sourceKind = .raster
        model.sourceDisplayName = "A"
        model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: identity), settings: .default)
        var settings = RawSettings.default
        try check(model.beginAdjustmentInteraction(settings: settings), "gesture begins with an accepted storage revision")
        for step in 1...30 {
            settings.exposure = Double(step) / 100
            model.queueSettingsSave(settings)
        }
        try check(model.editSaveWork == nil && store.state(for: identity) == nil,
                  "gesture previews never schedule debounce writes")
        try check(model.endAdjustmentInteraction(settings: settings), "gesture ending saves its final value")
        try check(model.adjustmentSession?.transactions.count == 1 && store.state(for: identity)?.settings == settings,
                  "one gesture creates exactly one transaction")
        let revision = try store.versionedState(for: identity)
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings) && model.adjustmentSession?.transactions.count == 1,
                  "late SwiftUI value echo does not create a duplicate history entry")
        try check(try store.versionedState(for: identity) == revision, "unchanged echo preserves timestamp and revision")
        try check(model.beginAdjustmentInteraction(settings: settings), "second gesture begins")
        settings.exposure = 0.9
        model.queueSettingsSave(settings)
        guard let restored = model.cancelAdjustmentInteraction() else { throw NSError(domain: "missing cancel snapshot", code: 1) }
        settings = restored
        try check(settings.exposure == 0.3 && model.pendingSettings == nil && model.consumePersistedEditorSettings(settings),
                  "cancel restores the exact gesture start and consumes the observer echo")
        try check(try store.versionedState(for: identity) == revision, "cancel does not write or record history")
        let undo = model.performAdjustmentHistory(undo: true)
        try check(undo.count == 1 && undo[0].status == .applied && model.adjustmentRestoredSettings == .default,
                  "undo restores the absent original and publishes default editor settings")
        try check(store.state(for: identity) == nil, "undo restores record absence")
        _ = model.performAdjustmentHistory(undo: false)
        try check(store.state(for: identity)?.settings.exposure == 0.3,
                  "redo restores the successfully committed gesture")
        model.adjustmentRestoredSettings = nil
        try check(model.beginAdjustmentInteraction(settings: settings), "failed gesture begins")
        settings.exposure = 0.6
        model.queueSettingsSave(settings)
        rejectWrite = true
        try check(!model.endAdjustmentInteraction(settings: settings) && model.pendingSettings == settings,
                  "failed gesture save retains the current edit for retry")
        try check(model.adjustmentSession?.transactions.count == 1 && store.state(for: identity)?.settings.exposure == 0.3,
                  "failed save does not add history or change persistence")
        rejectWrite = false
        try check(model.saveCurrentSettings(settings) && model.adjustmentSession?.transactions.count == 2,
                  "retry saves exactly one new successful transaction")
        var external = settings; external.exposure = 0.8
        try store.save(identity, state: PhotoEditState(settings: external))
        settings.exposure = 1.0
        model.queueSettingsSave(settings)
        try check(!model.saveCurrentSettings(settings) && store.state(for: identity)?.settings.exposure == 0.8,
                  "ordinary edits retain their original CAS receipt and cannot overwrite an external edit")
        try check(model.adjustmentSession?.transactions.count == 2, "CAS rejection creates no transaction")
        try check(model.reloadSavedAdjustments() && model.pendingSettings == nil && model.adjustmentRestoredSettings == external,
                  "explicit reload abandons stale pending edits and restores the external saved record")
        try check(try model.loadedEditRecord == store.versionedState(for: identity), "explicit reload accepts the fresh CAS receipt")
        try check(model.beginAdjustmentInteraction(settings: external), "new source context can start a gesture")
        model.sourceRevision = UUID()
        try check(model.cancelAdjustmentInteraction() == nil, "stale gesture cancellation cannot restore another source context")
        try model.copyAdjustments(scope: .custom([.exposure, .hslHueRed]), settings: external)
        try check(model.adjustmentSession?.clipboard?[.exposure]?.number == external.exposure &&
                  model.adjustmentSession?.clipboard?.fields == [.exposure, .hslHueRed],
                  "native editor captures exactly the requested exposure and HSL fields")
        try preflight(model, store: store, directory: directory)
        try cancelledImportMetadata(directory: directory)
        print("PASS: native adjustment history model (\(checks) assertions)")
    }

    private static func cancelledImportMetadata(directory: URL) throws {
        let store = try EditPersistence(directory: directory.appendingPathComponent("cancel-store"))
        let identity = PhotoIdentity(resourceIdentifier: "cancel-original"), other = PhotoIdentity(resourceIdentifier: "cancel-other")
        var settings = RawSettings.default; settings.lutID = "retained-unavailable-look"
        let state = PhotoEditState(settings: settings).replacing(settings: settings, preservingFilmID: nil)
        try store.save(identity, state: state)
        let before = try store.versionedState(for: identity)
        let queue = DispatchQueue(label: "cancelled-import-metadata")
        var deliveries: [() -> Void] = []
        let model = RawEditorViewModel(editPersistence: store, importQueue: queue, resultDelivery: { deliveries.append($0) })
        let png = directory.appendingPathComponent("valid.png")
        model.sourceFile = .externallyManaged(png)
        model.sourceIdentity = identity; model.sourceKind = .raster; model.hasImage = true
        model.currentPreviewSettings = settings; model.committedPreviewSettings = settings
        model.acceptImportedEditRecord(before, settings: settings)
        queue.suspend()
        let request = model.importImage(from: .raster(png), identity: other)
        model.cancelImageImport(request)
        queue.resume(); queue.sync {}
        deliveries.forEach { $0() }
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "retained photo remains editable after cancelling a new import")
        try check(try store.versionedState(for: identity) == before && model.adjustmentSession?.transactions.isEmpty == true,
                  "cancelled import retains explicit nil metadata without a false edit transaction")
        settings.exposure = 0.2
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings) && store.state(for: identity)?.filmID == nil && store.state(for: other) == nil,
                  "scalar save after cancelled import keeps the original receipt, identity and nil film metadata")
    }

    private static func preflight(_ model: RawEditorViewModel, store: EditPersistence, directory: URL) throws {
        let png = directory.appendingPathComponent("valid.png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        try image.pngData()!.write(to: png)
        let bad = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: bad)
        let goodID = PhotoIdentity(resourceIdentifier: "valid-target"), badID = PhotoIdentity(resourceIdentifier: "invalid-target")
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "source", isRaw: false, processingVersion: 2, recipe: nil),
                                                    values: ["light.exposure": .number(0.4)])
        var result: Result<IOSPreparedAdjustmentTransfer, Error>?
        model.prepareAdjustmentPaste(payload, photos: [
            .init(identity: goodID, displayName: "valid", file: .externallyManaged(png), isRaw: false),
            .init(identity: badID, displayName: "invalid", file: .externallyManaged(bad), isRaw: false)
        ]) { result = $0 }
        let deadline = Date().addingTimeInterval(30)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let result else { throw NSError(domain: "preflight timed out", code: 1) }
        let operation = try result.get()
        try check(operation.targets.first { $0.id == goodID.key }?.error == nil, "actual display decoder accepts valid target pixels")
        try check(operation.targets.first { $0.id == badID.key }?.error != nil, "preflight rejects an undecodable target before any persistence")
        let blocked = model.applyAdjustmentPaste(operation, skipping: [])
        try check(blocked.allSatisfy { $0.status == .blocked } && store.state(for: goodID) == nil,
                  "one invalid target prevents default application to every target")
        let applied = model.applyAdjustmentPaste(operation, skipping: [badID.key])
        try check(applied.first { $0.targetID == goodID.key }?.status == .applied && store.state(for: badID) == nil,
                  "explicit skip applies only the compatible target")
        let saved = try store.versionedState(for: goodID)
        _ = model.applyAdjustmentPaste(operation, skipping: [badID.key])
        try check(try store.versionedState(for: goodID) == saved, "successful target is not rewritten on retry")
    }
}
