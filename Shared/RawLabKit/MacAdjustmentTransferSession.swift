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

public enum AdjustmentTransferStatus { case applied, unchanged, skipped, blocked, conflict, failed }

public struct AdjustmentTransferOutcome {
    public let targetID: String
    public let status: AdjustmentTransferStatus
    public let saved: MacPhotoEditRecord?
    public let error: Error?
    public var requiresHistoryDecision = false

    public init(targetID: String, status: AdjustmentTransferStatus, saved: MacPhotoEditRecord?,
                error: Error?, requiresHistoryDecision: Bool = false) {
        self.targetID = targetID
        self.status = status
        self.saved = saved
        self.error = error
        self.requiresHistoryDecision = requiresHistoryDecision
    }
}

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

public struct AdjustmentHistoryTransaction {
    public enum Action { case paste, preset, edit, synchronize }
    public enum State { case applied, undone, redoInvalidated }
    public struct Part {
        public let id: UUID
        public let priorHead: UUID?
        public let identity: OriginalFileIdentity
        public let before: MacPhotoEditState?
        public let after: MacPhotoEditState?
        public var state: State
    }
    public let id: UUID
    public let action: Action
    public let fields: Set<AdjustmentTransferField>
    public var parts: [Part]
}

// 编辑与历史在编辑器线程提交；后台预检只读取会话代次和冻结参数。
public final class AdjustmentTransferSession {
    private let store: MacEditPersistence
    private var outcomes: [UUID: [String: AdjustmentTransferOutcome]] = [:]
    private var knownRecords: [String: MacPhotoEditRecord] = [:]
    private let generationLock = NSLock()
    private var editGenerations: [String: UInt64] = [:]
    private var historyHeads: [String: UUID] = [:]
    public private(set) var transactions: [AdjustmentHistoryTransaction] = []
    public private(set) var clipboard: AdjustmentTransferPayload?

    public init(store: MacEditPersistence) { self.store = store }

    public func editGeneration(for url: URL) -> UInt64 {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        generationLock.lock(); defer { generationLock.unlock() }
        return editGenerations[path, default: 0]
    }

    public func isCurrentSave(_ record: MacPhotoEditRecord) -> Bool { knownRecords[record.identity.path] == record }

    // 迁移拥有持久回退；旧的内存历史不能越过这次原子提交覆盖它。
    public func adoptProcessingMigration(_ record: MacPhotoEditRecord) {
        for index in transactions.indices {
            transactions[index].parts.removeAll { $0.identity.path == record.identity.path }
        }
        transactions.removeAll { $0.parts.isEmpty }
        historyHeads.removeValue(forKey: record.identity.path)
        remember(record)
    }

    @discardableResult public func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord {
        let cleared = try store.resetToUnmodified(url)
        adoptProcessingMigration(cleared)
        return cleared
    }

    private func remember(_ record: MacPhotoEditRecord) {
        knownRecords[record.identity.path] = record
        generationLock.lock(); defer { generationLock.unlock() }
        editGenerations[record.identity.path, default: 0] &+= 1
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
        if shouldCancel() { throw CancellationError() }
        try payload.validate()
        var seen = Set<String>()
        var prepared = [PreparedAdjustmentTransfer.Target]()
        for target in targets {
            if shouldCancel() { throw CancellationError() }
            let id = target.url.resolvingSymlinksInPath().standardizedFileURL.path
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
        guard operation.targets.allSatisfy({ $0.error == nil || skipping.contains($0.id) }) else {
            return operation.targets.map { outcome($0.id, .blocked, error: $0.error ?? AdjustmentTransferError.incompatible("unresolved target preflight")) }
        }
        var result = [AdjustmentTransferOutcome]()
        for target in operation.targets {
            if let previous = outcomes[operation.id]?[target.id], [.applied, .unchanged, .skipped].contains(previous.status) {
                result.append(previous); continue
            }
            let applied: AdjustmentTransferOutcome
            if skipping.contains(target.id) { applied = outcome(target.id, .skipped) }
            else if target.isCurrent?() == false { applied = outcome(target.id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
            else if let original = target.original, let candidate = target.candidate {
                do {
                    try original.identity.requireCurrent()
                    guard editGeneration(for: URL(fileURLWithPath: target.id)) == target.editGeneration else { throw AdjustmentCommitError.expired }
                    if target.unchanged { applied = outcome(target.id, .unchanged, saved: original) }
                    else {
                        let saved = try store.saveState(identity: original.identity, state: candidate)
                        record(id: operation.id, action: operation.action, fields: operation.payload.fields, before: original, after: saved)
                        applied = outcome(target.id, .applied, saved: saved)
                    }
                } catch let error as AdjustmentCommitError { applied = outcome(target.id, .conflict, error: error) }
                catch { applied = outcome(target.id, .failed, error: error) }
            } else { applied = outcome(target.id, .blocked, error: target.error) }
            outcomes[operation.id, default: [:]][target.id] = applied
            result.append(applied)
        }
        return result
    }

    // 显式全部重置在落盘时单向清除处理迁移回执；调整历史只保存编辑值快照，undo 恢复重置前参数但不恢复迁移回执。
    public func commitEdit(expected: MacPhotoEditRecord, state: MacPhotoEditState,
                           clearsProcessingMigration: Bool = false,
                           isCurrent: () -> Bool = { true }) -> AdjustmentTransferOutcome {
        let id = expected.identity.path
        guard isCurrent() else { return outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
        do {
            let before = knownRecords[id].flatMap { $0.identity == expected.identity ? $0 : nil } ?? expected
            try state.settings.validateResetValues()
            guard state.masterRecipeID == state.settings.masterRecipeID else {
                throw AdjustmentTransferError.invalidPayload("recipe identity")
            }
            let saved = try store.saveState(identity: before.identity, state: state,
                                            clearsProcessingMigration: clearsProcessingMigration)
            guard saved != before else { return outcome(id, .unchanged, saved: saved) }
            record(id: UUID(), action: .edit, fields: [], before: before, after: saved)
            return outcome(id, .applied, saved: saved)
        } catch { return outcome(id, .failed, error: error) }
    }

    public func undoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        historyPhoto(url, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }
    public func canUndoPhoto(_ url: URL) -> Bool { hasHistory(url, state: .applied) }
    public func canRedoPhoto(_ url: URL) -> Bool { hasHistory(url, state: .undone) }
    private func hasHistory(_ url: URL, state: AdjustmentHistoryTransaction.State) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return transactions.contains { $0.parts.contains { $0.identity.path == path && $0.state == state } }
    }
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
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let desired: AdjustmentHistoryTransaction.State = undo ? .applied : .undone
        let indexes = undo ? Array(transactions.indices.reversed()) : Array(transactions.indices)
        return indexes.first(where: { transactions[$0].parts.contains { $0.identity.path == path && $0.state == desired } })
            .map { transactions[$0].id }
    }

    private func historyPhoto(_ url: URL, transactionID: UUID?, undo: Bool, isCurrent: (String) -> Bool) -> [AdjustmentTransferOutcome] {
        guard let id = transactionID ?? photoHistoryID(url, undo: undo) else { return [] }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return history(id: id, photo: path, undo: undo, skipping: [], isCurrent: isCurrent)
    }

    private func history(id: UUID, photo: String?, undo: Bool, skipping: Set<String>,
                         isCurrent: (String) -> Bool) -> [AdjustmentTransferOutcome] {
        guard let transaction = transactions.firstIndex(where: { $0.id == id }) else { return [] }
        let desired: AdjustmentHistoryTransaction.State = undo ? .applied : .undone
        let selected = transactions[transaction].parts.indices.filter {
            let part = transactions[transaction].parts[$0]
            return part.state == desired && (photo == nil || part.identity.path == photo)
        }
        var prepared: [Int: MacPhotoEditRecord] = [:]
        var rejected: [Int: AdjustmentTransferOutcome] = [:]
        for index in selected {
            let part = transactions[transaction].parts[index]
            let path = part.identity.path
            if skipping.contains(path) { continue }
            do {
                guard isCurrent(path) else { throw AdjustmentTransferError.draftRequiresPreflight }
                try part.identity.requireCurrent()
                guard let current = knownRecords[path], current.identity == part.identity else { throw AdjustmentCommitError.photoChanged }
                guard historyHeads[path] == (undo ? part.id : part.priorHead),
                      current.state == (undo ? part.after : part.before) else { throw AdjustmentCommitError.historyOrder }
                prepared[index] = current
            } catch let error as AdjustmentCommitError { rejected[index] = outcome(path, .conflict, error: error, requiresHistoryDecision: true) }
            catch { rejected[index] = outcome(path, .blocked, error: error, requiresHistoryDecision: true) }
        }
        guard rejected.isEmpty else {
            return selected.map { index in
                let path = transactions[transaction].parts[index].identity.path
                return rejected[index] ?? outcome(path, skipping.contains(path) ? .skipped : .blocked,
                    error: AdjustmentTransferError.incompatible("unresolved history conflict"))
            }
        }
        return selected.map { index in
            let part = transactions[transaction].parts[index]
            let path = part.identity.path
            guard let current = prepared[index] else { return outcome(path, .skipped) }
            guard isCurrent(path) else { return outcome(path, .blocked, error: AdjustmentTransferError.draftRequiresPreflight, requiresHistoryDecision: true) }
            do {
                let saved = try store.saveState(identity: current.identity, state: undo ? part.before : part.after)
                remember(saved)
                historyHeads[path] = undo ? part.priorHead : part.id
                transactions[transaction].parts[index].state = undo ? .undone : .applied
                return outcome(path, .applied, saved: saved)
            } catch let error as AdjustmentCommitError { return outcome(path, .conflict, error: error, requiresHistoryDecision: true) }
            catch { return outcome(path, .failed, error: error) }
        }
    }

    private func record(id: UUID, action: AdjustmentHistoryTransaction.Action, fields: Set<AdjustmentTransferField>,
                        before: MacPhotoEditRecord, after: MacPhotoEditRecord) {
        guard before.state != after.state else { return }
        let path = after.identity.path
        let priorHead = before == knownRecords[path] ? historyHeads[path] : nil
        remember(after)
        for transaction in transactions.indices {
            for part in transactions[transaction].parts.indices where transactions[transaction].parts[part].identity.path == path
                && transactions[transaction].parts[part].state == .undone {
                transactions[transaction].parts[part].state = .redoInvalidated
            }
        }
        let part = AdjustmentHistoryTransaction.Part(id: UUID(), priorHead: priorHead,
            identity: after.identity, before: before.state, after: after.state, state: .applied)
        historyHeads[path] = part.id
        if let index = transactions.firstIndex(where: { $0.id == id }) { transactions[index].parts.append(part) }
        else { transactions.append(.init(id: id, action: action, fields: fields, parts: [part])) }
    }

    private func outcome(_ path: String, _ status: AdjustmentTransferStatus, saved: MacPhotoEditRecord? = nil,
                         error: Error? = nil, requiresHistoryDecision: Bool = false) -> AdjustmentTransferOutcome {
        AdjustmentTransferOutcome(targetID: path, status: status, saved: saved, error: error,
            requiresHistoryDecision: requiresHistoryDecision)
    }
}
