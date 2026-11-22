import Combine
import Foundation

// 每个请求独占粘性取消标记；旧任务排空后才开始下一轮，完成回调也按请求身份验收。
public final class AdjustmentTransferPreflight: ObservableObject {
    private final class Cancellation {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    private let queue: DispatchQueue
    private var active: Cancellation?

    public init(queue: DispatchQueue = DispatchQueue(label: "rawlab.adjustment-preflight", qos: .userInitiated)) {
        self.queue = queue
    }

    deinit { active?.cancel() }

    public func cancel() { active?.cancel(); active = nil }

    public func start(_ operation: @escaping (@escaping () -> Bool) throws -> PreparedAdjustmentTransfer,
                      completed: @escaping (Result<PreparedAdjustmentTransfer, Error>) -> Void) {
        cancel()
        let cancellation = Cancellation()
        active = cancellation
        queue.async { [weak self] in
            let result = Result {
                if cancellation.cancelled { throw CancellationError() }
                return try operation { cancellation.cancelled }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active === cancellation, !cancellation.cancelled else { return }
                self.active = nil
                completed(result)
            }
        }
    }
}

public struct AdjustmentTransferTarget {
    public let url: URL
    public let defaultState: MacPhotoEditState
    public var context: MacAdjustmentTransferContext
    public var expectedIdentity: OriginalFileIdentity?
    public var isCurrent: (() -> Bool)?
    public var resolveMetadata: ((MacPhotoEditState) throws -> MacPhotoEditState)?
    public var resolveDefaultState: (() throws -> MacPhotoEditState)?

    public init(url: URL,
                defaultState: MacPhotoEditState,
                context: MacAdjustmentTransferContext,
                expectedIdentity: OriginalFileIdentity? = nil,
                isCurrent: (() -> Bool)? = nil,
                resolveMetadata: ((MacPhotoEditState) throws -> MacPhotoEditState)? = nil,
                resolveDefaultState: (() throws -> MacPhotoEditState)? = nil) {
        self.url = url
        self.defaultState = defaultState
        self.context = context
        self.expectedIdentity = expectedIdentity
        self.isCurrent = isCurrent
        self.resolveMetadata = resolveMetadata
        self.resolveDefaultState = resolveDefaultState
    }
}

public typealias AdjustmentTransferStatus = SharedAdjustmentTransferStatus
public typealias AdjustmentTransferOutcome = SharedAdjustmentTransferOutcome<MacPhotoEditRecord>
public typealias AdjustmentHistoryTransaction = SharedAdjustmentHistoryTransaction<OriginalFileIdentity, MacPhotoEditState>

public struct PreparedAdjustmentTransfer {
    public struct Target {
        public let id: String
        public let original: MacPhotoEditRecord?
        public let candidate: MacPhotoEditState?
        public let unchanged: Bool
        public let isCurrent: (() -> Bool)?
        public let error: Error?
        public var editGeneration: UInt64 = 0
        public var notices: [AdjustmentTransferNotice] = []

        public init(id: String,
                    original: MacPhotoEditRecord?,
                    candidate: MacPhotoEditState?,
                    unchanged: Bool,
                    isCurrent: (() -> Bool)?,
                    error: Error?,
                    editGeneration: UInt64 = 0,
                    notices: [AdjustmentTransferNotice] = []) {
            self.id = id
            self.original = original
            self.candidate = candidate
            self.unchanged = unchanged
            self.isCurrent = isCurrent
            self.error = error
            self.editGeneration = editGeneration
            self.notices = notices
        }
    }
    public let id: UUID
    public let payload: AdjustmentTransferPayload
    public let targets: [Target]
    public let action: AdjustmentHistoryTransaction.Action
    public var notices: [AdjustmentTransferNotice] = []

    public init(id: UUID,
                payload: AdjustmentTransferPayload,
                targets: [Target],
                action: AdjustmentHistoryTransaction.Action,
                notices: [AdjustmentTransferNotice] = []) {
        self.id = id
        self.payload = payload
        self.targets = targets
        self.action = action
        self.notices = notices
    }

    // Q3/S1：仅呈现实际应用（或确认无需改动）目标的去重提示；跳过、失败或冲突目标不提示。
    public func effectiveNotices(_ outcomes: [AdjustmentTransferOutcome]) -> [AdjustmentTransferNotice] {
        var merged = [AdjustmentTransferNotice]()
        for target in targets where target.error == nil
            && outcomes.contains(where: { $0.targetID == target.id && ($0.status == .applied || $0.status == .unchanged) }) {
            for notice in target.notices where !merged.contains(notice) { merged.append(notice) }
        }
        return merged
    }
}

// 编辑与历史在编辑器线程提交；后台预检只读取会话代次和冻结参数。
public final class AdjustmentTransferSession {
    private let store: MacEditPersistence
    private let ledger: AdjustmentHistoryLedger<OriginalFileIdentity, MacPhotoEditState, MacPhotoEditRecord>
    public var transactions: [AdjustmentHistoryTransaction] { ledger.transactions }
    public private(set) var clipboard: AdjustmentTransferPayload?

    public init(store: MacEditPersistence) {
        self.store = store
        self.ledger = AdjustmentHistoryLedger(
            keyOf: { $0.path },
            identityOf: { $0.identity },
            stateOf: { $0.state },
            sameState: { $0 == $1 },
            sameRecord: { $0 == $1 }
        )
    }

    public var hasPendingCommits: Bool {
        store.hasPendingCommits || ledger.hasInFlightCommits
    }

    @discardableResult
    public func flushPendingCommits() -> Bool {
        store.flushPendingCommits()
    }

    public func knownRecord(forPath path: String) -> MacPhotoEditRecord? {
        ledger.knownRecord(forKey: path)
    }

    public func editGeneration(for url: URL) -> UInt64 {
        ledger.editGeneration(forKey: Self.key(for: url))
    }

    public func isCurrentSave(_ record: MacPhotoEditRecord) -> Bool {
        ledger.isCurrentSave(record)
    }

    // 迁移拥有持久回退；旧的内存历史不能越过这次原子提交覆盖它。
    public func adoptProcessingMigration(_ record: MacPhotoEditRecord) {
        ledger.adoptProcessingMigration(record)
    }

    @discardableResult
    public func adoptExternalReload(
        expected: MacPhotoEditRecord,
        reloaded: MacPhotoEditRecord
    ) -> AdjustmentTransferOutcome {
        _ = store.flushPendingCommits()
        let key = reloaded.identity.path
        guard expected.identity.path == key else {
            return outcome(key, .conflict, error: AdjustmentCommitError.photoChanged)
        }
        if expected.state == reloaded.state {
            ledger.remember(reloaded, advanceGeneration: false)
            return outcome(key, .unchanged, saved: reloaded)
        }
        let known = ledger.knownRecord(forKey: key)
        let before = (known?.identity == reloaded.identity ? known : nil) ?? expected
        _ = ledger.record(
            id: UUID(),
            action: .edit,
            fields: [],
            displayName: "",
            before: before,
            after: reloaded
        )
        return outcome(key, .applied, saved: reloaded)
    }

    @discardableResult public func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord {
        _ = store.flushPendingCommits()
        let cleared = try store.resetToUnmodified(url)
        adoptProcessingMigration(cleared)
        return cleared
    }

    @discardableResult public func copy(scope: AdjustmentTransferScope, snapshot: MacPhotoEditState,
                                        context: MacAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        let captured = try MacAdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context)
        clipboard = captured
        return captured
    }

    public func prepare(payload: AdjustmentTransferPayload, targets: [AdjustmentTransferTarget],
                        action: AdjustmentHistoryTransaction.Action = .paste,
                        shouldCancel: () -> Bool = { false }) throws -> PreparedAdjustmentTransfer {
        if Thread.isMainThread {
            _ = store.flushPendingCommits()
        } else {
            store.waitForPendingIO()
        }
        if shouldCancel() { throw CancellationError() }
        try payload.validate()
        var seen = Set<String>()
        var prepared = [PreparedAdjustmentTransfer.Target]()
        for target in targets {
            if shouldCancel() { throw CancellationError() }
            let id = Self.key(for: target.url)
            guard seen.insert(id).inserted else { continue }
            do {
                guard target.isCurrent?() != false else { throw AdjustmentTransferError.draftRequiresPreflight }
                let generation = editGeneration(for: target.url)
                let original = try store.readState(for: target.url)
                if let expected = target.expectedIdentity, original.identity != expected { throw AdjustmentCommitError.photoChanged }
                let stored = try original.state ?? target.resolveDefaultState?() ?? target.defaultState
                let effective = try target.resolveMetadata?(stored) ?? stored
                var notices = [AdjustmentTransferNotice]()
                var context = target.context
                context.transferNotices = { notices.append($0) }
                let candidate = try MacAdjustmentTransfer.prepare(payload: payload, target: effective, context: context)
                prepared.append(.init(id: id, original: original, candidate: candidate, unchanged: candidate == effective,
                    isCurrent: target.isCurrent, error: nil, editGeneration: generation, notices: notices))
            } catch {
                prepared.append(.init(id: id, original: nil, candidate: nil, unchanged: false,
                    isCurrent: target.isCurrent, error: error))
            }
        }
        if shouldCancel() { throw CancellationError() }
        var mergedNotices = [AdjustmentTransferNotice]()
        for notice in prepared.flatMap(\.notices) where !mergedNotices.contains(notice) { mergedNotices.append(notice) }
        return PreparedAdjustmentTransfer(id: UUID(), payload: payload, targets: prepared, action: action, notices: mergedNotices)
    }

    public func apply(_ operation: PreparedAdjustmentTransfer, skipping: Set<String> = []) -> [AdjustmentTransferOutcome] {
        _ = store.flushPendingCommits()
        let specs = operation.targets.map { target in
            PreparedTransferTargetSpec(
                id: target.id,
                displayName: "",
                original: target.original,
                candidate: target.candidate,
                unchanged: target.unchanged,
                isCurrent: target.isCurrent,
                error: target.error,
                editGeneration: target.editGeneration,
                validateTarget: target.original.map { original in
                    { try original.identity.requireCurrent() }
                }
            )
        }
        return ledger.applyTargets(
            operationID: operation.id,
            action: operation.action,
            fields: operation.payload.fields,
            sourceIdentifier: operation.payload.source.identifier,
            targets: specs,
            skipping: skipping,
            rememberUnchanged: false,
            saveTarget: { original, candidate in
                try store.saveState(identity: original.identity, state: candidate)
            }
        )
    }

    // 显式全部重置在落盘时单向清除处理迁移回执；调整历史只保存编辑值快照，undo 恢复重置前参数但不恢复迁移回执。
    public func commitEdit(expected: MacPhotoEditRecord, state: MacPhotoEditState,
                           clearsProcessingMigration: Bool = false,
                           isCurrent: () -> Bool = { true }) -> AdjustmentTransferOutcome {
        _ = store.flushPendingCommits()
        return ledger.commitEdit(
            expected: expected,
            displayName: "",
            rememberUnchanged: false,
            isCurrent: isCurrent,
            validateBeforeSave: {
                try state.settings.validateResetValues()
                guard state.masterRecipeID == state.settings.masterRecipeID else {
                    throw AdjustmentTransferError.invalidPayload("recipe identity")
                }
            },
            save: { before in
                try store.saveState(identity: before.identity, state: state,
                                    clearsProcessingMigration: clearsProcessingMigration)
            }
        )
    }

    @discardableResult
    public func commitEditAsync(expected: MacPhotoEditRecord, state: MacPhotoEditState,
                                clearsProcessingMigration: Bool = false,
                                isCurrent: () -> Bool = { true },
                                completion: ((AdjustmentTransferOutcome, MacPhotoEditRecord?) -> Void)? = nil) -> AdjustmentTransferOutcome {
        let id = expected.identity.path
        guard isCurrent() else {
            let blocked = outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight)
            completion?(blocked, nil)
            return blocked
        }
        _ = store.deliverReadyCompletedCommits()
        var pushedCommitID: UUID?
        do {
            try state.settings.validateResetValues()
            guard state.masterRecipeID == state.settings.masterRecipeID else {
                throw AdjustmentTransferError.invalidPayload("recipe identity")
            }
            switch ledger.beginOptimisticEdit(
                expected: expected,
                state: state,
                forceWhenUnchanged: clearsProcessingMigration,
                makeRecord: { MacPhotoEditRecord(identity: $0, state: $1) }
            ) {
            case .unchanged(let before):
                let unchanged = outcome(id, .unchanged, saved: before)
                completion?(unchanged, nil)
                return unchanged
            case .enqueued(let commitID, let before, let optimisticSaved):
                pushedCommitID = commitID
                try store.enqueueSaveState(identity: before.identity, state: state,
                                           clearsProcessingMigration: clearsProcessingMigration,
                                           chainIfUndeliveredFailure: true) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let confirmed):
                        self.ledger.confirmInFlightCommit(commitID, forKey: id, confirmed: confirmed)
                        completion?(self.outcome(id, .applied, saved: confirmed), confirmed)
                    case .failure(let error):
                        let rolledBack = self.ledger.rollbackInFlightCommitsLIFO(
                            from: commitID,
                            forKey: id,
                            fallbackRecord: { MacPhotoEditRecord(identity: before.identity, state: nil) }
                        )
                        completion?(self.outcome(id, .failed, error: error), rolledBack)
                    }
                }
                return outcome(id, .applied, saved: optimisticSaved)
            }
        } catch {
            if let commitID = pushedCommitID {
                _ = ledger.rollbackInFlightCommitsLIFO(
                    from: commitID,
                    forKey: id,
                    fallbackRecord: { MacPhotoEditRecord(identity: expected.identity, state: nil) }
                )
            }
            let failed = outcome(id, .failed, error: error)
            completion?(failed, nil)
            return failed
        }
    }

    public func undoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        historyPhoto(url, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }
    public func canUndoPhoto(_ url: URL) -> Bool { ledger.canUndo(forKey: Self.key(for: url)) }
    public func canRedoPhoto(_ url: URL) -> Bool { ledger.canRedo(forKey: Self.key(for: url)) }
    public func redoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        historyPhoto(url, transactionID: transactionID, undo: false, isCurrent: isCurrent)
    }
    public func undoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }
    public func redoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }

    public func photoHistoryID(_ url: URL, undo: Bool) -> UUID? {
        ledger.photoHistoryID(forKey: Self.key(for: url), undo: undo)
    }

    private func historyPhoto(_ url: URL, transactionID: UUID?, undo: Bool, isCurrent: (String) -> Bool) -> [AdjustmentTransferOutcome] {
        guard let id = transactionID ?? photoHistoryID(url, undo: undo) else { return [] }
        return history(id: id, photo: Self.key(for: url), undo: undo, skipping: [], isCurrent: isCurrent)
    }

    private func history(id: UUID, photo: String?, undo: Bool, skipping: Set<String>,
                         isCurrent: (String) -> Bool) -> [AdjustmentTransferOutcome] {
        _ = store.flushPendingCommits()
        return ledger.applyHistory(
            id: id,
            photoKey: photo,
            undo: undo,
            skipping: skipping,
            isCurrent: isCurrent,
            validateBeforePrepare: { identity, _ in try identity.requireCurrent() },
            saveState: { identity, targetState in
                try self.store.saveState(identity: identity, state: targetState)
            }
        )
    }

    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func outcome(_ path: String, _ status: AdjustmentTransferStatus, saved: MacPhotoEditRecord? = nil,
                         error: Error? = nil, requiresHistoryDecision: Bool = false) -> AdjustmentTransferOutcome {
        AdjustmentTransferOutcome(targetID: path, status: status, saved: saved, error: error,
            requiresHistoryDecision: requiresHistoryDecision)
    }
}
