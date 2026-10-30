import AppKit

private func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: \(label)")
}

@main struct BatchSelectionModelTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("same.png")
        let second = root.appendingPathComponent("other/same.png")
        let third = root.appendingPathComponent("third.png")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(repeating: 128, count: 144) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for url in [first, second, third] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("fixture") }
        }
        try BatchFlowModelTests.preparedSourceChange(root: root, fixture: first)
        try BatchFlowModelTests.automaticLaunch(root: root, fixture: first)
        try BatchFlowModelTests.pendingLaunches(root: root, fixture: first)
        try BatchFlowModelTests.x3fSnapshots(root: root)
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.linkItem(at: first, to: alias)
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"), batchDirectory: root.appendingPathComponent("batch"),
            presetDirectory: root.appendingPathComponent("presets"))
        model.addCollectionPhotos([first, second, third, alias, second])
        let ids = model.batchSelection.ordered
        model.open(alias); try rendered(model)
        try check(model.file == first, "alias navigation reuses collection identity and its edit record")
        try check(ids.count == 3 && model.batchSelection.selected.count == 3, "collection deduplicates physical files and retains same names with different identities")
        model.editCollectionPhoto(ids[0]); try rendered(model)
        model.settings.exposure = 0.7; try check(model.saveEdits(), "source saved")
        let clipboard = try model.copyAdjustments(scope: .custom([.contrast]))
        let operation = try model.prepareCollectionSynchronization(scope: .custom([.exposure]))
        try check(operation.targets.count == 2 && !operation.targets.contains { $0.id == first.path }, "synchronization freezes actual targets and excludes selected source")
        let wrongBinding = AdjustmentTransferTarget(url: second, defaultState: PhotoEditState(settings: Adjustments(), filmID: ""),
            context: model.adjustmentTransferContext(for: second), expectedIdentity: try OriginalFileIdentity(first))
        let rejectedBinding = try model.adjustmentSession!.prepare(payload: operation.payload, targets: [wrongBinding], action: .synchronize)
        try check(rejectedBinding.targets.first?.error != nil, "prepared record must match the exact collection input identity")
        model.applyAdjustmentPaste(operation)
        try check(model.batchSelection.lastSynchronization == operation.id && model.adjustmentClipboard == clipboard && model.adjustmentSession?.clipboard == clipboard,
            "synchronization records collection history without changing clipboard")
        model.editCollectionPhoto(ids[1]); try rendered(model)
        try check(model.settings.exposure == 0.7, "single editor opens synchronized saved state")
        model.settings.contrast = 19; try check(model.saveEdits(), "micro edit saved")
        model.returnToBatchSelection()
        try check(model.batchSelection.current == nil && model.batchSelection.returnPosition == ids[1] && model.batchSelection.ordered == ids && model.batchSelection.selected == Set(ids),
            "return retains collection order selection and navigation position")
        try check(model.batchSelection.lastSynchronization == operation.id, "ordinary photo history does not replace synchronization entry")
        model.editCollectionPhoto(ids[0]); try rendered(model)
        model.settings.exposure = 1.2; try check(model.saveEdits(), "source updated")
        model.applyAdjustmentPaste(try model.prepareCollectionSynchronization(scope: .custom([.exposure])))
        try check(model.editStore!.state(for: second)?.settings.contrast == 19, "resynchronization preserves unselected micro edits")
        model.editCollectionPhoto(ids[1]); try rendered(model)
        model.setInteracting(true); model.settings.exposure = 2.4
        let draftReview = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: 1024, directory: root)
        try check(!draftReview.ready && draftReview.rows.first { $0.id == ids[1] }?.hasDraft == true, "export preflight includes unsaved active editor")
        let skipped = try model.prepareCollectionExport(skipping: [ids[1]], format: .jpeg, longEdge: 1024, directory: root)
        try check(skipped.ready && skipped.snapshots.count == 2 && model.dirty && model.batchSelection.selected == Set(ids),
            "preflight skip keeps draft and collection selection")
        try check(model.resolveCollectionDraft(ids[1], apply: true), "preflight Apply commits through common history")
        let review = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: 1024, directory: root)
        try check(review.ready && review.snapshots.count == 3, "final confirmation includes all committed snapshots")
        model.settings.exposure = 2.6; try check(model.saveEdits(), "late edit saved")
        do { _ = try model.freezeCollectionExport(review); throw NSError(domain: "accepted stale review", code: 1) }
        catch is EditPersistenceConflict { print("PASS: late edits invalidate final confirmation") }
        let final = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: 1024, directory: root)
        let job = try model.freezeCollectionExport(final)
        try check(model.collectionExportBlockedByTask, "an unstarted frozen task still blocks another collection export")
        try check(job.mode == .perTargetFrozen && job.items.map { $0.frozen!.settings.exposure } == [1.2, 2.6, 1.2], "freeze retains per-photo settings and order")
        try BatchFlowModelTests.declinedStart(job: job, journal: model.batchJournal)
        try BatchFlowModelTests.initializationFailure(job: job, root: root)
        model.settings.exposure = 3; try check(model.saveEdits(), "edit after freeze saved independently")
        let restored = try model.batchJournal.load()!
        try check(restored.items[1].frozen!.settings.exposure == 2.6 && restored.items[1].frozen!.settings.contrast == 19, "recovery never reads later live editor settings")
        model.batch?.setLongEdge(400); model.batch?.selectAll(false); model.batch?.remove(job.items[0].id)
        try check(model.batch?.job.longEdge == 1024 && model.batch?.job.selectedCount == 3 && model.batch?.job.items.count == 3,
            "frozen task cannot be edited as a uniform export draft")
        model.batch!.start()
        let exportDeadline = Date().addingTimeInterval(30)
        while model.batch!.running && Date() < exportDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(!model.batch!.running && model.batch!.job.succeededCount == 3, "real native batch exports all frozen photo snapshots")
        let outputs = model.batch!.job.items.map { $0.output! }
        func pixels(_ url: URL) -> Data {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            return image.dataProvider!.data! as Data
        }
        try check(pixels(outputs[0]) != pixels(outputs[1]) && pixels(outputs[0]) == pixels(outputs[2]),
            "native output pixels preserve per-photo differences after later editor changes")
        model.setInteracting(true); model.settings.exposure = 4
        try check(model.resolveCollectionDraft(ids[1], apply: false) && model.settings.exposure == 3 && !model.dirty, "preflight Discard restores committed state")
        try FileManager.default.removeItem(at: third)
        let missing = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: root)
        try check(!missing.ready && missing.rows.first { $0.id == ids[2] }?.error != nil && model.batchSelection.selected.contains(ids[2]),
            "missing input is reported per photo without changing selection")
        model.editCollectionPhoto(ids[0]); try rendered(model)
        let stale = try model.prepareCollectionSynchronization(scope: .custom([.exposure]))
        try FileManager.default.removeItem(at: second)
        try FileManager.default.linkItem(at: first, to: second)
        model.applyAdjustmentPaste(stale, skipping: [third.path])
        try check(model.adjustmentOutcomes.first { $0.targetID == second.path }?.status == .blocked,
            "write guard refuses a target replaced with the frozen source identity")
        try draftAndLookChecks(root: root, fixture: first)
    }

    static func draftAndLookChecks(root: URL, fixture: URL) throws {
        let photo = root.appendingPathComponent("look-photo.png")
        let other = root.appendingPathComponent("neutral-photo.png")
        try FileManager.default.copyItem(at: fixture, to: photo)
        try FileManager.default.copyItem(at: fixture, to: other)
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks2"),
            editDirectory: root.appendingPathComponent("edits2"), batchDirectory: root.appendingPathComponent("batch2"),
            presetDirectory: root.appendingPathComponent("presets2"))
        var fail = true
        model.editStore = try EditPersistence(directory: root.appendingPathComponent("edits2"), writeData: { data, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        model.addCollectionPhotos([photo, other]); let id = model.batchSelection.ordered[0]
        model.editCollectionPhoto(id); try rendered(model)
        model.settings.exposure = 0.4
        try check(!model.resolveCollectionDraft(id, apply: true) && model.dirty && model.adjustmentSession!.transactions.isEmpty,
            "preflight save failure preserves dirty state and does not add history")
        let failed = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: root)
        try check(!failed.ready && failed.snapshots.count == 1, "save failure blocks confirmation and keeps other prepared photos")
        fail = false
        try check(model.resolveCollectionDraft(id, apply: true) && model.adjustmentSession!.transactions.count == 1,
            "retry saves once through ordinary photo history")
        try rendered(model)
        try check(model.beginGeometryDraft(), "geometry preflight fixture opens")
        try rendered(model)
        model.updateGeometryDraft { $0.cropWidth = 0.75 }; try rendered(model)
        let skipped = try model.prepareCollectionExport(skipping: [id], format: .png, longEdge: nil, directory: root)
        try check(skipped.ready && model.geometryDraft != nil && model.batchSelection.selected.contains(id), "skipping geometry retains its draft and selection")
        try check(model.resolveCollectionDraft(id, apply: false) && model.settings.geometrySettings.isIdentity,
            "discarding geometry exports the prior committed crop")
        try rendered(model)
        try check(model.beginGeometryDraft(), "second geometry preflight fixture opens")
        try rendered(model)
        model.updateGeometryDraft { $0.cropWidth = 0.75 }; try rendered(model)
        try check(model.resolveCollectionDraft(id, apply: true), "applying geometry saves before final confirmation")
        let cube = root.appendingPathComponent("collection-look.cube")
        let data = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".data(using: .utf8)!
        try data.write(to: cube)
        model.films.append(Film(name: "Test look", url: cube, managedID: "test-collection-look"))
        model.selectedFilmID = "test-collection-look"
        try check(model.saveEdits(), "per-photo look saved")
        let stale = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: root)
        try (data + Data("# changed\n".utf8)).write(to: cube)
        do { _ = try model.freezeCollectionExport(stale); throw NSError(domain: "accepted changed look", code: 1) }
        catch is EditPersistenceConflict { print("PASS: changed look invalidates confirmation before copying") }
        let review = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: root)
        let job = try model.freezeCollectionExport(review)
        try check(job.items[0].frozen!.settings.geometrySettings.cropWidth == 0.75 && job.items[1].frozen!.settings.geometrySettings.isIdentity,
            "geometry Apply freezes the new crop only for that photo")
        try FileManager.default.removeItem(at: cube)
        try job.items[0].frozen!.verifyLook()
        try check(job.items[0].frozen!.look != cube && job.items[1].frozen!.look == nil,
            "each photo freezes its own look and retains task-owned copy after library removal")
        try check(model.batch!.discardDraft() && model.batch == nil, "discarding a frozen draft frees its task and owned resources")
        try check(!FileManager.default.fileExists(atPath: job.items[0].frozen!.look!.path), "discard cleans task-owned look")
    }

    static func rendered(_ model: EditorModel) throws {
        let deadline = Date().addingTimeInterval(30)
        while (model.busy || model.result == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(model.result != nil && !model.busy && !model.previewOutdated, "native editor preview completes")
    }
}
