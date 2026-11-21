import Foundation

public enum SharedAdjustmentTransferStatus: Equatable, Sendable {
    case applied
    case unchanged
    case skipped
    case blocked
    case conflict
    case failed
}

public enum SharedAdjustmentHistoryAction: Equatable, Sendable {
    case paste
    case preset
    case edit
    case synchronize
}

public enum SharedAdjustmentHistoryState: Equatable, Sendable {
    case applied
    case undone
    case redoInvalidated
}

public struct SharedAdjustmentTransferOutcome<Record> {
    public let targetID: String
    public let status: SharedAdjustmentTransferStatus
    public let saved: Record?
    public let error: Error?
    public var requiresHistoryDecision: Bool

    public init(
        targetID: String,
        status: SharedAdjustmentTransferStatus,
        saved: Record?,
        error: Error?,
        requiresHistoryDecision: Bool = false
    ) {
        self.targetID = targetID
        self.status = status
        self.saved = saved
        self.error = error
        self.requiresHistoryDecision = requiresHistoryDecision
    }
}

public struct SharedAdjustmentHistoryTransaction<Identity, EditState> {
    public typealias Action = SharedAdjustmentHistoryAction
    public typealias State = SharedAdjustmentHistoryState

    public struct Part {
        public let id: UUID
        public let priorHead: UUID?
        public let identity: Identity
        public let displayName: String
        public let before: EditState?
        public let after: EditState?
        public var state: State

        public init(
            id: UUID,
            priorHead: UUID?,
            identity: Identity,
            displayName: String = "",
            before: EditState?,
            after: EditState?,
            state: State
        ) {
            self.id = id
            self.priorHead = priorHead
            self.identity = identity
            self.displayName = displayName
            self.before = before
            self.after = after
            self.state = state
        }
    }

    public let id: UUID
    public let action: Action
    public let fields: Set<AdjustmentTransferField>
    public var parts: [Part]

    public init(
        id: UUID,
        action: Action,
        fields: Set<AdjustmentTransferField>,
        parts: [Part]
    ) {
        self.id = id
        self.action = action
        self.fields = fields
        self.parts = parts
    }
}

public struct PreparedTransferTargetSpec<Record, EditState> {
    public let id: String
    public let displayName: String
    public let original: Record?
    public let candidate: EditState?
    public let unchanged: Bool
    public let isCurrent: (() -> Bool)?
    public let error: Error?
    public let editGeneration: UInt64
    public let validateTarget: (() throws -> Void)?

    public init(
        id: String,
        displayName: String,
        original: Record?,
        candidate: EditState?,
        unchanged: Bool,
        isCurrent: (() -> Bool)?,
        error: Error?,
        editGeneration: UInt64,
        validateTarget: (() throws -> Void)? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.original = original
        self.candidate = candidate
        self.unchanged = unchanged
        self.isCurrent = isCurrent
        self.error = error
        self.editGeneration = editGeneration
        self.validateTarget = validateTarget
    }
}

public enum OptimisticEditPreparation<Record> {
    case unchanged(Record)
    case enqueued(commitID: UUID, before: Record, optimistic: Record)
}

public final class AdjustmentHistoryLedger<Identity: Equatable, EditState, Record> {
    private struct InFlightCommit {
        let id: UUID
        let key: String
        let partID: UUID?
        let previousRecord: Record?
        let previousIdentity: Identity?
        let previousHistoryHead: UUID?
        let restoredUndonePartIDs: [UUID]
    }

    private let keyOf: (Identity) -> String
    private let identityOf: (Record) -> Identity
    private let stateOf: (Record) -> EditState?
    private let sameState: (EditState?, EditState?) -> Bool
    private let sameRecord: (Record, Record) -> Bool

    private let stateLock = NSLock()
    private var outcomes: [UUID: [String: SharedAdjustmentTransferOutcome<Record>]] = [:]
    private var knownRecords: [String: Record] = [:]
    private var knownIdentities: [String: Identity] = [:]
    private var historyHeads: [String: UUID] = [:]
    private var editGenerations: [String: UInt64] = [:]
    private var inFlightCommits: [String: [InFlightCommit]] = [:]
    private var partKeys: [UUID: String] = [:]
    private var _transactions: [SharedAdjustmentHistoryTransaction<Identity, EditState>] = []

    public init(
        keyOf: @escaping (Identity) -> String,
        identityOf: @escaping (Record) -> Identity,
        stateOf: @escaping (Record) -> EditState?,
        sameState: @escaping (EditState?, EditState?) -> Bool,
        sameRecord: @escaping (Record, Record) -> Bool
    ) {
        self.keyOf = keyOf
        self.identityOf = identityOf
        self.stateOf = stateOf
        self.sameState = sameState
        self.sameRecord = sameRecord
    }

    public var transactions: [SharedAdjustmentHistoryTransaction<Identity, EditState>] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _transactions
    }

    public var hasInFlightCommits: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !inFlightCommits.isEmpty
    }

    public func editGeneration(forKey key: String) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return editGenerations[key, default: 0]
    }

    public func knownRecord(forKey key: String) -> Record? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return knownRecords[key]
    }

    public func isCurrentSave(_ record: Record) -> Bool {
        let key = keyOf(identityOf(record))
        stateLock.lock()
        let known = knownRecords[key]
        stateLock.unlock()
        guard let known else { return false }
        return sameRecord(known, record)
    }

    public func remember(_ record: Record, advanceGeneration: Bool = true) {
        let identity = identityOf(record)
        let key = keyOf(identity)
        stateLock.lock()
        knownRecords[key] = record
        knownIdentities[key] = identity
        if advanceGeneration {
            editGenerations[key, default: 0] &+= 1
        }
        stateLock.unlock()
    }

    public func adoptProcessingMigration(_ record: Record) {
        let identity = identityOf(record)
        let key = keyOf(identity)
        stateLock.lock()
        for index in _transactions.indices {
            var removedIDs: [UUID] = []
            _transactions[index].parts.removeAll { part in
                let matches = (partKeys[part.id] == key)
                if matches { removedIDs.append(part.id) }
                return matches
            }
            for partID in removedIDs {
                partKeys.removeValue(forKey: partID)
            }
        }
        _transactions.removeAll { $0.parts.isEmpty }
        historyHeads.removeValue(forKey: key)
        knownRecords[key] = record
        knownIdentities[key] = identity
        editGenerations[key, default: 0] &+= 1
        stateLock.unlock()
    }

    public func applyTargets(
        operationID: UUID,
        action: SharedAdjustmentHistoryAction,
        fields: Set<AdjustmentTransferField>,
        sourceIdentifier: String?,
        targets: [PreparedTransferTargetSpec<Record, EditState>],
        skipping: Set<String> = [],
        rememberUnchanged: Bool,
        saveTarget: (_ original: Record, _ candidate: EditState) throws -> Record,
        onRemembered: ((_ record: Record, _ targetID: String) -> Void)? = nil
    ) -> [SharedAdjustmentTransferOutcome<Record>] {
        guard targets.allSatisfy({ $0.error == nil || skipping.contains($0.id) }) else {
            return targets.map {
                makeOutcome(
                    $0.id,
                    .blocked,
                    error: $0.error ?? AdjustmentTransferError.incompatible("unresolved target preflight")
                )
            }
        }

        return targets.map { target in
            stateLock.lock()
            let cached = outcomes[operationID]?[target.id]
            stateLock.unlock()
            if let cached, [.applied, .unchanged, .skipped].contains(cached.status) {
                return cached
            }

            let result: SharedAdjustmentTransferOutcome<Record>
            if action == .synchronize && target.id == sourceIdentifier {
                result = makeOutcome(
                    target.id,
                    .blocked,
                    error: AdjustmentTransferError.incompatible("synchronization source")
                )
            } else if skipping.contains(target.id) {
                result = makeOutcome(target.id, .skipped)
            } else if target.isCurrent?() == false {
                result = makeOutcome(
                    target.id,
                    .blocked,
                    error: AdjustmentTransferError.draftRequiresPreflight
                )
            } else if let original = target.original, let candidate = target.candidate {
                do {
                    try target.validateTarget?()
                    let key = keyOf(identityOf(original))
                    guard editGeneration(forKey: key) == target.editGeneration else {
                        throw AdjustmentCommitError.expired
                    }
                    if target.unchanged {
                        if rememberUnchanged {
                            remember(original, advanceGeneration: false)
                            onRemembered?(original, target.id)
                        }
                        result = makeOutcome(target.id, .unchanged, saved: original)
                    } else {
                        let saved = try saveTarget(original, candidate)
                        _ = record(
                            id: operationID,
                            action: action,
                            fields: fields,
                            displayName: target.displayName,
                            before: original,
                            after: saved
                        )
                        onRemembered?(saved, target.id)
                        result = makeOutcome(target.id, .applied, saved: saved)
                    }
                } catch let error as AdjustmentCommitError {
                    result = makeOutcome(target.id, .conflict, error: error)
                } catch {
                    result = makeOutcome(target.id, .failed, error: error)
                }
            } else {
                result = makeOutcome(target.id, .blocked, error: target.error)
            }

            stateLock.lock()
            outcomes[operationID, default: [:]][target.id] = result
            stateLock.unlock()
            return result
        }
    }

    public func commitEdit(
        expected: Record,
        displayName: String = "",
        rememberUnchanged: Bool,
        isCurrent: () -> Bool = { true },
        validateBeforeSave: () throws -> Void = {},
        save: (_ before: Record) throws -> Record,
        onRemembered: ((Record) -> Void)? = nil
    ) -> SharedAdjustmentTransferOutcome<Record> {
        let expectedIdentity = identityOf(expected)
        let key = keyOf(expectedIdentity)
        guard isCurrent() else {
            return makeOutcome(key, .blocked, error: AdjustmentTransferError.draftRequiresPreflight)
        }
        do {
            try validateBeforeSave()
            stateLock.lock()
            let known = knownRecords[key]
            let knownIdentity = knownIdentities[key]
            stateLock.unlock()
            let before = (knownIdentity == expectedIdentity ? known : nil) ?? expected
            let saved = try save(before)
            if sameRecord(before, saved) {
                if rememberUnchanged {
                    remember(saved, advanceGeneration: false)
                    onRemembered?(saved)
                }
                return makeOutcome(key, .unchanged, saved: saved)
            }
            _ = record(
                id: UUID(),
                action: .edit,
                fields: [],
                displayName: displayName,
                before: before,
                after: saved
            )
            onRemembered?(saved)
            return makeOutcome(key, .applied, saved: saved)
        } catch {
            return makeOutcome(key, .failed, error: error)
        }
    }

    @discardableResult
    public func record(
        id: UUID,
        action: SharedAdjustmentHistoryAction,
        fields: Set<AdjustmentTransferField>,
        displayName: String = "",
        before: Record,
        after: Record
    ) -> UUID? {
        if sameRecord(before, after) { return nil }
        let afterIdentity = identityOf(after)
        let key = keyOf(afterIdentity)
        let beforeState = stateOf(before)
        let afterState = stateOf(after)

        stateLock.lock()
        let known = knownRecords[key]
        stateLock.unlock()
        let matchesKnown = known.map { sameRecord($0, before) } ?? false

        let partID = UUID()
        stateLock.lock()
        invalidateRedoAndAppendPartLocked(
            transactionID: id,
            partID: partID,
            key: key,
            action: action,
            fields: fields,
            identity: afterIdentity,
            displayName: displayName,
            before: beforeState,
            after: afterState,
            matchesKnown: matchesKnown
        )
        knownRecords[key] = after
        knownIdentities[key] = afterIdentity
        editGenerations[key, default: 0] &+= 1
        stateLock.unlock()
        return partID
    }

    public func beginOptimisticEdit(
        expected: Record,
        state: EditState,
        displayName: String = "",
        forceWhenUnchanged: Bool = false,
        makeRecord: (Identity, EditState) -> Record
    ) -> OptimisticEditPreparation<Record> {
        let expectedIdentity = identityOf(expected)
        let key = keyOf(expectedIdentity)

        stateLock.lock()
        let known = knownRecords[key]
        let knownIdentity = knownIdentities[key]
        stateLock.unlock()

        let matchingKnown = (knownIdentity == expectedIdentity) ? known : nil
        let before = matchingKnown ?? expected
        let beforeState = stateOf(before)
        if sameState(beforeState, state) && !forceWhenUnchanged {
            return .unchanged(before)
        }

        let beforeIdentity = identityOf(before)
        let optimistic = makeRecord(beforeIdentity, state)
        let optimisticIdentity = identityOf(optimistic)
        let optimisticState = stateOf(optimistic)
        let recordChanged = !sameRecord(before, optimistic)
        let matchesKnown = matchingKnown.map { sameRecord($0, before) } ?? false

        let commitID = UUID()
        let newPartID = recordChanged ? UUID() : nil

        stateLock.lock()
        let previousHead = historyHeads[key]
        var undonePartIDs: [UUID] = []
        for transaction in _transactions {
            for part in transaction.parts where partKeys[part.id] == key && part.state == .undone {
                undonePartIDs.append(part.id)
            }
        }
        if let newPartID {
            invalidateRedoAndAppendPartLocked(
                transactionID: UUID(),
                partID: newPartID,
                key: key,
                action: .edit,
                fields: [],
                identity: optimisticIdentity,
                displayName: displayName,
                before: beforeState,
                after: optimisticState,
                matchesKnown: matchesKnown
            )
        }
        knownRecords[key] = optimistic
        knownIdentities[key] = optimisticIdentity
        editGenerations[key, default: 0] &+= 1
        let inFlight = InFlightCommit(
            id: commitID,
            key: key,
            partID: newPartID,
            previousRecord: before,
            previousIdentity: beforeIdentity,
            previousHistoryHead: previousHead,
            restoredUndonePartIDs: undonePartIDs
        )
        inFlightCommits[key, default: []].append(inFlight)
        stateLock.unlock()

        return .enqueued(commitID: commitID, before: before, optimistic: optimistic)
    }

    public func confirmInFlightCommit(_ commitID: UUID, forKey key: String, confirmed: Record) {
        let confirmedIdentity = identityOf(confirmed)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var queue = inFlightCommits[key],
              let index = queue.firstIndex(where: { $0.id == commitID }) else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            inFlightCommits.removeValue(forKey: key)
            if knownIdentities[key] == confirmedIdentity {
                knownRecords[key] = confirmed
            }
        } else {
            inFlightCommits[key] = queue
        }
    }

    public func rollbackInFlightCommitsLIFO(
        from commitID: UUID,
        forKey key: String,
        fallbackRecord: () -> Record
    ) -> Record {
        stateLock.lock()
        guard var queue = inFlightCommits[key],
              let targetIndex = queue.firstIndex(where: { $0.id == commitID }) else {
            let current = knownRecords[key]
            stateLock.unlock()
            return current ?? fallbackRecord()
        }
        while queue.count > targetIndex {
            let entry = queue.removeLast()
            if let partID = entry.partID {
                partKeys.removeValue(forKey: partID)
                for tIndex in _transactions.indices {
                    _transactions[tIndex].parts.removeAll { $0.id == partID }
                }
                _transactions.removeAll { $0.parts.isEmpty }
            }
            if !entry.restoredUndonePartIDs.isEmpty {
                let restoreSet = Set(entry.restoredUndonePartIDs)
                for tIndex in _transactions.indices {
                    for pIndex in _transactions[tIndex].parts.indices
                        where restoreSet.contains(_transactions[tIndex].parts[pIndex].id) {
                        _transactions[tIndex].parts[pIndex].state = .undone
                    }
                }
            }
            if let priorHead = entry.previousHistoryHead {
                historyHeads[key] = priorHead
            } else {
                historyHeads.removeValue(forKey: key)
            }
            if let priorRecord = entry.previousRecord {
                knownRecords[key] = priorRecord
                knownIdentities[key] = entry.previousIdentity
            } else {
                knownRecords.removeValue(forKey: key)
                knownIdentities.removeValue(forKey: key)
            }
            editGenerations[key, default: 0] &+= 1
        }
        if queue.isEmpty {
            inFlightCommits.removeValue(forKey: key)
        } else {
            inFlightCommits[key] = queue
        }
        let restored = knownRecords[key]
        stateLock.unlock()
        return restored ?? fallbackRecord()
    }

    public func canUndo(forKey key: String) -> Bool {
        photoHistoryID(forKey: key, undo: true) != nil
    }

    public func canRedo(forKey key: String) -> Bool {
        photoHistoryID(forKey: key, undo: false) != nil
    }

    public func photoHistoryID(forKey key: String, undo: Bool) -> UUID? {
        let desired: SharedAdjustmentHistoryState = undo ? .applied : .undone
        stateLock.lock()
        defer { stateLock.unlock() }
        if undo {
            for transaction in _transactions.reversed() {
                if transaction.parts.contains(where: { partKeys[$0.id] == key && $0.state == desired }) {
                    return transaction.id
                }
            }
        } else {
            for transaction in _transactions {
                if transaction.parts.contains(where: { partKeys[$0.id] == key && $0.state == desired }) {
                    return transaction.id
                }
            }
        }
        return nil
    }

    public func applyHistory(
        id: UUID,
        photoKey: String?,
        undo: Bool,
        skipping: Set<String> = [],
        isCurrent: (String) -> Bool = { _ in true },
        validateBeforePrepare: (Identity, String) throws -> Void = { _, _ in },
        validateBeforeSave: (Identity, String) throws -> Void = { _, _ in },
        saveState: (Identity, EditState?) throws -> Record
    ) -> [SharedAdjustmentTransferOutcome<Record>] {
        let desired: SharedAdjustmentHistoryState = undo ? .applied : .undone
        stateLock.lock()
        guard let transactionIndex = _transactions.firstIndex(where: { $0.id == id }) else {
            stateLock.unlock()
            return []
        }
        let selectedParts: [(key: String, part: SharedAdjustmentHistoryTransaction<Identity, EditState>.Part)] =
            _transactions[transactionIndex].parts.compactMap { part in
                guard let key = partKeys[part.id],
                      part.state == desired,
                      photoKey == nil || key == photoKey else { return nil }
                return (key, part)
            }
        stateLock.unlock()

        var prepared: [UUID: Record] = [:]
        var rejected: [UUID: SharedAdjustmentTransferOutcome<Record>] = [:]
        for (key, part) in selectedParts {
            if skipping.contains(key) { continue }
            do {
                guard isCurrent(key) else {
                    throw AdjustmentTransferError.draftRequiresPreflight
                }
                try validateBeforePrepare(part.identity, key)
                stateLock.lock()
                let current = knownRecords[key]
                let currentIdentity = knownIdentities[key]
                let currentHead = historyHeads[key]
                stateLock.unlock()
                guard let current, currentIdentity == part.identity else {
                    throw AdjustmentCommitError.photoChanged
                }
                let expectedHead = undo ? part.id : part.priorHead
                let expectedState = undo ? part.after : part.before
                guard currentHead == expectedHead,
                      sameState(stateOf(current), expectedState) else {
                    throw AdjustmentCommitError.historyOrder
                }
                prepared[part.id] = current
            } catch let error as AdjustmentCommitError {
                rejected[part.id] = makeOutcome(key, .conflict, error: error, requiresHistoryDecision: true)
            } catch {
                rejected[part.id] = makeOutcome(key, .blocked, error: error, requiresHistoryDecision: true)
            }
        }

        guard rejected.isEmpty else {
            return selectedParts.map { key, part in
                if let reject = rejected[part.id] {
                    return reject
                }
                return makeOutcome(
                    key,
                    skipping.contains(key) ? .skipped : .blocked,
                    error: AdjustmentTransferError.incompatible("unresolved history conflict")
                )
            }
        }

        return selectedParts.map { key, part in
            guard let current = prepared[part.id] else {
                return makeOutcome(key, .skipped)
            }
            guard isCurrent(key) else {
                return makeOutcome(
                    key,
                    .blocked,
                    error: AdjustmentTransferError.draftRequiresPreflight,
                    requiresHistoryDecision: true
                )
            }
            do {
                let currentIdentity = identityOf(current)
                try validateBeforeSave(currentIdentity, key)
                let saved = try saveState(currentIdentity, undo ? part.before : part.after)
                let savedIdentity = identityOf(saved)
                stateLock.lock()
                knownRecords[key] = saved
                knownIdentities[key] = savedIdentity
                editGenerations[key, default: 0] &+= 1
                historyHeads[key] = undo ? part.priorHead : part.id
                if let tIdx = _transactions.firstIndex(where: { $0.id == id }),
                   let pIdx = _transactions[tIdx].parts.firstIndex(where: { $0.id == part.id }) {
                    _transactions[tIdx].parts[pIdx].state = undo ? .undone : .applied
                }
                stateLock.unlock()
                return makeOutcome(key, .applied, saved: saved)
            } catch let error as AdjustmentCommitError {
                return makeOutcome(key, .conflict, error: error, requiresHistoryDecision: true)
            } catch {
                return makeOutcome(key, .failed, error: error)
            }
        }
    }

    private func invalidateRedoAndAppendPartLocked(
        transactionID: UUID,
        partID: UUID,
        key: String,
        action: SharedAdjustmentHistoryAction,
        fields: Set<AdjustmentTransferField>,
        identity: Identity,
        displayName: String,
        before: EditState?,
        after: EditState?,
        matchesKnown: Bool
    ) {
        let priorHead = matchesKnown ? historyHeads[key] : nil
        for tIndex in _transactions.indices {
            for pIndex in _transactions[tIndex].parts.indices
                where partKeys[_transactions[tIndex].parts[pIndex].id] == key
                    && _transactions[tIndex].parts[pIndex].state == .undone {
                _transactions[tIndex].parts[pIndex].state = .redoInvalidated
            }
        }
        let part = SharedAdjustmentHistoryTransaction<Identity, EditState>.Part(
            id: partID,
            priorHead: priorHead,
            identity: identity,
            displayName: displayName,
            before: before,
            after: after,
            state: .applied
        )
        partKeys[partID] = key
        historyHeads[key] = partID
        if let index = _transactions.firstIndex(where: { $0.id == transactionID }) {
            _transactions[index].parts.append(part)
        } else {
            _transactions.append(
                SharedAdjustmentHistoryTransaction(
                    id: transactionID,
                    action: action,
                    fields: fields,
                    parts: [part]
                )
            )
        }
    }

    private func makeOutcome(
        _ id: String,
        _ status: SharedAdjustmentTransferStatus,
        saved: Record? = nil,
        error: Error? = nil,
        requiresHistoryDecision: Bool = false
    ) -> SharedAdjustmentTransferOutcome<Record> {
        SharedAdjustmentTransferOutcome(
            targetID: id,
            status: status,
            saved: saved,
            error: error,
            requiresHistoryDecision: requiresHistoryDecision
        )
    }
}
