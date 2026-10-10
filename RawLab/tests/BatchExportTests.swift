import Foundation

@main
struct BatchExportTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        check(ExportSize.isValid(nil), "native export size is valid")
        check(ExportSize.presets == [2048, 3000, 4096], "standard export sizes are available")
        check(ExportSize.isValid(1) && ExportSize.isValid(65535) && !ExportSize.isValid(0) && !ExportSize.isValid(65536),
              "custom export size enforces the 1-65535 range")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.ARW")
        try Data("source".utf8).write(to: sourceURL)
        var settings = RawSettings.default
        settings.denoise = RawDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        let source = BatchSourceSnapshot(identity: PhotoIdentity(resourceIdentifier: "source"),
                                          sourceURL: sourceURL, displayName: "source.ARW", settings: settings)
        let targets = (1...6).map { index in
            BatchTarget(identity: PhotoIdentity(resourceIdentifier: "target-\(index)"),
                        sourceURL: root.appendingPathComponent("target-\(index).ARW"),
                        displayName: "target-\(index).ARW")
        }
        for target in targets { try Data(target.id.utf8).write(to: target.sourceURL) }
        var job = BatchExportJob(source: source, targets: targets, longEdge: 3000)
        let journal = try BatchJournalStore(directory: root.appendingPathComponent("journal", isDirectory: true))
        try journal.save(job)
        let reopenedJob = try journal.load(id: job.id)
        let pendingJobs = try journal.pendingJobs()
        check(reopenedJob?.targets.count == 6, "journal round-trips the selected rows")
        check(reopenedJob?.longEdge == 3000, "journal freezes the selected export long edge")
        var oldJournal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        oldJournal.removeValue(forKey: "longEdge")
        let oldJob = try JSONDecoder().decode(BatchExportJob.self,
                                              from: JSONSerialization.data(withJSONObject: oldJournal))
        check(oldJob.longEdge == nil, "old journals default to native export size")
        check(reopenedJob?.source.settings.denoise == settings.denoise, "journal preserves denoise settings")
        check(pendingJobs.contains(where: { $0.id == job.id }), "pending journal is recoverable after interruption")
        var renderCount = 0
        var writeCount = 0
        var failedTarget: String?
        job = try BatchExportRunner.run(job: job, journalStore: journal,
                                        render: { target, settings in
                                            renderCount += 1
                                            check(settings.denoise == source.settings.denoise, "batch uses frozen denoise settings")
                                            return Data("\(target.id):\(settings.exposure)".utf8)
                                        }, write: { data, name, target, _ in
                                            writeCount += 1
                                            if target.id.hasSuffix("3") && failedTarget == nil {
                                                failedTarget = target.id
                                                throw BatchExportError.target("fixture failure")
                                            }
                                            try data.write(to: root.appendingPathComponent(name))
                                        })
        check(job.targets.filter { $0.status == .succeeded }.count == 5, "six selected targets produce five successes")
        check(job.targets.filter { $0.status == .failed }.count == 1, "individual failure does not stop the batch")
        check(renderCount == 6 && writeCount == 6, "each target is rendered and written once")

        let successfulID = job.targets.first(where: { $0.status == .succeeded })!.id
        var cancelled = job
        cancelled.targets = targets.map { BatchTarget(identity: PhotoIdentity(resourceIdentifier: $0.id),
                                                      sourceURL: $0.sourceURL, displayName: $0.displayName) }
        var cancelledAfter = 0
        cancelled = try BatchExportRunner.run(job: cancelled, journalStore: nil,
                                               render: { _, _ in Data([1]) },
                                               write: { _, _, _, _ in
                                                   cancelledAfter += 1
                                               }, shouldCancel: { cancelledAfter >= 2 })
        check(cancelled.targets.filter { $0.status == .succeeded }.count == 2, "cancellation preserves completed rows")
        check(cancelled.targets.dropFirst(2).contains(where: { $0.status == .cancelled }), "cancellation marks remaining rows")

        var retry = job
        retry = try BatchExportRunner.retryFailed(job: retry, journalStore: journal,
                                                   render: { _, _ in Data([9]) },
                                                   write: { data, name, _, _ in try data.write(to: root.appendingPathComponent(name)) })
        check(retry.targets.filter { $0.status == .succeeded }.count == 6, "retry only reruns the failed row")
        check(retry.longEdge == 3000, "retry retains the frozen export long edge")
        check(retry.targets.first(where: { $0.id == successfulID })?.status == .succeeded,
              "retry preserves the original successful row")
        check(Set(retry.targets.map(\.outputName)).count == 6, "output names remain collision free")
        let completedPendingJobs = try journal.pendingJobs()
        check(completedPendingJobs.isEmpty, "completed journal is not reported as pending")
        try journal.save(cancelled)
        let resumableCancelled = try journal.pendingJobs()
        check(resumableCancelled.contains(where: { $0.id == cancelled.id }), "cancelled work remains accessible for resume")
        var interrupted = BatchExportJob(source: source, targets: targets)
        interrupted.status = .running
        interrupted.targets[0].status = .publishing
        interrupted.targets[0].outputAssetIdentifier = "saved-asset"
        interrupted.targets[1].status = .processing
        let reconciled = interrupted.recovered { $0 == "saved-asset" ? true : nil }
        check(reconciled.targets[0].status == .succeeded, "asset published before checkpoint is never repeated")
        check(reconciled.targets[1].status == .pending, "interrupted render is safe to rerun")
        let uncertain = interrupted.recovered { _ in nil }
        check(uncertain.targets[0].status == .needsConfirmation, "unreadable Photos publication requires confirmation before retry")
        var phases: [BatchTargetStatus] = []
        var publishingIdentifiers: [String] = []
        let observed = try BatchExportRunner.run(job: BatchExportJob(source: source, targets: [targets[0]]), journalStore: journal,
            render: { _, _ in Data([1]) }, write: { _, _, _, checkpoint in try checkpoint("asset-1") },
            didUpdate: {
                phases.append($0.targets[0].status)
                if $0.targets[0].status == .publishing, let identifier = $0.targets[0].outputAssetIdentifier {
                    publishingIdentifiers.append(identifier)
                }
            })
        check(phases.contains(.processing) && phases.contains(.publishing) && phases.last == .succeeded, "progress publishes per-phase updates")
        check(observed.targets[0].outputAssetIdentifier == "asset-1", "Photos identifier is journaled before completion")
        check(publishingIdentifiers == ["asset-1"], "checkpoint identity reaches model before final journal commit")
        let oldContainer = root.appendingPathComponent("old-container")
        let oldStore = try BatchJournalStore(directory: oldContainer)
        var moved = BatchExportJob(source: source, targets: [targets[0]])
        try BatchInputStore.prepare(&moved, look: nil, root: oldContainer)
        moved.targets[0].sourceURL = try BatchInputStore.copy(targets[0].sourceURL, identity: targets[0].identity, jobID: moved.id, root: oldContainer)
        let look = oldContainer.appendingPathComponent(moved.id.uuidString).appendingPathComponent("look.cube")
        try Data("look".utf8).write(to: look)
        moved.source.lookURL = look
        try oldStore.save(moved)
        let newContainer = root.appendingPathComponent("new-container")
        try FileManager.default.moveItem(at: oldContainer, to: newContainer)
        let movedStore = try BatchJournalStore(directory: newContainer)
        let relocated = try movedStore.load(id: moved.id)!
        check(FileManager.default.fileExists(atPath: relocated.source.sourceURL.path), "source survives iOS data-container relocation")
        check(FileManager.default.fileExists(atPath: relocated.targets[0].sourceURL.path), "target survives iOS data-container relocation")
        check(FileManager.default.fileExists(atPath: relocated.source.lookURL!.path), "look survives iOS data-container relocation")
        let relocatedPending = try movedStore.pendingJobs()
        check(relocatedPending.first?.source.sourceURL == relocated.source.sourceURL, "startup uses relocated owned paths")
        print("PASS: batch export regression suite")
    }
}
