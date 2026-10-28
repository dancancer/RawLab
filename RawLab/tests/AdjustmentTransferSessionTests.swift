import Foundation

@main struct IOSAdjustmentSessionTests {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: label, code: 1) }; print("PASS: \(label)")
    }
    static var context: IOSAdjustmentTransferContext { .init(identifier: "source", isRaw: true) }
    static func state(_ exposure: Double) -> PhotoEditState {
        var settings = RawSettings.default; settings.exposure = exposure
        return .init(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var failB = false
        let targets = [IOSAdjustmentTransferTarget(identity: a, displayName: "A", defaultState: state(0), context: context),
            IOSAdjustmentTransferTarget(identity: b, displayName: "B", defaultState: state(0), context: context,
                validateSource: { if failB { throw NSError(domain: "missing B", code: 1) } })]
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let operation = try session.prepare(payload: copy, targets: targets + [targets[0]])
        try check(operation.targets.count == 2, "Stable identities deduplicate operation targets")
        failB = true
        let partial = session.apply(operation)
        try check(partial.map(\.status) == [.applied, .failed] && session.transactions.count == 1
            && session.transactions[0].parts.count == 1, "Only successfully saved targets enter a partial transaction")
        let savedA = try store.versionedState(for: a)
        failB = false
        let retry = session.apply(operation)
        try check(retry.map(\.status) == [.applied, .applied] && store.versionedState(for: a) == savedA,
            "Retry saves only the failed target and preserves successful revision")
        let undoA = session.undoPhoto(a)
        try check(undoA.count == 1 && undoA[0].status == .applied && store.state(for: a) == nil,
            "Single-photo undo restores absence without undoing other successful targets")
        let undoRest = session.undoTransaction(operation.id)
        try check(undoRest.count == 1 && undoRest[0].targetID == b.key && store.state(for: b) == nil,
            "Batch undo processes only still-applied components")
        try check(session.redoTransaction(operation.id).count == 2 && store.state(for: a)?.settings.exposure == 1,
            "Batch redo restores exactly the two undone components")
        let noChange = try session.prepare(payload: copy, targets: targets)
        let count = session.transactions.count
        try check(session.apply(noChange).allSatisfy { $0.status == .unchanged } && session.transactions.count == count,
            "Identical paste creates no history")
        _ = session.undoPhoto(a)
        let timestampOnly = session.commitEdit(expected: try store.versionedState(for: a), state: state(0), defaultState: state(0))
        try check(timestampOnly.status == .unchanged && session.canRedoPhoto(a), "Default absence no-op preserves redo")
        let newEdit = session.commitEdit(expected: try store.versionedState(for: a), state: state(2))
        try check(newEdit.status == .applied && !session.canRedoPhoto(a), "New edit clears only that photo's redo")
        try check(session.transactions.first!.parts.first(where: { $0.identity == b })?.state == .applied,
            "Other photo history survives a new single-photo edit")
        _ = session.commitEdit(expected: try store.versionedState(for: a), state: state(1))
        let remaining = session.undoTransaction(operation.id)
        try check(remaining.count == 1 && remaining[0].targetID == b.key && remaining[0].status == .applied
            && store.state(for: a)?.settings.exposure == 1 && store.state(for: b) == nil,
            "Batch undo excludes the component invalidated by a new independent edit")
        try preflightAndExternal(root.appendingPathComponent("preflight"))
        try historyOrder(root.appendingPathComponent("lineage"))
        try saveFailure(root.appendingPathComponent("failures"))
        try synchronization(root.appendingPathComponent("collection-sync"))
        try presetApplication(root.appendingPathComponent("presets"))
        var invalid = context; invalid.hasUncommittedDraft = true
        do { _ = try session.copy(scope: .all, snapshot: state(2), context: invalid) } catch {}
        try check(session.clipboard == copy, "Failed copy preserves the frozen clipboard")
        let empty = try session.prepare(payload: copy, targets: [])
        try check(session.apply(empty).isEmpty, "Empty target operation reports no successes")
    }
    static func synchronization(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let source = PhotoIdentity(resourceIdentifier: "sync-source"), other = PhotoIdentity(resourceIdentifier: "sync-other")
        var context = self.context; context.identifier = source.key
        let clipboard = try session.copy(scope: .all, snapshot: state(0.5), context: context)
        let payload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(1.25), context: context)
        var original = state(0).settings; original.contrast = 0.37
        try store.save(source, state: state(0.5))
        try store.save(other, state: PhotoEditState(settings: original))
        let targets = [source, other, other].map {
            IOSAdjustmentTransferTarget(identity: $0, displayName: "same.png", defaultState: state(0), context: context)
        }
        let operation = try session.prepare(payload: payload, targets: targets, action: .synchronize)
        try check(operation.targets.map(\.id) == [other.key], "Synchronization excludes the selected source and deduplicates by identity, not filename")
        let results = session.apply(operation)
        try check(results.map(\.status) == [.applied] && store.state(for: source)?.settings.exposure == 0.5
            && store.state(for: other)?.settings.exposure == 1.25 && store.state(for: other)?.settings.contrast == 0.37,
            "Synchronization saves only selected fields on actual targets")
        try check(session.clipboard == clipboard && session.transactions.first?.action == .synchronize,
            "Synchronization retains clipboard and records its own history action")
        let unsafe = try session.prepare(payload: payload, targets: [targets[0]], action: .paste)
        let injected = IOSPreparedAdjustmentTransfer(id: UUID(), payload: payload, action: .synchronize, targets: unsafe.targets)
        let rejected = session.apply(injected)
        try check(rejected.map(\.status) == [.blocked] && store.state(for: source)?.settings.exposure == 0.5,
            "Write-time source exclusion rejects a source reintroduced after preparation")
        let before = try store.versionedState(for: other)
        var micro = before.state!.settings; micro.contrast = 0.61
        let edit = session.commitEdit(expected: before, state: PhotoEditState(settings: micro))
        try check(edit.status == .applied && store.state(for: other)?.settings.contrast == 0.61,
            "A collection photo can receive an independent micro-edit")
        let secondPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(1.75), context: context)
        let second = try session.prepare(payload: secondPayload, targets: targets, action: .synchronize)
        _ = session.apply(second)
        try check(store.state(for: other)?.settings.exposure == 1.75 && store.state(for: other)?.settings.contrast == 0.61,
            "A second synchronization preserves unselected micro-edits")
        let undo = session.undoTransaction(second.id)
        try check(undo.map(\.status) == [.applied] && store.state(for: other)?.settings.exposure == 1.25
            && store.state(for: other)?.settings.contrast == 0.61, "Transaction history restores only the successful synchronization component")
    }

    static func presetApplication(_ root: URL) throws {
        let edits = try EditPersistence(directory: root.appendingPathComponent("edits"))
        let session = IOSAdjustmentTransferSession(store: edits)
        let library = AdjustmentPresetStore(directory: root.appendingPathComponent("library"))
        let clipboard = try session.copy(scope: .custom([.exposure]), snapshot: state(0.5), context: context)
        var sourceSettings = state(1.25).settings
        sourceSettings.blackPoint = -32.75; sourceSettings.whitePoint = 46.5; sourceSettings.vibrance = 21.25
        let source = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure, .blackPoint, .whitePoint, .vibrance]),
            snapshot: PhotoEditState(settings: sourceSettings), context: context)
        let saved = try library.create(name: "iOS preset", payload: source)
        try check(session.clipboard == clipboard && session.transactions.isEmpty,
            "Preset save leaves clipboard and photo history unchanged")
        let reloaded = try AdjustmentPresetStore(directory: library.directory).list().first!
        var beforeSettings = state(-0.5).settings; beforeSettings.saturation = 1.2
        let before = PhotoEditState(settings: beforeSettings)
        let identity = PhotoIdentity(resourceIdentifier: "preset-target")
        try edits.save(identity, state: before)
        let direct = try IOSAdjustmentTransfer.prepare(payload: source, target: before, context: context)
        let candidate = try IOSAdjustmentTransfer.prepare(payload: reloaded.payload, target: before, context: context)
        try check(candidate.settings == direct.settings, "Preset and clipboard resolve identical native settings")
        let targets = [IOSAdjustmentTransferTarget(identity: identity, displayName: "Preset target",
            defaultState: state(0), context: context)]
        let operation = try session.prepare(payload: reloaded.payload, targets: targets, action: .preset)
        try check(session.apply(operation).first?.status == .applied && edits.state(for: identity)?.settings.exposure == 1.25,
            "Persisted preset applies through the existing conditional-save path")
        try check(edits.state(for: identity)?.settings.saturation == 1.2 && session.clipboard == clipboard,
            "Preset application preserves unselected fields and the frozen clipboard")
        try check(session.transactions.count == 1 && session.transactions[0].action == .preset,
            "Preset application records its own action in the shared photo history")
        try check(edits.state(for: identity)?.settings.toneSettings == sourceSettings.toneSettings,
            "Preset application saves exact tone fields in the photo registry")
        try library.delete(saved)
        try check(edits.state(for: identity)?.settings.exposure == 1.25,
            "Deleting a preset does not change an already-applied photo")
        try check(session.undoPhoto(identity).first?.status == .applied && edits.state(for: identity)?.hasSameAdjustments(as: before) == true,
            "Preset undo restores the full prior photo state")
        let unchanged = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: before, context: context)
        let noChange = try session.prepare(payload: unchanged, targets: targets, action: .preset)
        try check(session.apply(noChange).first?.status == .unchanged && session.canRedoPhoto(identity),
            "No-change preset application preserves the redo branch")
        try check(session.redoPhoto(identity).first?.status == .applied && edits.state(for: identity)?.settings.exposure == 1.25,
            "Preset redo restores the saved result after the preset itself was deleted")
        try check(edits.state(for: identity)?.settings.toneSettings == sourceSettings.toneSettings,
            "Preset redo restores all tone values after deleting the source preset")
    }
    static func preflightAndExternal(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let blocked = try session.prepare(payload: copy, targets: [
            .init(identity: a, displayName: "A", defaultState: state(0), context: context),
            .init(identity: b, displayName: "B", defaultState: state(0), context: context, isCurrent: { false })])
        try check(session.apply(blocked).allSatisfy { $0.status == .blocked } && store.state(for: a) == nil,
            "Unresolved draft preflight writes no target")
        try check(session.apply(blocked, skipping: [b.key]).map(\.status) == [.applied, .skipped],
            "Explicit preflight skip saves only the accepted target")
        let next = try session.copy(scope: .custom([.exposure]), snapshot: state(2), context: context)
        let both = try session.prepare(payload: next, targets: [a, b].map {
            .init(identity: $0, displayName: $0.key, defaultState: state(0), context: context)
        })
        _ = session.apply(both)
        let external = try EditPersistence(directory: root)
        try external.save(a, state: state(3)); try external.save(a, state: state(2))
        try check(session.undoPhoto(a).first?.status == .conflict && store.state(for: a)?.settings.exposure == 2,
            "External ABA cannot bypass history revision guards")
        let conflict = session.undoTransaction(both.id)
        try check(conflict.filter(\.requiresHistoryDecision).map(\.targetID) == [a.key] && store.state(for: b)?.settings.exposure == 2,
            "Unresolved history conflict aborts other targets without marking them as conflicts")
        let skipped = session.undoTransaction(both.id, skipping: [a.key])
        try check(skipped.contains { $0.targetID == b.key && $0.status == .applied } && store.state(for: b) == nil,
            "Explicit history skip processes only nonconflicting components")
    }
    static func historyOrder(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let id = PhotoIdentity(resourceIdentifier: "ordered")
        for value in [1.0, 2, 1] { _ = session.commitEdit(expected: try store.versionedState(for: id), state: state(value)) }
        let first = session.transactions[0].id
        try check(session.undoTransaction(first).first?.status == .conflict, "Own ABA cannot undo an older transaction out of order")
        _ = session.undoPhoto(id); try check(store.state(for: id)?.settings.exposure == 2, "Latest undo restores immediate predecessor")
        _ = session.undoPhoto(id); try check(store.state(for: id)?.settings.exposure == 1, "Second undo follows causal history")
        _ = session.undoPhoto(id); try check(store.state(for: id) == nil, "Final undo restores original absence")
        for _ in 0..<3 { _ = session.redoPhoto(id) }
        try check(store.state(for: id)?.settings.exposure == 1, "Redo replays the same causal chain")
    }
    static func saveFailure(_ root: URL) throws {
        var fail = false
        let store = try EditPersistence(directory: root, writeData: { bytes, url in
            if fail { throw NSError(domain: "disk failure", code: 1) }; try bytes.write(to: url, options: .atomic)
        })
        let session = IOSAdjustmentTransferSession(store: store), id = PhotoIdentity(resourceIdentifier: "retry")
        let before = try store.versionedState(for: id)
        fail = true
        try check(session.commitEdit(expected: before, state: state(1)).status == .failed && session.transactions.isEmpty,
            "Failed ordinary save creates no history")
        fail = false
        try check(session.commitEdit(expected: before, state: state(1)).status == .applied && session.transactions.count == 1,
            "Ordinary save retry creates one successful history component")
        fail = true
        try check(session.undoPhoto(id).first?.status == .failed && !session.canRedoPhoto(id), "Failed inverse save does not move history state")
        fail = false
        try check(session.undoPhoto(id).first?.status == .applied && session.canRedoPhoto(id), "Inverse save can retry successfully")
    }
}
