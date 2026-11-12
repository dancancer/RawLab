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
        model.acceptImportedEditRecord(try store.readState(for: identity), settings: .default)
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
        let revision = try store.readState(for: identity)
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings) && model.adjustmentSession?.transactions.count == 1,
                  "late SwiftUI value echo does not create a duplicate history entry")
        try check(store.readState(for: identity).hasSameAdjustments(as: revision), "unchanged echo preserves the committed record")
        try check(model.beginAdjustmentInteraction(settings: settings), "second gesture begins")
        settings.exposure = 0.9
        settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        model.queueSettingsSave(settings)
        guard let restored = model.cancelAdjustmentInteraction() else { throw NSError(domain: "missing cancel snapshot", code: 1) }
        settings = restored
        try check(settings.exposure == 0.3 && settings.gradingSettings.shadows == ColorGradingWheel(hue: 231.25, saturation: 0) && model.pendingSettings == nil && model.consumePersistedEditorSettings(settings),
                  "cancel restores the exact gesture start and consumes the observer echo")
        try check(store.readState(for: identity).hasSameAdjustments(as: revision), "cancel does not write or record history")
        let undo = model.performAdjustmentHistory(undo: true)
        try check(undo.count == 1, "undo returns exactly one photo outcome")
        try check(undo[0].status == .applied, "undo applies the original gesture transaction")
        var rasterDefaults = RawSettings.default
        rasterDefaults.exposureMode = .sensor
        try check(model.adjustmentRestoredSettings == rasterDefaults,
                  "undo publishes the complete raster defaults with sensor exposure")
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
        try check(model.saveCurrentSettings(settings) && store.state(for: identity)?.settings.exposure == 1.0,
                  "ordinary edits remain usable and replace an external saved value")
        try check(model.adjustmentSession?.transactions.count == 3, "ordinary replacement records one new transaction")
        try check(model.beginAdjustmentInteraction(settings: settings), "new source context can start a gesture")
        model.sourceRevision = UUID()
        try check(model.cancelAdjustmentInteraction() == nil, "stale gesture cancellation cannot restore another source context")
        try model.copyAdjustments(scope: .custom([.exposure, .hslHueRed]), settings: external)
        try check(model.adjustmentSession?.clipboard?[.exposure]?.number == external.exposure &&
                  model.adjustmentSession?.clipboard?.fields == [.exposure, .hslHueRed],
                  "native editor captures exactly the requested exposure and HSL fields")
        try storageRecovery(directory: directory)
        try discardPendingSave(directory: directory)
        try preflight(model, store: store, directory: directory)
        try cancelledImportMetadata(directory: directory)
        try presetCapture(directory: directory)
        try collection(directory: directory)
        try IOSQuickPresetModelChecks.run(directory: directory)
        try IOSBatchFlowModelChecks.preparedSourceChange(directory: directory)
        try IOSBatchFlowModelChecks.launchRequests(directory: directory)
        try recentLookHistory(directory: directory)
        try processingMigrationReset(directory: directory)
        print("PASS: native adjustment history model (\(checks) assertions)")
    }

    private static func storageRecovery(directory: URL) throws {
        let store = try EditPersistence(directory: directory.appendingPathComponent("recovered-store"))
        let identity = PhotoIdentity(resourceIdentifier: "recovered-photo")
        // SDR 对比度保存为倍率，界面上的 +12 对应 1.12。
        var saved = RawSettings.default; saved.exposure = 0.7; saved.contrast = 1.12
        try store.save(identity, state: PhotoEditState(settings: saved))
        let model = RawEditorViewModel(editPersistence: store)
        model.sourceFile = .externallyManaged(directory.appendingPathComponent("source.png"))
        model.sourceIdentity = identity; model.sourceKind = .raster; model.hasImage = true
        model.editPersistence = nil; model.adjustmentSession = nil
        model.openEditPersistence = { store }
        model.acceptImportedEditRecord(nil, settings: .default)
        model.retrySave(settings: .default)
        try check(model.adjustmentRestoredSettings == saved && model.loadedEditRecord?.state?.settings == saved,
                  "recovering an unread store restores saved settings before the next edit")
        var next = model.adjustmentRestoredSettings!; next.exposure = 0.9
        model.queueSettingsSave(next)
        try check(model.saveCurrentSettings(next), "the first edit after recovery saves successfully")
        try check(store.readState(for: identity).state?.settings == next,
                  "the first edit after recovery preserves other saved adjustments")
        try check(model.performAdjustmentHistory(undo: true).first?.status == .applied &&
                  store.readState(for: identity).state?.settings == saved && model.adjustmentRestoredSettings == saved,
                  "recovered history retains the real saved before state")

        model.editPersistence = nil; model.adjustmentSession = nil
        model.acceptImportedEditRecord(nil, settings: .default)
        var pending = RawSettings.default; pending.exposure = 1.1
        model.queueSettingsSave(pending)
        model.openEditPersistence = { throw CocoaError(.fileReadNoPermission) }
        model.retrySave(settings: pending)
        try check(model.pendingSettings == pending && store.state(for: identity)?.settings == saved,
                  "failed store recovery preserves pending edits and the existing disk record")
        model.openEditPersistence = { store }
        model.retrySave(settings: pending)
        try check(model.pendingSettings == nil && store.state(for: identity)?.settings == pending,
                  "retry reopens the unavailable store even with pending edits")
        try check(model.performAdjustmentHistory(undo: true).first?.status == .applied &&
                  store.state(for: identity)?.settings == saved,
                  "retrying unread edits preserves the original saved adjustments in undo")
    }

    private static func discardPendingSave(directory: URL) throws {
        let store = try EditPersistence(directory: directory.appendingPathComponent("discard-store"))
        let identity = PhotoIdentity(resourceIdentifier: "discard-photo")
        var saved = RawSettings.default; saved.exposure = 0.4
        try store.save(identity, state: PhotoEditState(settings: saved))
        let record = try store.readState(for: identity)
        let model = RawEditorViewModel(editPersistence: store)
        model.sourceFile = .externallyManaged(directory.appendingPathComponent("source.png"))
        model.sourceIdentity = identity; model.sourceKind = .raster; model.hasImage = true
        model.acceptImportedEditRecord(record, settings: saved)
        var pending = saved; pending.exposure = 1.2
        model.queueSettingsSave(pending)
        model.failedDraftSource = model.editorEditSource
        model.hasAdjustmentDraft = true
        model.editSaveState = .failed("injected draft failure")
        // 放弃失败草稿会重新排入普通保存；恢复已保存参数必须取消它。
        model.discardDraftSaveFailure(settings: pending)
        let restored = try model.restoreCommittedSettings()
        try check(restored == saved && model.pendingSettings == nil && model.editSaveWork == nil &&
                  !model.hasFailedDraftSave && model.adjustmentTargetIsCurrent(identity.key),
                  "discard clears queued, pending and failed state for collection operations")
        try check(model.consumePersistedEditorSettings(restored), "discard consumes the UI settings echo")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try check(store.readState(for: identity) == record && model.adjustmentSession?.transactions.isEmpty == true,
                  "discarded values cannot be saved later by the debounce callback")
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
        model.acceptImportedEditRecord(try store.readState(for: identity), settings: .default)
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
        model.acceptImportedEditRecord(try store.readState(for: a), settings: .default)
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
        model.acceptImportedEditRecord(try store.readState(for: b), settings: settings)
        _ = model.batchSelection.selection.beginEditing(b.key)
        settings.contrast = 0.4; model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "native micro-edit commits only the current collection photo")
        model.batchSelection.selection.returnToCollection()
        try check(model.batchSelection.selection.returnPosition == b.key && model.batchSelection.selection.selected == Set([a.key, b.key])
            && model.batchSelection.selection.lastSynchronization == operation.id, "micro-edit return preserves collection and synchronization history")
        model.hasAdjustmentDraft = true
        let draft = model.batchSelection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: nil, x3fDefaultMode: { _ in .legacy }, probeHDR: { _ in false },
            validateActive: model.validateCollectionActive, resolveLook: { _ in (nil, nil) })
        try check(!draft.ready && draft.rows.first { $0.id == b.key }?.error != nil, "native export preflight inspects the active editor draft")
        let skipped = model.batchSelection.prepareExport(store: store, skipping: [b.key], format: .jpeg, longEdge: nil, x3fDefaultMode: { _ in .legacy }, probeHDR: { _ in false },
            validateActive: model.validateCollectionActive, resolveLook: { _ in (nil, nil) })
        try check(skipped.ready && model.hasAdjustmentDraft && model.batchSelection.selection.selected.contains(b.key),
                  "native export Skip preserves the active draft and selection")
        model.hasAdjustmentDraft = false
        let review = model.batchSelection.prepareExport(store: store, skipping: [], format: .jpeg, longEdge: nil, x3fDefaultMode: { _ in .legacy }, probeHDR: { _ in false },
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
        model.acceptImportedEditRecord(try store.readState(for: identity), settings: .default)
        var settings = RawSettings.default; settings.exposure = 0.75
        model.queueSettingsSave(settings)
        try check(model.saveCurrentSettings(settings), "preset source edit commits before capture")
        try model.copyAdjustments(scope: .custom([.contrast]), settings: settings)
        let clipboard = model.adjustmentSession?.clipboard
        let revision = try store.readState(for: identity)
        let historyCount = model.adjustmentSession?.transactions.count
        let captured = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: settings)
        _ = try library.create(name: "Native iOS", payload: captured)
        try check(captured.fields == [.exposure] && captured[.exposure]?.number == 0.75,
                  "preset capture uses the exact selected committed values")
        try check(try model.adjustmentSession?.clipboard == clipboard && model.adjustmentSession?.transactions.count == historyCount
                  && store.readState(for: identity).hasSameAdjustments(as: revision),
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
        let externalReceipt = try store.readState(for: identity)
        var capturedExternal: AdjustmentTransferPayload?
        rejected = false
        do { capturedExternal = try model.capturePresetAdjustments(scope: .custom([.exposure]), settings: settings) } catch { rejected = true }
        try check(!rejected && capturedExternal?[.exposure]?.number == settings.exposure && store.readState(for: identity).state?.settings.exposure == 1.4 && library.list().count == 1 &&
                  model.adjustmentSession?.clipboard == clipboard && model.adjustmentSession?.transactions.map(\.id) == historyBeforeExternal,
                  "external disk edits do not block preset capture from the session's committed snapshot")
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
        let before = try store.readState(for: identity)
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
        try check(store.readState(for: identity).hasSameAdjustments(as: before) && model.adjustmentSession?.transactions.isEmpty == true,
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
        let saved = try store.readState(for: goodID)
        _ = model.applyAdjustmentPaste(operation, skipping: [badID.key])
        try check(store.readState(for: goodID).hasSameAdjustments(as: saved), "successful target is not rewritten on retry")
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
        let afterLens = try store.readState(for: goodID)
        try check(lensOutcome.first?.status == .blocked && afterLens.hasSameAdjustments(as: saved),
                  "blocked inactive lens request preserves the raster receipt")

    }

    private static func processingMigrationReset(directory: URL) throws {
        let storeRoot = directory.appendingPathComponent("migration-reset-model")
        var rejectResetWrite = false
        let store = try EditPersistence(directory: storeRoot, writeData: { data, url in
            if rejectResetWrite { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let model = RawEditorViewModel(editPersistence: store)
        let source = directory.appendingPathComponent("migration-reset.png")
        try Data([1, 2, 3, 4]).write(to: source)
        let identity = PhotoIdentity(resourceIdentifier: "model-reset-asset", contentIdentifier: "model-reset-bytes")
        var old = RawSettings.default; old.processing = .c5; old.exposure = 0.6; old.contrast = 1.15
        let original = PhotoEditState(settings: old, filmID: "legacy-film", updatedAt: Date(timeIntervalSince1970: 20))
        try store.save(identity, state: original)
        var newer = old; newer.processing = .current
        let migrated = original.replacing(settings: newer, preservingFilmID: original.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002,
                                                 detailRMSE: 0.001, evaluations: 20)
        let accepted = try store.commitProcessingMigration(expected: store.readState(for: identity),
                                                           candidate: migrated, quality: quality)
        model.sourceFile = .externallyManaged(source)
        model.sourceIdentity = identity
        model.sourceKind = .raw
        model.sourceDisplayName = "MigrationReset"
        model.hasImage = true
        model.acceptImportedEditRecord(accepted, settings: newer)
        model.adjustmentSession?.adoptProcessingMigration(accepted)
        model.processingMigrationReceipt = try store.processingMigration(for: identity)
        try check(model.processingMigrationReceipt?.status == .migrated && model.processingMigrationStatus != nil,
                  "imported migrated photo exposes processingMigrationReceipt in RawEditorViewModel")

        let draft = EditorDraftSnapshot(geometry: nil, lens: nil, tool: .film)
        let partialRev = UUID()
        guard case .prepared(let partial) = model.prepareReset(.group(.light), settings: newer, revision: partialRev, draft: draft),
              let partialCandidate = model.commitReset(partial, settings: newer, revision: partialRev, draft: draft) else {
            throw NSError(domain: "partial reset preparation failed", code: 1)
        }
        model.queueSettingsSave(partialCandidate.settings)
        try check(model.saveCurrentSettings(partialCandidate.settings) &&
                  model.processingMigrationReceipt?.status == .migrated &&
                  (try store.processingMigration(for: identity)?.status) == .migrated,
                  "partial group reset keeps processingMigrationReceipt in memory and on disk")

        // Active interaction cancelled after a pending full-reset intent must clear pendingResetMigrationClear and not leak to manual zeroing.
        try check(model.beginAdjustmentInteraction(settings: partialCandidate.settings), "interaction begins before cancel-leak check")
        let cancelRev = UUID()
        guard case .prepared(let cancelledReset) = model.prepareReset(.all, settings: partialCandidate.settings, revision: cancelRev, draft: draft),
              let cancelledCandidate = model.commitReset(cancelledReset, settings: partialCandidate.settings, revision: cancelRev, draft: draft) else {
            throw NSError(domain: "cancel-leak reset preparation failed", code: 1)
        }
        model.queueSettingsSave(cancelledCandidate.settings)
        try check(model.pendingResetMigrationClear != nil, "reset-all queues pendingResetMigrationClear before interaction cancel")
        let restoredFromCancel = model.cancelAdjustmentInteraction()
        try check(restoredFromCancel == partialCandidate.settings && model.pendingResetMigrationClear == nil,
                  "cancelAdjustmentInteraction clears pendingResetMigrationClear")
        var manualNeutral = cancelledCandidate.settings
        manualNeutral.lutID = nil
        model.queueSettingsSave(manualNeutral)
        try check(model.saveCurrentSettings(manualNeutral) &&
                  model.processingMigrationReceipt?.status == .migrated &&
                  (try store.processingMigration(for: identity)?.status) == .migrated,
                  "manual zeroing after cancelAdjustmentInteraction does not clear processingMigrationReceipt")

        // Failed full reset -> restoreCommittedSettings (discard) -> partial reset must also preserve the receipt.
        var lightOnly = manualNeutral; lightOnly.exposure = 0.45
        model.queueSettingsSave(lightOnly)
        try check(model.saveCurrentSettings(lightOnly), "re-apply single-group edit before failed-reset discard check")
        rejectResetWrite = true
        let failedRev = UUID()
        guard case .prepared(let failedFull) = model.prepareReset(.all, settings: lightOnly, revision: failedRev, draft: draft),
              let failedCandidate = model.commitReset(failedFull, settings: lightOnly, revision: failedRev, draft: draft) else {
            throw NSError(domain: "failed full reset preparation failed", code: 1)
        }
        model.queueSettingsSave(failedCandidate.settings)
        try check(!model.saveCurrentSettings(failedCandidate.settings) && model.pendingResetMigrationClear != nil,
                  "failed full reset retains pendingResetMigrationClear for retry until discarded")
        let discarded = try model.restoreCommittedSettings()
        try check(discarded == lightOnly && model.pendingResetMigrationClear == nil,
                  "restoreCommittedSettings clears pendingResetMigrationClear on discard")
        rejectResetWrite = false
        let postDiscardRev = UUID()
        guard case .prepared(let postDiscardPartial) = model.prepareReset(.group(.light), settings: discarded, revision: postDiscardRev, draft: draft),
              let postDiscardCandidate = model.commitReset(postDiscardPartial, settings: discarded, revision: postDiscardRev, draft: draft) else {
            throw NSError(domain: "post-discard partial reset preparation failed", code: 1)
        }
        model.queueSettingsSave(postDiscardCandidate.settings)
        try check(model.saveCurrentSettings(postDiscardCandidate.settings) &&
                  model.processingMigrationReceipt?.status == .migrated &&
                  (try store.processingMigration(for: identity)?.status) == .migrated,
                  "partial reset after failed-reset discard preserves processingMigrationReceipt")

        var beforeFinalReset = postDiscardCandidate.settings; beforeFinalReset.exposure = 0.5
        model.queueSettingsSave(beforeFinalReset)
        try check(model.saveCurrentSettings(beforeFinalReset), "re-apply edit before final full reset")
        let allRev = UUID()
        guard case .prepared(let full) = model.prepareReset(.all, settings: beforeFinalReset, revision: allRev, draft: draft),
              let fullCandidate = model.commitReset(full, settings: beforeFinalReset, revision: allRev, draft: draft) else {
            throw NSError(domain: "full reset preparation failed", code: 1)
        }
        model.queueSettingsSave(fullCandidate.settings)
        try check(model.saveCurrentSettings(fullCandidate.settings) &&
                  model.processingMigrationReceipt == nil && model.processingMigrationStatus == nil &&
                  store.state(for: identity)?.settings == fullCandidate.settings &&
                  fullCandidate.settings.processing == .current &&
                  (try store.processingMigration(for: identity)) == nil,
                  "full reset persists neutral current record and clears processingMigrationReceipt in RawEditorViewModel memory and on disk")
        try check(try EditPersistence(directory: storeRoot).processingMigration(for: identity) == nil,
                  "reopened EditPersistence still reports nil receipt after ViewModel reset-all")
        let undone = model.performAdjustmentHistory(undo: true)
        try check(undone.first?.status == .applied &&
                  model.currentPreviewSettings.exposure == 0.5 &&
                  model.processingMigrationReceipt == nil && model.processingMigrationStatus == nil &&
                  (try store.processingMigration(for: identity)) == nil,
                  "undoing full reset restores pre-reset adjustments while keeping processingMigrationReceipt nil")
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: identity))
            throw NSError(domain: "rollback after undoing full reset must stay expired", code: 1)
        } catch AdjustmentCommitError.expired { }
    }
}
