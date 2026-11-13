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
        try Self.effectiveNoticesFilter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var failB = false
        let targets = [IOSAdjustmentTransferTarget(identity: a, displayName: "A", defaultState: state(0), context: context),
            IOSAdjustmentTransferTarget(identity: b, displayName: "B", defaultState: state(0), context: context,
                validateSource: { if failB { throw NSError(domain: "missing B", code: 1) } })]
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let preview = try IOSAdjustmentTransfer.previewCapture(scope: .modified, snapshot: state(1), committed: state(1), context: context)
        try check(preview.fields == [.exposure] && preview[.exposure] == .number(1),
                  "Scope preview uses actual modified capture fields and values")
        let emptyPreview = Result { try IOSAdjustmentTransfer.previewCapture(scope: .modified, snapshot: state(0), committed: state(0), context: context) }
        if case .failure(let error) = emptyPreview {
            try check(error as? AdjustmentTransferError == .emptyScope, "Neutral modified preview is an empty scope")
        } else { try check(false, "Neutral modified preview must be empty") }
        let stale = Result { try IOSAdjustmentTransfer.previewCapture(scope: .all, snapshot: state(2), committed: state(1), context: context) }
        if case .failure(let error) = stale {
            try check(error as? AdjustmentTransferError == .draftRequiresPreflight, "Unsaved settings cannot display a stale scope preview")
        } else { try check(false, "Stale preview must fail") }
        var hdrSettings = RawSettings.default; hdrSettings.hdr = HDRSettings()
        let hdrState = PhotoEditState(settings: hdrSettings)
        let hdrPreview = try IOSAdjustmentTransfer.previewCapture(scope: .standard(isHDR: true), snapshot: hdrState,
            committed: hdrState, context: .init(identifier: "hdr", isRaw: false, sourceIsHDR: true))
        try check(hdrPreview.fields == AdjustmentTransferField.hdrCommon && hdrPreview.source.isHDR,
                  "HDR scope preview preserves the seven-field family")
        try check(session.clipboard == copy && session.transactions.isEmpty && store.state(for: a) == nil,
                  "Scope preview leaves clipboard, history and persistence unchanged")
        let operation = try session.prepare(payload: copy, targets: targets + [targets[0]])
        try check(operation.targets.count == 2, "Stable identities deduplicate operation targets")
        failB = true
        let partial = session.apply(operation)
        try check(partial.map(\.status) == [.applied, .failed] && session.transactions.count == 1
            && session.transactions[0].parts.count == 1, "Only successfully saved targets enter a partial transaction")
        let savedA = try store.readState(for: a)
        failB = false
        let retry = session.apply(operation)
        try check(retry.map(\.status) == [.applied, .applied] && store.readState(for: a).hasSameAdjustments(as: savedA),
            "Retry saves only the failed target and preserves the successful target")
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
        let timestampOnly = session.commitEdit(expected: try store.readState(for: a), state: state(0), defaultState: state(0))
        try check(timestampOnly.status == .unchanged && session.canRedoPhoto(a), "Default absence no-op preserves redo")
        let newEdit = session.commitEdit(expected: try store.readState(for: a), state: state(2))
        try check(newEdit.status == .applied && !session.canRedoPhoto(a), "New edit clears only that photo's redo")
        try check(session.transactions.first!.parts.first(where: { $0.identity == b })?.state == .applied,
            "Other photo history survives a new single-photo edit")
        _ = session.commitEdit(expected: try store.readState(for: a), state: state(1))
        let remaining = session.undoTransaction(operation.id)
        try check(remaining.count == 1 && remaining[0].targetID == b.key && remaining[0].status == .applied
            && store.state(for: a)?.settings.exposure == 1 && store.state(for: b) == nil,
            "Batch undo excludes the component invalidated by a new independent edit")
        try preflightAndExternal(root.appendingPathComponent("preflight"))
        try preparedLocalEdit(root.appendingPathComponent("prepared-local-edit"))
        try historyOrder(root.appendingPathComponent("lineage"))
        try saveFailure(root.appendingPathComponent("failures"))
        try synchronization(root.appendingPathComponent("collection-sync"))
        try legacyAssetSynchronization(root.appendingPathComponent("legacy-asset-sync"))
        try presetApplication(root.appendingPathComponent("presets"))
        try fallbackHistory(root.appendingPathComponent("fallback-history"))
        try processingMigrationReset(root.appendingPathComponent("migration-reset"))
        var invalid = context; invalid.hasUncommittedDraft = true
        do { _ = try session.copy(scope: .all, snapshot: state(2), context: invalid) } catch {}
        try check(session.clipboard == copy, "Failed copy preserves the frozen clipboard")
        let empty = try session.prepare(payload: copy, targets: [])
        try check(session.apply(empty).isEmpty, "Empty target operation reports no successes")
    }
    static func legacyAssetSynchronization(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let asset = PhotoIdentity(resourceIdentifier: "legacy-library-photo")
        let photo = PhotoIdentity(resourceIdentifier: "legacy-library-photo", contentIdentifier: "verified-current-bytes")
        let regular = PhotoIdentity(contentIdentifier: "ordinary-target")
        let late = PhotoIdentity(resourceIdentifier: "late-library-photo", contentIdentifier: "verified-late-bytes")
        let lateAsset = PhotoIdentity(resourceIdentifier: "late-library-photo")
        let legacy = state(2)
        var source = RawSettings.default; source.contrast = 1.35
        let payload = try IOSAdjustmentTransfer.capture(scope: .custom([.contrast]), snapshot: .init(settings: source), context: context)
        func prepare(_ identities: [PhotoIdentity]) throws -> IOSPreparedAdjustmentTransfer {
            try session.prepare(payload: payload, targets: identities.map {
                .init(identity: $0, displayName: "Photo", defaultState: state(0), context: context)
            }, action: .synchronize)
        }

        try store.save(asset, state: legacy)
        let pending = try prepare([photo, regular])
        guard case .legacyAssetEditNeedsDecision? = pending.targets[0].error as? EditPersistenceError else {
            try check(false, "Synchronization preflight must flag an unconfirmed Photos edit")
            return
        }
        let rejected = session.apply(pending)
        let preserved = try store.unverifiedAssetEdit(for: photo)
        try check(rejected.allSatisfy { $0.status == .blocked } && store.state(for: regular) == nil && preserved == legacy,
                  "An unresolved Photos edit blocks writes and preserves the restoration prompt")
        try check(session.apply(pending, skipping: [photo.key]).map(\.status) == [.skipped, .applied] && store.state(for: photo) == nil,
                  "Skipping the legacy target saves only the other photo")

        try store.resolveUnverifiedAssetEdit(for: photo, expected: legacy, restore: true)
        let confirmed = try prepare([photo])
        try check(session.apply(confirmed).first?.status == .applied && store.state(for: photo)?.settings.exposure == 2 &&
                  store.state(for: photo)?.settings.contrast == 1.35, "Synchronizing only contrast preserves the confirmed +2 EV")
        try check(session.undoTransaction(confirmed.id).first?.status == .applied &&
                  store.state(for: photo)?.settings.exposure == 2 && store.state(for: photo)?.settings.contrast == 1,
                  "Undo restores the confirmed legacy edit without changing its exposure")

        let stale = try prepare([late])
        try store.save(lateAsset, state: legacy)
        let lateResult = session.apply(stale).first
        let unconfirmed = try store.unverifiedAssetEdit(for: late)
        try check(lateResult?.status != .applied && store.state(for: late) == nil && unconfirmed == legacy,
                  "A legacy record discovered after preflight cannot be shadowed on commit")
        try store.resolveUnverifiedAssetEdit(for: late, expected: legacy, restore: true)
        try check(session.apply(stale).first?.status == .conflict && store.state(for: late)?.settings.exposure == 2,
                  "A preflight from before restoration cannot overwrite the restored exposure")
    }

    static func fallbackHistory(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let content = PhotoIdentity(contentIdentifier: "original-content")
        let photo = PhotoIdentity(resourceIdentifier: "library-photo", contentIdentifier: "original-content")
        let legacy = state(0.5)
        try store.save(content, state: legacy)
        let payload = try session.copy(scope: .custom([.exposure]), snapshot: state(1.5), context: context)
        let target = IOSAdjustmentTransferTarget(identity: photo, displayName: "Photo", defaultState: state(0), context: context)
        let operation = try session.prepare(payload: payload, targets: [target])
        try check(operation.targets.first?.original?.state == legacy,
                  "Paste preflight starts from the fallback edit receipt")
        try check(session.apply(operation).first?.status == .applied && store.state(for: photo)?.settings.exposure == 1.5,
                  "Paste writes a new photo record from the fallback receipt")
        try check(session.undoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 0.5,
                  "Undo restores the prior fallback adjustments")
        try check(session.redoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 1.5 &&
                  store.state(for: content) == legacy,
                  "Redo restores photo edits while leaving the old content record untouched")
        try store.reset(photo)
        try check(session.undoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 0.5,
                  "Session history restores its own prior edit after an external photo reset")
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
        let before = try store.readState(for: other)
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
            "Persisted preset applies through the session-owned save path")
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
        try check(session.undoPhoto(a).first?.status == .applied && store.state(for: a)?.settings.exposure == 1,
            "External disk edits do not block a session-owned history operation")
        let remaining = session.undoTransaction(both.id)
        try check(remaining.count == 1 && remaining[0].targetID == b.key && remaining[0].status == .applied
            && store.state(for: b) == nil,
            "History undo processes the remaining target without rereading an old disk receipt")
    }
    static func preparedLocalEdit(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let identity = PhotoIdentity(resourceIdentifier: "prepared-local-edit")
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let operation = try session.prepare(payload: copy, targets: [
            .init(identity: identity, displayName: "A", defaultState: state(0), context: context)])
        let edited = session.commitEdit(expected: try store.readState(for: identity), state: state(2))
        try check(edited.status == .applied, "A local edit succeeds after the paste preflight")
        let result = session.apply(operation).first!
        try check(result.status == .conflict && result.error as? AdjustmentCommitError == .expired &&
                  store.state(for: identity)?.settings.exposure == 2 && session.transactions.count == 1,
                  "The old prepared operation expires without overwriting the local edit or adding history")
    }

    static func historyOrder(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let id = PhotoIdentity(resourceIdentifier: "ordered")
        for value in [1.0, 2, 1] { _ = session.commitEdit(expected: try store.readState(for: id), state: state(value)) }
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
        let before = try store.readState(for: id)
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

    static func processingMigrationReset(_ root: URL) throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        var old = RawSettings.default; old.processing = .c5; old.exposure = 0.75
        let original = PhotoEditState(settings: old, filmID: "legacy-look", updatedAt: Date(timeIntervalSince1970: 10))
        var newer = old; newer.processing = .current
        let migrated = original.replacing(settings: newer, preservingFilmID: original.filmID)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.002, worstTileRMSE: 0.002,
                                                 detailRMSE: 0.001, evaluations: 20)
        let id = PhotoIdentity(resourceIdentifier: "session-reset", contentIdentifier: "bytes-1")
        let sibling = PhotoIdentity(resourceIdentifier: "session-reset", contentIdentifier: "bytes-2")
        let content = PhotoIdentity(contentIdentifier: "bytes-1")
        for target in [id, sibling, content] {
            try store.save(target, state: original)
            let accepted = try store.commitProcessingMigration(expected: store.readState(for: target), candidate: migrated, quality: quality)
            session.adoptProcessingMigration(accepted)
        }
        var edited = newer; edited.exposure = 1.1
        try check(session.commitEdit(expected: store.readState(for: id),
                                     state: original.replacing(settings: edited, preservingFilmID: original.filmID)).status == .applied,
                  "Ordinary session edit succeeds after migration")
        try check(try store.processingMigration(for: id)?.status == .migrated,
                  "Ordinary session edit preserves migration receipt")
        var neutral = RawSettings.default; neutral.processing = .current
        let resetOutcome = session.commitEdit(expected: try store.readState(for: id),
                                              state: PhotoEditState(settings: neutral),
                                              clearsProcessingMigration: true)
        try check(resetOutcome.status == .applied && (try store.processingMigration(for: id)) == nil,
                  "Session reset-all commit clears target migration receipt")
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: id))
            try check(false, "Rollback after session reset must throw expired")
        } catch AdjustmentCommitError.expired { print("PASS: Session reset expires rollback") }
        let reopened = try EditPersistence(directory: root)
        try check(try reopened.processingMigration(for: id) == nil &&
                  reopened.processingMigration(for: sibling)?.status == .migrated &&
                  reopened.processingMigration(for: content)?.status == .migrated,
                  "Reopened store keeps reset target nil while preserving same-PHAsset-other-bytes and content:<id> receipts")
        let undone = session.undoPhoto(id)
        try check(undone.first?.status == .applied && store.state(for: id)?.settings.exposure == 1.1 &&
                  (try store.processingMigration(for: id)) == nil,
                  "Undoing session reset-all restores pre-reset adjustments while keeping migration receipt nil")
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: id))
            try check(false, "Rollback after undoing session reset must stay expired")
        } catch AdjustmentCommitError.expired { }

        let clearedBroken = try session.resetToUnmodified(id)
        try check(clearedBroken.state == nil && !session.canUndoPhoto(id) &&
                  (try store.readState(for: id)).state == nil &&
                  (try store.readState(for: sibling)).state?.settings.exposure == 0.75 &&
                  (try store.readState(for: content)).state?.settings.exposure == 0.75,
                  "Session resetToUnmodified clears target history and record while preserving same-PHAsset-other-bytes and content:<id>")
    }

    // Q3/S1 seam：粘贴提示只随实际应用或确认无关改动的目标呈现（修前提示走根 statusMessage，
    // 被粘贴 Sheet 的模态层级吞掉，快捷预设路径又弹成阻塞 Alert）。
    static func effectiveNoticesFilter() throws {
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "src", isRaw: true, processingVersion: 2,
            recipe: nil, hdrProcessingVersion: nil), values: ["light.exposure": .number(0.5)])
        func target(_ id: String, _ error: Error?, _ notices: [AdjustmentTransferNotice]) -> IOSPreparedAdjustmentTransfer.Target {
            .init(id: id, displayName: id, original: nil, candidate: nil, unchanged: false, isCurrent: nil,
                validateSource: nil, error: error, editGeneration: 0, notices: notices)
        }
        let prepared = IOSPreparedAdjustmentTransfer(id: UUID(), payload: payload, action: .paste, targets: [
            target("a", nil, [.ignoredRawDenoise]), target("b", nil, [.ignoredPostRGBDenoise]),
            target("c", nil, [.retainedTargetProcessingVersion]),
            target("d", NSError(domain: "gone", code: 1), [.ignoredRawDenoise])], notices: [.ignoredRawDenoise])
        let outcomes = [IOSAdjustmentTransferOutcome(targetID: "a", status: .applied, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "b", status: .skipped, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "c", status: .failed, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "d", status: .applied, saved: nil, error: nil)]
        try check(prepared.effectiveNotices(outcomes) == [.ignoredRawDenoise],
            "Paste notices surface only for targets that actually applied")
        try check(prepared.effectiveNotices([]).isEmpty, "Prepared notices stay hidden until apply outcomes exist")
    }
}
