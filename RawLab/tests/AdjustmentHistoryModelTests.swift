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
        let summaryLook = directory.appendingPathComponent("summary.cube")
        try Data("fixture".utf8).write(to: summaryLook)
        model.lutMap["summary-look"] = LUTReference(id: "summary-look", name: "Summary look", sourceURL: summaryLook, isCustom: true)
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == "Summary look",
                  "Summary resolves a readable managed look")
        try FileManager.default.removeItem(at: summaryLook)
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == nil,
                  "Summary rejects a deleted look retained in the metadata cache")
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
            settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
            settings.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: Double(step))
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
        settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        model.queueSettingsSave(settings)
        guard let restored = model.cancelAdjustmentInteraction() else { throw NSError(domain: "missing cancel snapshot", code: 1) }
        settings = restored
        try check(settings.exposure == 0.3 && settings.gradingSettings.shadows == ColorGradingWheel(hue: 231.25, saturation: 0) && model.pendingSettings == nil && model.consumePersistedEditorSettings(settings),
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
        try presetCapture(directory: directory)
        try collection(directory: directory)
        try IOSQuickPresetModelChecks.run(directory: directory)
        try IOSBatchFlowModelChecks.preparedSourceChange(directory: directory)
        try IOSBatchFlowModelChecks.launchRequests(directory: directory)
        try recentLookHistory(directory: directory)
        print("PASS: native adjustment history model (\(checks) assertions)")
    }

    private static func recentLookHistory(directory: URL) throws {
        var failWrite = false
        let store = try EditPersistence(directory: directory.appendingPathComponent("look-browser")) { data, url in
            if failWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        let model = RawEditorViewModel(editPersistence: store)
        let identity = PhotoIdentity(resourceIdentifier: "look-browser")
        model.sourceFile = .externallyManaged(directory.appendingPathComponent("source.png"))
        model.sourceIdentity = identity; model.sourceKind = .raster; model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: identity), settings: .default)
        model.availableLUTs = [LUTOption(id: "first", name: "Été"), LUTOption(id: "second", name: "Winter")]
        let firstURL = directory.appendingPathComponent("first.cube"), secondURL = directory.appendingPathComponent("second.cube")
        try Data("fixture".utf8).write(to: firstURL); try Data("fixture".utf8).write(to: secondURL)
        model.lutMap = ["first": LUTReference(id: "first", name: "Été", sourceURL: firstURL, isCustom: true),
                        "second": LUTReference(id: "second", name: "Winter", sourceURL: secondURL, isCustom: true)]
        var settings = RawSettings.default; settings.lutID = "first"
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings) && model.recentLooks.ids == ["first"], "Saved look application updates recent")
        failWrite = true; settings.lutID = "second"; model.queueSettingsSave(settings)
        try check(!model.saveCurrentSettings(settings) && model.recentLooks.ids == ["first"], "Failed look save preserves recent history")
        failWrite = false
        try check(model.saveCurrentSettings(settings) && model.recentLooks.ids == ["second", "first"], "Successful retry records the same applied look")
        let restored = RawEditorViewModel(editPersistence: store)
        try check(restored.recentLooks == model.recentLooks, "Recent look preferences survive model recreation")
        restored.availableLUTs = [LUTOption(id: "first", name: "Renamed"), LUTOption(id: "second", name: "Winter")]
        restored.lutMap = model.lutMap
        try FileManager.default.removeItem(at: secondURL)
        restored.pruneRecentLooks()
        try check(restored.recentLooks.ids == ["first"], "Missing managed bytes are pruned while renamed identity survives")
    }

    private static func collection(directory: URL) throws {
        let store = try EditPersistence(directory: directory.appendingPathComponent("collection-edits"))
        let model = RawEditorViewModel(editPersistence: store)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let file = directory.appendingPathComponent("collection-native.png")
        try image.pngData()!.write(to: file)
        let a = PhotoIdentity(resourceIdentifier: "native-collection-source")
        let b = PhotoIdentity(resourceIdentifier: "native-collection-target")
        model.sourceFile = .externallyManaged(file); model.sourceIdentity = a; model.sourceKind = .raster
        model.sourceDisplayName = "same.png"; model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: a), settings: .default)
        var settings = RawSettings.default; settings.exposure = 0.75
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "collection source saves before synchronization capture")
        model.batchSelection.append(model.currentAdjustmentPhoto!)
        model.batchSelection.append(.init(identity: b, displayName: "same.png", file: .externallyManaged(file), isRaw: false))
        try model.copyAdjustments(scope: .custom([.contrast]), settings: settings)
        let clipboard = model.adjustmentSession?.clipboard
        model.hasAdjustmentDraft = true
        var blocked = false
        do { _ = try model.captureCollectionSynchronization(scope: .custom([.exposure]), settings: settings) } catch { blocked = true }
        try check(blocked, "native collection source draft blocks capture")
        model.hasAdjustmentDraft = false
        let sync = try model.captureCollectionSynchronization(scope: .custom([.exposure]), settings: settings)
        try check(sync.photos.map(\.id) == [b.key] && model.adjustmentSession?.clipboard == clipboard,
                  "native collection capture excludes source and preserves clipboard")
        var prepared: Result<IOSPreparedAdjustmentTransfer, Error>?
        model.prepareAdjustmentPaste(sync.payload, photos: sync.photos, action: .synchronize) { prepared = $0 }
        let deadline = Date().addingTimeInterval(30)
        while prepared == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let prepared else { throw NSError(domain: "collection preparation timed out", code: 1) }
        let operation = try prepared.get()
        let results = model.applyAdjustmentPaste(operation, skipping: [])
        try check(results.map(\.status) == [.applied] && model.batchSelection.selection.lastSynchronization == operation.id,
                  "native synchronization saves target and retains its transaction entry")
        model.sourceIdentity = b; model.sourceRevision = UUID()
        model.acceptImportedEditRecord(try store.versionedState(for: b), settings: settings)
        _ = model.batchSelection.selection.beginEditing(b.key)
        settings.contrast = 0.4; model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "native micro-edit commits only the current collection photo")
        model.batchSelection.selection.returnToCollection()
        try check(model.batchSelection.selection.returnPosition == b.key && model.batchSelection.selection.selected == Set([a.key, b.key])
            && model.batchSelection.selection.lastSynchronization == operation.id, "micro-edit return preserves collection and synchronization history")
        model.hasAdjustmentDraft = true
        let draft = model.batchSelection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: nil, probeHDR: { _ in false },
            validateActive: model.validateCollectionActive, resolveLook: { _ in (nil, nil) })
        try check(!draft.ready && draft.rows.first { $0.id == b.key }?.error != nil, "native export preflight inspects the active editor draft")
        let skipped = model.batchSelection.prepareExport(store: store, skipping: [b.key], format: .jpeg, longEdge: nil, probeHDR: { _ in false },
            validateActive: model.validateCollectionActive, resolveLook: { _ in (nil, nil) })
        try check(skipped.ready && model.hasAdjustmentDraft && model.batchSelection.selection.selected.contains(b.key),
                  "native export Skip preserves the active draft and selection")
        model.hasAdjustmentDraft = false
        let review = model.batchSelection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: nil, probeHDR: { _ in false },
            validateActive: model.validateCollectionActive, resolveLook: { _ in (nil, nil) })
        let journal = try BatchJournalStore(directory: directory.appendingPathComponent("collection-jobs"))
        let job = try model.batchSelection.freeze(review, store: store, journal: journal, validateActive: model.validateCollectionActive)
        settings.exposure = -0.5; model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "editor remains independently editable after freezing")
        let batch = BatchExportModel(job: job, journalStore: journal)
        let bytes = try job.targets.map { try batch.render(target: $0, settings: job.settings(for: $0), look: job.look(for: $0), longEdge: nil) }
        try check(bytes[0] != bytes[1] && job.targets[1].frozen?.settings.exposure == 0.75,
                  "native JPEG rendering retains per-photo contrast and ignores later editor exposure")
    }

    private static func presetCapture(directory: URL) throws {
        var rejectWrite = false
        let store = try EditPersistence(directory: directory.appendingPathComponent("preset-edits"), writeData: { data, url in
            if rejectWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let library = AdjustmentPresetStore(directory: directory.appendingPathComponent("preset-library"))
        let model = RawEditorViewModel(editPersistence: store, presetStore: library)
        let source = directory.appendingPathComponent("preset-source.png")
        try Data([1, 2, 3]).write(to: source)
        let identity = PhotoIdentity(resourceIdentifier: "preset-capture")
        model.sourceFile = .externallyManaged(source); model.sourceIdentity = identity
        model.sourceKind = .raster; model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: identity), settings: .default)
        var settings = RawSettings.default; settings.exposure = 0.75
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "preset source edit commits before capture")
        try model.copyAdjustments(scope: .custom([.contrast]), settings: settings)
        let clipboard = model.adjustmentSession?.clipboard
        let revision = try store.versionedState(for: identity)
        let historyCount = model.adjustmentSession?.transactions.count
        let captured = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: settings)
        _ = try library.create(name: "Native iOS", payload: captured)
        try check(captured.fields == [.exposure] && captured[.exposure]?.number == 0.75,
                  "preset capture uses the exact selected committed values")
        try check(try model.adjustmentSession?.clipboard == clipboard && model.adjustmentSession?.transactions.count == historyCount
                  && store.versionedState(for: identity) == revision,
                  "preset capture and library save leave clipboard, photo receipt and history unchanged")
        model.hasAdjustmentDraft = true
        var rejected = false
        do { _ = try model.capturePresetAdjustments(scope: .all, settings: settings) } catch { rejected = true }
        try check(rejected, "unresolved geometry draft prevents preset capture")
        model.hasAdjustmentDraft = false
        settings.exposure = 1.0; model.queueSettingsSave(settings); rejectWrite = true
        try check(!model.saveCurrentSettings(settings), "preset capture fixture retains failed pending edits")
        rejected = false
        do { _ = try model.capturePresetAdjustments(scope: .all, settings: settings) } catch { rejected = true }
        try check(rejected && model.adjustmentSession?.clipboard == clipboard,
                  "failed pending photo save prevents preset capture without changing clipboard")
        rejectWrite = false
        try check(model.saveCurrentSettings(settings), "preset source can recover through the existing save retry")
        let historyBeforeExternal = model.adjustmentSession?.transactions.map(\.id)
        var external = settings; external.exposure = 1.4
        try store.save(identity, state: PhotoEditState(settings: external))
        let externalReceipt = try store.versionedState(for: identity)
        rejected = false
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: settings) } catch { rejected = true }
        try check(try rejected && store.versionedState(for: identity) == externalReceipt && library.list().count == 1 &&
                  model.adjustmentSession?.clipboard == clipboard && model.adjustmentSession?.transactions.map(\.id) == historyBeforeExternal,
                  "external photo revision blocks preset capture without changing library or history")
        try check(model.adjustmentReloadRequired, "stale preset capture offers explicit saved-adjustment reload")
        model.acceptImportedEditRecord(externalReceipt, settings: external)
        settings = external
        var uncommitted = settings; uncommitted.exposure = 1.8
        rejected = false
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: uncommitted) } catch { rejected = true }
        try check(rejected, "pure preset capture rejects values outside the committed snapshot")
        try Data([4, 5, 6, 7]).write(to: source)
        rejected = false
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: settings) } catch { rejected = true }
        try check(try rejected && library.list().count == 1 && model.adjustmentSession?.clipboard == clipboard,
                  "changed source identity blocks capture and preserves the existing library")
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
        let lens = try AdjustmentTransferPayload(source: .init(identifier: "raw-source", isRaw: true, processingVersion: 2, recipe: nil),
            values: ["geometry.lens.profile_id": .string("fixture-profile")])
        var pendingLens: Result<IOSPreparedAdjustmentTransfer, Error>?
        model.prepareAdjustmentPaste(lens, photos: [.init(identity: goodID, displayName: "valid", file: .externallyManaged(png), isRaw: false)]) { pendingLens = $0 }
        let lensDeadline = Date().addingTimeInterval(30)
        while pendingLens == nil && Date() < lensDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let lensResult = pendingLens else { throw NSError(domain: "lens preflight timed out", code: 1) }
        let lensOperation = try lensResult.get()
        try check(lensOperation.targets.first?.error != nil, "actual raster target blocks an inactive explicit lens profile")
        let lensOutcome = model.applyAdjustmentPaste(lensOperation, skipping: [])
        let afterLens = try store.versionedState(for: goodID)
        try check(lensOutcome.first?.status == .blocked && afterLens == saved,
                  "blocked inactive lens request preserves the raster receipt")

    }
}
