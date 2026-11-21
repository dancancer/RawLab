import RawLabKit
import AppKit

private func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: \(label)")
}

@main struct EditorAdjustmentHistoryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        let pixels = [UInt8](repeating: 128, count: 8 * 6 * 3)
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for url in [first, second] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("fixture") }
        }
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"), batchDirectory: root.appendingPathComponent("batch"))
        let originalFilms = model.films
        let summaryLook = root.appendingPathComponent("summary.cube")
        try Data("fixture".utf8).write(to: summaryLook)
        model.films = [Film(name: "Summary look", url: summaryLook, managedID: "summary-look")]
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == "Summary look",
                  "Summary resolves a readable managed look")
        try FileManager.default.removeItem(at: summaryLook)
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == nil,
                  "Summary marks a deleted look unavailable even while metadata is cached")
        model.films = originalFilms
        model.open(first); try rendered(model)
        try check(model.adjustmentSession!.transactions.isEmpty, "opening and resolving metadata create no history")
        model.setInteracting(true)
        model.settings.exposure = 0.2
        model.settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        model.settings.exposure = 0.6
        model.settings.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        try check(model.adjustmentSession!.transactions.isEmpty, "a long slider gesture does not save intermediate history")
        model.undoAdjustment(); model.redoAdjustment()
        try check(model.scheduler.interacting && model.settings.exposure == 0.6 && model.adjustmentSession!.transactions.isEmpty,
            "Undo and Redo do not split an active adjustment gesture")
        model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.dirty, "gesture end saves exactly one history item")
        try rendered(model)
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0 && model.settings.gradingSettings.isDefault && model.canRedoAdjustment, "undo restores the pre-gesture state")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0.6 && model.settings.gradingSettings.shadows.hue == 231.25
            && model.settings.gradingSettings.midtones.saturation == 32.375, "redo restores the saved gesture including pending hue")
        model.setInteracting(true); model.settings.exposure = 1.2
        model.settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        model.cancelAdjustmentInteraction(); try rendered(model)
        try check(model.settings.exposure == 0.6 && model.settings.gradingSettings.shadows == ColorGradingWheel(hue: 231.25, saturation: 0)
            && model.adjustmentSession!.transactions.count == 1,
            "cancelled gesture restores its entry snapshot without history")
        model.settings.contrast = 15; try check(model.saveEdits(), "ordinary change saves")
        try check(model.applyCurrentSettings(to: [first, first]) == 0,
            "sync excludes its source and does not report an empty target set as success")
        let clipboard = try model.copyAdjustments(scope: .custom([.exposure]))
        model.settings.exposure = 1.1; try check(model.saveEdits(), "source can change after copying")
        try check(clipboard[.exposure]?.number == 0.6 && model.adjustmentSession!.clipboard == clipboard,
            "copy freezes the saved selection")
        model.open(second); try rendered(model)
        let operation = try model.prepareAdjustmentPaste(payload: clipboard, targets: [second])
        model.applyAdjustmentPaste(operation)
        try rendered(model)
        try check(model.settings.exposure == 0.6 && !model.dirty, "pasting the active photo updates the committed model")
        model.setInteracting(true); model.settings.saturation = 17
        model.applyAdjustmentPaste(operation)
        try check(model.settings.saturation == 17 && model.dirty,
            "retry receipts never replace later unsaved edits on an already successful photo")
        model.cancelAdjustmentInteraction(); try rendered(model)
        model.settings.saturation = 20; try check(model.saveEdits(), "editing after paste saves the new photo state")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.saturation == 0 && model.settings.exposure == 0.6, "ordinary undo leaves earlier paste intact")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0, "next undo reaches paste history")
        model.open(first); try rendered(model)
        try check(model.settings.exposure == 1.1 && model.settings.contrast == 15, "photo histories do not cross identities")
        let geometryCount = model.adjustmentSession!.transactions.count
        try check(model.beginGeometryDraft(), "geometry draft opens after committed edits")
        try rendered(model)
        model.updateGeometryDraft { $0.cropWidth = 0.75 }
        try check(model.applyGeometryDraft(), "geometry draft saves through the common transaction entry")
        try rendered(model)
        try check(model.adjustmentSession!.transactions.count == geometryCount + 1, "geometry Apply creates one ordinary history item")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.geometrySettings.isIdentity && model.settings.exposure == 1.1,
            "geometry undo preserves earlier color edits")
        let count = model.adjustmentSession!.transactions.count
        _ = try model.copyAdjustments(scope: .all)
        try check(model.adjustmentSession!.transactions.count == count, "copy is not a photo edit")
        model.settings.exposure = 3
        try check(model.saveEdits() && !model.dirty && model.saveError == nil,
            "a later ordinary edit remains saveable in the single editor session")
        try check(model.editStore!.state(for: first)?.settings.exposure == 3,
            "the later ordinary edit becomes the current saved state")
        try recipeLUTChecks(root: root, first: first, second: second)
        try historyErrorChecks(root: root, first: first)
        try presetChecks(root: root, first: first, second: second)
        try QuickPresetModelChecks.run(root: root, first: first, second: second)
        try hslTargetChecks(root: root, second: second)
        try curveNavigationChecks(root: root, photo: first)
        var aiSettings = Adjustments(); aiSettings.aiDenoiseEnabled = true
        let aiBatch = BatchExportModel(job: MacBatchExportJob(source: first, settings: aiSettings, look: nil, lookName: "Neutral"),
            journal: MacBatchJournal(directory: root.appendingPathComponent("ai-batch")))
        aiBatch.add([second])
        let deadline = Date().addingTimeInterval(30)
        while aiBatch.validating && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(!aiBatch.validating && aiBatch.job.items.first?.selected == true && aiBatch.job.items.first?.validationError == nil,
            "AI batch preflight keeps raster targets selected without validation errors")
        let rasterItem = aiBatch.job.items[0]
        try check(aiBatch.job.settings.aiDenoiseEnabled && !aiBatch.job.snapshot(for: rasterItem).settings.aiDenoiseEnabled,
            "AI batch export disables AI for raster targets while retaining the source settings")
        try check(aiBatch.notice(for: rasterItem) == L10n.text("普通图片未使用 AI 降噪"),
            "AI batch raster targets explain that AI denoise was not used")
        try asyncCommitAndTerminationFlushChecks(root: root, photo: first)
    }

    static func asyncCommitAndTerminationFlushChecks(root: URL, photo: URL) throws {
        let dir = root.appendingPathComponent("async-editor-model")
        let editsDir = dir.appendingPathComponent("edits")
        let looksDir = dir.appendingPathComponent("looks")
        let batchDir = dir.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let target = dir.appendingPathComponent("target.png")
        try FileManager.default.copyItem(at: photo, to: target)

        let model = EditorModel(lookDirectory: looksDir, editDirectory: editsDir, batchDirectory: batchDir)
        model.open(target); try rendered(model)

        let gate = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var shouldFail = false
        let controlledStore = try MacEditPersistence(directory: editsDir, writeData: { data, url in
            lock.lock()
            let fail = shouldFail
            lock.unlock()
            if gate.wait(timeout: .now()) == .success {
                // no-op; use separate block flag below
            }
            if fail {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        _ = controlledStore

        // Verify interaction end enqueues async commit and saveEdits() acts as flush barrier.
        model.setInteracting(true)
        model.settings.exposure = 1.75
        model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.dirty,
                  "Async gesture commit records optimistic transaction and clears dirty immediately")
        try check(model.saveEdits(), "saveEdits() flushes pending async commit cleanly")
        try check(!model.hasPendingEditCommits &&
                  (try MacEditPersistence(directory: editsDir).state(for: target)?.settings.exposure == 1.75),
                  "saveEdits() flush barrier durably persists async edit to disk")

        // Verify async failure rolls back committed state and marks dirty + saveError.
        let failStore = try MacEditPersistence(directory: editsDir, writeData: { data, url in
            if gate.wait(timeout: .now()) == .success { /* unused */ }
            lock.lock()
            let fail = shouldFail
            lock.unlock()
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        _ = release
        let priorCommitted = model.committedEdit
        model.editStore = failStore
        model.committedEdit = priorCommitted
        let baseTransactions = model.adjustmentSession!.transactions.count
        lock.lock(); shouldFail = true; lock.unlock()
        model.setInteracting(true)
        model.settings.exposure = 2.5
        model.setInteracting(false)
        try check(!model.saveEdits() && model.dirty && model.saveError != nil &&
                  model.adjustmentSession!.transactions.count == baseTransactions &&
                  model.committedEdit?.state?.settings.exposure == 1.75,
                  "Failed async edit commit rolls back history transaction, preserves committedEdit, restores dirty=true, and surfaces saveError on flush")

        // Reopen a photo with pre-existing persisted exposure=1.25 in a fresh EditorModel (knownRecords[path] == nil):
        // failing the first async edit must preserve committedEdit.state?.settings.exposure == 1.25 and undo baseline.
        let reopenPhoto = dir.appendingPathComponent("reopen-preexisting.png")
        try FileManager.default.copyItem(at: photo, to: reopenPhoto)
        let reopenEditsDir = dir.appendingPathComponent("reopen-edits")
        let reopenLooksDir = dir.appendingPathComponent("reopen-looks")
        let reopenBatchDir = dir.appendingPathComponent("reopen-batch")
        let preStore = try MacEditPersistence(directory: reopenEditsDir)
        var preSettings = Adjustments(); preSettings.exposure = 1.25
        try preStore.save(reopenPhoto, state: MacPhotoEditState(settings: preSettings, filmID: ""))

        let reopenModel = EditorModel(lookDirectory: reopenLooksDir, editDirectory: reopenEditsDir, batchDirectory: reopenBatchDir)
        let failLock = NSLock()
        var reopenShouldFail = true
        reopenModel.editStore = try MacEditPersistence(directory: reopenEditsDir, writeData: { data, url in
            failLock.lock()
            let fail = reopenShouldFail
            failLock.unlock()
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        reopenModel.open(reopenPhoto); try rendered(reopenModel)
        try check(reopenModel.committedEdit?.state?.settings.exposure == 1.25 &&
                  reopenModel.settings.exposure == 1.25,
                  "Reopened EditorModel loads pre-existing exposure=1.25")
        reopenModel.setInteracting(true)
        reopenModel.settings.exposure = 2.5
        reopenModel.setInteracting(false)
        try check(!reopenModel.saveEdits() && reopenModel.dirty && reopenModel.saveError != nil,
                  "First async commit failure on reopened photo reports error and marks dirty")
        try check(reopenModel.committedEdit?.state?.settings.exposure == 1.25,
                  "First async commit failure preserves pre-existing committedEdit exposure == 1.25 (not nil)")

        failLock.lock(); reopenShouldFail = false; failLock.unlock()
        reopenModel.setInteracting(true)
        reopenModel.settings.exposure = 3.0
        reopenModel.setInteracting(false)
        try check(reopenModel.saveEdits(), "Subsequent edit after recovery flushes cleanly")
        reopenModel.undoAdjustment(); try rendered(reopenModel)
        try check(reopenModel.settings.exposure == 2.5,
                  "First undo restores the prior recovered 2.5 edit")
        reopenModel.undoAdjustment(); try rendered(reopenModel)
        try check(reopenModel.settings.exposure == 1.25 && reopenModel.committedEdit?.state?.settings.exposure == 1.25,
                  "Second undo after post-failure edit restores pre-existing 1.25, not nil")

        // Verify pendingAllResetRevision and processingMigrationReceipt are restored if async reset-all fails.
        let migPhoto = dir.appendingPathComponent("migration-reset-fail.png")
        try FileManager.default.copyItem(at: photo, to: migPhoto)
        let migEditsDir = dir.appendingPathComponent("mig-edits")
        let migStore = try MacEditPersistence(directory: migEditsDir)
        var oldSettings = Adjustments(); oldSettings.processing = .c5; oldSettings.exposure = 0.8
        let oldState = MacPhotoEditState(settings: oldSettings, filmID: "")
        try migStore.save(migPhoto, state: oldState)
        var migratedSettings = oldSettings; migratedSettings.processing = .current; migratedSettings.exposure = 0.9
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002, detailRMSE: 0.001, evaluations: 24)
        _ = try migStore.commitProcessingMigration(
            expected: try migStore.readState(for: migPhoto),
            candidate: MacPhotoEditState(settings: migratedSettings, filmID: ""),
            quality: quality
        )
        let migModel = EditorModel(lookDirectory: reopenLooksDir, editDirectory: migEditsDir, batchDirectory: reopenBatchDir)
        migModel.editStore = try MacEditPersistence(directory: migEditsDir, writeData: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        migModel.open(migPhoto); try rendered(migModel)
        try check(migModel.processingMigrationReceipt?.status == .migrated,
                  "Migration receipt loaded on reopen")
        guard case .prepared(let preparedReset) = migModel.prepareReset(scope: .all) else {
            throw NSError(domain: "Expected .prepared reset", code: 1)
        }
        try check(migModel.commitReset(preparedReset), "All reset commits to model")
        try check(migModel.saveEditsAsync(), "All reset enqueues async commit optimistically")
        try check(!migModel.saveEdits(), "Flush reports failure for async reset-all")
        try check(migModel.processingMigrationReceipt?.status == .migrated &&
                  migModel.pendingAllResetRevision == migModel.editRevision &&
                  migModel.committedEdit?.state?.settings.exposure == 0.9,
                  "Failed async reset-all restores processingMigrationReceipt, pendingAllResetRevision, and committedEdit")

        // PROBE_498_RUNLOOP: A1 fails on ioQueue before RunLoop.main drains -> A2 enqueued on main -> no split-brain.
        let runloopDir = dir.appendingPathComponent("runloop-split-brain")
        let runloopEditsDir = runloopDir.appendingPathComponent("edits")
        try FileManager.default.createDirectory(at: runloopDir, withIntermediateDirectories: true)
        let runloopPhoto = runloopDir.appendingPathComponent("runloop.png")
        try FileManager.default.copyItem(at: photo, to: runloopPhoto)
        let runloopModel = EditorModel(lookDirectory: looksDir, editDirectory: runloopEditsDir, batchDirectory: batchDir)
        let rlLock = NSLock()
        var rlWriteAttempts = 0
        runloopModel.editStore = try MacEditPersistence(directory: runloopEditsDir, writeData: { data, url in
            rlLock.lock(); rlWriteAttempts += 1; let idx = rlWriteAttempts; rlLock.unlock()
            if idx == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        runloopModel.open(runloopPhoto); try rendered(runloopModel)
        runloopModel.settings.exposure = 1.0
        runloopModel.edited()
        try check(runloopModel.saveEditsAsync(), "First async edit enqueues optimistically")
        runloopModel.editStore?.waitForPendingIO()
        // Before RunLoop.main drains A1's failure, enqueue A2 via saveEditsAsync().
        runloopModel.settings.exposure = 2.0
        runloopModel.edited()
        try check(runloopModel.saveEditsAsync(), "Second async edit enqueues before RunLoop.main drains A1")
        let rlDeadline = Date().addingTimeInterval(5)
        while runloopModel.hasPendingEditCommits && Date() < rlDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        let diskAfterRunLoop = try MacEditPersistence(directory: runloopEditsDir).state(for: runloopPhoto)?.settings.exposure
        try check(!runloopModel.hasPendingEditCommits &&
                  runloopModel.committedEdit?.state?.settings.exposure == diskAfterRunLoop &&
                  runloopModel.adjustmentSession?.knownRecord(forPath: runloopPhoto.resolvingSymlinksInPath().standardizedFileURL.path)?.state?.settings.exposure == diskAfterRunLoop &&
                  diskAfterRunLoop == 2.0 &&
                  runloopModel.adjustmentSession?.transactions.count == 1,
                  "EditorModel RunLoop pre-drain async failure never split-brains committedEdit vs disk")

        // Verify saveEdits() never masks flushedOK == false when an undrained async commit fails transiently.
        let maskDir = dir.appendingPathComponent("save-edits-mask")
        let maskEditsDir = maskDir.appendingPathComponent("edits")
        try FileManager.default.createDirectory(at: maskDir, withIntermediateDirectories: true)
        let maskPhoto = maskDir.appendingPathComponent("mask.png")
        try FileManager.default.copyItem(at: photo, to: maskPhoto)
        let maskModel = EditorModel(lookDirectory: looksDir, editDirectory: maskEditsDir, batchDirectory: batchDir)
        let maskLock = NSLock()
        var maskWriteAttempts = 0
        maskModel.editStore = try MacEditPersistence(directory: maskEditsDir, writeData: { data, url in
            maskLock.lock(); maskWriteAttempts += 1; let idx = maskWriteAttempts; maskLock.unlock()
            if idx == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        maskModel.open(maskPhoto); try rendered(maskModel)
        maskModel.settings.exposure = 1.2
        maskModel.edited()
        try check(maskModel.saveEditsAsync(), "Transient failing async edit enqueues")
        maskModel.editStore?.waitForPendingIO()
        try check(!maskModel.saveEdits() && maskModel.dirty && maskModel.saveError != nil,
                  "saveEdits() preserves flushedOK == false and saveError instead of masking via synchronous retry")
        try check((try MacEditPersistence(directory: maskEditsDir).state(for: maskPhoto)) == nil,
                  "Disk stays unmodified when saveEdits() surfaces undrained async flush failure")
        try check(maskModel.saveEdits() && !maskModel.dirty && maskModel.saveError == nil &&
                  (try MacEditPersistence(directory: maskEditsDir).state(for: maskPhoto)?.settings.exposure == 1.2),
                  "Subsequent explicit saveEdits() retry after flush failure succeeds cleanly")

        // Verify stale rolled-back A2 completion does not clobber newer A3 saveError/committedEdit.
        let staleDir = dir.appendingPathComponent("stale-a2-clobber")
        let staleEditsDir = staleDir.appendingPathComponent("edits")
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        let stalePhoto = staleDir.appendingPathComponent("stale.png")
        let stalePhotoB = staleDir.appendingPathComponent("stale-b.png")
        try FileManager.default.copyItem(at: photo, to: stalePhoto)
        try FileManager.default.copyItem(at: photo, to: stalePhotoB)
        let staleModel = EditorModel(lookDirectory: looksDir, editDirectory: staleEditsDir, batchDirectory: batchDir)
        let staleLock = NSLock()
        var staleAttempts = 0
        let a1Entered = DispatchSemaphore(value: 0)
        let a1Release = DispatchSemaphore(value: 0)
        let b1Entered = DispatchSemaphore(value: 0)
        let b1Release = DispatchSemaphore(value: 0)
        staleModel.editStore = try MacEditPersistence(directory: staleEditsDir, writeData: { data, url in
            staleLock.lock(); staleAttempts += 1; let idx = staleAttempts; staleLock.unlock()
            if idx == 1 {
                a1Entered.signal()
                a1Release.wait()
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if idx == 2 {
                b1Entered.signal()
                b1Release.wait()
            }
            try data.write(to: url, options: .atomic)
        })
        staleModel.open(stalePhoto); try rendered(staleModel)
        staleModel.settings.exposure = 1.0; staleModel.edited()
        try check(staleModel.saveEditsAsync(), "Stale-clobber A1 enqueues")
        try check(a1Entered.wait(timeout: .now() + 5) == .success, "Stale-clobber A1 entered ioQueue")

        var bSettings = Adjustments(); bSettings.exposure = 0.5
        try staleModel.editStore!.enqueueSaveState(identity: try OriginalFileIdentity(stalePhotoB),
                                                   state: MacPhotoEditState(settings: bSettings, filmID: ""))
        staleModel.settings.exposure = 2.0; staleModel.edited()
        try check(staleModel.saveEditsAsync(), "Stale-clobber A2 enqueues behind B1")
        a1Release.signal()
        try check(b1Entered.wait(timeout: .now() + 5) == .success, "Stale-clobber B1 pauses ioQueue")

        // Drain A1 while B1 holds ioQueue; A1 rolls back [A1, A2].
        let staleDeadline = Date().addingTimeInterval(5)
        while staleModel.saveError == nil && Date() < staleDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        try check(staleModel.saveError != nil && staleModel.committedEdit?.state == nil, "A1 failure drains cleanly")

        // Enqueue A3 while B1 still holds ioQueue (ahead of A2's failure delivery).
        staleModel.settings.exposure = 3.0; staleModel.edited()
        try check(staleModel.saveEditsAsync(), "Stale-clobber A3 enqueues after A1 rollback")
        b1Release.signal()
        let postA3Deadline = Date().addingTimeInterval(5)
        while staleModel.hasPendingEditCommits && Date() < postA3Deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        try check(!staleModel.hasPendingEditCommits && staleModel.saveEdits() &&
                  staleModel.saveError == nil && !staleModel.dirty &&
                  staleModel.committedEdit?.state?.settings.exposure == 3.0 &&
                  (try MacEditPersistence(directory: staleEditsDir).state(for: stalePhoto)?.settings.exposure == 3.0),
                  "Stale rolled-back A2 completion does not clobber newer A3 saveError or committedEdit")
    }

    static func curveNavigationChecks(root: URL, photo: URL) throws {
        let model = EditorModel(lookDirectory: root.appendingPathComponent("curve-looks"),
            editDirectory: root.appendingPathComponent("curve-edits"), batchDirectory: root.appendingPathComponent("curve-batch"))
        model.open(photo); try rendered(model)
        model.settings.curveSettings = .identity; try check(model.saveEdits(), "curve mode saves")
        let before = model.settings, count = model.adjustmentSession!.transactions.count
        for collapse in [false, true] {
            model.selectAdjustmentTool(.toneCurve)
            model.setInteracting(true); model.settings.curveSettings = .identity.inserting(x: 0.5, y: 0.7)
            if collapse { model.selectAdjustmentGroup(.light) } else { model.selectAdjustmentTool(.exposure) }
            try check(model.settings == before && !model.scheduler.interacting && model.interactionEntry == nil &&
                model.adjustmentSession!.transactions.count == count,
                "curve navigation cancels before changing the tool or collapsing its group")
        }
        model.selectAdjustmentTool(.exposure)
        model.setInteracting(true); model.settings.exposure = 0.4; model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == count + 1 && model.settings.curveSettings == .identity,
            "the next tool creates its own history entry after curve cancellation")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings == before, "undo of the next tool retains the saved curve")
    }

    static func hslTargetChecks(root: URL, second: URL) throws {
        let photo = root.appendingPathComponent("hsl-target.png")
        let pixels: [UInt8] = Array(repeating: [204, 102, 51], count: 8 * 6).flatMap { $0 }
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("fixture") }
        let model = EditorModel(lookDirectory: root.appendingPathComponent("hsl-looks"),
            editDirectory: root.appendingPathComponent("hsl-edits"), batchDirectory: root.appendingPathComponent("hsl-batch"))
        model.open(photo); try rendered(model); model.selectAdjustmentTool(.hsl); model.hslTargetEnabled = true
        func sampled() throws {
            let deadline = Date().addingTimeInterval(30)
            while model.hslTargetInteraction.isWaiting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            try check(!model.hslTargetInteraction.isWaiting, "target sampling completes")
        }
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); model.moveHSLTarget(20); model.endHSLTarget()
        try sampled(); try rendered(model)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.settings.hslSettings.isIdentity,
            "release before native sample creates exactly one durable HSL edit")
        let point = model.hslTargetPoint
        let beforeKeys = model.settings.hslSettings
        model.busy = true
        model.keyHSLTarget(1); model.keyHSLTarget(1); model.keyHSLTarget(1)
        try check(model.hslTargetPoint == point, "Keyboard repeats preserve the sample point while preview is busy")
        model.refreshBusy(); try sampled(); try rendered(model)
        try check(model.adjustmentSession!.transactions.count == 2, "Buffered keyboard repeats form one HSL history transaction")
        let keySample = model.hslTargetInteraction.selection!
        for channel in 0..<8 {
            let expected = min(100, max(-100, beforeKeys.value(model.hslTargetAxis, channel: channel) + 3 * keySample.weights[channel]))
            try check(abs(model.settings.hslSettings.value(model.hslTargetAxis, channel: channel) - expected) < 0.000001,
                "Keyboard repeats apply every weighted step to channel \(channel)")
        }
        model.undoAdjustment(); try rendered(model)
        let targetHistoryCount = model.adjustmentSession!.transactions.count
        let saved = model.settings
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); try sampled()
        model.moveHSLTarget(50); model.cancelHSLTarget(); model.endHSLTarget(); try rendered(model)
        try check(model.settings == saved && model.adjustmentSession!.transactions.count == targetHistoryCount,
            "native target cancellation restores before without a second history item")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.hslSettings.isIdentity, "target undo restores all HSL channels")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings == saved, "target redo restores frozen weighted values")
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); model.moveHSLTarget(10); model.open(second); try rendered(model)
        try check(model.settings.hslSettings.isIdentity && !model.hslTargetInteraction.isWaiting,
            "source switch discards a pending native target sample")
        model.selectAdjustmentTool(.hsl); model.hslTargetEnabled = true
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5))
        try check(model.referenceSource(second).hdrFingerprint == nil && model.hslTargetNotice != .stale &&
            model.hslTargetInteraction.isWaiting, "an accepted preview without a gain map stays current for target sampling")
        try sampled(); model.endHSLTarget(); try rendered(model)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: second.path)
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5))
        try check(model.hslTargetNotice == .stale && !model.hslTargetInteraction.isWaiting,
            "a rewritten source without a gain map still reports a changed preview")
    }

    static func presetChecks(root: URL, first: URL, second: URL) throws {
        let directory = root.appendingPathComponent("preset-edits")
        let model = EditorModel(lookDirectory: root.appendingPathComponent("preset-looks"), editDirectory: directory,
            batchDirectory: root.appendingPathComponent("preset-batch"), presetDirectory: root.appendingPathComponent("preset-library"))
        model.open(first); try rendered(model)
        model.settings.exposure = 0.7; try check(model.saveEdits(), "preset source is committed")
        let clipboard = try model.copyAdjustments(scope: .custom([.contrast]))
        let count = model.adjustmentSession!.transactions.count
        let payload = try model.capturePresetAdjustments(scope: .custom([.exposure]))
        let preset = try model.presetStore.create(name: "Native preset", payload: payload)
        try check(model.adjustmentClipboard == clipboard && model.adjustmentSession!.clipboard == clipboard &&
            model.adjustmentSession!.transactions.count == count, "native preset save preserves both clipboard and photo history")
        try check(model.beginGeometryDraft(), "preset fixture enters a geometry draft")
        try rendered(model); model.updateGeometryDraft { $0.cropWidth = 0.8 }
        model.requestAdjustmentSheet(.presets)
        try check(model.adjustmentSheet == .presets && model.geometryDraft != nil && !model.geometryDraftDeparturePending,
            "opening preset management does not apply or discard a photo draft")
        var continued = false
        model.preparePresetAction { continued = true }
        try check(model.geometryDraftDeparturePending && !continued, "preset save waits for the shared geometry decision")
        model.resolveGeometryDraftDeparture(.stay)
        try check(!continued && model.geometryDraft != nil, "Continue Editing cancels the preset action and preserves its draft")
        model.preparePresetAction { continued = true }
        model.resolveGeometryDraftDeparture(.discard)
        try check(continued && model.geometryDraft == nil && model.adjustmentSession!.transactions.count == count,
            "Discard then preset capture uses committed values without adding a geometry history item")
        model.adjustmentSheet = nil
        model.open(second); try rendered(model)
        model.settings.exposure = -0.2; model.settings.saturation = 14
        try check(model.saveEdits(), "preset target has independent committed adjustments")
        let operation = try model.prepareAdjustmentPaste(payload: preset.payload, targets: [second], action: .preset)
        model.applyAdjustmentPaste(operation); try rendered(model)
        try check(model.settings.exposure == 0.7 && model.settings.saturation == 14 && !model.dirty,
            "native preset apply adopts its conditional receipt and preserves unselected settings")
        try check(model.adjustmentSession!.transactions.last?.action == .preset, "native preset history records its actual action")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == -0.2 && model.canRedoAdjustment, "native Undo restores the pre-preset photo")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0.7, "native Redo restores the same preset component")
        model.settings.exposure = 1.8
        try check(model.saveEdits(), "a later local edit remains saveable before preset capture")
        let beforePresetCaptureHistory = model.adjustmentSession!.transactions.count
        let recaptured = try model.capturePresetAdjustments(scope: .custom([.exposure]))
        try check(recaptured.fields == [.exposure] && model.presetStore.list() == [preset] &&
            model.adjustmentSession!.transactions.count == beforePresetCaptureHistory && model.adjustmentClipboard == clipboard && model.saveError == nil,
            "preset capture uses the current in-memory saved state without a disk revision gate")
        model.editStore = try MacEditPersistence(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteUnknown) })
        model.settings.exposure = 1.3
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure])); throw NSError(domain: "Expected preset source save failure", code: 1) }
        catch AdjustmentTransferError.draftRequiresPreflight {}
        try check(model.dirty && model.saveError != nil && model.adjustmentClipboard == clipboard,
            "failed source persistence blocks preset capture without changing clipboard")
        try check(model.presetStore.list() == [preset], "source save failure does not alter the preset library")
    }

    static func recipeLUTChecks(root: URL, first: URL, second: URL) throws {
        let model = EditorModel(lookDirectory: root.appendingPathComponent("recipe-looks"),
            editDirectory: root.appendingPathComponent("recipe-edits"), batchDirectory: root.appendingPathComponent("recipe-batch"))
        model.open(first); try rendered(model)
        model.selectMasterRecipe(.hamadaDaylightV2); try rendered(model)
        let payload = try model.copyAdjustments(scope: .custom([.look]))
        model.open(second); try rendered(model)
        let before = model.settings
        let operation = try model.prepareAdjustmentPaste(payload: payload, targets: [second])
        model.applyAdjustmentPaste(operation); try rendered(model)
        try check(model.settings.masterRecipeID == nil && model.selectedFilmID == "recipe-lut:hamada_daylight_v2",
            "partial recipe look remains an independent LUT")
        try check(model.selectedFilm?.url == MasterRecipe.hamadaDaylightV2.lutURL() && !model.missingFilm,
            "preview and export resolver finds a recipe LUT reference")
        try check(model.settings.exposure == before.exposure && model.settings.hsl == before.hsl,
            "resolving the LUT does not reapply recipe parameter deltas")
        try check(model.prepareBatch() && model.batch?.job.look != nil, "batch export freezes the resolved recipe LUT")
        model.open(first); try rendered(model); model.open(second); try rendered(model)
        try check(model.selectedFilmID == "recipe-lut:hamada_daylight_v2" && model.selectedFilm != nil,
            "saved recipe LUT references restore without selecting a full recipe")
        try check(model.filmChoices.contains { $0.id == model.selectedFilmID }, "independent recipe look has a visible selected film choice")
        model.selectFilm(""); try rendered(model)
        model.selectFilm("recipe-lut:hamada_daylight_v2"); try rendered(model)
        try check(model.selectedFilmID == "recipe-lut:hamada_daylight_v2" && model.settings.masterRecipeID == nil,
            "an encountered independent recipe look can be selected again without recipe deltas")
    }

    static func historyErrorChecks(root: URL, first: URL) throws {
        let directory = root.appendingPathComponent("history-errors")
        // 历史操作不再比较磁盘上的调整记录，改用原图身份变化触发失败；只改这张专用副本，不影响后续用例。
        let photo = root.appendingPathComponent("history-error-source").appendingPathExtension(first.pathExtension)
        try? FileManager.default.removeItem(at: photo)
        try FileManager.default.copyItem(at: first, to: photo)
        let model = EditorModel(lookDirectory: root.appendingPathComponent("error-looks"), editDirectory: directory,
            batchDirectory: root.appendingPathComponent("error-batch"))
        model.open(photo); try rendered(model)
        model.settings.exposure = 1; try check(model.saveEdits(), "history error fixture saves")
        let modified = try FileManager.default.attributesOfItem(atPath: photo.path)[.modificationDate] as! Date
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(60)], ofItemAtPath: photo.path)
        model.undoAdjustment()
        try check(model.saveError == nil && model.adjustmentSheet == .history,
            "keyboard history failure opens history recovery without pretending the photo is unsaved")
        try check(model.pendingAdjustmentHistory?.photo == photo && model.pendingAdjustmentHistory?.undo == true,
            "keyboard recovery retains the single-photo operation scope")
    }

    static func rendered(_ model: EditorModel) throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(!model.busy && model.result != nil && model.error == nil, "native preview completes")
    }
}
