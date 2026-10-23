import Foundation

struct IOSAdjustmentTransferTarget {
    let identity: PhotoIdentity
    let displayName: String
    let defaultState: PhotoEditState
    var context: IOSAdjustmentTransferContext
    var isCurrent: (() -> Bool)? = nil
    var validateSource: (() throws -> Void)? = nil
}

enum IOSAdjustmentTransferStatus { case applied, unchanged, skipped, blocked, conflict, failed }

struct IOSAdjustmentTransferOutcome {
    let targetID: String
    let status: IOSAdjustmentTransferStatus
    let saved: VersionedPhotoEdit?
    let error: Error?
    var requiresHistoryDecision = false
}

struct IOSPreparedAdjustmentTransfer {
    struct Target {
        let id: String
        let displayName: String
        let original: VersionedPhotoEdit?
        let candidate: PhotoEditState?
        let unchanged: Bool
        let isCurrent: (() -> Bool)?
        let validateSource: (() throws -> Void)?
        let error: Error?
    }
    let id: UUID
    let payload: AdjustmentTransferPayload
    let targets: [Target]
}

struct IOSAdjustmentHistoryTransaction {
    enum Action { case paste, edit }
    enum State { case applied, undone, redoInvalidated }
    struct Part {
        let id: UUID
        let priorHead: UUID?
        let identity: PhotoIdentity
        let displayName: String
        let before: PhotoEditState?
        let after: PhotoEditState?
        var state: State
    }
    let id: UUID
    let action: Action
    let fields: Set<AdjustmentTransferField>
    var parts: [Part]
}

// 与 Mac 共用逐照片 history head 和 CAS 语义；本端只替换稳定身份、存储及 native adapter。
final class IOSAdjustmentTransferSession {
    private let store: EditPersistence
    private var outcomes: [UUID: [String: IOSAdjustmentTransferOutcome]] = [:]
    private var knownRecords: [String: VersionedPhotoEdit] = [:]
    private var historyHeads: [String: UUID] = [:]
    private var sourceValidators: [String: () throws -> Void] = [:]
    private(set) var transactions: [IOSAdjustmentHistoryTransaction] = []
    private(set) var clipboard: AdjustmentTransferPayload?

    init(store: EditPersistence) { self.store = store }

    func refreshSource(_ identity: PhotoIdentity, validate: @escaping () throws -> Void) {
        if knownRecords[identity.key] != nil { sourceValidators[identity.key] = validate }
    }

    @discardableResult func copy(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                                 context: IOSAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        let captured = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context)
        clipboard = captured
        return captured
    }

    func prepare(payload: AdjustmentTransferPayload, targets: [IOSAdjustmentTransferTarget]) throws -> IOSPreparedAdjustmentTransfer {
        try payload.validate()
        var seen = Set<String>(), prepared = [IOSPreparedAdjustmentTransfer.Target]()
        for target in targets {
            let id = target.identity.key
            guard seen.insert(id).inserted else { continue }
            do {
                guard target.isCurrent?() != false else { throw AdjustmentTransferError.draftRequiresPreflight }
                try target.validateSource?()
                let original = try store.versionedState(for: target.identity), before = original.state ?? target.defaultState
                let candidate = try IOSAdjustmentTransfer.prepare(payload: payload, target: before, context: target.context)
                prepared.append(.init(id: id, displayName: target.displayName, original: original, candidate: candidate,
                    unchanged: candidate.hasSameAdjustments(as: before), isCurrent: target.isCurrent,
                    validateSource: target.validateSource, error: nil))
            } catch {
                prepared.append(.init(id: id, displayName: target.displayName, original: nil, candidate: nil, unchanged: false,
                    isCurrent: target.isCurrent, validateSource: target.validateSource, error: error))
            }
        }
        return .init(id: UUID(), payload: payload, targets: prepared)
    }

    func apply(_ operation: IOSPreparedAdjustmentTransfer, skipping: Set<String> = []) -> [IOSAdjustmentTransferOutcome] {
        guard operation.targets.allSatisfy({ $0.error == nil || skipping.contains($0.id) }) else {
            return operation.targets.map { outcome($0.id, .blocked, error: $0.error ?? AdjustmentTransferError.incompatible("unresolved target preflight")) }
        }
        return operation.targets.map { target in
            if let cached = outcomes[operation.id]?[target.id], [.applied, .unchanged, .skipped].contains(cached.status) { return cached }
            let result: IOSAdjustmentTransferOutcome
            if skipping.contains(target.id) { result = outcome(target.id, .skipped) }
            else if target.isCurrent?() == false { result = outcome(target.id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
            else if let original = target.original, let candidate = target.candidate {
                do {
                    try target.validateSource?()
                    guard try store.versionedState(for: original.identity) == original else { throw EditPersistenceConflict.changed }
                    if target.unchanged { result = outcome(target.id, .unchanged, saved: original) }
                    else {
                        let saved = try store.compareAndSave(expected: original, state: candidate.withUpdatedAt(Date()))
                        record(id: operation.id, action: .paste, fields: operation.payload.fields, displayName: target.displayName,
                            before: original, after: saved, validateSource: target.validateSource)
                        result = outcome(target.id, .applied, saved: saved)
                    }
                } catch is EditPersistenceConflict { result = outcome(target.id, .conflict, error: EditPersistenceConflict.changed) }
                catch { result = outcome(target.id, .failed, error: error) }
            } else { result = outcome(target.id, .blocked, error: target.error) }
            outcomes[operation.id, default: [:]][target.id] = result
            return result
        }
    }

    func commitEdit(expected: VersionedPhotoEdit, state: PhotoEditState, displayName: String? = nil,
                    defaultState: PhotoEditState? = nil, isCurrent: () -> Bool = { true },
                    validateSource: (() throws -> Void)? = nil) -> IOSAdjustmentTransferOutcome {
        let id = expected.identity.key
        guard isCurrent() else { return outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
        do {
            try IOSAdjustmentTransfer.validate(state.settings)
            try validateSource?()
            if expected.state == nil, let defaultState, state.hasSameAdjustments(as: defaultState) {
                guard try store.versionedState(for: expected.identity) == expected else { throw EditPersistenceConflict.changed }
                return outcome(id, .unchanged, saved: expected)
            }
            let saved = try store.compareAndSave(expected: expected, state: state.withUpdatedAt(Date()))
            guard saved != expected else { return outcome(id, .unchanged, saved: saved) }
            record(id: UUID(), action: .edit, fields: [], displayName: displayName ?? id, before: expected, after: saved,
                validateSource: validateSource)
            return outcome(id, .applied, saved: saved)
        } catch is EditPersistenceConflict { return outcome(id, .conflict, error: EditPersistenceConflict.changed) }
        catch { return outcome(id, .failed, error: error) }
    }

    func undoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }
    func redoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: false, isCurrent: isCurrent)
    }
    func canUndoPhoto(_ identity: PhotoIdentity) -> Bool { photoHistoryID(identity, undo: true) != nil }
    func canRedoPhoto(_ identity: PhotoIdentity) -> Bool { photoHistoryID(identity, undo: false) != nil }
    func undoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }
    func redoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }
    func photoHistoryID(_ identity: PhotoIdentity, undo: Bool) -> UUID? {
        let desired: IOSAdjustmentHistoryTransaction.State = undo ? .applied : .undone
        let indexes = undo ? Array(transactions.indices.reversed()) : Array(transactions.indices)
        return indexes.first { transactions[$0].parts.contains { $0.identity.key == identity.key && $0.state == desired } }
            .map { transactions[$0].id }
    }
    private func historyPhoto(_ identity: PhotoIdentity, transactionID: UUID?, undo: Bool, isCurrent: (String) -> Bool) -> [IOSAdjustmentTransferOutcome] {
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
        var prepared: [Int: VersionedPhotoEdit] = [:], rejected: [Int: IOSAdjustmentTransferOutcome] = [:]
        for index in selected {
            let part = transactions[transaction].parts[index], key = transactions[transaction].parts[index].identity.key
            if skipping.contains(key) { continue }
            do {
                guard isCurrent(key) else { throw AdjustmentTransferError.draftRequiresPreflight }
                try sourceValidators[key]?()
                let current = try store.versionedState(for: part.identity)
                guard current == knownRecords[key], historyHeads[key] == (undo ? part.id : part.priorHead),
                      current.state == (undo ? part.after : part.before) else { throw EditPersistenceConflict.changed }
                prepared[index] = current
            } catch is EditPersistenceConflict { rejected[index] = outcome(key, .conflict, error: EditPersistenceConflict.changed, decision: true) }
            catch { rejected[index] = outcome(key, .blocked, error: error, decision: true) }
        }
        guard rejected.isEmpty else {
            return selected.map { index in
                let key = transactions[transaction].parts[index].identity.key
                return rejected[index] ?? outcome(key, skipping.contains(key) ? .skipped : .blocked,
                    error: AdjustmentTransferError.incompatible("unresolved history conflict"))
            }
        }
        return selected.map { index in
            let part = transactions[transaction].parts[index], key = transactions[transaction].parts[index].identity.key
            guard let current = prepared[index] else { return outcome(key, .skipped) }
            guard isCurrent(key) else { return outcome(key, .blocked, error: AdjustmentTransferError.draftRequiresPreflight, decision: true) }
            do {
                try sourceValidators[key]?()
                let saved = try store.compareAndSave(expected: current, state: undo ? part.before : part.after)
                knownRecords[key] = saved; historyHeads[key] = undo ? part.priorHead : part.id
                transactions[transaction].parts[index].state = undo ? .undone : .applied
                return outcome(key, .applied, saved: saved)
            } catch is EditPersistenceConflict { return outcome(key, .conflict, error: EditPersistenceConflict.changed, decision: true) }
            catch { return outcome(key, .failed, error: error) }
        }
    }
    private func record(id: UUID, action: IOSAdjustmentHistoryTransaction.Action, fields: Set<AdjustmentTransferField>,
                        displayName: String, before: VersionedPhotoEdit, after: VersionedPhotoEdit,
                        validateSource: (() throws -> Void)?) {
        let key = after.identity.key, priorHead = before == knownRecords[after.identity.key] ? historyHeads[after.identity.key] : nil
        knownRecords[key] = after
        if let validateSource { sourceValidators[key] = validateSource }
        for transaction in transactions.indices {
            for part in transactions[transaction].parts.indices where transactions[transaction].parts[part].identity.key == key
                && transactions[transaction].parts[part].state == .undone {
                transactions[transaction].parts[part].state = .redoInvalidated
            }
        }
        let part = IOSAdjustmentHistoryTransaction.Part(id: UUID(), priorHead: priorHead, identity: after.identity,
            displayName: displayName, before: before.state, after: after.state, state: .applied)
        historyHeads[key] = part.id
        if let index = transactions.firstIndex(where: { $0.id == id }) { transactions[index].parts.append(part) }
        else { transactions.append(.init(id: id, action: action, fields: fields, parts: [part])) }
    }
    private func outcome(_ id: String, _ status: IOSAdjustmentTransferStatus, saved: VersionedPhotoEdit? = nil,
                         error: Error? = nil, decision: Bool = false) -> IOSAdjustmentTransferOutcome {
        .init(targetID: id, status: status, saved: saved, error: error, requiresHistoryDecision: decision)
    }
}
