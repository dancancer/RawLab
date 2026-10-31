import AppKit

enum BatchFlowModelTests {
    static func x3fSnapshots(root: URL) throws {
        let directory = root.appendingPathComponent("x3f-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let normal = directory.appendingPathComponent("normal.X3F")
        let legacy = directory.appendingPathComponent("legacy.X3F")
        // 预检只验证文件身份和已保存设置；这里不触发 RAW 解码。
        for file in [normal, legacy] { try Data("FOVb snapshot fixture".utf8).write(to: file) }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.addCollectionPhotos([normal, legacy])
        var settings = Adjustments()
        settings.x3fMode = .normal; settings.aiDenoiseEnabled = true
        try model.editStore!.save(normal, state: PhotoEditState(settings: settings, filmID: ""))
        settings.x3fMode = .legacy; settings.aiDenoiseEnabled = false
        try model.editStore!.save(legacy, state: PhotoEditState(settings: settings, filmID: ""))
        let rejected = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(!rejected.ready && rejected.rows.first?.error?.localizedDescription ==
                    L10n.text("此 X3F 显影模式不支持 AI 降噪。"),
                    "moved collection preflight preserves the normal X3F AI restriction")
        settings.selectX3fMode(.normal)
        try model.editStore!.save(normal, state: PhotoEditState(settings: settings, filmID: ""))
        let review = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(review.ready && review.snapshots.map { $0.settings.x3fMode } == [.normal, .legacy],
                    "collection preparation retains each photo's saved X3F mode")
        let job = try model.freezeCollectionExport(review)
        try require(job.items.map { $0.frozen!.settings.x3fMode } == [.normal, .legacy],
                    "collection freeze retains mixed normal and legacy X3F identities")
    }

    static func automaticLaunch(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("automatic-launch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.png"), second = directory.appendingPathComponent("second.png")
        for file in [first, second] { try FileManager.default.copyItem(at: fixture, to: file) }
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.addCollectionPhotos([first, second])
        model.open(first); try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = 0.8; try require(model.saveEdits(), "first export target saves its own adjustment")
        model.open(second); try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = -0.6; try require(model.saveEdits(), "second export target saves a different adjustment")
        let history = model.adjustmentSession!.transactions.count

        model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
        try wait { model.batch != nil && model.batch?.running == false }
        let job = model.batch!.job
        try require(job.started && job.succeededCount == 2 && job.mode == .perTargetFrozen,
            "one collection action prepares freezes and exports both photos")
        try require(try model.batchJournal.load()?.id == job.id && model.adjustmentSession!.transactions.count == history,
            "automatic export retains one journal and adds no photo history")
        let outputs = job.items.compactMap(\.output)
        try require(outputs.count == 2 && pixels(outputs[0]) != pixels(outputs[1]),
            "one-action export renders each photo's independent saved exposure")
        try require(!model.collectionExportBlockedByTask, "a completed task leaves the next collection export available")
        model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
        try wait { model.batch?.job.id != job.id && model.batch?.running == false }
        try require(model.batch!.job.succeededCount == 2,
            "another collection export can start after the previous task completes")
    }

    private static func pixels(_ url: URL) -> Data {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!.dataProvider!.data! as Data
    }

    static func pendingLaunches(root: URL, fixture: URL) throws {
        for action in ["cancel", "photo", "edit", "selection", "conflict", "restart"] {
            let directory = root.appendingPathComponent("pending-\(action)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let first = directory.appendingPathComponent("first.png"), second = directory.appendingPathComponent("second.png")
            for file in [first, second] { try FileManager.default.copyItem(at: fixture, to: file) }
            let output = directory.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
                editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
                presetDirectory: directory.appendingPathComponent("presets"))
            model.addCollectionPhotos([first, second]); model.open(first)
            try BatchSelectionModelTests.rendered(model)
            let prepare = model.prepareCollectionExportOperation
            let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var calls = 0
            model.prepareCollectionExportOperation = { input in
                calls += 1
                let result = try prepare(input)
                ready.signal(); release.wait()
                return result
            }
            defer { release.signal() }
            model.startCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: output)
            model.startCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: output)
            var prepared = false
            try wait {
                if !prepared { prepared = ready.wait(timeout: .now()) == .success }
                return prepared
            }
            try require(calls == 1 && model.collectionExportPreparing && model.batch == nil,
                "\(action): duplicate clicks keep one cancellable preparation")
            try require(try model.batchJournal.load() == nil, "\(action): checking has no journal")
            switch action {
            case "photo": model.open(second); try BatchSelectionModelTests.rendered(model)
            case "edit": model.settings.exposure = 0.3; try require(model.saveEdits(), "ordinary edits still save during a cancelled check")
            case "selection": model.batchSelection.selectAll(false)
            case "conflict":
                var changed = Adjustments(); changed.exposureMode = .sensor; changed.exposure = 0.6
                try EditPersistence(directory: directory.appendingPathComponent("edits"))
                    .save(second, state: PhotoEditState(settings: changed, filmID: ""))
            case "restart":
                model.cancelCollectionExportPreparation()
                model.prepareCollectionExportOperation = prepare
                model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
            default: model.cancelCollectionExportPreparation()
            }
            release.signal()
            var delivered = false
            model.collectionExportQueue.async { DispatchQueue.main.async { delivered = true } }
            try wait { delivered }
            if action == "restart" {
                try wait { model.batch != nil && model.batch?.running == false }
                try require(model.batch!.job.format == .png && model.batch!.job.succeededCount == 2,
                    "only the newer request freezes and runs its selected format")
            } else {
                try require(!model.collectionExportPreparing && model.batch == nil && (try model.batchJournal.load()) == nil,
                    "\(action): a late result cannot freeze or attach a task")
                try require(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
                    "\(action): a rejected check creates no output")
                if action == "conflict" {
                    try require(model.collectionExportError != nil, "external edit conflicts remain visible for a new check")
                }
            }
        }
    }

    static func preparedSourceChange(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("source-change")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.png")
        let target = directory.appendingPathComponent("target.png")
        let next = directory.appendingPathComponent("next.png")
        for file in [source, target, next] { try FileManager.default.copyItem(at: fixture, to: file) }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"),
            batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.open(source)
        try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = 0.8
        try require(model.saveEdits(), "source edit is saved before preparing a transfer")
        let payload = try model.copyAdjustments(scope: .custom([.exposure]))
        let prepared = try model.prepareAdjustmentPaste(payload: payload, targets: [target])
        let before = try model.editStore!.versionedState(for: target)
        let historyCount = model.adjustmentSession!.transactions.count

        model.open(next)
        try BatchSelectionModelTests.rendered(model)
        model.applyAdjustmentPaste(prepared)
        try require(try model.editStore!.versionedState(for: target) == before,
            "switching the host photo rejects prepared writes to a different target")
        try require(model.adjustmentSession!.transactions.count == historyCount,
            "an expired transfer adds no history")

        let current = try model.prepareAdjustmentPaste(payload: payload, targets: [target])
        model.applyAdjustmentPaste(current)
        try require(try model.editStore!.state(for: target)?.settings.exposure == 0.8,
            "a new request can still use the independent copied payload")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: label, code: 1) }
        print("PASS: \(label)")
    }

    static func declinedStart(job: BatchExportJob, journal: BatchJournal) throws {
        var unavailable = job
        unavailable.outputDirectory = nil
        let batch = BatchExportModel(job: unavailable, journal: journal)
        let accepted = batch.start()
        try require(!accepted && !batch.running && batch.error == L10n.text("选择输出文件夹"),
            "a declined start reports the missing output destination")
        try require(try journal.load()?.id == job.id && batch.job.id == job.id,
            "declined admission preserves the existing frozen job identity")
    }

    static func initializationFailure(job: BatchExportJob, root: URL) throws {
        let destination = root.appendingPathComponent("blocked-output")
        try Data("blocked".utf8).write(to: destination)
        var blocked = job
        blocked.outputDirectory = destination
        let journal = BatchJournal(directory: root.appendingPathComponent("failed-start"))
        try journal.save(blocked)
        let failed = BatchExportModel(job: blocked, journal: journal)
        try require(failed.start(), "the runner accepts a structurally valid frozen task")
        try wait { !failed.running }
        let stored = try journal.load()!
        try require(stored.id == job.id && stored.failure != nil && stored.interrupted,
            "initialization failure persists its reason on the same frozen job")
        try require(failed.error != nil && !stored.started, "failed initialization remains visible without claiming a started export")
        try require(failed.close(), "a frozen task can close after initialization failure")
        try require(try journal.load()?.id == job.id,
            "closing an unstarted frozen task preserves it for recovery")

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let recovered = BatchExportModel(job: stored, journal: journal)
        try require(recovered.start(), "the recovered frozen task can retry after its destination is repaired")
        try wait { !recovered.running }
        try require(recovered.job.id == job.id && recovered.job.succeededCount == job.selectedCount,
            "startup retry exports the original frozen job without creating another one")
        var draft = BatchExportJob(source: job.source, settings: Adjustments(), look: nil, lookName: "neutral")
        draft.outputDirectory = destination
        try journal.save(draft)
        let uniform = BatchExportModel(job: draft, journal: journal)
        try require(try uniform.close() && journal.load() == nil,
            "closing an unstarted uniform draft still discards it")
    }

    static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(predicate(), "batch flow asynchronous work completes")
    }
}
