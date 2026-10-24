import Foundation

struct AdjustmentTransferTarget {
    let url: URL
    let defaultState: PhotoEditState
    var context: MacAdjustmentTransferContext
    var isCurrent: (() -> Bool)? = nil
    var resolveMetadata: ((PhotoEditState) throws -> PhotoEditState)? = nil
}

enum AdjustmentTransferStatus { case applied, unchanged, skipped, blocked, conflict, failed }

struct AdjustmentTransferOutcome {
    let targetID: String
    let status: AdjustmentTransferStatus
    let saved: VersionedPhotoEdit?
    let error: Error?
    var requiresHistoryDecision = false
}

struct PreparedAdjustmentTransfer {
    struct Target {
        let id: String
        let original: VersionedPhotoEdit?
        let candidate: PhotoEditState?
        let unchanged: Bool
        let isCurrent: (() -> Bool)?
        let error: Error?
    }
    let id: UUID
    let payload: AdjustmentTransferPayload
    let targets: [Target]
    let action: AdjustmentHistoryTransaction.Action
}

struct AdjustmentHistoryTransaction {
    enum Action { case paste, preset, edit }
    enum State { case applied, undone, redoInvalidated }
    struct Part {
        let id: UUID
        let priorHead: UUID?
        let identity: OriginalFileIdentity
        let before: PhotoEditState?
        let after: PhotoEditState?
        var state: State
    }
    let id: UUID
    let action: Action
    let fields: Set<AdjustmentTransferField>
    var parts: [Part]
}

// 会话层按原生编辑器的串行提交顺序调用；跨实例/进程的条件写入由 EditPersistence 锁保护。
final class AdjustmentTransferSession {
    private let store: EditPersistence
    private var outcomes: [UUID: [String: AdjustmentTransferOutcome]] = [:]
    private var knownRecords: [String: VersionedPhotoEdit] = [:]
    private var historyHeads: [String: UUID] = [:]
    private(set) var transactions: [AdjustmentHistoryTransaction] = []
    private(set) var clipboard: AdjustmentTransferPayload?

    init(store: EditPersistence) { self.store = store }

    @discardableResult func copy(scope: AdjustmentTransferScope, snapshot: PhotoEditState,
                                 context: MacAdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        let captured = try MacAdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context)
        clipboard = captured
        return captured
    }

    func prepare(payload: AdjustmentTransferPayload, targets: [AdjustmentTransferTarget],
                 action: AdjustmentHistoryTransaction.Action = .paste) throws -> PreparedAdjustmentTransfer {
        try payload.validate()
        var seen = Set<String>()
        var prepared = [PreparedAdjustmentTransfer.Target]()
        for target in targets {
            let id = target.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(id).inserted else { continue }
            do {
                guard target.isCurrent?() != false else { throw AdjustmentTransferError.draftRequiresPreflight }
                let original = try store.versionedState(for: target.url)
                let stored = original.state ?? target.defaultState
                let effective = try target.resolveMetadata?(stored) ?? stored
                let candidate = try MacAdjustmentTransfer.prepare(payload: payload, target: effective, context: target.context)
                prepared.append(.init(id: id, original: original, candidate: candidate, unchanged: candidate == effective,
                    isCurrent: target.isCurrent, error: nil))
            } catch {
                prepared.append(.init(id: id, original: nil, candidate: nil, unchanged: false,
                    isCurrent: target.isCurrent, error: error))
            }
        }
        return PreparedAdjustmentTransfer(id: UUID(), payload: payload, targets: prepared, action: action)
    }

    func apply(_ operation: PreparedAdjustmentTransfer, skipping: Set<String> = []) -> [AdjustmentTransferOutcome] {
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
                    // 无变化也重新读取前态，不能把过期 prepared 误报为当前已一致。
                    guard try store.versionedState(for: URL(fileURLWithPath: target.id)) == original else { throw EditPersistenceConflict.changed }
                    if target.unchanged { applied = outcome(target.id, .unchanged, saved: original) }
                    else {
                        let saved = try store.compareAndSave(expected: original, state: candidate)
                        record(id: operation.id, action: operation.action, fields: operation.payload.fields, before: original, after: saved)
                        applied = outcome(target.id, .applied, saved: saved)
                    }
                } catch is EditPersistenceConflict { applied = outcome(target.id, .conflict, error: EditPersistenceConflict.changed) }
                catch { applied = outcome(target.id, .failed, error: error) }
            } else { applied = outcome(target.id, .blocked, error: target.error) }
            outcomes[operation.id, default: [:]][target.id] = applied
            result.append(applied)
        }
        return result
    }

    func commitEdit(expected: VersionedPhotoEdit, state: PhotoEditState,
                    isCurrent: () -> Bool = { true }) -> AdjustmentTransferOutcome {
        let id = expected.identity.path
        guard isCurrent() else { return outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
        do {
            try state.settings.validateResetValues()
            guard state.masterRecipeID == state.settings.masterRecipeID else {
                throw AdjustmentTransferError.invalidPayload("recipe identity")
            }
            let saved = try store.compareAndSave(expected: expected, state: state)
            guard saved != expected else { return outcome(id, .unchanged, saved: saved) }
            record(id: UUID(), action: .edit, fields: [], before: expected, after: saved)
            return outcome(id, .applied, saved: saved)
        } catch is EditPersistenceConflict { return outcome(id, .conflict, error: EditPersistenceConflict.changed) }
        catch { return outcome(id, .failed, error: error) }
    }

    func undoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        historyPhoto(url, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }
    func canUndoPhoto(_ url: URL) -> Bool { hasHistory(url, state: .applied) }
    func canRedoPhoto(_ url: URL) -> Bool { hasHistory(url, state: .undone) }
    private func hasHistory(_ url: URL, state: AdjustmentHistoryTransaction.State) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return transactions.contains { $0.parts.contains { $0.identity.path == path && $0.state == state } }
    }
    func redoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        historyPhoto(url, transactionID: transactionID, undo: false, isCurrent: isCurrent)
    }
    func undoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }
    func redoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }

    func photoHistoryID(_ url: URL, undo: Bool) -> UUID? {
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
        var prepared: [Int: VersionedPhotoEdit] = [:]
        var rejected: [Int: AdjustmentTransferOutcome] = [:]
        for index in selected {
            let part = transactions[transaction].parts[index]
            let path = part.identity.path
            if skipping.contains(path) { continue }
            do {
                guard isCurrent(path) else { throw AdjustmentTransferError.draftRequiresPreflight }
                let current = try store.versionedState(for: URL(fileURLWithPath: path))
                guard current.identity == part.identity, current == knownRecords[path],
                      historyHeads[path] == (undo ? part.id : part.priorHead),
                      current.state == (undo ? part.after : part.before) else { throw EditPersistenceConflict.changed }
                prepared[index] = current
            } catch is EditPersistenceConflict { rejected[index] = outcome(path, .conflict, error: EditPersistenceConflict.changed, requiresHistoryDecision: true) }
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
                let saved = try store.compareAndSave(expected: current, state: undo ? part.before : part.after)
                knownRecords[path] = saved
                historyHeads[path] = undo ? part.priorHead : part.id
                transactions[transaction].parts[index].state = undo ? .undone : .applied
                return outcome(path, .applied, saved: saved)
            } catch is EditPersistenceConflict { return outcome(path, .conflict, error: EditPersistenceConflict.changed, requiresHistoryDecision: true) }
            catch { return outcome(path, .failed, error: error) }
        }
    }

    private func record(id: UUID, action: AdjustmentHistoryTransaction.Action, fields: Set<AdjustmentTransferField>,
                        before: VersionedPhotoEdit, after: VersionedPhotoEdit) {
        guard before.state != after.state else { return }
        let path = after.identity.path
        let priorHead = before == knownRecords[path] ? historyHeads[path] : nil
        knownRecords[path] = after
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

    private func outcome(_ path: String, _ status: AdjustmentTransferStatus, saved: VersionedPhotoEdit? = nil,
                         error: Error? = nil, requiresHistoryDecision: Bool = false) -> AdjustmentTransferOutcome {
        AdjustmentTransferOutcome(targetID: path, status: status, saved: saved, error: error,
            requiresHistoryDecision: requiresHistoryDecision)
    }
}
