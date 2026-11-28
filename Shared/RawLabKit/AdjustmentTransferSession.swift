import Foundation

public final class AdjustmentTransferPreflight: ObservableObject {
    @Published public private(set) var isRunning = false
    private let queue: DispatchQueue; private var active: DispatchWorkItem?
    public init(queue: DispatchQueue = DispatchQueue(label: "rawlab.adjustment-preflight", qos: .userInitiated)) { self.queue = queue }
    deinit { active?.cancel() }
    public func cancel() {
        active?.cancel(); active = nil
        if Thread.isMainThread { isRunning = false } else { DispatchQueue.main.async { [weak self] in if self?.active == nil { self?.isRunning = false } } }
    }

    public func start(_ operation: @escaping (@escaping () -> Bool) throws -> PreparedAdjustmentTransfer, completed: @escaping (Result<PreparedAdjustmentTransfer, Error>) -> Void) {
        cancel(); isRunning = true
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            let cancelled = { work?.isCancelled ?? true }, result = Result<PreparedAdjustmentTransfer, Error> { try operation(cancelled) }
            DispatchQueue.main.async { guard let self, self.active === work, !cancelled() else { return }; self.active = nil; self.isRunning = false; completed(result) }
        }
        active = work; if let work { queue.async(execute: work) }
    }
}

public struct TransferTargetDescriptor<Identity: Equatable> {
    public let id: String, targetIdentity: Identity?, url: URL, displayName: String, defaultState: PhotoEditState
    public var context: AdjustmentTransferContext; public var expectedIdentity: Identity? { targetIdentity }
    public var isCurrent: (() -> Bool)?, validateSource: (() throws -> Void)?, resolveMetadata: ((PhotoEditState) throws -> PhotoEditState)?, resolveDefaultState: (() throws -> PhotoEditState)?
    public var isX3f: Bool

    fileprivate init(id: String, targetIdentity: Identity?, url: URL, displayName: String, defaultState: PhotoEditState, context: AdjustmentTransferContext,
                     isCurrent: (() -> Bool)? = nil, validateSource: (() throws -> Void)? = nil, resolveMetadata: ((PhotoEditState) throws -> PhotoEditState)? = nil, resolveDefaultState: (() throws -> PhotoEditState)? = nil, isX3f: Bool = false) {
        self.id = id; self.targetIdentity = targetIdentity; self.url = url; self.displayName = displayName; self.defaultState = defaultState; self.context = context
        self.isCurrent = isCurrent; self.validateSource = validateSource; self.resolveMetadata = resolveMetadata; self.resolveDefaultState = resolveDefaultState; self.isX3f = isX3f
    }
}

public extension TransferTargetDescriptor where Identity == PhotoIdentity {
    var identity: PhotoIdentity { targetIdentity! }
    init(identity: PhotoIdentity, displayName: String, defaultState: PhotoEditState, context: AdjustmentTransferContext, isCurrent: (() -> Bool)? = nil, validateSource: (() throws -> Void)? = nil, isX3f: Bool = false) {
        self.init(id: identity.key, targetIdentity: identity, url: URL(fileURLWithPath: "/\(identity.key)"), displayName: displayName, defaultState: defaultState, context: context, isCurrent: isCurrent, validateSource: validateSource, isX3f: isX3f)
    }
}

public extension TransferTargetDescriptor where Identity == OriginalFileIdentity {
    init(url: URL, defaultState: PhotoEditState, context: AdjustmentTransferContext, expectedIdentity: OriginalFileIdentity? = nil,
         isCurrent: (() -> Bool)? = nil, resolveMetadata: ((PhotoEditState) throws -> PhotoEditState)? = nil, resolveDefaultState: (() throws -> PhotoEditState)? = nil) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        self.init(id: canonical.path, targetIdentity: expectedIdentity, url: canonical, displayName: canonical.lastPathComponent, defaultState: defaultState, context: context, isCurrent: isCurrent, resolveMetadata: resolveMetadata, resolveDefaultState: resolveDefaultState)
    }
}

public typealias IOSAdjustmentTransferStatus = SharedAdjustmentTransferStatus
public typealias AdjustmentTransferStatus = SharedAdjustmentTransferStatus
public typealias IOSAdjustmentTransferOutcome = SharedAdjustmentTransferOutcome<PhotoEditRecord>
public typealias AdjustmentTransferOutcome = SharedAdjustmentTransferOutcome<MacPhotoEditRecord>
public typealias IOSAdjustmentHistoryTransaction = SharedAdjustmentHistoryTransaction<PhotoIdentity, PhotoEditState>
public typealias AdjustmentHistoryTransaction = SharedAdjustmentHistoryTransaction<OriginalFileIdentity, PhotoEditState>
public typealias IOSAdjustmentTransferTarget = TransferTargetDescriptor<PhotoIdentity>
public typealias AdjustmentTransferTarget = TransferTargetDescriptor<OriginalFileIdentity>
public typealias MacAdjustmentTransferTarget = AdjustmentTransferTarget

public struct PreparedTransferOperation<Record> {
    public struct Target {
        public let id: String, displayName: String; public let original: Record?; public let candidate: PhotoEditState?
        public let unchanged: Bool; public let isCurrent: (() -> Bool)?; public let validateSource: (() throws -> Void)?
        public let error: Error?; public let editGeneration: UInt64; public var notices: [AdjustmentTransferNotice] = []
        public let isX3f: Bool

        public init(id: String, displayName: String = "", original: Record?, candidate: PhotoEditState?, unchanged: Bool,
                    isCurrent: (() -> Bool)?, validateSource: (() throws -> Void)? = nil, error: Error?, editGeneration: UInt64 = 0, notices: [AdjustmentTransferNotice] = [], isX3f: Bool = false) {
            self.id = id; self.displayName = displayName; self.original = original; self.candidate = candidate; self.unchanged = unchanged
            self.isCurrent = isCurrent; self.validateSource = validateSource; self.error = error; self.editGeneration = editGeneration; self.notices = notices; self.isX3f = isX3f
        }
    }

    public let id: UUID; public let payload: AdjustmentTransferPayload; public let action: SharedAdjustmentHistoryAction
    public let targets: [Target]; public var notices: [AdjustmentTransferNotice] = []

    public init(id: UUID, payload: AdjustmentTransferPayload, action: SharedAdjustmentHistoryAction, targets: [Target], notices: [AdjustmentTransferNotice] = []) {
        self.id = id; self.payload = payload; self.action = action; self.targets = targets; self.notices = notices
    }
    public init(id: UUID, payload: AdjustmentTransferPayload, targets: [Target], action: SharedAdjustmentHistoryAction, notices: [AdjustmentTransferNotice] = []) {
        self.init(id: id, payload: payload, action: action, targets: targets, notices: notices)
    }
    public func effectiveNotices(_ outcomes: [SharedAdjustmentTransferOutcome<Record>]) -> [AdjustmentTransferNotice] {
        let active = Set(outcomes.filter { $0.status == .applied || $0.status == .unchanged }.map(\.targetID))
        var merged = [AdjustmentTransferNotice]()
        for target in targets where target.error == nil && active.contains(target.id) {
            for notice in target.notices where !merged.contains(notice) { merged.append(notice) }
        }
        return merged
    }
}

public typealias IOSPreparedAdjustmentTransfer = PreparedTransferOperation<PhotoEditRecord>
public typealias PreparedAdjustmentTransfer = PreparedTransferOperation<MacPhotoEditRecord>
public typealias MacPreparedAdjustmentTransfer = PreparedAdjustmentTransfer

public final class EditTransferSession<Identity: Equatable, Record: Equatable> {
    internal struct Backend {
        let storeHasPendingCommits: () -> Bool, storeFlushPendingCommits: () -> Bool, prepareSync: () -> Void
        let readPreparedTarget: (TransferTargetDescriptor<Identity>, (String) -> Record?) throws -> (record: Record, baseState: PhotoEditState, context: AdjustmentTransferContext)
        let captureState: (AdjustmentTransferScope, PhotoEditState, AdjustmentTransferContext) throws -> AdjustmentTransferPayload
        let prepareState: (AdjustmentTransferPayload, PhotoEditState, AdjustmentTransferContext) throws -> PhotoEditState
        let saveTransferred: (PhotoEditState, Record, Bool) throws -> Record, saveEdited: (Identity, PhotoEditState?, Bool) throws -> Record
        let prepareCommitState: (PhotoEditState, Record, PhotoEditState?) -> PhotoEditState?
        let resetByIdentity: ((Identity) throws -> Record)?, resetByURL: ((URL) throws -> Record)?
        let deliverReadyCompletedCommits: () -> Void
        let enqueueEdited: ((Identity, PhotoEditState?, Bool, @escaping (Result<Record, Error>) -> Void) throws -> Void)?
        let validateBeforeApply: (Record) throws -> Void, validateCommitState: (PhotoEditState) throws -> Void
        let validateHistoryPrepare: (Identity, String) throws -> Void, validateHistorySave: (Identity, String) throws -> Void
        let makeRecord: (Identity, PhotoEditState?) -> Record, keyOf: (Identity) -> String
        let identityOf: (Record) -> Identity, stateOf: (Record) -> PhotoEditState?
        let sameState: (PhotoEditState?, PhotoEditState?) -> Bool, hasSameAdjustments: (Record, Record?) -> Bool, rememberUnchanged: Bool
    }

    private let backend: Backend
    private let ledger: AdjustmentHistoryLedger<Identity, PhotoEditState, Record>
    private var defaultStates: [String: PhotoEditState] = [:], sourceValidators: [String: () throws -> Void] = [:]
    private let syncLock = NSLock(), validatorLock = NSLock()

    public var transactions: [SharedAdjustmentHistoryTransaction<Identity, PhotoEditState>] { ledger.transactions }
    public private(set) var clipboard: AdjustmentTransferPayload?

    internal init(backend: Backend) {
        self.backend = backend
        self.ledger = AdjustmentHistoryLedger(
            keyOf: backend.keyOf, identityOf: backend.identityOf, stateOf: backend.stateOf,
            sameState: backend.sameState, sameRecord: backend.hasSameAdjustments
        )
    }

    public var hasPendingCommits: Bool { backend.storeHasPendingCommits() || ledger.hasInFlightCommits }
    @discardableResult public func flushPendingCommits() -> Bool { backend.storeFlushPendingCommits() }
    public func editGeneration(forKey key: String) -> UInt64 { ledger.editGeneration(forKey: key) }
    public func isCurrentSave(_ record: Record) -> Bool { ledger.isCurrentSave(record) }
    public func adoptProcessingMigration(_ record: Record) { ledger.adoptProcessingMigration(record) }
    public func rememberExternalSave(_ record: Record) {
        syncLock.lock(); defer { syncLock.unlock() }
        let key = backend.keyOf(backend.identityOf(record))
        let known = ledger.knownRecord(forKey: key)
        let changed = known.map {
            !backend.sameState(backend.stateOf($0), backend.stateOf(record)) ||
            backend.identityOf($0) != backend.identityOf(record)
        } ?? true
        ledger.remember(record, advanceGeneration: changed)
    }
    fileprivate func sourceValidator(for key: String) -> (() throws -> Void)? {
        validatorLock.lock(); defer { validatorLock.unlock() }; return sourceValidators[key]
    }
    fileprivate func setSourceValidator(_ validator: @escaping () throws -> Void, forKey key: String) {
        validatorLock.lock(); defer { validatorLock.unlock() }; sourceValidators[key] = validator
    }

    @discardableResult
    public func copy(scope: AdjustmentTransferScope, snapshot: PhotoEditState, context: AdjustmentTransferContext) throws -> AdjustmentTransferPayload {
        let captured = try backend.captureState(scope, snapshot, context)
        clipboard = captured
        return captured
    }

    public func prepare(payload: AdjustmentTransferPayload, targets: [TransferTargetDescriptor<Identity>],
                        action: SharedAdjustmentHistoryAction = .paste, shouldCancel: () -> Bool = { false }) throws -> PreparedTransferOperation<Record> {
        backend.prepareSync()
        guard !shouldCancel() else { throw CancellationError() }
        try payload.validate()
        var seen = Set<String>(), prepared = [PreparedTransferOperation<Record>.Target]()
        for target in targets {
            guard !shouldCancel() else { throw CancellationError() }
            guard seen.insert(target.id).inserted, action != .synchronize || target.id != payload.source.identifier else { continue }
            do {
                guard target.isCurrent?() != false else { throw AdjustmentTransferError.draftRequiresPreflight }
                try target.validateSource?()
                let read = try backend.readPreparedTarget(target) { [ledger] in ledger.knownRecord(forKey: $0) }
                let editGeneration = ledger.editGeneration(forKey: backend.keyOf(backend.identityOf(read.record)))
                var notices = [AdjustmentTransferNotice](), context = read.context
                context.transferNotices = { notices.append($0) }
                let candidate = try backend.prepareState(payload, read.baseState, context)
                prepared.append(.init(id: target.id, displayName: target.displayName, original: read.record, candidate: candidate,
                                      unchanged: backend.sameState(candidate, read.baseState), isCurrent: target.isCurrent, validateSource: target.validateSource,
                                      error: nil, editGeneration: editGeneration, notices: notices, isX3f: target.isX3f))
            } catch {
                prepared.append(.init(id: target.id, displayName: target.displayName, original: nil, candidate: nil, unchanged: false,
                                      isCurrent: target.isCurrent, validateSource: target.validateSource, error: error,
                                      editGeneration: ledger.editGeneration(forKey: target.id), isX3f: target.isX3f))
            }
        }
        if shouldCancel() { throw CancellationError() }
        var mergedNotices = [AdjustmentTransferNotice]()
        for notice in prepared.flatMap(\.notices) where !mergedNotices.contains(notice) { mergedNotices.append(notice) }
        return PreparedTransferOperation(id: UUID(), payload: payload, action: action, targets: prepared, notices: mergedNotices)
    }

    public func apply(_ operation: PreparedTransferOperation<Record>, skipping: Set<String> = []) -> [SharedAdjustmentTransferOutcome<Record>] {
        syncLock.lock(); defer { syncLock.unlock() }
        _ = backend.storeFlushPendingCommits()
        let validators = Dictionary(operation.targets.compactMap { t in t.validateSource.map { (t.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let specs = operation.targets.map { t in
            PreparedTransferTargetSpec(
                id: t.id, displayName: t.displayName, original: t.original, candidate: t.candidate, unchanged: t.unchanged,
                isCurrent: t.isCurrent, error: t.error, editGeneration: t.editGeneration,
                validateTarget: { try t.validateSource?(); if let o = t.original { try self.backend.validateBeforeApply(o) } }
            )
        }
        let defaults = operation.targets.reduce(into: [String: PhotoEditState]()) { map, target in
            if let original = target.original, let candidate = target.candidate { map[target.id] = backend.stateOf(original) ?? candidate }
        }
        let x3fTargets = Set(operation.targets.filter(\.isX3f).map(\.id))
        return ledger.applyTargets(
            operationID: operation.id, action: operation.action, fields: operation.payload.fields, sourceIdentifier: operation.payload.source.identifier,
            targets: specs, skipping: skipping, rememberUnchanged: backend.rememberUnchanged,
            saveTarget: { try self.backend.saveTransferred($1, $0, x3fTargets.contains(self.backend.keyOf(self.backend.identityOf($0)))) },
            onRemembered: { saved, targetID in
                if let fallback = defaults[targetID] { self.defaultStates[targetID] = self.defaultStates[targetID] ?? fallback }
                if let validator = validators[targetID] { self.setSourceValidator(validator, forKey: self.backend.keyOf(self.backend.identityOf(saved))) }
            }
        )
    }

    @discardableResult
    public func commitEdit(expected: Record, state: PhotoEditState, displayName: String? = nil, defaultState: PhotoEditState? = nil,
                           clearsProcessingMigration: Bool = false, isCurrent: () -> Bool = { true }, validateSource: (() throws -> Void)? = nil) -> SharedAdjustmentTransferOutcome<Record> {
        syncLock.lock(); defer { syncLock.unlock() }
        _ = backend.storeFlushPendingCommits()
        let key = backend.keyOf(backend.identityOf(expected))
        defaultStates[key] = defaultStates[key] ?? backend.stateOf(expected) ?? state
        return ledger.commitEdit(
            expected: expected, displayName: displayName ?? (defaultState != nil || validateSource != nil ? key : ""),
            rememberUnchanged: backend.rememberUnchanged, isCurrent: isCurrent,
            validateBeforeSave: { try self.backend.validateCommitState(state); try validateSource?() },
            save: { try self.backend.saveEdited(self.backend.identityOf($0), self.backend.prepareCommitState(state, $0, defaultState), clearsProcessingMigration) },
            onRemembered: { saved in if let validateSource { self.setSourceValidator(validateSource, forKey: self.backend.keyOf(self.backend.identityOf(saved))) } }
        )
    }

    @discardableResult
    public func commitEditAsync(expected: Record, state: PhotoEditState, displayName: String = "",
                                clearsProcessingMigration: Bool = false, isCurrent: () -> Bool = { true },
                                completion: ((SharedAdjustmentTransferOutcome<Record>, Record?) -> Void)? = nil) -> SharedAdjustmentTransferOutcome<Record> {
        let id = backend.keyOf(backend.identityOf(expected))
        guard isCurrent() else {
            let blocked = outcome(id, .blocked, error: AdjustmentTransferError.draftRequiresPreflight)
            completion?(blocked, nil); return blocked
        }
        backend.deliverReadyCompletedCommits()
        var pushedCommitID: UUID?
        var rollbackBaseline = expected
        do {
            try backend.validateCommitState(state)
            defaultStates[id] = defaultStates[id] ?? backend.stateOf(expected) ?? state
            switch ledger.beginOptimisticEdit(expected: expected, state: state, displayName: displayName,
                                              forceWhenUnchanged: clearsProcessingMigration, makeRecord: backend.makeRecord) {
            case .unchanged(let before):
                let unchanged = outcome(id, .unchanged, saved: before)
                completion?(unchanged, nil); return unchanged
            case .enqueued(let commitID, let before, let optimisticSaved):
                pushedCommitID = commitID; rollbackBaseline = before
                if let enqueueEdited = backend.enqueueEdited {
                    try enqueueEdited(backend.identityOf(before), state, clearsProcessingMigration) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success(let confirmed):
                            self.ledger.confirmInFlightCommit(commitID, forKey: id, confirmed: confirmed)
                            completion?(self.outcome(id, .applied, saved: confirmed), confirmed)
                        case .failure(let error):
                            let rollback = self.ledger.rollbackInFlightCommitsLIFO(from: commitID, forKey: id, fallbackRecord: { before })
                            completion?(self.outcome(id, .failed, error: error), rollback)
                        }
                    }
                    return outcome(id, .applied, saved: optimisticSaved)
                }
                let confirmed = try backend.saveEdited(backend.identityOf(before), state, clearsProcessingMigration)
                ledger.confirmInFlightCommit(commitID, forKey: id, confirmed: confirmed)
                let applied = outcome(id, .applied, saved: confirmed)
                completion?(applied, confirmed); return applied
            }
        } catch {
            let rollback = pushedCommitID.flatMap { ledger.rollbackInFlightCommitsLIFO(from: $0, forKey: id, fallbackRecord: { rollbackBaseline }) }
            let failed = outcome(id, .failed, error: error)
            completion?(failed, rollback); return failed
        }
    }

    public func undoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [SharedAdjustmentTransferOutcome<Record>] {
        history(id: id, photoKey: nil, undo: true, skipping: skipping, isCurrent: isCurrent)
    }
    public func redoTransaction(_ id: UUID, skipping: Set<String> = [], isCurrent: (String) -> Bool = { _ in true }) -> [SharedAdjustmentTransferOutcome<Record>] {
        history(id: id, photoKey: nil, undo: false, skipping: skipping, isCurrent: isCurrent)
    }

    fileprivate func history(id: UUID, photoKey: String?, undo: Bool, skipping: Set<String> = [], isCurrent: (String) -> Bool) -> [SharedAdjustmentTransferOutcome<Record>] {
        syncLock.lock(); defer { syncLock.unlock() }
        _ = backend.storeFlushPendingCommits()
        return ledger.applyHistory(id: id, photoKey: photoKey, undo: undo, skipping: skipping, isCurrent: isCurrent,
                                   validateBeforePrepare: { try self.backend.validateHistoryPrepare($0, $1); try self.sourceValidator(for: $1)?() },
                                   validateBeforeSave: { try self.backend.validateHistorySave($0, $1); try self.sourceValidator(for: $1)?() },
                                   saveState: { try self.backend.saveEdited($0, $1, false) })
    }

    fileprivate func historyPhoto(key: String, transactionID: UUID?, undo: Bool, isCurrent: (String) -> Bool) -> [SharedAdjustmentTransferOutcome<Record>] {
        guard let id = transactionID ?? ledger.photoHistoryID(forKey: key, undo: undo) else { return [] }
        return history(id: id, photoKey: key, undo: undo, isCurrent: isCurrent)
    }

    fileprivate func outcome(_ id: String, _ status: SharedAdjustmentTransferStatus, saved: Record? = nil,
                             error: Error? = nil, requiresHistoryDecision: Bool = false) -> SharedAdjustmentTransferOutcome<Record> {
        SharedAdjustmentTransferOutcome(targetID: id, status: status, saved: saved, error: error, requiresHistoryDecision: requiresHistoryDecision)
    }
}

public extension EditTransferSession where Identity == PhotoIdentity, Record == PhotoEditRecord {
    convenience init(store: EditPersistence) {
        self.init(backend: Backend(
            storeHasPendingCommits: { false }, storeFlushPendingCommits: { true }, prepareSync: {},
            readPreparedTarget: { target, _ in
                let original = try store.readState(for: target.identity, requiringLegacyDecision: true, isX3f: target.isX3f)
                let fallback = target.defaultState.repairingLegacyNormalX3f(isX3f: target.isX3f).state
                return (original, original.state ?? fallback, target.context)
            },
            captureState: { try IOSAdjustmentTransfer.capture(scope: $0, snapshot: $1, context: $2) },
            prepareState: { try IOSAdjustmentTransfer.prepare(payload: $0, target: $1, context: $2) },
            saveTransferred: { try store.saveTransferredState($0.withUpdatedAt(Date()), expected: $1, isX3f: $2) },
            saveEdited: { try store.saveState(identity: $0, state: $1, clearsProcessingMigration: $2) },
            prepareCommitState: { state, before, defaultState in
                (before.state == nil && defaultState.map { state.hasSameAdjustments(as: $0) } == true) ? nil : state.withUpdatedAt(Date())
            },
            resetByIdentity: { try store.resetToUnmodified($0) }, resetByURL: nil, deliverReadyCompletedCommits: {}, enqueueEdited: nil,
            validateBeforeApply: { _ in }, validateCommitState: { try IOSAdjustmentTransfer.validate($0.settings) },
            validateHistoryPrepare: { _, _ in }, validateHistorySave: { _, _ in },
            makeRecord: { PhotoEditRecord(identity: $0, state: $1) }, keyOf: { $0.key }, identityOf: { $0.identity },
            stateOf: { $0.state }, sameState: { lhs, rhs in (lhs == nil && rhs == nil) || (lhs != nil && rhs != nil && lhs!.hasSameAdjustments(as: rhs!)) },
            hasSameAdjustments: { $0.hasSameAdjustments(as: $1) }, rememberUnchanged: true
        ))
    }

    func editGeneration(for identity: PhotoIdentity) -> UInt64 { editGeneration(forKey: identity.key) }
    func refreshSource(_ identity: PhotoIdentity, validate: @escaping () throws -> Void, record: PhotoEditRecord? = nil) {
        syncLock.lock(); defer { syncLock.unlock() }
        let key = identity.key
        guard let known = ledger.knownRecord(forKey: key) else { return }
        if let record, record.identity == identity,
           !backend.sameState(backend.stateOf(known), backend.stateOf(record)) || known.identity != record.identity {
            ledger.remember(record, advanceGeneration: true)
        }
        setSourceValidator(validate, forKey: key)
    }
    @discardableResult func resetToUnmodified(_ identity: PhotoIdentity) throws -> PhotoEditRecord { let c = try backend.resetByIdentity!(identity); adoptProcessingMigration(c); return c }
    func undoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] { historyPhoto(key: identity.key, transactionID: transactionID, undo: true, isCurrent: isCurrent) }
    func redoPhoto(_ identity: PhotoIdentity, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [IOSAdjustmentTransferOutcome] { historyPhoto(key: identity.key, transactionID: transactionID, undo: false, isCurrent: isCurrent) }
    func canUndoPhoto(_ identity: PhotoIdentity) -> Bool { ledger.canUndo(forKey: identity.key) }
    func canRedoPhoto(_ identity: PhotoIdentity) -> Bool { ledger.canRedo(forKey: identity.key) }
    func photoHistoryID(_ identity: PhotoIdentity, undo: Bool) -> UUID? { ledger.photoHistoryID(forKey: identity.key, undo: undo) }
}

public extension EditTransferSession where Identity == OriginalFileIdentity, Record == MacPhotoEditRecord {
    convenience init(store: MacEditPersistence) {
        self.init(backend: Backend(
            storeHasPendingCommits: { store.hasPendingCommits }, storeFlushPendingCommits: { store.flushPendingCommits() },
            prepareSync: { if Thread.isMainThread { _ = store.flushPendingCommits() } else { store.waitForPendingIO() } },
            readPreparedTarget: { target, _ in
                let original = try store.readState(for: target.url)
                if let expectedIdentity = target.targetIdentity, expectedIdentity != original.identity { throw AdjustmentCommitError.photoChanged }
                let stored = try original.state ?? target.resolveDefaultState?() ?? target.defaultState
                return (original, try target.resolveMetadata?(stored) ?? stored, target.context)
            },
            captureState: { try MacAdjustmentTransfer.capture(scope: $0, snapshot: $1, context: $2) },
            prepareState: { try MacAdjustmentTransfer.prepare(payload: $0, target: $1, context: $2) },
            saveTransferred: { state, expected, _ in try store.saveState(identity: expected.identity, state: state) },
            saveEdited: { try store.saveState(identity: $0, state: $1, clearsProcessingMigration: $2) },
            prepareCommitState: { state, _, _ in state }, resetByIdentity: nil, resetByURL: { try store.resetToUnmodified($0) },
            deliverReadyCompletedCommits: { _ = store.deliverReadyCompletedCommits() },
            enqueueEdited: { try store.enqueueSaveState(identity: $0, state: $1, clearsProcessingMigration: $2, chainIfUndeliveredFailure: true, completion: $3) },
            validateBeforeApply: { try $0.identity.requireCurrent() },
            validateCommitState: { try $0.settings.validateResetValues(); guard $0.masterRecipeID == $0.settings.masterRecipeID else { throw AdjustmentTransferError.invalidPayload("recipe identity") } },
            validateHistoryPrepare: { identity, _ in try identity.requireCurrent() }, validateHistorySave: { identity, _ in try identity.requireCurrent() },
            makeRecord: { MacPhotoEditRecord(identity: $0, state: $1) }, keyOf: { $0.path }, identityOf: { $0.identity },
            stateOf: { $0.state }, sameState: { $0 == $1 }, hasSameAdjustments: { lhs, rhs in rhs.map { lhs == $0 } ?? false }, rememberUnchanged: false
        ))
    }

    private static func key(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    func knownRecord(forPath path: String) -> MacPhotoEditRecord? { ledger.knownRecord(forKey: path) }
    func editGeneration(for url: URL) -> UInt64 { editGeneration(forKey: Self.key(for: url)) }

    @discardableResult
    func adoptExternalReload(expected: MacPhotoEditRecord, reloaded: MacPhotoEditRecord) -> AdjustmentTransferOutcome {
        _ = flushPendingCommits(); let key = reloaded.identity.path
        guard expected.identity.path == key else { return outcome(key, .conflict, error: AdjustmentCommitError.photoChanged) }
        if expected.state == reloaded.state { ledger.remember(reloaded, advanceGeneration: false); return outcome(key, .unchanged, saved: reloaded) }
        let known = ledger.knownRecord(forKey: key), before = (known?.identity == reloaded.identity ? known : nil) ?? expected
        _ = ledger.record(id: UUID(), action: .edit, fields: [], displayName: "", before: before, after: reloaded)
        return outcome(key, .applied, saved: reloaded)
    }

    @discardableResult func resetToUnmodified(_ url: URL) throws -> MacPhotoEditRecord { _ = flushPendingCommits(); let c = try backend.resetByURL!(url); adoptProcessingMigration(c); return c }
    func undoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] { historyPhoto(key: Self.key(for: url), transactionID: transactionID, undo: true, isCurrent: isCurrent) }
    func canUndoPhoto(_ url: URL) -> Bool { ledger.canUndo(forKey: Self.key(for: url)) }
    func canRedoPhoto(_ url: URL) -> Bool { ledger.canRedo(forKey: Self.key(for: url)) }
    func redoPhoto(_ url: URL, transactionID: UUID? = nil, isCurrent: (String) -> Bool = { _ in true }) -> [AdjustmentTransferOutcome] { historyPhoto(key: Self.key(for: url), transactionID: transactionID, undo: false, isCurrent: isCurrent) }
    func photoHistoryID(_ url: URL, undo: Bool) -> UUID? { ledger.photoHistoryID(forKey: Self.key(for: url), undo: undo) }
}

public typealias IOSAdjustmentTransferSession = EditTransferSession<PhotoIdentity, PhotoEditRecord>
public typealias AdjustmentTransferSession = EditTransferSession<OriginalFileIdentity, MacPhotoEditRecord>
public typealias MacAdjustmentTransferSession = AdjustmentTransferSession
