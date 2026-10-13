import Foundation

@main
struct BatchExportTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "DNGPublicationRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
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
        settings.applyMasterRecipe(MasterRecipe.allRecipes[0])
        settings.lutStrength = 0.5
        settings.denoise = RawDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        settings.photoEffects.vignetteMidpoint = 62
        settings.photoEffects.grainSize = 60
        settings.exposureMode = .sensor
        settings.hsl.set(.hue, channel: 3, value: 32)
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
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
        check(reopenedJob?.source.settings.lensCorrection == settings.lensCorrection &&
              reopenedJob?.source.settings.lensSettings.coreProfileID.isEmpty == true,
              "batch freezes automatic lens settings, not a resolved source lens")
        check(reopenedJob?.source.settings.masterRecipeID == settings.masterRecipeID && reopenedJob?.source.settings.lutStrength == 0.5,
              "journal freezes master recipe identity and strength without reinjecting defaults")
        check(reopenedJob?.longEdge == 3000, "journal freezes the selected export long edge")
        var oldJournal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        oldJournal.removeValue(forKey: "longEdge")
        let oldJob = try JSONDecoder().decode(BatchExportJob.self,
                                              from: JSONSerialization.data(withJSONObject: oldJournal))
        check(oldJob.longEdge == nil, "old journals default to native export size")
        check(reopenedJob?.source.settings.denoise == settings.denoise, "journal preserves denoise settings")
        check(reopenedJob?.source.settings.photoEffects == settings.photoEffects,
              "journal preserves photo effects auxiliary values")
        check(reopenedJob?.source.settings.hsl == settings.hsl && reopenedJob?.source.settings.exposureMode == .sensor,
              "journal preserves HSL and the exposure baseline")
        check(pendingJobs.contains(where: { $0.id == job.id }), "pending journal is recoverable after interruption")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        legacyJSON.removeValue(forKey: "outputFormat")
        let legacyJPEG = try JSONDecoder().decode(BatchExportJob.self,
                                                  from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacyJPEG.outputFormat == .jpeg, "legacy batch journals default to JPEG")
        var dngJob = BatchExportJob(source: source, targets: [targets[0]], outputFormat: .renderedDNG)
        check(dngJob.targets[0].outputName.hasSuffix(".dng"), "DNG batch names use the DNG suffix")
        let dngOutput = root.appendingPathComponent("persistent-output.dng")
        try Data("DNG".utf8).write(to: dngOutput)
        dngJob.status = .running
        dngJob.targets[0].status = .publishing
        dngJob.targets[0].outputFileURL = dngOutput
        let dngRecovered = dngJob.recovered()
        check(dngRecovered.targets[0].status == .succeeded, "DNG recovery verifies the output file without Photos")
        let durableDNG = BatchFileOutputStore.destination(jobID: dngJob.id, outputName: dngJob.targets[0].outputName)
        check(durableDNG.path.contains("/Exports/\(dngJob.id.uuidString)/") && !durableDNG.path.contains("/inputs/"),
              "DNG outputs live outside the journal-owned inputs directory")
        dngJob.targets[0].outputFileURL = nil
        let derivedRecovery = dngJob.recovered(fileExists: { $0 == durableDNG })
        check(derivedRecovery.targets[0].status == .succeeded, "DNG recovery derives and verifies its persistent path")
        var staleDNG = dngRecovered
        staleDNG.targets[0].outputFileURL = root.appendingPathComponent("old-container-output.dng")
        let staleRecovery = staleDNG.recovered(fileExists: { $0 == durableDNG })
        check(staleRecovery.targets[0].status == .succeeded && staleRecovery.targets[0].outputFileURL == durableDNG,
              "DNG recovery prefers the current persistent path over a stale container URL")
        let deletedDNG = dngRecovered.recovered(fileExists: { _ in false })
        check(deletedDNG.targets[0].status == .pending && deletedDNG.status == .interrupted,
              "missing completed DNG output becomes pending instead of a false completed job")
        var renderCount = 0
        var writeCount = 0
        var failedTarget: String?
        job = try BatchExportRunner.run(job: job, journalStore: journal,
                                        render: { target, settings in
                                            renderCount += 1
                                            check(settings.denoise == source.settings.denoise, "batch uses frozen denoise settings")
                                            check(settings.photoEffects == source.settings.photoEffects,
                                                  "batch uses frozen photo effects settings")
                                            check(settings.hsl == source.settings.hsl && settings.exposureMode == .sensor,
                                                  "batch uses frozen HSL and exposure baseline")
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
        let missingTarget = BatchTarget(identity: PhotoIdentity(resourceIdentifier: "missing-raw"),
                                        sourceURL: root.appendingPathComponent("missing.ARW"),
                                        displayName: "missing.ARW")
        var continuationWrites = 0
        let missingContinuation = try BatchExportRunner.run(
            job: BatchExportJob(source: source, targets: [missingTarget, targets[0]]),
            journalStore: nil,
            render: { target, _ in
                if target.id == missingTarget.id { throw BatchExportError.target("missing RAW") }
                return Data([1])
            },
            write: { data, name, _, _ in
                continuationWrites += 1
                try data.write(to: root.appendingPathComponent(name))
            })
        check(missingContinuation.targets[0].status == .failed &&
              missingContinuation.targets[1].status == .succeeded && continuationWrites == 1,
              "missing RAW remains a per-target failure and the batch continues")

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
        let completedDNG = dngRecovered
        try journal.save(completedDNG)
        let completedDNGPendingJobs = try journal.pendingJobs()
        check(completedDNGPendingJobs.contains(where: { $0.id == completedDNG.id }),
              "completed DNG journal remains recoverable until explicit discard")
        try journal.discard(id: completedDNG.id)
        let afterDiscardDNGJobs = try journal.pendingJobs()
        check(!afterDiscardDNGJobs.contains(where: { $0.id == completedDNG.id }),
              "explicit DNG discard removes the durable journal")
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
        let dngTemp = root.appendingPathComponent("rendered.dng")
        var dngCleaned = false
        let dngObserved = try BatchExportRunner.run(job: BatchExportJob(source: source, targets: [targets[0]], outputFormat: .renderedDNG),
            journalStore: nil,
            render: { _, _ in try Data("DNG".utf8).write(to: dngTemp); return dngTemp },
            write: { file, name, _, checkpoint in
                let destination = root.appendingPathComponent(name)
                try FileManager.default.moveItem(at: file, to: destination)
                try checkpoint("file:\(destination.path)")
            },
            cleanup: { _ in dngCleaned = true })
        check(dngObserved.targets[0].outputFileURL?.lastPathComponent == dngObserved.targets[0].outputName,
              "generic batch runner journals persistent file outputs")
        check(dngCleaned, "generic batch runner disposes URL payloads after publication")
        let failedDNGTemp = root.appendingPathComponent("failed-rendered.dng")
        var failedDNGCleaned = false
        let failedDNG = try BatchExportRunner.run(
            job: BatchExportJob(source: source, targets: [targets[0]], outputFormat: .renderedDNG),
            journalStore: nil,
            render: { _, _ in try Data("DNG".utf8).write(to: failedDNGTemp); return failedDNGTemp },
            write: { _, _, _, _ in throw BatchExportError.target("publication failed") },
            cleanup: { file in
                failedDNGCleaned = true
                try? FileManager.default.removeItem(at: file)
            })
        check(failedDNG.targets[0].status == .failed && failedDNGCleaned,
              "generic batch runner disposes URL payloads after write failures")
        let oldContainer = root.appendingPathComponent("old-container")
        let oldStore = try BatchJournalStore(directory: oldContainer)
        var moved = BatchExportJob(source: source, targets: [targets[0]])
        try BatchInputStore.prepare(&moved, look: MasterRecipe.allRecipes[0].lutURL(), root: oldContainer)
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
        let outputRoot = BatchFileOutputStore.root()
        let hadOutputRoot = FileManager.default.fileExists(atPath: outputRoot.path)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer {
            if !hadOutputRoot, (try? FileManager.default.contentsOfDirectory(atPath: outputRoot.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: outputRoot)
            }
        }
        try testDNGCheckpointFailure(source: source, targets: Array(targets.prefix(2)), root: root)
        try testDNGDirectoryFailures(source: source, targets: Array(targets.prefix(2)), root: root)
        print("PASS: batch export regression suite")
    }

    static func testDNGCheckpointFailure(source: BatchSourceSnapshot, targets: [BatchTarget], root: URL) throws {
        let job = BatchExportJob(source: source, targets: targets, outputFormat: .renderedDNG)
        let outputDirectory = BatchFileOutputStore.root().appendingPathComponent(job.id.uuidString)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let journalDirectory = root.appendingPathComponent("checkpoint-journal")
        let journal = try BatchJournalStore(directory: journalDirectory)
        let parkedDirectory = root.appendingPathComponent("checkpoint-journal-backup")
        var rendered: [String] = []
        let interrupted = try BatchExportRunner.run(job: job, journalStore: journal,
            render: { target, _ in
                rendered.append(target.id)
                let file = root.appendingPathComponent("checkpoint-\(UUID().uuidString).dng")
                try Data("published-\(target.id)".utf8).write(to: file)
                return file
            },
            write: { file, name, _, checkpoint in
                try BatchFileWriter.write(file: file, outputName: name, jobID: job.id) { identifier in
                    // 让真实 checkpoint 写入失败，同时允许后续中断状态保存成功。
                    try FileManager.default.moveItem(at: journalDirectory, to: parkedDirectory)
                    defer { try! FileManager.default.moveItem(at: parkedDirectory, to: journalDirectory) }
                    try checkpoint(identifier)
                }
            },
            cleanup: { try? FileManager.default.removeItem(at: $0) })
        try require(interrupted.status == .interrupted && interrupted.targets[0].status == .needsConfirmation,
              "published DNG checkpoint failure is uncertain instead of a normal target failure")
        try require(interrupted.targets[1].status == .pending && rendered == [targets[0].id],
              "published DNG checkpoint failure stops before rendering the second target")
        let firstOutput = BatchFileOutputStore.destination(jobID: job.id, outputName: "target-1.dng")
        let firstBytes = try Data(contentsOf: firstOutput)
        try require(firstBytes == Data("published-\(targets[0].id)".utf8), "checkpoint failure preserves the published DNG")
        let persisted = try journal.load(id: job.id)!
        try require(persisted.targets[0].status == .needsConfirmation,
              "uncertain DNG publication survives a subsequent successful journal save")
        let recovered = persisted.recovered()
        try require(recovered.targets[0].status == .succeeded && recovered.targets[1].status == .pending,
              "recovery verifies the already published DNG before continuing")
        try require(recovered.globalError == nil,
              "verified DNG publication clears the resolved uncertain global error")
        let completed = try BatchExportRunner.run(job: recovered, journalStore: journal,
            render: { target, _ in
                rendered.append(target.id)
                let file = root.appendingPathComponent("continued-\(UUID().uuidString).dng")
                try Data("continued-\(target.id)".utf8).write(to: file)
                return file
            },
            write: { file, name, _, checkpoint in
                try BatchFileWriter.write(file: file, outputName: name, jobID: job.id, checkpoint: checkpoint)
            },
            cleanup: { try? FileManager.default.removeItem(at: $0) })
        try require(completed.status == .completed && completed.targets.allSatisfy { $0.status == .succeeded },
              "recovered DNG publication continues to finish the batch")
        try require(rendered == targets.map(\.id) && (try? Data(contentsOf: firstOutput)) == firstBytes,
              "continuing after checkpoint failure never rerenders or replaces the completed DNG")
    }

    static func testDNGDirectoryFailures(source: BatchSourceSnapshot, targets: [BatchTarget], root: URL) throws {
        for failureDuringRender in [false, true] {
            let job = BatchExportJob(source: source, targets: targets, outputFormat: .renderedDNG)
            let blockedDirectory = BatchFileOutputStore.root().appendingPathComponent(job.id.uuidString)
            try Data("directory blocker".utf8).write(to: blockedDirectory, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: blockedDirectory) }
            var renderCount = 0
            var checkpointCount = 0
            let result = try BatchExportRunner.run(job: job, journalStore: nil,
                render: { _, _ in
                    renderCount += 1
                    if failureDuringRender { _ = try BatchFileOutputStore.directory(for: job.id) }
                    let file = root.appendingPathComponent("blocked-\(UUID().uuidString).dng")
                    try Data("DNG".utf8).write(to: file)
                    return file
                },
                write: { file, name, _, _ in
                    try BatchFileWriter.write(file: file, outputName: name, jobID: job.id) { _ in checkpointCount += 1 }
                },
                cleanup: { try? FileManager.default.removeItem(at: $0) })
            try require(result.status == .failed && result.globalError != nil && result.targets[0].status == .failed,
                  "DNG directory failure during \(failureDuringRender ? "render" : "publication") is a global storage failure")
            try require(result.recovered().globalError == result.globalError,
                  "DNG recovery preserves unresolved global storage failures")
            try require(result.targets[1].status == .pending && renderCount == 1 && checkpointCount == 0,
                  "DNG directory failure during \(failureDuringRender ? "render" : "publication") does not process the second target")
            try require((try? Data(contentsOf: blockedDirectory)) == Data("directory blocker".utf8),
                  "DNG directory failure preserves the existing blocking file")
        }
    }
}
