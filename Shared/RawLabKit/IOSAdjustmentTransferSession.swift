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

public typealias IOSAdjustmentTransferStatus = SharedAdjustmentTransferStatus
public typealias IOSAdjustmentTransferOutcome = SharedAdjustmentTransferOutcome<PhotoEditRecord>
public typealias IOSAdjustmentHistoryTransaction = SharedAdjustmentHistoryTransaction<PhotoIdentity, PhotoEditState>

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

// 候选来自预检快照，提交时核对该记录；会话历史仍由记录、head 和编辑代次决定。
public final class IOSAdjustmentTransferSession {
    private let store: EditPersistence
    private let ledger: AdjustmentHistoryLedger<PhotoIdentity, PhotoEditState, PhotoEditRecord>
    private let validatorLock = NSLock()
    private var sourceValidators: [String: () throws -> Void] = [:]
    public var transactions: [IOSAdjustmentHistoryTransaction] { ledger.transactions }
    public private(set) var clipboard: AdjustmentTransferPayload?

    public init(store: EditPersistence) {
        self.store = store
        self.ledger = AdjustmentHistoryLedger(
            keyOf: { $0.key },
            identityOf: { $0.identity },
            stateOf: { $0.state },
            sameState: Self.sameState,
            sameRecord: { $0.hasSameAdjustments(as: $1) }
        )
    }

    public func editGeneration(for identity: PhotoIdentity) -> UInt64 {
        editGeneration(forKey: identity.key)
    }

    public func editGeneration(forKey key: String) -> UInt64 {
        ledger.editGeneration(forKey: key)
    }

    public func isCurrentSave(_ record: PhotoEditRecord) -> Bool {
        ledger.isCurrentSave(record)
    }

    public func refreshSource(_ identity: PhotoIdentity, validate: @escaping () throws -> Void) {
        let key = identity.key
        guard ledger.knownRecord(forKey: key) != nil else { return }
        setSourceValidator(validate, forKey: key)
    }

    public func adoptProcessingMigration(_ record: PhotoEditRecord) {
        ledger.adoptProcessingMigration(record)
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
        let validatorsByTargetID = Dictionary(
            operation.targets.compactMap { target in
                target.validateSource.map { (target.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let specs = operation.targets.map { target in
            PreparedTransferTargetSpec(
                id: target.id,
                displayName: target.displayName,
                original: target.original,
                candidate: target.candidate,
                unchanged: target.unchanged,
                isCurrent: target.isCurrent,
                error: target.error,
                editGeneration: target.editGeneration,
                validateTarget: target.validateSource
            )
        }
        return ledger.applyTargets(
            operationID: operation.id,
            action: operation.action,
            fields: operation.payload.fields,
            sourceIdentifier: operation.payload.source.identifier,
            targets: specs,
            skipping: skipping,
            rememberUnchanged: true,
            saveTarget: { original, candidate in
                try store.saveTransferredState(candidate.withUpdatedAt(Date()), expected: original)
            },
            onRemembered: { saved, targetID in
                if let validator = validatorsByTargetID[targetID] {
                    self.setSourceValidator(validator, forKey: saved.identity.key)
                }
            }
        )
    }

    // 显式全部重置在落盘时单向清除处理迁移回执；调整历史只保存编辑值快照，undo 恢复重置前参数但不恢复迁移回执。
    public func commitEdit(expected: PhotoEditRecord, state: PhotoEditState, displayName: String? = nil,
                           defaultState: PhotoEditState? = nil, clearsProcessingMigration: Bool = false,
                           isCurrent: () -> Bool = { true },
                           validateSource: (() throws -> Void)? = nil) -> IOSAdjustmentTransferOutcome {
        let id = expected.identity.key
        return ledger.commitEdit(
            expected: expected,
            displayName: displayName ?? id,
            rememberUnchanged: true,
            isCurrent: isCurrent,
            validateBeforeSave: {
                try IOSAdjustmentTransfer.validate(state.settings)
                try validateSource?()
            },
            save: { before in
                let desired: PhotoEditState? = before.state == nil &&
                    defaultState.map({ state.hasSameAdjustments(as: $0) }) == true ? nil : state.withUpdatedAt(Date())
                return try store.saveState(identity: before.identity, state: desired,
                                           clearsProcessingMigration: clearsProcessingMigration)
            },
            onRemembered: { saved in
                if let validateSource {
                    self.setSourceValidator(validateSource, forKey: saved.identity.key)
                }
            }
        )
    }

    public func undoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil,
                          isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: true, isCurrent: isCurrent)
    }

    public func redoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil,
                          isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        historyPhoto(identity, transactionID: transactionID, undo: false, isCurrent: isCurrent)
    }

    public func canUndoPhoto(_ identity: PhotoIdentity) -> Bool { ledger.canUndo(forKey: identity.key) }
    public func canRedoPhoto(_ identity: PhotoIdentity) -> Bool { ledger.canRedo(forKey: identity.key) }

    public func undoTransaction(_ id: UUID, skipping: Set<String> = [],
                                isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }

    public func redoTransaction(_ id: UUID, skipping: Set<String> = [],
                                isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] {
        history(id: id, photo: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }

    public func photoHistoryID(_ identity: PhotoIdentity, undo: Bool) -> UUID? {
        ledger.photoHistoryID(forKey: identity.key, undo: undo)
    }

    private func historyPhoto(_ identity: PhotoIdentity, transactionID: UUID?, undo: Bool,
                              isCurrent: (String) -> Bool) -> [IOSAdjustmentTransferOutcome] {
        guard let id = transactionID ?? photoHistoryID(identity, undo: undo) else { return [] }
        return history(id: id, photo: identity.key, undo: undo, skipping: [], isCurrent: isCurrent)
    }

    private func history(id: UUID, photo: String?, undo: Bool, skipping: Set<String>,
                         isCurrent: (String) -> Bool) -> [IOSAdjustmentTransferOutcome] {
        ledger.applyHistory(
            id: id,
            photoKey: photo,
            undo: undo,
            skipping: skipping,
            isCurrent: isCurrent,
            validateBeforePrepare: { _, key in try self.sourceValidator(for: key)?() },
            validateBeforeSave: { _, key in try self.sourceValidator(for: key)?() },
            saveState: { identity, targetState in
                try self.store.saveState(identity: identity, state: targetState)
            }
        )
    }

    private func sourceValidator(for key: String) -> (() throws -> Void)? {
        validatorLock.lock(); defer { validatorLock.unlock() }
        return sourceValidators[key]
    }

    private func setSourceValidator(_ validator: @escaping () throws -> Void, forKey key: String) {
        validatorLock.lock(); defer { validatorLock.unlock() }
        sourceValidators[key] = validator
    }

    private static func sameState(_ lhs: PhotoEditState?, _ rhs: PhotoEditState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameAdjustments(as: rhs)
        default: return false
        }
    }
}
