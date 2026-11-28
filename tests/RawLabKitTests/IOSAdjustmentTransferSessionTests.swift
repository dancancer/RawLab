import Foundation
import XCTest
@testable import RawLabKit

final class IOSAdjustmentTransferSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-ios-transfer-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private var context: IOSAdjustmentTransferContext {
        .init(identifier: "source", isRaw: true)
    }

    private func state(_ exposure: Double) -> PhotoEditState {
        var settings = RawSettings.default; settings.exposure = exposure
        return .init(settings: settings, updatedAt: Date(timeIntervalSince1970: 100))
    }

    func testCoreCopyPreviewPartialApplyRetryUndoRedoAndInvalidDraft() throws {
        let store = try EditPersistence(directory: root), session = IOSAdjustmentTransferSession(store: store)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var failB = false
        let targets = [
            IOSAdjustmentTransferTarget(identity: a, displayName: "A", defaultState: state(0), context: context),
            IOSAdjustmentTransferTarget(identity: b, displayName: "B", defaultState: state(0), context: context,
                validateSource: { if failB { throw NSError(domain: "missing B", code: 1) } })
        ]
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let preview = try IOSAdjustmentTransfer.previewCapture(scope: .modified, snapshot: state(1), committed: state(1), context: context)
        XCTAssertTrue(
            preview.fields == [.exposure] && preview[.exposure] == .number(1),
            "Scope preview uses actual modified capture fields and values"
        )
        let emptyPreview = Result { try IOSAdjustmentTransfer.previewCapture(scope: .modified, snapshot: state(0), committed: state(0), context: context) }
        if case .failure(let error) = emptyPreview {
            XCTAssertEqual(error as? AdjustmentTransferError, .emptyScope, "Neutral modified preview is an empty scope")
        } else {
            XCTFail("Neutral modified preview must be empty")
        }
        let stale = Result { try IOSAdjustmentTransfer.previewCapture(scope: .all, snapshot: state(2), committed: state(1), context: context) }
        if case .failure(let error) = stale {
            XCTAssertEqual(error as? AdjustmentTransferError, .draftRequiresPreflight, "Unsaved settings cannot display a stale scope preview")
        } else {
            XCTFail("Stale preview must fail")
        }
        var hdrSettings = RawSettings.default; hdrSettings.hdr = HDRSettings()
        let hdrState = PhotoEditState(settings: hdrSettings)
        let hdrPreview = try IOSAdjustmentTransfer.previewCapture(
            scope: .standard(isHDR: true),
            snapshot: hdrState,
            committed: hdrState,
            context: .init(identifier: "hdr", isRaw: false, sourceIsHDR: true)
        )
        XCTAssertTrue(
            hdrPreview.fields == AdjustmentTransferField.hdrCommon && hdrPreview.source.isHDR,
            "HDR scope preview preserves the seven-field family"
        )
        XCTAssertTrue(
            try session.clipboard == copy && session.transactions.isEmpty && store.state(for: a) == nil,
            "Scope preview leaves clipboard, history and persistence unchanged"
        )
        let operation = try session.prepare(payload: copy, targets: targets + [targets[0]])
        XCTAssertEqual(operation.targets.count, 2, "Stable identities deduplicate operation targets")
        failB = true
        let partial = session.apply(operation)
        XCTAssertTrue(
            partial.map(\.status) == [.applied, .failed] && session.transactions.count == 1 &&
                session.transactions[0].parts.count == 1,
            "Only successfully saved targets enter a partial transaction"
        )
        let savedA = try store.readState(for: a, isX3f: false)
        failB = false
        let retry = session.apply(operation)
        XCTAssertTrue(
            try retry.map(\.status) == [.applied, .applied] && store.readState(for: a, isX3f: false).hasSameAdjustments(as: savedA),
            "Retry saves only the failed target and preserves the successful target"
        )
        let undoA = session.undoPhoto(a)
        XCTAssertTrue(
            try undoA.count == 1 && undoA[0].status == .applied && store.state(for: a) == nil,
            "Single-photo undo restores absence without undoing other successful targets"
        )
        let undoRest = session.undoTransaction(operation.id)
        XCTAssertTrue(
            try undoRest.count == 1 && undoRest[0].targetID == b.key && store.state(for: b) == nil,
            "Batch undo processes only still-applied components"
        )
        XCTAssertTrue(
            try session.redoTransaction(operation.id).count == 2 && store.state(for: a)?.settings.exposure == 1,
            "Batch redo restores exactly the two undone components"
        )
        let noChange = try session.prepare(payload: copy, targets: targets)
        let count = session.transactions.count
        XCTAssertTrue(
            session.apply(noChange).allSatisfy { $0.status == .unchanged } && session.transactions.count == count,
            "Identical paste creates no history"
        )
        _ = session.undoPhoto(a)
        let timestampOnly = session.commitEdit(expected: try store.readState(for: a, isX3f: false), state: state(0), defaultState: state(0))
        XCTAssertTrue(timestampOnly.status == .unchanged && session.canRedoPhoto(a), "Default absence no-op preserves redo")
        let newEdit = session.commitEdit(expected: try store.readState(for: a, isX3f: false), state: state(2))
        XCTAssertTrue(newEdit.status == .applied && !session.canRedoPhoto(a), "New edit clears only that photo's redo")
        XCTAssertEqual(
            session.transactions.first?.parts.first(where: { $0.identity == b })?.state,
            .applied,
            "Other photo history survives a new single-photo edit"
        )
        _ = session.commitEdit(expected: try store.readState(for: a, isX3f: false), state: state(1))
        let remaining = session.undoTransaction(operation.id)
        XCTAssertTrue(
            try remaining.count == 1 && remaining[0].targetID == b.key && remaining[0].status == .applied &&
                store.state(for: a)?.settings.exposure == 1 && store.state(for: b) == nil,
            "Batch undo excludes the component invalidated by a new independent edit"
        )

        var invalid = context; invalid.hasUncommittedDraft = true
        do { _ = try session.copy(scope: .all, snapshot: state(2), context: invalid) } catch {}
        XCTAssertEqual(session.clipboard, copy, "Failed copy preserves the frozen clipboard")
        let empty = try session.prepare(payload: copy, targets: [])
        XCTAssertTrue(session.apply(empty).isEmpty, "Empty target operation reports no successes")
    }

    func testLegacyAssetSynchronization() throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("legacy-asset-sync"))
        let session = IOSAdjustmentTransferSession(store: store)
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
            XCTFail("Synchronization preflight must flag an unconfirmed Photos edit")
            return
        }
        let rejected = session.apply(pending)
        let preserved = try store.unverifiedAssetEdit(for: photo)
        XCTAssertTrue(
            try rejected.allSatisfy { $0.status == .blocked } && store.state(for: regular) == nil && preserved == legacy,
            "An unresolved Photos edit blocks writes and preserves the restoration prompt"
        )
        XCTAssertTrue(
            try session.apply(pending, skipping: [photo.key]).map(\.status) == [.skipped, .applied] && store.state(for: photo) == nil,
            "Skipping the legacy target saves only the other photo"
        )

        try store.resolveUnverifiedAssetEdit(for: photo, expected: legacy, restore: true)
        let confirmed = try prepare([photo])
        XCTAssertTrue(
            try session.apply(confirmed).first?.status == .applied && store.state(for: photo)?.settings.exposure == 2 &&
                store.state(for: photo)?.settings.contrast == 1.35,
            "Synchronizing only contrast preserves the confirmed +2 EV"
        )
        XCTAssertTrue(
            try session.undoTransaction(confirmed.id).first?.status == .applied &&
                store.state(for: photo)?.settings.exposure == 2 && store.state(for: photo)?.settings.contrast == 1,
            "Undo restores the confirmed legacy edit without changing its exposure"
        )

        let stale = try prepare([late])
        try store.save(lateAsset, state: legacy)
        let lateResult = session.apply(stale).first
        let unconfirmed = try store.unverifiedAssetEdit(for: late)
        XCTAssertTrue(
            try lateResult?.status != .applied && store.state(for: late) == nil && unconfirmed == legacy,
            "A legacy record discovered after preflight cannot be shadowed on commit"
        )
        try store.resolveUnverifiedAssetEdit(for: late, expected: legacy, restore: true)
        XCTAssertTrue(
            try session.apply(stale).first?.status == .conflict && store.state(for: late)?.settings.exposure == 2,
            "A preflight from before restoration cannot overwrite the restored exposure"
        )
    }

    func testFallbackHistory() throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("fallback-history"))
        let session = IOSAdjustmentTransferSession(store: store)
        let content = PhotoIdentity(contentIdentifier: "original-content")
        let photo = PhotoIdentity(resourceIdentifier: "library-photo", contentIdentifier: "original-content")
        let legacy = state(0.5)
        try store.save(content, state: legacy)
        let payload = try session.copy(scope: .custom([.exposure]), snapshot: state(1.5), context: context)
        let target = IOSAdjustmentTransferTarget(identity: photo, displayName: "Photo", defaultState: state(0), context: context)
        let operation = try session.prepare(payload: payload, targets: [target])
        XCTAssertEqual(operation.targets.first?.original?.state, legacy, "Paste preflight starts from the fallback edit receipt")
        XCTAssertTrue(
            try session.apply(operation).first?.status == .applied && store.state(for: photo)?.settings.exposure == 1.5,
            "Paste writes a new photo record from the fallback receipt"
        )
        XCTAssertTrue(
            try session.undoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 0.5,
            "Undo restores the prior fallback adjustments"
        )
        XCTAssertTrue(
            try session.redoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 1.5 &&
                store.state(for: content) == legacy,
            "Redo restores photo edits while leaving the old content record untouched"
        )
        try store.reset(photo)
        XCTAssertTrue(
            try session.undoPhoto(photo).first?.status == .applied && store.state(for: photo)?.settings.exposure == 0.5,
            "Session history restores its own prior edit after an external photo reset"
        )
    }

    func testSynchronization() throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("collection-sync"))
        let session = IOSAdjustmentTransferSession(store: store)
        let source = PhotoIdentity(resourceIdentifier: "sync-source"), other = PhotoIdentity(resourceIdentifier: "sync-other")
        var syncContext = self.context; syncContext.identifier = source.key
        let clipboard = try session.copy(scope: .all, snapshot: state(0.5), context: syncContext)
        let payload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(1.25), context: syncContext)
        var original = state(0).settings; original.contrast = 0.37
        try store.save(source, state: state(0.5))
        try store.save(other, state: PhotoEditState(settings: original))
        let targets = [source, other, other].map {
            IOSAdjustmentTransferTarget(identity: $0, displayName: "same.png", defaultState: state(0), context: syncContext)
        }
        let operation = try session.prepare(payload: payload, targets: targets, action: .synchronize)
        XCTAssertEqual(operation.targets.map(\.id), [other.key], "Synchronization excludes the selected source and deduplicates by identity, not filename")
        let results = session.apply(operation)
        XCTAssertTrue(
            try results.map(\.status) == [.applied] && store.state(for: source)?.settings.exposure == 0.5 &&
                store.state(for: other)?.settings.exposure == 1.25 && store.state(for: other)?.settings.contrast == 0.37,
            "Synchronization saves only selected fields on actual targets"
        )
        XCTAssertTrue(
            session.clipboard == clipboard && session.transactions.first?.action == .synchronize,
            "Synchronization retains clipboard and records its own history action"
        )
        let unsafe = try session.prepare(payload: payload, targets: [targets[0]], action: .paste)
        let injected = IOSPreparedAdjustmentTransfer(id: UUID(), payload: payload, action: .synchronize, targets: unsafe.targets)
        let rejected = session.apply(injected)
        XCTAssertTrue(
            try rejected.map(\.status) == [.blocked] && store.state(for: source)?.settings.exposure == 0.5,
            "Write-time source exclusion rejects a source reintroduced after preparation"
        )
        let before = try store.readState(for: other, isX3f: false)
        var micro = before.state!.settings; micro.contrast = 0.61
        let edit = session.commitEdit(expected: before, state: PhotoEditState(settings: micro))
        XCTAssertTrue(
            try edit.status == .applied && store.state(for: other)?.settings.contrast == 0.61,
            "A collection photo can receive an independent micro-edit"
        )
        let secondPayload = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: state(1.75), context: syncContext)
        let second = try session.prepare(payload: secondPayload, targets: targets, action: .synchronize)
        _ = session.apply(second)
        XCTAssertTrue(
            try store.state(for: other)?.settings.exposure == 1.75 && store.state(for: other)?.settings.contrast == 0.61,
            "A second synchronization preserves unselected micro-edits"
        )
        let undo = session.undoTransaction(second.id)
        XCTAssertTrue(
            try undo.map(\.status) == [.applied] && store.state(for: other)?.settings.exposure == 1.25 &&
                store.state(for: other)?.settings.contrast == 0.61,
            "Transaction history restores only the successful synchronization component"
        )
    }

    func testPresetApplication() throws {
        let presetRoot = root.appendingPathComponent("presets")
        let edits = try EditPersistence(directory: presetRoot.appendingPathComponent("edits"))
        let session = IOSAdjustmentTransferSession(store: edits)
        let library = AdjustmentPresetStore(directory: presetRoot.appendingPathComponent("library"))
        let clipboard = try session.copy(scope: .custom([.exposure]), snapshot: state(0.5), context: context)
        var sourceSettings = state(1.25).settings
        sourceSettings.blackPoint = -32.75; sourceSettings.whitePoint = 46.5; sourceSettings.vibrance = 21.25
        let source = try IOSAdjustmentTransfer.capture(
            scope: .custom([.exposure, .blackPoint, .whitePoint, .vibrance]),
            snapshot: PhotoEditState(settings: sourceSettings),
            context: context
        )
        let saved = try library.create(name: "iOS preset", payload: source)
        XCTAssertTrue(session.clipboard == clipboard && session.transactions.isEmpty, "Preset save leaves clipboard and photo history unchanged")
        let reloaded = try XCTUnwrap(AdjustmentPresetStore(directory: library.directory).list().first)
        var beforeSettings = state(-0.5).settings; beforeSettings.saturation = 1.2
        let before = PhotoEditState(settings: beforeSettings)
        let identity = PhotoIdentity(resourceIdentifier: "preset-target")
        try edits.save(identity, state: before)
        let direct = try IOSAdjustmentTransfer.prepare(payload: source, target: before, context: context)
        let candidate = try IOSAdjustmentTransfer.prepare(payload: reloaded.payload, target: before, context: context)
        XCTAssertEqual(candidate.settings, direct.settings, "Preset and clipboard resolve identical native settings")
        let targets = [IOSAdjustmentTransferTarget(
            identity: identity,
            displayName: "Preset target",
            defaultState: state(0),
            context: context
        )]
        let operation = try session.prepare(payload: reloaded.payload, targets: targets, action: .preset)
        XCTAssertTrue(
            try session.apply(operation).first?.status == .applied && edits.state(for: identity)?.settings.exposure == 1.25,
            "Persisted preset applies through the session-owned save path"
        )
        XCTAssertTrue(
            try edits.state(for: identity)?.settings.saturation == 1.2 && session.clipboard == clipboard,
            "Preset application preserves unselected fields and the frozen clipboard"
        )
        XCTAssertTrue(
            session.transactions.count == 1 && session.transactions[0].action == .preset,
            "Preset application records its own action in the shared photo history"
        )
        XCTAssertEqual(
            try edits.state(for: identity)?.settings.toneSettings,
            sourceSettings.toneSettings,
            "Preset application saves exact tone fields in the photo registry"
        )
        try library.delete(saved)
        XCTAssertEqual(
            try edits.state(for: identity)?.settings.exposure,
            1.25,
            "Deleting a preset does not change an already-applied photo"
        )
        XCTAssertTrue(
            try session.undoPhoto(identity).first?.status == .applied && edits.state(for: identity)?.hasSameAdjustments(as: before) == true,
            "Preset undo restores the full prior photo state"
        )
        let unchanged = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: before, context: context)
        let noChange = try session.prepare(payload: unchanged, targets: targets, action: .preset)
        XCTAssertTrue(
            session.apply(noChange).first?.status == .unchanged && session.canRedoPhoto(identity),
            "No-change preset application preserves the redo branch"
        )
        XCTAssertTrue(
            try session.redoPhoto(identity).first?.status == .applied && edits.state(for: identity)?.settings.exposure == 1.25,
            "Preset redo restores the saved result after the preset itself was deleted"
        )
        XCTAssertEqual(
            try edits.state(for: identity)?.settings.toneSettings,
            sourceSettings.toneSettings,
            "Preset redo restores all tone values after deleting the source preset"
        )
    }

    func testPreflightAndExternal() throws {
        let dir = root.appendingPathComponent("preflight")
        let store = try EditPersistence(directory: dir), session = IOSAdjustmentTransferSession(store: store)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let blocked = try session.prepare(payload: copy, targets: [
            .init(identity: a, displayName: "A", defaultState: state(0), context: context),
            .init(identity: b, displayName: "B", defaultState: state(0), context: context, isCurrent: { false })
        ])
        XCTAssertTrue(
            try session.apply(blocked).allSatisfy { $0.status == .blocked } && store.state(for: a) == nil,
            "Unresolved draft preflight writes no target"
        )
        XCTAssertEqual(
            session.apply(blocked, skipping: [b.key]).map(\.status),
            [.applied, .skipped],
            "Explicit preflight skip saves only the accepted target"
        )
        let next = try session.copy(scope: .custom([.exposure]), snapshot: state(2), context: context)
        let both = try session.prepare(payload: next, targets: [a, b].map {
            .init(identity: $0, displayName: $0.key, defaultState: state(0), context: context)
        })
        _ = session.apply(both)
        let external = try EditPersistence(directory: dir)
        try external.save(a, state: state(3)); try external.save(a, state: state(2))
        XCTAssertTrue(
            try session.undoPhoto(a).first?.status == .applied && store.state(for: a)?.settings.exposure == 1,
            "External disk edits do not block a session-owned history operation"
        )
        let remaining = session.undoTransaction(both.id)
        XCTAssertTrue(
            try remaining.count == 1 && remaining[0].targetID == b.key && remaining[0].status == .applied &&
                store.state(for: b) == nil,
            "History undo processes the remaining target without rereading an old disk receipt"
        )
    }

    func testPreparedLocalEdit() throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("prepared-local-edit"))
        let session = IOSAdjustmentTransferSession(store: store)
        let identity = PhotoIdentity(resourceIdentifier: "prepared-local-edit")
        let copy = try session.copy(scope: .custom([.exposure]), snapshot: state(1), context: context)
        let operation = try session.prepare(payload: copy, targets: [
            .init(identity: identity, displayName: "A", defaultState: state(0), context: context)
        ])
        let edited = session.commitEdit(expected: try store.readState(for: identity, isX3f: false), state: state(2))
        XCTAssertEqual(edited.status, .applied, "A local edit succeeds after the paste preflight")
        let result = try XCTUnwrap(session.apply(operation).first)
        XCTAssertTrue(
            try result.status == .conflict && result.error as? AdjustmentCommitError == .expired &&
                store.state(for: identity)?.settings.exposure == 2 && session.transactions.count == 1,
            "The old prepared operation expires without overwriting the local edit or adding history"
        )
    }

    func testHistoryOrder() throws {
        let store = try EditPersistence(directory: root.appendingPathComponent("lineage"))
        let session = IOSAdjustmentTransferSession(store: store)
        let id = PhotoIdentity(resourceIdentifier: "ordered")
        for value in [1.0, 2, 1] { _ = session.commitEdit(expected: try store.readState(for: id, isX3f: false), state: state(value)) }
        let first = session.transactions[0].id
        XCTAssertEqual(session.undoTransaction(first).first?.status, .conflict, "Own ABA cannot undo an older transaction out of order")
        _ = session.undoPhoto(id); XCTAssertEqual(try store.state(for: id)?.settings.exposure, 2, "Latest undo restores immediate predecessor")
        _ = session.undoPhoto(id); XCTAssertEqual(try store.state(for: id)?.settings.exposure, 1, "Second undo follows causal history")
        _ = session.undoPhoto(id); XCTAssertNil(try store.state(for: id), "Final undo restores original absence")
        for _ in 0..<3 { _ = session.redoPhoto(id) }
        XCTAssertEqual(try store.state(for: id)?.settings.exposure, 1, "Redo replays the same causal chain")
    }

    func testSaveFailure() throws {
        var fail = false
        let store = try EditPersistence(directory: root.appendingPathComponent("failures"), writeData: { bytes, url in
            if fail { throw NSError(domain: "disk failure", code: 1) }
            try bytes.write(to: url, options: .atomic)
        })
        let session = IOSAdjustmentTransferSession(store: store), id = PhotoIdentity(resourceIdentifier: "retry")
        let before = try store.readState(for: id, isX3f: false)
        fail = true
        XCTAssertTrue(
            session.commitEdit(expected: before, state: state(1)).status == .failed && session.transactions.isEmpty,
            "Failed ordinary save creates no history"
        )
        fail = false
        XCTAssertTrue(
            session.commitEdit(expected: before, state: state(1)).status == .applied && session.transactions.count == 1,
            "Ordinary save retry creates one successful history component"
        )
        fail = true
        XCTAssertTrue(
            session.undoPhoto(id).first?.status == .failed && !session.canRedoPhoto(id),
            "Failed inverse save does not move history state"
        )
        fail = false
        XCTAssertTrue(
            session.undoPhoto(id).first?.status == .applied && session.canRedoPhoto(id),
            "Inverse save can retry successfully"
        )
    }

    func testProcessingMigrationReset() throws {
        let dir = root.appendingPathComponent("migration-reset")
        let store = try EditPersistence(directory: dir), session = IOSAdjustmentTransferSession(store: store)
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
            let accepted = try store.commitProcessingMigration(expected: store.readState(for: target, isX3f: false), candidate: migrated, quality: quality)
            session.adoptProcessingMigration(accepted)
        }
        var edited = newer; edited.exposure = 1.1
        XCTAssertEqual(
            session.commitEdit(
                expected: try store.readState(for: id, isX3f: false),
                state: original.replacing(settings: edited, preservingFilmID: original.filmID)
            ).status,
            .applied,
            "Ordinary session edit succeeds after migration"
        )
        XCTAssertEqual(try store.processingMigration(for: id)?.status, .migrated, "Ordinary session edit preserves migration receipt")
        var neutral = RawSettings.default; neutral.processing = .current
        let resetOutcome = session.commitEdit(
            expected: try store.readState(for: id, isX3f: false),
            state: PhotoEditState(settings: neutral),
            clearsProcessingMigration: true
        )
        XCTAssertTrue(
            try resetOutcome.status == .applied && store.processingMigration(for: id) == nil,
            "Session reset-all commit clears target migration receipt"
        )
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: id, isX3f: false), isX3f: false)
            XCTFail("Rollback after session reset must throw expired")
        } catch AdjustmentCommitError.expired {}
        let reopened = try EditPersistence(directory: dir)
        XCTAssertTrue(
            try reopened.processingMigration(for: id) == nil &&
                reopened.processingMigration(for: sibling)?.status == .migrated &&
                reopened.processingMigration(for: content)?.status == .migrated,
            "Reopened store keeps reset target nil while preserving same-PHAsset-other-bytes and content:<id> receipts"
        )
        let undone = session.undoPhoto(id)
        XCTAssertTrue(
            try undone.first?.status == .applied && store.state(for: id)?.settings.exposure == 1.1 &&
                store.processingMigration(for: id) == nil,
            "Undoing session reset-all restores pre-reset adjustments while keeping migration receipt nil"
        )
        do {
            _ = try store.rollbackProcessingMigration(expected: store.readState(for: id, isX3f: false), isX3f: false)
            XCTFail("Rollback after undoing session reset must stay expired")
        } catch AdjustmentCommitError.expired {}

        let clearedBroken = try session.resetToUnmodified(id)
        XCTAssertTrue(
            try clearedBroken.state == nil && !session.canUndoPhoto(id) &&
                store.readState(for: id, isX3f: false).state == nil &&
                store.readState(for: sibling, isX3f: false).state?.settings.exposure == 0.75 &&
                store.readState(for: content, isX3f: false).state?.settings.exposure == 0.75,
            "Session resetToUnmodified clears target history and record while preserving same-PHAsset-other-bytes and content:<id>"
        )
    }

    // Q3/S1 seam：粘贴提示只随实际应用或确认无关改动的目标呈现（修前提示走根 statusMessage，
    // 被粘贴 Sheet 的模态层级吞掉，快捷预设路径又弹成阻塞 Alert）。
    func testEffectiveNoticesFilter() throws {
        let payload = try AdjustmentTransferPayload(
            source: .init(identifier: "src", isRaw: true, processingVersion: 2, recipe: nil, hdrProcessingVersion: nil),
            values: ["light.exposure": .number(0.5)]
        )
        func target(_ id: String, _ error: Error?, _ notices: [AdjustmentTransferNotice]) -> IOSPreparedAdjustmentTransfer.Target {
            .init(id: id, displayName: id, original: nil, candidate: nil, unchanged: false, isCurrent: nil,
                  validateSource: nil, error: error, editGeneration: 0, notices: notices)
        }
        let prepared = IOSPreparedAdjustmentTransfer(id: UUID(), payload: payload, action: .paste, targets: [
            target("a", nil, [.ignoredRawDenoise]), target("b", nil, [.ignoredPostRGBDenoise]),
            target("c", nil, [.retainedTargetProcessingVersion]),
            target("d", NSError(domain: "gone", code: 1), [.ignoredRawDenoise])
        ], notices: [.ignoredRawDenoise])
        let outcomes = [
            IOSAdjustmentTransferOutcome(targetID: "a", status: .applied, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "b", status: .skipped, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "c", status: .failed, saved: nil, error: nil),
            IOSAdjustmentTransferOutcome(targetID: "d", status: .applied, saved: nil, error: nil)
        ]
        XCTAssertEqual(
            prepared.effectiveNotices(outcomes),
            [.ignoredRawDenoise],
            "Paste notices surface only for targets that actually applied"
        )
        XCTAssertTrue(prepared.effectiveNotices([]).isEmpty, "Prepared notices stay hidden until apply outcomes exist")
    }

    // V-UIIOS #301 seam：Sheet 内提示行只随当前粘贴批次的结果展示。提示属性留在共享
    // ViewModel 上，重开面板或重新检查后 pasteResults 已清空，旧提示不得抢先显示。
    func testSheetNoticeDisplay() {
        XCTAssertFalse(
            IOSAdjustmentPasteNoticeDisplay.showsInSheet(notices: ["降噪已忽略"], hasPasteResults: false),
            "Sheet hides stale notices before the new batch produces paste results"
        )
        XCTAssertTrue(
            IOSAdjustmentPasteNoticeDisplay.showsInSheet(notices: ["降噪已忽略"], hasPasteResults: true),
            "Sheet shows delivered notices next to the current paste results"
        )
        XCTAssertFalse(
            IOSAdjustmentPasteNoticeDisplay.showsInSheet(notices: [], hasPasteResults: true),
            "No notices keep the sheet notice row closed"
        )
    }
}
