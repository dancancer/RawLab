import Foundation
import UIKit

enum IOSBatchFlowModelChecks {
    static func launchRequests(directory: URL) throws {
        let fixture = directory.appendingPathComponent("batch-flow/target.png")
        for action in ["cancel", "source", "selection", "freeze-cancel", "frozen-cancel", "success"] {
            let root = directory.appendingPathComponent("launch-\(action)")
            let store = try EditPersistence(directory: root.appendingPathComponent("edits"))
            let journal = try BatchJournalStore(directory: root.appendingPathComponent("jobs"))
            var deliveries = [() -> Void](), freezes = 0
            let model = RawEditorViewModel(editPersistence: store, resultDelivery: { callback in
                DispatchQueue.main.async { deliveries.append(callback) }
            })
            model.makeCollectionJournal = { freezes += 1; return journal }
            let identity = PhotoIdentity(resourceIdentifier: "launch-\(action)")
            model.batchSelection.append(.init(identity: identity, displayName: "target.png", file: .externallyManaged(fixture), isRaw: false))
            var created = [(BatchExportJob, BatchJournalStore, Bool)]()
            func start() {
                model.startCollectionExport(skipping: [], format: .jpeg, longEdge: 32) { created.append(($0, $1, $2)) }
            }
            start(); start()
            try wait { !deliveries.isEmpty }
            try require(deliveries.count == 1 && model.collectionExportPreparing && freezes == 0,
                "\(action): repeated clicks keep one read-only preparation")
            switch action {
            case "cancel": model.cancelCollectionExportPreparation()
            case "source": model.sourceRevision = UUID()
            case "selection": model.batchSelection.selection.select(identity.key, false)
            case "freeze-cancel": model.adjustmentQueue.suspend()
            default: break
            }
            deliveries.removeFirst()()
            if ["cancel", "source", "selection"].contains(action) {
                try require(try created.isEmpty && journal.pendingJobs().isEmpty && freezes == 0,
                    "\(action): late prepare does not create a task")
                continue
            }
            if action == "freeze-cancel" {
                model.cancelCollectionExportPreparation()
                start()
                model.adjustmentQueue.resume()
            }
            try wait { !deliveries.isEmpty }
            if action == "frozen-cancel" {
                try require(try journal.pendingJobs().count == 1, "a frozen task exists before its delayed handoff")
                model.cancelCollectionExportPreparation()
                start()
            }
            deliveries.removeFirst()()
            if action == "freeze-cancel" {
                try require(try created.isEmpty && journal.pendingJobs().isEmpty, "cancel before journal publication leaves no frozen task")
            } else {
                try require(created.count == 1 && freezes == 1, "\(action): exactly one frozen task is handed off")
                let item = created[0]
                try require(try journal.pendingJobs().map(\.id) == [item.0.id], "\(action): the handoff retains the persisted job identity")
                try require(item.2 == (action == "success"), "\(action): only the current request authorizes automatic start")
                if action == "success" { try handoff(job: item.0, journal: item.1) }
            }
        }
    }

    private static func handoff(job: BatchExportJob, journal: BatchJournalStore) throws {
        for scenario in ["active", "inactive", "background", "manual"] {
            let batch = BatchExportModel(job: job, journalStore: journal)
            var owner = IOSCollectionBatchHandoff()
            owner.enqueue(batch, automaticallyStart: scenario != "manual")
            if scenario == "background" { owner.cancelAutomaticStart() }
            var configured = false, starts = 0
            let promoted = owner.promote(sceneIsActive: scenario != "inactive", configure: { model in
                configured = model.job.id == job.id
                model.onUsage = { _ in }
                model.onDiscard = { }
            }, start: { model in
                precondition(configured)
                starts += 1
                return false
            })
            let repeated = owner.promote(sceneIsActive: true, configure: { _ in }, start: { _ in starts += 1; return true })
            try require(promoted?.job.id == job.id && repeated == nil && !owner.hasPending,
                "\(scenario): promotion consumes the queued owner exactly once")
            try require(starts == (scenario == "active" ? 1 : 0),
                "\(scenario): background and existing-task presentation never start automatically")
            try require(try journal.load(id: job.id)?.id == promoted?.job.id,
                "\(scenario): declined admission keeps the same frozen task")
        }
        var empty = job; empty.targets = []
        let invalid = BatchExportModel(job: empty, journalStore: journal)
        try require(!invalid.start() && !invalid.isRunning && invalid.validationMessage != nil,
            "declined start has an explicit result and visible reason")
    }

    static func preparedSourceChange(directory: URL) throws {
        let root = directory.appendingPathComponent("batch-flow")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let files = ["source", "target", "next"].map { root.appendingPathComponent("\($0).png") }
        for file in files { try image.pngData()!.write(to: file) }
        let identities = ["source", "target", "next"].map { PhotoIdentity(resourceIdentifier: "batch-flow-\($0)") }
        let store = try EditPersistence(directory: root.appendingPathComponent("edits"))
        var deliveries = [() -> Void]()
        let model = RawEditorViewModel(editPersistence: store, resultDelivery: { callback in
            DispatchQueue.main.async { deliveries.append(callback) }
        })
        model.sourceFile = .externallyManaged(files[0]); model.sourceIdentity = identities[0]
        model.sourceKind = .raster; model.hasImage = true
        model.acceptImportedEditRecord(try store.versionedState(for: identities[0]), settings: .default)
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "independent-copy", isRaw: false,
            processingVersion: 2, recipe: nil), values: ["light.exposure": .number(0.7)])
        let target = IOSAdjustmentPhoto(identity: identities[1], displayName: "target", file: .externallyManaged(files[1]), isRaw: false)
        var prepared: IOSPreparedAdjustmentTransfer?
        model.prepareAdjustmentPaste(payload, photos: [target]) { prepared = try? $0.get() }
        try wait { !deliveries.isEmpty }
        deliveries.removeFirst()()
        try require(prepared?.targets.first?.error == nil, "the transfer is ready before switching source")
        let before = try store.versionedState(for: identities[1])
        let history = model.adjustmentSession!.transactions.count
        model.sourceRevision = UUID()
        model.sourceFile = .externallyManaged(files[2]); model.sourceIdentity = identities[2]
        model.acceptImportedEditRecord(try store.versionedState(for: identities[2]), settings: .default)
        _ = model.applyAdjustmentPaste(prepared!, skipping: [])
        try require(try store.versionedState(for: identities[1]) == before,
            "a source switch rejects an old prepared write to another target")
        try require(model.adjustmentSession!.transactions.count == history, "an expired transfer adds no history")

        prepared = nil
        model.prepareAdjustmentPaste(payload, photos: [target]) { prepared = try? $0.get() }
        try wait { !deliveries.isEmpty }
        deliveries.removeFirst()()
        _ = model.applyAdjustmentPaste(prepared!, skipping: [])
        try require(store.state(for: identities[1])?.settings.exposure == 0.7,
            "a fresh request can reuse the independent copied payload")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: message, code: 1) }
        print("PASS: batch flow \(message)")
    }

    static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try require(predicate(), "asynchronous operation completes")
    }
}
