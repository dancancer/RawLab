import Foundation

public struct IOSAdjustmentTransferTarget {
    public let identity: PhotoIdentity
    public let displayName: String
    public let defaultState: PhotoEditState
    public var context: IOSAdjustmentTransferContext
    public var isCurrent: (() -> Bool)?
    public var validateSource: (() throws -> Void)?

    public init(identity: PhotoIdentity,
                displayName: String,
                defaultState: PhotoEditState,
                context: IOSAdjustmentTransferContext,
                isCurrent: (() -> Bool)? = nil,
                validateSource: (() throws -> Void)? = nil) {
        self.identity = identity
        self.displayName = displayName
        self.defaultState = defaultState
        self.context = context
        self.isCurrent = isCurrent
        self.validateSource = validateSource
    }
}

public enum IOSAdjustmentTransferStatus { case applied, unchanged, skipped, blocked, conflict, failed }

public struct IOSAdjustmentTransferOutcome {
    public let targetID: String
    public let status: IOSAdjustmentTransferStatus
    public let saved: PhotoEditRecord?
    public let error: Error?
    public var requiresHistoryDecision = false

    public init(targetID: String, status: IOSAdjustmentTransferStatus, saved: PhotoEditRecord?,
                error: Error?, requiresHistoryDecision: Bool = false) {
        self.targetID = targetID
        self.status = status
        self.saved = saved
        self.error = error
        self.requiresHistoryDecision = requiresHistoryDecision
    }
}

public struct IOSPreparedAdjustmentTransfer {
    public struct Target {
        public let id: String
        public let displayName: String
        public let original: PhotoEditRecord?
        public let candidate: PhotoEditState?
        public let unchanged: Bool
        public let isCurrent: (() -> Bool)?
        public let validateSource: (() throws -> Void)?
        public let error: Error?
        public let editGeneration: UInt64
        public var notices: [AdjustmentTransferNotice] = []

        public init(id: String,
                    displayName: String,
                    original: PhotoEditRecord?,
                    candidate: PhotoEditState?,
                    unchanged: Bool,
                    isCurrent: (() -> Bool)?,
                    validateSource: (() throws -> Void)? = nil,
                    error: Error?,
                    editGeneration: UInt64 = 0,
                    notices: [AdjustmentTransferNotice] = []) {
            self.id = id
            self.displayName = displayName
            self.original = original
            self.candidate = candidate
            self.unchanged = unchanged
            self.isCurrent = isCurrent
            self.validateSource = validateSource
            self.error = error
            self.editGeneration = editGeneration
            self.notices = notices
        }
    }
    public let id: UUID
    public let payload: AdjustmentTransferPayload
    public let action: IOSAdjustmentHistoryTransaction.Action
    public let targets: [Target]
    public var notices: [AdjustmentTransferNotice] = []

    public init(id: UUID,
                payload: AdjustmentTransferPayload,
                action: IOSAdjustmentHistoryTransaction.Action,
                targets: [Target],
                notices: [AdjustmentTransferNotice] = []) {
        self.id = id
        self.payload = payload
        self.action = action
        self.targets = targets
        self.notices = notices
    }

    // Q3/S1：仅呈现实际应用（或确认无需改动）目标的去重提示；跳过、失败或冲突目标不提示。
    public func effectiveNotices(_ outcomes: [IOSAdjustmentTransferOutcome]) -> [AdjustmentTransferNotice] {
        var merged = [AdjustmentTransferNotice]()
        for target in targets where target.error == nil
            && outcomes.contains(where: { $0.targetID == target.id && ($0.status == .applied || $0.status == .unchanged) }) {
            for notice in target.notices where !merged.contains(notice) { merged.append(notice) }
        }
        return merged
    }
}

public struct IOSAdjustmentHistoryTransaction {
    public enum Action { case paste, preset, edit, synchronize }
    public enum State { case applied, undone, redoInvalidated }
    public struct Part {
        public let id: UUID
        public let priorHead: UUID?
        public let identity: PhotoIdentity
        public let displayName: String
        public let before: PhotoEditState?
        public let after: PhotoEditState?
        public var state: State
    }
    public let id: UUID
    public let action: Action
    public let fields: Set<AdjustmentTransferField>
    public var parts: [Part]
}

// 候选来自预检快照，提交时核对该记录；会话历史仍由记录、head 和编辑代次决定。
public final class IOSAdjustmentTransferSession {
    private let store: EditPersistence
    private var outcomes: [UUID: [String: IOSAdjustmentTransferOutcome]] = [:]
    private var knownRecords: [String: PhotoEditRecord] = [:]
    private var historyHeads: [String: UUID] = [:]
    private var editGenerations: [String: UInt64] = [:]
    private let stateLock = NSLock()
    private var sourceValidators: [String: () throws -> Void] = [:]
    public private(set) var transactions: [IOSAdjustmentHistoryTransaction] = []
    public private(set) var clipboard: AdjustmentTransferPayload?

    public init(store: EditPersistence) { self.store = store }

    public func editGeneration(for identity: PhotoIdentity) -> UInt64 {
        editGeneration(forKey: identity.key)
    }

    public func editGeneration(forKey key: String) -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return editGenerations[key, default: 0]
    }

    public func isCurrentSave(_ record: PhotoEditRecord) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return knownRecords[record.identity.key]?.hasSameAdjustments(as: record) == true
    }

    public func refreshSource(_ identity: PhotoIdentity, validate: @escaping () throws -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        if knownRecords[identity.key] != nil { sourceValidators[identity.key] = validate }
    }

    public func adoptProcessingMigration(_ record: PhotoEditRecord) {
        for index in transactions.indices {
            transactions[index].parts.removeAll { $0.identity.key == record.identity.key }
        }
        transactions.removeAll { $0.parts.isEmpty }
        setHistoryHead(nil, for: record.identity.key)
        remember(record)
    }

    @discardableResult
    public func resetToUnmodified(_ identity: PhotoIdentity) throws -> PhotoEditRecord {
        let cleared = try store.resetToUnmodified(identity)
        adoptProcessingMigration(cleared)
        return cleared
    }

    @discardableResult
    public func copy(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                     context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        let captured = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context)
        clipboard = captured
        return captured
    }

    public func prepare(payload: AdjustmentTransferPayload, targets: [IOSAdjustmentTransferTarget],
                        action: IOSAdjustmentHistoryTransaction.Action = .paste) throws -> IOSPreparedAdjustmentTransfer {
        try payload.validate()
        var seen = Set<String>(), prepared = [IOSPreparedAdjustmentTransfer.Target]()
        for target in targets {
            let id = target.identity.key
            guard seen.insert(id).inserted, action != .synchronize || id != payload.source.identifier else { continue }
            do {
                guard target.isCurrent?() != false else { throw AdjustmentTransferError.draftRequiresPreflight }
                try target.validateSource?()
                let generation = editGeneration(for: target.identity)
                let original = try store.readState(for: target.identity, requiringLegacyDecision: true)
                let before = original.state ?? target.defaultState
                var notices = [AdjustmentTransferNotice]()
                var context = target.context
                context.transferNotices = { notices.append($0) }
                let candidate = try IOSAdjustmentTransfer.prepare(payload: payload, target: before, context: context)
                prepared.append(.init(id: id, displayName: target.displayName, original: original, candidate: candidate,
                    unchanged: candidate.hasSameAdjustments(as: before), isCurrent: target.isCurrent,
                    validateSource: target.validateSource, error: nil, editGeneration: generation, notices: notices))
            } catch {
                prepared.append(.init(id: id, displayName: target.displayName, original: nil, candidate: nil,
                    unchanged: false, isCurrent: target.isCurrent, validateSource: target.validateSource,
                    error: error, editGeneration: editGeneration(for: target.identity)))
            }
        }
        var mergedNotices = [AdjustmentTransferNotice]()
        for notice in prepared.flatMap(\.notices) where !mergedNotices.contains(notice) { mergedNotices.append(notice) }
        return .init(id: UUID(), payload: payload, action: action, targets: prepared, notices: mergedNotices)
    }

    public func apply(_ operation: IOSPreparedAdjustmentTransfer,
                      skipping: Set<String> = []) -> [IOSAdjustmentTransferOutcome] {
        guard operation.targets.allSatisfy({ $0.error == nil || skipping.contains($0.id) }) else {
            return operation.targets.map {
                outcome($0.id, .blocked,
                        error: $0.error ?? AdjustmentTransferError.incompatible("unresolved target preflight"))
            }
        }
        return operation.targets.map { target in
            if let cached = outcomes[operation.id]?[target.id],
               [.applied, .unchanged, .skipped].contains(cached.status) { return cached }
            let result: IOSAdjustmentTransferOutcome
            if operation.action == .synchronize && target.id == operation.payload.source.identifier {
                result = outcome(target.id, .blocked, error: AdjustmentTransferError.incompatible("synchronization source"))
            } else if skipping.contains(target.id) {
                result = outcome(target.id, .skipped)
            } else if target.isCurrent?() == false {
                result = outcome(target.id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight)
            } else if let original = target.original, let candidate = target.candidate {
                do {
                    try target.validateSource?()
                    guard editGeneration(for: original.identity) == target.editGeneration else {
                        throw AdjustmentCommitError.expired
                    }
                    if target.unchanged {
                        remember(original, advanceGeneration: false, validator: target.validateSource)
                        result = outcome(target.id, .unchanged, saved: original)
                    } else {
                        let saved = try store.saveTransferredState(candidate.withUpdatedAt(Date()), expected: original)
                        record(id: operation.id, action: operation.action, fields: operation.payload.fields,
                               displayName: target.displayName, before: original, after: saved,
                               validateSource: target.validateSource)
                        result = outcome(target.id, .applied, saved: saved)
                    }
                } catch let error as AdjustmentCommitError {
                    result = outcome(target.id, .conflict, error: error)
                } catch {
                    result = outcome(target.id, .failed, error: error)
                }
            } else {
                result = outcome(target.id, .blocked, error: target.error)
            }
            outcomes[operation.id, default: [:]][target.id] = result
            return result
        }
    }

    // 显式全部重置在落盘时单向清除处理迁移回执；调整历史只保存编辑值快照，undo 恢复重置前参数但不恢复迁移回执。
    public func commitEdit(expected: PhotoEditRecord, state: PhotoEditState, displayName: String? = nil,
                           defaultState: PhotoEditState? = nil, clearsProcessingMigration: Bool = false,
                           isCurrent: () -> Bool = { true },
                           validateSource: (() throws -> Void)? = nil) -> IOSAdjustmentTransferOutcome {
        let id = expected.identity.key
        guard isCurrent() else { return outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
        do {
            try IOSAdjustmentTransfer.validate(state.settings)
            try validateSource?()
            let before = currentRecord(for: id).flatMap { $0.identity == expected.identity ? $0 : nil } ?? expected
            let desired: PhotoEditState? = before.state == nil &&
                defaultState.map({ state.hasSameAdjustments(as: $0) }) == true ? nil : state.withUpdatedAt(Date())
            let saved = try store.saveState(identity: before.identity, state: desired,
                                            clearsProcessingMigration: clearsProcessingMigration)
            guard !saved.hasSameAdjustments(as: before) else {
                remember(saved, advanceGeneration: false, validator: validateSource)
                return outcome(id, .unchanged, saved: saved)
            }
            record(id: UUID(), action: .edit, fields: [], displayName: displayName ?? id,
                   before: before, after: saved, validateSource: validateSource)
            return outcome(id, .applied, saved: saved)
        } catch {
            return outcome(id, .failed, error: error)
        }
    }

    public func undoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil,
                          isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }

    public func redoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil,
                          isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: false, isCurrent: isCurrent)
    }

    public func canUndoPhoto(_ identity: PhotoIdentity) -> Bool { photoHistoryID(identity, undo: true) != nil }
    public func canRedoPhoto(_ identity: PhotoIdentity) -> Bool { photoHistoryID(identity, undo: false) != nil }

    public func undoTransaction(_ id: UUID, skipping: Set<String> = [],
                                isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }

    public func redoTransaction(_ id: UUID, skipping: Set<String> = [],
                                isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }

    public func photoHistoryID(_ identity: PhotoIdentity, undo: Bool) -> UUID? {
        let desired: IOSAdjustmentHistoryTransaction.State = undo ? .applied : .undone
        let indexes = undo ? Array(transactions.indices.reversed()) : Array(transactions.indices)
        return indexes.first {
            transactions[$0].parts.contains { $0.identity.key == identity.key && $0.state == desired }
        }.map { transactions[$0].id }
    }

    private func historyPhoto(_ identity: PhotoIdentity, transactionID: UUID?, undo: Bool,
                              isCurrent: (String) -> Bool) -> [IOSAdjustmentTransferOutcome] {
        guard let id = transactionID ?? photoHistoryID(identity, undo: undo) else { return [] }
        return history(id: id, photo: identity.key, undo: undo, skipping: [], isCurrent: isCurrent)
    }

    private func history(id: UUID, photo: String?, undo: Bool, skipping: Set<String>,
                         isCurrent: (String) -> Bool) -> [IOSAdjustmentTransferOutcome] {
        guard let transaction = transactions.firstIndex(where: { $0.id == id }) else { return [] }
        let desired: IOSAdjustmentHistoryTransaction.State = undo ? .applied : .undone
        let selected = transactions[transaction].parts.indices.filter {
            let part = transactions[transaction].parts[$0]
            return part.state == desired && (photo == nil || part.identity.key == photo)
        }
        var prepared: [Int: PhotoEditRecord] = [:]
        var rejected: [Int: IOSAdjustmentTransferOutcome] = [:]
        for index in selected {
            let part = transactions[transaction].parts[index], key = part.identity.key
            if skipping.contains(key) { continue }
            do {
                guard isCurrent(key) else { throw AdjustmentTransferError.draftRequiresPreflight }
                try sourceValidator(for: key)?()
                guard let current = currentRecord(for: key), current.identity == part.identity else {
                    throw AdjustmentCommitError.photoChanged
                }
                guard historyHead(for: key) == (undo ? part.id : part.priorHead),
                      sameState(current.state, undo ? part.after : part.before) else {
                    throw AdjustmentCommitError.historyOrder
                }
                prepared[index] = current
            } catch let error as AdjustmentCommitError {
                rejected[index] = outcome(key, .conflict, error: error, decision: true)
            } catch {
                rejected[index] = outcome(key, .blocked, error: error, decision: true)
            }
        }
        guard rejected.isEmpty else {
            return selected.map { index in
                let key = transactions[transaction].parts[index].identity.key
                return rejected[index] ?? outcome(key, skipping.contains(key) ? .skipped : .blocked,
                    error: AdjustmentTransferError.incompatible("unresolved history conflict"))
            }
        }
        return selected.map { index in
            let part = transactions[transaction].parts[index], key = part.identity.key
            guard let current = prepared[index] else { return outcome(key, .skipped) }
            guard isCurrent(key) else {
                return outcome(key, .blocked, error: AdjustmentTransferError.draftRequiresPreflight, decision: true)
            }
            do {
                try sourceValidator(for: key)?()
                let saved = try store.saveState(identity: current.identity, state: undo ? part.before : part.after)
                remember(saved, validator: sourceValidator(for: key))
                setHistoryHead(undo ? part.priorHead : part.id, for: key)
                transactions[transaction].parts[index].state = undo ? .undone : .applied
                return outcome(key, .applied, saved: saved)
            } catch let error as AdjustmentCommitError {
                return outcome(key, .conflict, error: error, decision: true)
            } catch {
                return outcome(key, .failed, error: error)
            }
        }
    }

    private func record(id: UUID, action: IOSAdjustmentHistoryTransaction.Action,
                        fields: Set<AdjustmentTransferField>, displayName: String,
                        before: PhotoEditRecord, after: PhotoEditRecord,
                        validateSource: (() throws -> Void)?) {
        guard !after.hasSameAdjustments(as: before) else { return }
        let key = after.identity.key
        let priorHead = currentRecord(for: key).map { $0.hasSameAdjustments(as: before) } == true
            ? historyHead(for: key) : nil
        remember(after, validator: validateSource)
        for transaction in transactions.indices {
            for part in transactions[transaction].parts.indices
                where transactions[transaction].parts[part].identity.key == key
                    && transactions[transaction].parts[part].state == .undone {
                transactions[transaction].parts[part].state = .redoInvalidated
            }
        }
        let part = IOSAdjustmentHistoryTransaction.Part(id: UUID(), priorHead: priorHead, identity: after.identity,
            displayName: displayName, before: before.state, after: after.state, state: .applied)
        setHistoryHead(part.id, for: key)
        if let index = transactions.firstIndex(where: { $0.id == id }) {
            transactions[index].parts.append(part)
        } else {
            transactions.append(.init(id: id, action: action, fields: fields, parts: [part]))
        }
    }

    private func currentRecord(for key: String) -> PhotoEditRecord? {
        stateLock.lock(); defer { stateLock.unlock() }
        return knownRecords[key]
    }

    private func historyHead(for key: String) -> UUID? {
        stateLock.lock(); defer { stateLock.unlock() }
        return historyHeads[key]
    }

    private func setHistoryHead(_ head: UUID?, for key: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        historyHeads[key] = head
    }

    private func sourceValidator(for key: String) -> (() throws -> Void)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return sourceValidators[key]
    }

    private func remember(_ record: PhotoEditRecord, advanceGeneration: Bool = true,
                          validator: (() throws -> Void)? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        knownRecords[record.identity.key] = record
        if let validator { sourceValidators[record.identity.key] = validator }
        if advanceGeneration { editGenerations[record.identity.key, default: 0] &+= 1 }
    }

    private func sameState(_ lhs: PhotoEditState?, _ rhs: PhotoEditState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameAdjustments(as: rhs)
        default: return false
        }
    }

    private func outcome(_ id: String, _ status: IOSAdjustmentTransferStatus,
                         saved: PhotoEditRecord? = nil, error: Error? = nil,
                         decision: Bool = false) -> IOSAdjustmentTransferOutcome {
        .init(targetID: id, status: status, saved: saved, error: error, requiresHistoryDecision: decision)
    }
}
