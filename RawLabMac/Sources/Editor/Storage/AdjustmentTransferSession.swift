import Foundation

struct AdjustmentTransferTarget {
    let url: URL
    let defaultState: PhotoEditState
    var context: MacAdjustmentTransferContext
    var expectedIdentity: OriginalFileIdentity? = nil
    var isCurrent: (() -> Bool)? = nil
    var resolveMetadata: ((PhotoEditState) throws -> PhotoEditState)? = nil
    var resolveDefaultState: (() throws -> PhotoEditState)? = nil
}

enum AdjustmentTransferStatus { case applied, unchanged, skipped, blocked, conflict, failed }

struct AdjustmentTransferOutcome {
    let targetID: String
    let status: AdjustmentTransferStatus
    let saved: PhotoEditRecord?
    let error: Error?
    var requiresHistoryDecision = false
}

struct PreparedAdjustmentTransfer {
    struct Target {
        let id: String
        let original: PhotoEditRecord?
        let candidate: PhotoEditState?
        let unchanged: Bool
        let isCurrent: (() -> Bool)?
        let error: Error?
        var editGeneration: UInt64 = 0
    }
    let id: UUID
    let payload: AdjustmentTransferPayload
    let targets: [Target]
    let action: AdjustmentHistoryTransaction.Action
}

struct AdjustmentHistoryTransaction {
    enum Action { case paste, preset, edit, synchronize }
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

// 编辑与历史在编辑器线程提交；后台预检只读取会话代次和冻结参数。
final class AdjustmentTransferSession {
    private let store: EditPersistence
    private var outcomes: [UUID: [String: AdjustmentTransferOutcome]] = [:]
    private var knownRecords: [String: PhotoEditRecord] = [:]
    private let generationLock = NSLock()
    private var editGenerations: [String: UInt64] = [:]
    private var historyHeads: [String: UUID] = [:]
    private(set) var transactions: [AdjustmentHistoryTransaction] = []
    private(set) var clipboard: AdjustmentTransferPayload?

    init(store: EditPersistence) { self.store = store }

    func editGeneration(for url: URL) -> UInt64 {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        generationLock.lock(); defer { generationLock.unlock() }
        return editGenerations[path, default: 0]
    }

    func isCurrentSave(_ record: PhotoEditRecord) -> Bool { knownRecords[record.identity.path] == record }

    // 迁移拥有持久回退；旧的内存历史不能越过这次原子提交覆盖它。
    func adoptProcessingMigration(_ record: PhotoEditRecord) {
        for index in transactions.indices {
            transactions[index].parts.removeAll { $0.identity.path == record.identity.path }
        }
        transactions.removeAll { $0.parts.isEmpty }
        historyHeads.removeValue(forKey: record.identity.path)
        remember(record)
    }

    private func remember(_ record: PhotoEditRecord) {
        knownRecords[record.identity.path] = record
        generationLock.lock(); defer { generationLock.unlock() }
        editGenerations[record.identity.path, default: 0] &+= 1
    }

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
                let generation = editGeneration(for: target.url)
                let original = try store.readState(for: target.url)
                if let expected = target.expectedIdentity, original.identity != expected { throw AdjustmentCommitError.photoChanged }
                let stored = try original.state ?? target.resolveDefaultState?() ?? target.defaultState
                let effective = try target.resolveMetadata?(stored) ?? stored
                let candidate = try MacAdjustmentTransfer.prepare(payload: payload, target: effective, context: target.context)
                prepared.append(.init(id: id, original: original, candidate: candidate, unchanged: candidate == effective,
                    isCurrent: target.isCurrent, error: nil, editGeneration: generation))
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

    func commitEdit(expected: PhotoEditRecord, state: PhotoEditState,
                    isCurrent: () -> Bool = { true }) -> AdjustmentTransferOutcome {
        let id = expected.identity.path
        guard isCurrent() else { return outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight) }
        do {
            let before = knownRecords[id].flatMap { $0.identity == expected.identity ? $0 : nil } ?? expected
            try state.settings.validateResetValues()
            guard state.masterRecipeID == state.settings.masterRecipeID else {
                throw AdjustmentTransferError.invalidPayload("recipe identity")
            }
            let saved = try store.saveState(identity: before.identity, state: state)
            guard saved != before else { return outcome(id, .unchanged, saved: saved) }
            record(id: UUID(), action: .edit, fields: [], before: before, after: saved)
            return outcome(id, .applied, saved: saved)
        } catch { return outcome(id, .failed, error: error) }
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
        var prepared: [Int: PhotoEditRecord] = [:]
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
                        before: PhotoEditRecord, after: PhotoEditRecord) {
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

    private func outcome(_ path: String, _ status: AdjustmentTransferStatus, saved: PhotoEditRecord? = nil,
                         error: Error? = nil, requiresHistoryDecision: Bool = false) -> AdjustmentTransferOutcome {
        AdjustmentTransferOutcome(targetID: path, status: status, saved: saved, error: error,
            requiresHistoryDecision: requiresHistoryDecision)
    }
}
