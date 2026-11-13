import Foundation

@main
struct AdjustmentTransferSessionTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func isExpired(_ error: Error?) -> Bool {
        guard let error = error as? AdjustmentCommitError else { return false }
        if case .expired = error { return true }
        return false
    }
    static func state(_ exposure: Double) -> PhotoEditState {
        var settings = Adjustments(); settings.exposure = exposure
        return PhotoEditState(settings: settings, filmID: "")
    }
    static func context(_ url: URL) -> MacAdjustmentTransferContext {
        MacAdjustmentTransferContext(identifier: url.path, isRaw: true)
    }
    static func payload(_ exposure: Double) throws -> AdjustmentTransferPayload {
        try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(exposure),
            context: MacAdjustmentTransferContext(identifier: "source", isRaw: true))
    }
    static func target(_ url: URL) -> AdjustmentTransferTarget {
        AdjustmentTransferTarget(url: url, defaultState: state(0), context: context(url))
    }
    static func main() throws {
        Self.effectiveNoticesFilter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A.raw"), b = root.appendingPathComponent("B.raw")
        try Data("original-A".utf8).write(to: a); try Data("original-B".utf8).write(to: b)
        try partialFailureAndHistory(root: root, a: a, b: b)
        try saveAndLegacy(root: root, a: a)
        try preflight(root: root, a: a, b: b)
        try historyOrder(root: root, a: a)
        try historyFailureAndSkip(root: root, a: a, b: b)
        try historyRace(root: root, a: a)
        try storageFailures(root: root, a: a, b: b)
        try clipboardAndEmptyTargets(root: root, a: a)
        try sourceDefaults(root: root, a: a, b: b)
        try processingMigrationReset(root: root, a: a, b: b)
        try perRecordIsolationAndRecovery(root: root)
    }

    static func sourceDefaults(root: URL, a: URL, b: URL) throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("source-defaults"))
        let session = AdjustmentTransferSession(store: store)
        var legacy = state(0); legacy.settings.x3fMode = .legacy
        var good = target(a), failed = target(b)
        good.resolveDefaultState = { legacy }
        failed.resolveDefaultState = { throw CocoaError(.fileReadNoPermission) }
        let prepared = try session.prepare(payload: payload(1), targets: [good, failed])
        check(prepared.targets[0].candidate?.settings.x3fMode == .legacy && prepared.targets[1].error != nil,
              "Per-source defaults retain Legacy while a failed probe stays attached to its own target")
        check(try store.state(for: a) == nil && store.state(for: b) == nil,
              "Default preparation never creates edit records")
        try store.save(a, state: state(0))
        good.resolveDefaultState = { throw CocoaError(.fileReadNoPermission) }
        let saved = try session.prepare(payload: payload(1), targets: [good])
        check(saved.targets[0].error == nil && saved.targets[0].candidate?.settings.x3fMode == .normal,
              "Saved records skip the default probe and retain their selected mode")
    }

    static func partialFailureAndHistory(root: URL, a: URL, b: URL) throws {
        let directory = root.appendingPathComponent("partial")
        var writes = 0
        let store = try EditPersistence(directory: directory, writeData: { data, file in
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: file, options: .atomic)
        })
        let session = AdjustmentTransferSession(store: store)
        let operation = try session.prepare(payload: payload(1), targets: [target(a), target(b), target(a)])
        let first = session.apply(operation)
        check(first.map(\.status) == [.applied, .failed], "Multi-target commit reports partial save failure and deduplicates targets")
        check(try store.state(for: a) == state(1) && store.state(for: b) == nil, "Failure preserves target's original absence")
        check(session.transactions.count == 1 && session.transactions[0].parts.count == 1, "History contains only successful targets")
        let retried = session.apply(operation)
        check(retried.map(\.status) == [.applied, .applied] && session.transactions[0].parts.count == 2,
              "Retry appends only newly successful targets to the same transaction")
        check(writes == 3, "Retry does not save an already successful target again")
        let undoneA = session.undoPhoto(a)
        check(try undoneA.map(\.status) == [.applied] && store.state(for: a) == nil, "Single photo undo restores no-record state")
        let undoneBatch = session.undoTransaction(operation.id)
        check(try undoneBatch.count == 1 && undoneBatch[0].targetID == b.resolvingSymlinksInPath().path && store.state(for: b) == nil,
              "Whole transaction undo skips the already undone photo")
        _ = session.redoPhoto(a)
        check(try store.state(for: a) == state(1), "Single photo redo restores its own successful value")
        _ = session.undoPhoto(a)
        let noChange = try session.prepare(payload: payload(0), targets: [target(a)])
        check(session.apply(noChange).map(\.status) == [.unchanged], "Default-to-default paste is unchanged")
        check(session.redoPhoto(a).map(\.status) == [.applied], "No-change paste preserves redo")
        _ = session.undoPhoto(a)
        let before = try store.readState(for: a)
        check(session.commitEdit(expected: before, state: state(2)).status == .applied, "Ordinary successful edit shares the commit ledger")
        check(session.redoPhoto(a).isEmpty, "New edit invalidates only that photo's redo")
        check(try session.redoPhoto(b).map(\.status) == [.applied] && store.state(for: b) == state(1),
              "Other photo redo survives an independent edit")
        _ = session.undoPhoto(a)
        check((try store.state(for: a)) == nil, "Latest ordinary edit undo restores its previous state")
        let reopened = try EditPersistence(directory: directory)
        check(try reopened.state(for: b) == state(1), "Saved changes survive reopening the real registry")
        check(try Data(contentsOf: a) == Data("original-A".utf8) && Data(contentsOf: b) == Data("original-B".utf8),
              "Original photos remain untouched")
    }

    static func saveAndLegacy(root: URL, a: URL) throws {
        let directory = root.appendingPathComponent("versions")
        let store = try EditPersistence(directory: directory)
        let session = AdjustmentTransferSession(store: store)
        let old = try session.prepare(payload: payload(1), targets: [target(a)])
        let before = try store.readState(for: a)
        check(session.commitEdit(expected: before, state: state(2)).status == .applied,
              "A later local commit advances the in-memory edit generation")
        let expired = session.apply(old)
        check(expired.map(\.status) == [.conflict] && isExpired(expired.first?.error),
              "A prepared candidate expires after a later local edit")
        check(try store.state(for: a) == state(2), "An expired candidate cannot overwrite the later local edit")
        let current = try session.prepare(payload: payload(3), targets: [target(a)])
        check(session.apply(current).map(\.status) == [.applied], "A fresh operation applies after the stale one is rejected")
        let file = directory.appendingPathComponent("edits.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["revisions"] = [a.resolvingSymlinksInPath().path: "legacy-revision"]
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        let legacy = try EditPersistence(directory: directory)
        check(try legacy.state(for: a) == state(3),
              "Legacy registry with removed revision metadata remains readable")
        let saved = try legacy.readState(for: a)
        _ = try legacy.saveState(identity: saved.identity, state: state(4))
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let currentState = try legacy.state(for: a)
        check(rewritten["revisions"] == nil && currentState == state(4),
              "New writes omit the removed revision metadata")
    }

    static func preflight(root: URL, a: URL, b: URL) throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("preflight"))
        let session = AdjustmentTransferSession(store: store)
        var blocked = target(b); blocked.context.hasUncommittedDraft = true
        let operation = try session.prepare(payload: payload(1), targets: [target(a), blocked])
        check(session.apply(operation).allSatisfy { $0.status == .blocked }, "Unresolved target preflight prevents all writes")
        check((try store.state(for: a)) == nil, "Preflight does not silently commit compatible targets")
        check(session.apply(operation, skipping: [b.resolvingSymlinksInPath().path]).map(\.status) == [.applied, .skipped],
              "Explicitly skipping blocked target permits the confirmed subset")
        var current = true
        var guarded = target(a); guarded.isCurrent = { current }
        let pending = try session.prepare(payload: payload(2), targets: [guarded])
        current = false
        check(session.apply(pending).map(\.status) == [.blocked], "Active session changes after prepare block commit")
        check((try store.state(for: a)) == state(1), "Active session guard preserves committed edits")
    }

    static func historyOrder(root: URL, a: URL) throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("history-order"))
        let session = AdjustmentTransferSession(store: store)
        let first = try session.prepare(payload: payload(1), targets: [target(a)])
        _ = session.apply(first)
        _ = session.commitEdit(expected: try store.readState(for: a), state: state(2))
        _ = session.commitEdit(expected: try store.readState(for: a), state: state(1))
        guard session.undoTransaction(first.id).map(\.status) == [.conflict] else {
            throw NSError(domain: "AdjustmentHistoryTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Older transaction must not undo later independent edits that returned to the same value"])
        }
        _ = session.undoPhoto(a)
        check((try store.state(for: a)) == state(2), "Undo latest same-value edit follows history order")
        _ = session.undoPhoto(a)
        check((try store.state(for: a)) == state(1), "Undo previous edit restores the earlier transaction head")
        check(session.undoTransaction(first.id).map(\.status) == [.applied], "Older transaction becomes undoable after later edits are undone")
        _ = session.redoPhoto(a); _ = session.redoPhoto(a); _ = session.redoPhoto(a)
        check((try store.state(for: a)) == state(1), "Three dependent edits redo in their original order")
    }

    static func historyFailureAndSkip(root: URL, a: URL, b: URL) throws {
        var writes = 0
        var failAt = 0
        let directory = root.appendingPathComponent("history-failure")
        let store = try EditPersistence(directory: directory, writeData: { data, file in
            writes += 1
            if writes == failAt { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: file, options: .atomic)
        })
        let session = AdjustmentTransferSession(store: store)
        let operation = try session.prepare(payload: payload(1), targets: [target(a), target(b)])
        _ = session.apply(operation)
        failAt = writes + 2
        check(session.undoTransaction(operation.id).map(\.status) == [.applied, .failed], "Partial history save failure moves only successful components")
        check(session.transactions[0].parts.map(\.state) == [.undone, .applied], "Failed undo remains applied and retryable")
        check(session.undoTransaction(operation.id).map(\.status) == [.applied], "Whole undo retry only processes remaining applied photo")
        _ = session.redoTransaction(operation.id)
        _ = session.commitEdit(expected: try store.readState(for: a), state: state(2))
        let blocked = session.undoTransaction(operation.id)
        check(blocked.map(\.status) == [.conflict, .blocked], "Later photo edit blocks whole transaction before any write")
        check(blocked.map(\.requiresHistoryDecision) == [true, false], "Conflict UI skips only rejected targets, not the compatible waiting targets")
        check((try store.state(for: b)) == state(1), "Conflict preflight preserves other target until explicit skip")
        check(session.undoTransaction(operation.id, skipping: [a.resolvingSymlinksInPath().path]).map(\.status) == [.skipped, .applied],
              "Explicit history skip undoes only conflict-free photo")
        check((try store.state(for: a)) == state(2), "Skipped photo retains later edit")
    }

    static func storageFailures(root: URL, a: URL, b: URL) throws {
        let directory = root.appendingPathComponent("storage-failure")
        let store = try EditPersistence(directory: directory)
        try store.save(a, state: state(1))
        let expected = try store.readState(for: a)
        let failing = try EditPersistence(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let session = AdjustmentTransferSession(store: failing)
        check(session.commitEdit(expected: expected, state: state(2)).status == .failed, "Disk write failure is reported by ordinary commit")
        check(try store.readState(for: a) == expected && session.transactions.isEmpty, "Failed write preserves the existing record")
        let replacement = root.appendingPathComponent("replacement.raw")
        try Data("first".utf8).write(to: replacement)
        let replaceSession = AdjustmentTransferSession(store: store)
        let operation = try replaceSession.prepare(payload: payload(1), targets: [target(replacement)])
        try Data("replacement-with-other-size".utf8).write(to: replacement, options: .atomic)
        check(replaceSession.apply(operation).map(\.status) == [.conflict], "Replacing original file after prepare prevents save")
        let file = directory.appendingPathComponent("edits.json")
        let bytes = try Data(contentsOf: file)
        var future = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        future["version"] = 99
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        try futureBytes.write(to: file, options: .atomic)
        check(AdjustmentTransferSession(store: store).commitEdit(expected: expected, state: state(2)).status == .failed,
              "Future registry blocks existing store's write")
        check((try Data(contentsOf: file)) == futureBytes, "Future registry is preserved unchanged")
        try bytes.write(to: file, options: .atomic)
        let other = try EditPersistence(directory: directory)
        let lock = NSLock()
        var errors = [Error]()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                for value in 1...20 { try (index == 0 ? store : other).save(index == 0 ? a : b, state: state(Double(value) / 10)) }
            } catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        check(errors.isEmpty, "Concurrent independent store writers finish without error")
        check(try store.state(for: a) == state(2) && store.state(for: b) == state(2), "Locked registry writes preserve both photos across instances")
    }

    static func historyRace(root: URL, a: URL) throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("history-race"))
        let session = AdjustmentTransferSession(store: store)
        let pending = try session.prepare(payload: payload(1), targets: [target(a)])
        _ = session.commitEdit(expected: try store.readState(for: a), state: state(2))
        let results = session.apply(pending)
        check(results.first?.status == .conflict && isExpired(results.first?.error),
            "A later local edit keeps the stale operation expired at write time")
    }

    static func clipboardAndEmptyTargets(root: URL, a: URL) throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("clipboard"))
        let session = AdjustmentTransferSession(store: store)
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context(a))
        var draft = context(a); draft.hasUncommittedDraft = true
        do {
            _ = try session.copy(scope: .all, snapshot: state(2), context: draft)
            throw NSError(domain: "Tests", code: 2)
        } catch AdjustmentTransferError.draftRequiresPreflight { }
        check(session.clipboard == copy, "Failed copy preserves previous frozen clipboard")
        let empty = try session.prepare(payload: copy, targets: [])
        check(session.apply(empty).isEmpty && session.transactions.isEmpty, "Empty target operation creates no success or history")
        var invalid = state(1); invalid.settings.exposure = .nan
        check(session.commitEdit(expected: try store.readState(for: a), state: invalid).status == .failed,
              "Invalid ordinary candidate cannot enter saved history")
    }

    static func processingMigrationReset(root: URL, a: URL, b: URL) throws {
        let directory = root.appendingPathComponent("migration-reset")
        let store = try EditPersistence(directory: directory)
        let session = AdjustmentTransferSession(store: store)
        var oldSettings = Adjustments(); oldSettings.processing = .c5; oldSettings.exposure = 0.6; oldSettings.highlights = -18
        let original = PhotoEditState(settings: oldSettings, filmID: "saved-look")
        try store.save(a, state: original)
        let initial = try store.readState(for: a)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002, detailRMSE: 0.001, evaluations: 24)
        var migratedSettings = oldSettings; migratedSettings.processing = .current; migratedSettings.highlights = -12
        let migrated = PhotoEditState(settings: migratedSettings, filmID: "saved-look")
        let accepted = try store.commitProcessingMigration(expected: initial, candidate: migrated, quality: quality)
        session.adoptProcessingMigration(accepted)
        check(try store.processingMigration(for: a)?.status == .migrated, "Migration receipt recorded before reset")

        var edited = migrated; edited.settings.exposure = 0.9
        check(session.commitEdit(expected: accepted, state: edited).status == .applied, "Ordinary edit after migration succeeds")
        check(try store.processingMigration(for: a)?.status == .migrated, "Ordinary edit without reset intent preserves migration receipt")

        var neutralSettings = Adjustments(); neutralSettings.processing = .current
        let neutralCandidate = PhotoEditState(settings: neutralSettings, filmID: "")
        let resetOutcome = session.commitEdit(expected: try store.readState(for: a), state: neutralCandidate,
                                              clearsProcessingMigration: true)
        check(resetOutcome.status == .applied && resetOutcome.saved?.state == neutralCandidate,
              "Reset-all commits neutral v3 candidate on real commitEdit path")
        check(try store.processingMigration(for: a) == nil, "Reset-all clears migrated receipt on disk")
        do {
            _ = try store.rollbackProcessingMigration(expected: try store.readState(for: a))
            fatalError("Rollback after reset must throw expired")
        } catch AdjustmentCommitError.expired { }
        let reopened = try EditPersistence(directory: directory)
        check(try reopened.processingMigration(for: a) == nil, "Cleared receipt stays nil after reopening store")
        do {
            _ = try reopened.rollbackProcessingMigration(expected: try reopened.readState(for: a))
            fatalError("Rollback after reopen must stay expired")
        } catch AdjustmentCommitError.expired { }
        let undone = session.undoPhoto(a)
        let restoredAfterUndo = try store.state(for: a)
        check(undone.first?.status == .applied && restoredAfterUndo == edited,
              "Undoing reset-all restores pre-reset adjustments")
        check(try store.processingMigration(for: a) == nil,
              "Undoing reset-all keeps processing migration receipt nil")
        do {
            _ = try store.rollbackProcessingMigration(expected: try store.readState(for: a))
            fatalError("Rollback after undoing reset-all must stay expired")
        } catch AdjustmentCommitError.expired { }

        // Also verify .kept and .rolledBack receipts are cleared by explicit reset intent.
        try store.save(b, state: original)
        let expectedB = try store.readState(for: b)
        let highError = ProcessingMigrationQuality(rgbRMSE: 0.1, p99Error: 0.2, worstTileRMSE: 0.2, detailRMSE: 0.02, evaluations: 80)
        _ = try store.commitProcessingMigration(expected: expectedB, candidate: nil, quality: highError)
        check(try store.processingMigration(for: b)?.status == .kept, "Kept receipt recorded")
        var neutralLegacy = Adjustments(); neutralLegacy.processing = .c5
        _ = session.commitEdit(expected: try store.readState(for: b),
                               state: PhotoEditState(settings: neutralLegacy, filmID: ""),
                               clearsProcessingMigration: true)
        check(try EditPersistence(directory: directory).processingMigration(for: b) == nil,
              "Reset-all clears kept receipt across reopen")

        try store.save(b, state: original)
        let remigrated = try store.commitProcessingMigration(expected: try store.readState(for: b),
                                                             candidate: migrated, quality: quality)
        let rolledBack = try store.rollbackProcessingMigration(expected: remigrated)
        session.adoptProcessingMigration(rolledBack)
        check(try store.processingMigration(for: b)?.status == .rolledBack, "Rolled-back receipt recorded")
        _ = session.commitEdit(expected: rolledBack,
                               state: PhotoEditState(settings: neutralLegacy, filmID: ""),
                               clearsProcessingMigration: true)
        check(try EditPersistence(directory: directory).processingMigration(for: b) == nil,
              "Reset-all clears rolled-back receipt across reopen")
    }

    static func perRecordIsolationAndRecovery(root: URL) throws {
        let directory = root.appendingPathComponent("per-record-isolation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let healthyA = directory.appendingPathComponent("healthy-a.raw")
        let healthyB = directory.appendingPathComponent("healthy-b.raw")
        let brokenVer = directory.appendingPathComponent("broken-ver.raw")
        let brokenSub = directory.appendingPathComponent("broken-sub.raw")
        for (index, url) in [healthyA, healthyB, brokenVer, brokenSub].enumerated() {
            try Data("fixture-\(index)".utf8).write(to: url)
        }
        let store = try EditPersistence(directory: directory)
        let session = AdjustmentTransferSession(store: store)
        var c5 = Adjustments(); c5.processing = .c5; c5.exposure = 0.5
        let c5State = PhotoEditState(settings: c5, filmID: "look-a")
        try store.save(healthyA, state: c5State)
        try store.save(healthyB, state: state(-0.25))
        try store.save(brokenVer, state: c5State)
        try store.save(brokenSub, state: state(0.1))
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002, detailRMSE: 0.001, evaluations: 24)
        var migrated = c5; migrated.processing = .current
        _ = try store.commitProcessingMigration(expected: store.readState(for: healthyA),
                                                candidate: PhotoEditState(settings: migrated, filmID: "look-a"),
                                                quality: quality)
        _ = try store.commitProcessingMigration(expected: store.readState(for: brokenVer),
                                                candidate: PhotoEditState(settings: migrated, filmID: "look-a"),
                                                quality: quality)

        let file = directory.appendingPathComponent("edits.json")
        let keyBrokenVer = try OriginalFileIdentity(brokenVer).path
        let keyBrokenSub = try OriginalFileIdentity(brokenSub).path
        let idVerJSON = String(data: try JSONEncoder().encode(try OriginalFileIdentity(brokenVer)), encoding: .utf8)!
        let idSubJSON = String(data: try JSONEncoder().encode(try OriginalFileIdentity(brokenSub)), encoding: .utf8)!
        let verbatimBrokenVerSlice = """
        { "identity" : \(idVerJSON), "state" : { "filmID" : "custom", "settings" : { "exposure" : 0.75, "processing" : { "family" : "rawlab", "quality" : "standard", "version" : 99 } } } }
        """
        let verbatimBrokenSubSlice = """
        {"state":{"filmID":"","settings":{"exposure":0,"toneControls":{"blackPoint":999,"whitePoint":0,"vibrance":0}}},"identity":\(idSubJSON)}
        """
        let baseObject = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let baseRecords = baseObject["records"] as! [String: Any]
        let healthyASlice = String(data: try JSONSerialization.data(withJSONObject: baseRecords[try OriginalFileIdentity(healthyA).path]!), encoding: .utf8)!
        let healthyBSlice = String(data: try JSONSerialization.data(withJSONObject: baseRecords[try OriginalFileIdentity(healthyB).path]!), encoding: .utf8)!
        let migrationsSlice = String(data: try JSONSerialization.data(withJSONObject: baseObject["processingMigrations"]!), encoding: .utf8)!
        let keyAJSON = String(data: try JSONEncoder().encode(try OriginalFileIdentity(healthyA).path), encoding: .utf8)!
        let keyBJSON = String(data: try JSONEncoder().encode(try OriginalFileIdentity(healthyB).path), encoding: .utf8)!
        let keyVerJSON = String(data: try JSONEncoder().encode(keyBrokenVer), encoding: .utf8)!
        let keySubJSON = String(data: try JSONEncoder().encode(keyBrokenSub), encoding: .utf8)!
        let injected = """
        {"version":1,"records":{\(keyAJSON):\(healthyASlice),\(keyBJSON):\(healthyBSlice),\(keyVerJSON):\(verbatimBrokenVerSlice),\(keySubJSON):\(verbatimBrokenSubSlice)},"processingMigrations":\(migrationsSlice)}
        """
        try Data(injected.utf8).write(to: file)

        let reopened = try EditPersistence(directory: directory)
        check(try reopened.state(for: healthyA)?.settings.exposure == 0.5 &&
              reopened.state(for: healthyB)?.settings.exposure == -0.25,
              "Healthy sibling records remain readable when other records are unusable")
        for broken in [brokenVer, brokenSub] {
            do {
                _ = try reopened.readState(for: broken)
                fatalError("Broken record must throw UnusableEditRecordError on readState")
            } catch is UnusableEditRecordError { }
            do {
                _ = try reopened.state(for: broken)
                fatalError("Broken record must throw UnusableEditRecordError on state")
            } catch is UnusableEditRecordError { }
            do {
                try reopened.save(broken, state: state(0))
                fatalError("Ordinary save must refuse to overwrite unusable record")
            } catch is UnusableEditRecordError { }
        }

        // D1/b: Saving another photo preserves broken entries verbatim on disk.
        try reopened.save(healthyB, state: state(1.25))
        let diskTextAfterHealthySave = String(data: try Data(contentsOf: file), encoding: .utf8)!
        check(diskTextAfterHealthySave.contains("\(keyVerJSON):\(verbatimBrokenVerSlice)") &&
              diskTextAfterHealthySave.contains("\(keySubJSON):\(verbatimBrokenSubSlice)"),
              "Saving another photo preserves broken record JSON slices byte-for-byte verbatim")
        check(try EditPersistence(directory: directory).state(for: healthyB)?.settings.exposure == 1.25,
              "Updated sibling record persists cleanly alongside preserved broken entries")

        // D3/c: resetToUnmodified clears ONLY the target photo's record and migration receipt.
        let cleared = try session.resetToUnmodified(brokenVer)
        let clearedAfter = try reopened.state(for: brokenVer)
        check(cleared.state == nil && clearedAfter == nil,
              "resetToUnmodified removes target photo's broken record")
        check(try reopened.processingMigration(for: brokenVer) == nil &&
              reopened.processingMigration(for: healthyA)?.status == .migrated,
              "resetToUnmodified clears target migration receipt while preserving sibling receipt")
        let diskAfterReset = String(data: try Data(contentsOf: file), encoding: .utf8)!
        check(diskAfterReset.contains("\(keySubJSON):\(verbatimBrokenSubSlice)"),
              "resetToUnmodified on one broken photo leaves other broken photo verbatim")
        try reopened.save(brokenVer, state: state(0.4))
        check(try EditPersistence(directory: directory).state(for: brokenVer)?.settings.exposure == 0.4,
              "Recovered photo can save new adjustments normally")

        // D2/d: Whole-table structural corruption still rejects the entire store.
        let corruptStoreDir = root.appendingPathComponent("corrupt-whole-store")
        try FileManager.default.createDirectory(at: corruptStoreDir, withIntermediateDirectories: true)
        let corruptFile = corruptStoreDir.appendingPathComponent("edits.json")
        for badJSON in [
            "{\"version\":1,\"records\":{",
            "{\"version\":2,\"records\":{}}",
            "{\"records\":{}}",
            "{\"version\":1,\"records\":[]}",
            "{\"version\":1,\"records\":{},\"processingMigrations\":[]}",
            "{\"version\":1,\"version\":1,\"records\":{}}"
        ] {
            try Data(badJSON.utf8).write(to: corruptFile)
            do {
                _ = try EditPersistence(directory: corruptStoreDir)
                fatalError("Whole-store corruption must fail closed: \(badJSON)")
            } catch is CocoaError { }
        }
        check(true, "Whole-store structural corruption remains fail-closed")
    }

    // Q3/S1 seam：提示按实际应用结果过滤；跳过与预检失败目标不产生误报。
    static func effectiveNoticesFilter() {
        let payload = try! AdjustmentTransferPayload(source: .init(identifier: "src", isRaw: true, processingVersion: 2,
            recipe: nil, hdrProcessingVersion: nil), values: ["light.exposure": .number(0.5)])
        func target(_ id: String, _ error: Error?, _ notices: [AdjustmentTransferNotice]) -> PreparedAdjustmentTransfer.Target {
            .init(id: id, original: nil, candidate: nil, unchanged: false, isCurrent: nil, error: error, notices: notices)
        }
        let prepared = PreparedAdjustmentTransfer(id: UUID(), payload: payload, targets: [
            target("a", nil, [.ignoredRawDenoise]), target("b", nil, [.ignoredPostRGBDenoise]),
            target("c", nil, [.retainedTargetProcessingVersion]),
            target("d", NSError(domain: "gone", code: 1), [.ignoredRawDenoise])], action: .paste, notices: [.ignoredRawDenoise])
        let outcomes = [AdjustmentTransferOutcome(targetID: "a", status: .applied, saved: nil, error: nil),
            AdjustmentTransferOutcome(targetID: "b", status: .skipped, saved: nil, error: nil),
            AdjustmentTransferOutcome(targetID: "c", status: .failed, saved: nil, error: nil),
            AdjustmentTransferOutcome(targetID: "d", status: .applied, saved: nil, error: nil)]
        check(prepared.effectiveNotices(outcomes) == [.ignoredRawDenoise],
            "Paste notices surface only for targets that actually applied")
        check(prepared.effectiveNotices([]).isEmpty, "Prepared notices stay hidden until apply outcomes exist")
    }
}
