import Foundation

@main
struct AdjustmentTransferSessionTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A.raw"), b = root.appendingPathComponent("B.raw")
        try Data("original-A".utf8).write(to: a); try Data("original-B".utf8).write(to: b)
        try partialFailureAndHistory(root: root, a: a, b: b)
        try conditionalSaveAndLegacy(root: root, a: a)
        try preflight(root: root, a: a, b: b)
        try historyOrder(root: root, a: a)
        try historyFailureAndSkip(root: root, a: a, b: b)
        try storageFailures(root: root, a: a, b: b)
        try clipboardAndEmptyTargets(root: root, a: a)
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
        let before = try store.versionedState(for: a)
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

    static func conditionalSaveAndLegacy(root: URL, a: URL) throws {
        let directory = root.appendingPathComponent("versions")
        let first = try EditPersistence(directory: directory)
        let second = try EditPersistence(directory: directory)
        let session = AdjustmentTransferSession(store: first)
        let old = try session.prepare(payload: payload(1), targets: [target(a)])
        try second.save(a, state: state(2))
        check(session.apply(old).map(\.status) == [.conflict], "Another store's save invalidates a prepared candidate")
        check((try first.state(for: a)) == state(2) && session.transactions.isEmpty, "Conflict does not overwrite or create history")
        let current = try session.prepare(payload: payload(3), targets: [target(a)])
        _ = session.apply(current)
        try second.save(a, state: state(1))
        try second.save(a, state: state(3))
        check(session.undoPhoto(a).map(\.status) == [.conflict], "Revision guard detects external change-and-return (ABA)")
        let file = directory.appendingPathComponent("edits.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json.removeValue(forKey: "revisions")
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        let legacy = try EditPersistence(directory: directory)
        check(try legacy.versionedState(for: a).revision == nil && legacy.state(for: a) == state(3),
              "Registry v1 without revision metadata remains readable")
        let saved = try legacy.versionedState(for: a)
        _ = try legacy.compareAndSave(expected: saved, state: state(4))
        check((try legacy.versionedState(for: a)).revision != nil, "Revision metadata is added only by a successful write")
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
        _ = session.commitEdit(expected: try store.versionedState(for: a), state: state(2))
        _ = session.commitEdit(expected: try store.versionedState(for: a), state: state(1))
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
        _ = session.commitEdit(expected: try store.versionedState(for: a), state: state(2))
        let blocked = session.undoTransaction(operation.id)
        check(blocked.map(\.status) == [.conflict, .blocked], "Later photo edit blocks whole transaction before any write")
        check((try store.state(for: b)) == state(1), "Conflict preflight preserves other target until explicit skip")
        check(session.undoTransaction(operation.id, skipping: [a.resolvingSymlinksInPath().path]).map(\.status) == [.skipped, .applied],
              "Explicit history skip undoes only conflict-free photo")
        check((try store.state(for: a)) == state(2), "Skipped photo retains later edit")
    }

    static func storageFailures(root: URL, a: URL, b: URL) throws {
        let directory = root.appendingPathComponent("storage-failure")
        let store = try EditPersistence(directory: directory)
        try store.save(a, state: state(1))
        let expected = try store.versionedState(for: a)
        let failing = try EditPersistence(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let session = AdjustmentTransferSession(store: failing)
        check(session.commitEdit(expected: expected, state: state(2)).status == .failed, "Disk write failure is reported by ordinary commit")
        check(try store.versionedState(for: a) == expected && session.transactions.isEmpty, "Failed write preserves existing record and revision")
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
        check(session.commitEdit(expected: try store.versionedState(for: a), state: invalid).status == .failed,
              "Invalid ordinary candidate cannot enter saved history")
    }
}
