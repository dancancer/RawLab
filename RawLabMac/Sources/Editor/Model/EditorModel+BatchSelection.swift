import AppKit
import UniformTypeIdentifiers

extension EditorModel {
    func addCollectionPhotos(_ urls: [URL]) {
        var errors = [String]()
        for url in urls {
            do {
                guard DirectoryContents.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw RenderError.failed(L10n.text("不是支持的图像文件"))
                }
                let input = file.flatMap { (try? BatchExportItem.resourceKey($0)) == (try? BatchExportItem.resourceKey(url)) ? $0 : nil } ?? url
                let photo = try MacCollectionPhoto(input)
                if batchSelectionPhotos[photo.id] == nil { batchSelectionPhotos[photo.id] = photo }
                batchSelection.append([photo.id])
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        collectionError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func chooseCollectionPhotos() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要编辑的照片")
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { addCollectionPhotos(panel.urls) }
    }

    func collectionFailure(_ id: String) -> Error? {
        do {
            guard let photo = batchSelectionPhotos[id] else { throw BatchExportFailure.changedInput }
            try photo.validate(); return nil
        } catch { return error }
    }

    func collectionHasDraft(_ id: String) -> Bool {
        guard let photo = batchSelectionPhotos[id], file == photo.url else { return false }
        return dirty || geometryDraft != nil || scheduler.interacting || ParameterValueField.hasPendingInputs
    }

    // 所有窗口共享同一个 EditorModel；集合导航也经过该编辑器的草稿与保存守卫。
    func editCollectionPhoto(_ id: String, completion: @escaping () -> Void = {}) {
        guard !exporting, let photo = batchSelectionPhotos[id] else { return }
        if let failure = collectionFailure(id) { collectionError = failure.localizedDescription; return }
        guard ParameterValueField.resolvePendingInputs() else { return }
        let navigate = { [weak self] in
            guard let self else { return }
            if self.scheduler.interacting { self.setInteracting(false) }
            guard self.saveEdits(), self.collectionFailure(id) == nil else { return }
            self.open(photo.url)
            guard self.file == photo.url else { return }
            self.batchSelection.beginEditing(id); self.collectionError = nil
            completion()
        }
        if geometryDraft != nil { requestLeavingGeometryDraft(navigate) } else { navigate() }
    }

    func returnToBatchSelection(completion: @escaping () -> Void = {}) {
        guard !exporting, ParameterValueField.resolvePendingInputs() else { return }
        let navigate = { [weak self] in
            guard let self else { return }
            if self.scheduler.interacting { self.setInteracting(false) }
            guard self.saveEdits() else { return }
            self.batchSelection.returnToCollection(); completion()
        }
        if geometryDraft != nil { requestLeavingGeometryDraft(navigate) } else { navigate() }
    }

    @discardableResult func resolveCollectionDraft(_ id: String, apply: Bool) -> Bool {
        guard let photo = batchSelectionPhotos[id], file == photo.url, !exporting else { return false }
        if apply {
            guard ParameterValueField.commitPendingInputs() else { return false }
            if scheduler.interacting { setInteracting(false) }
            if geometryDraft != nil, !applyGeometryDraft() { return false }
            return saveEdits()
        }
        ParameterValueField.cancelPendingInputs()
        cancelHSLTarget()
        if geometryDraft != nil { cancelGeometryDraft() }
        saveWork?.cancel(); scheduler.setInteracting(false); interactionEntry = nil
        guard let committedEdit else { return false }
        var defaults = Adjustments()
        defaults.exposureMode = RenderEngine.isRasterInput(photo.url) ? .sensor : .preview
        restoreAdjustmentState(committedEdit.state ?? PhotoEditState(settings: defaults, filmID: ""))
        dirty = false; saveError = nil; editRevision = UUID(); schedule(forceExact: true)
        return true
    }

    func prepareCollectionSource(completion: @escaping () -> Void) {
        guard !exporting, ParameterValueField.resolvePendingInputs() else { return }
        let ready = { [weak self] in
            guard let self else { return }
            if self.scheduler.interacting { self.setInteracting(false) }
            guard self.saveEdits() else { return }
            completion()
        }
        if geometryDraft != nil { requestLeavingGeometryDraft(ready) } else { ready() }
    }

    func captureCollectionSynchronization(scope: AdjustmentTransferScope) throws -> MacCollectionSynchronization {
        guard let file, !exporting, !aiState.isRunning, !ParameterValueField.hasPendingInputs,
              geometryDraft == nil else { throw AdjustmentTransferError.draftRequiresPreflight }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits(), let committedEdit, try editStore?.versionedState(for: file) == committedEdit else {
            throw EditPersistenceConflict.changed
        }
        let sourceIdentity = try BatchExportItem.resourceKey(file)
        let targets = batchSelection.targets(excluding: sourceIdentity).compactMap { batchSelectionPhotos[$0]?.url }
        guard !targets.isEmpty else { throw BatchExportFailure.noSelection }
        let payload = try MacAdjustmentTransfer.capture(scope: scope, snapshot: editState(settings: settings),
            context: adjustmentTransferContext(for: file))
        return MacCollectionSynchronization(sourceIdentity: sourceIdentity, payload: payload, targets: targets)
    }

    func prepareCollectionSynchronization(scope: AdjustmentTransferScope) throws -> PreparedAdjustmentTransfer {
        let sync = try captureCollectionSynchronization(scope: scope)
        return try requireAdjustmentSession().prepare(payload: sync.payload,
            targets: adjustmentTransferTargets(sync.targets, payload: sync.payload,
                excludingIdentity: sync.sourceIdentity, collection: true), action: .synchronize)
    }

    func showCollectionSynchronization(scope: AdjustmentTransferScope) throws {
        let sync = try captureCollectionSynchronization(scope: scope)
        adjustmentSheetPayload = sync.payload; adjustmentSheetTargets = sync.targets
        adjustmentSheetExcludedSource = nil; adjustmentSheetExcludedIdentity = sync.sourceIdentity
        pendingAdjustmentHistory = nil; adjustmentSheetInCollection = true; adjustmentSheet = .synchronize
    }

    func prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?,
                                 directory: URL) throws -> MacCollectionExportReview {
        _ = try requireAdjustmentSession()
        guard longEdge == nil || (1...65535).contains(longEdge!) else { throw BatchExportFailure.destination }
        let selection = batchSelection.targets()
        let rows = selection.compactMap { id -> MacCollectionExportReview.Row? in
            guard let photo = batchSelectionPhotos[id] else { return nil }
            let draft = collectionHasDraft(id)
            if skipping.contains(id) {
                return .init(id: id, url: photo.url, hasDraft: draft, skipped: true, snapshot: nil, error: nil)
            }
            do {
                guard !draft else { throw AdjustmentTransferError.draftRequiresPreflight }
                let snapshot = try collectionExportSnapshot(photo)
                return .init(id: id, url: photo.url, hasDraft: false, skipped: false, snapshot: snapshot, error: nil)
            } catch {
                return .init(id: id, url: photo.url, hasDraft: draft, skipped: false, snapshot: nil, error: error)
            }
        }
        return MacCollectionExportReview(selection: selection, skipped: skipping, rows: rows,
            format: format, longEdge: longEdge, directory: directory)
    }

    private func collectionExportSnapshot(_ photo: MacCollectionPhoto) throws -> MacCollectionExportReview.Snapshot {
        try photo.validate()
        guard !collectionHasDraft(photo.id) else { throw AdjustmentTransferError.draftRequiresPreflight }
        let record = try editStore!.versionedState(for: photo.url)
        guard record.identity == photo.original else { throw BatchExportFailure.changedInput }
        if file == photo.url {
            guard committedEdit == record, !aiState.isRunning else { throw EditPersistenceConflict.changed }
        }
        var defaults = Adjustments()
        defaults.exposureMode = RenderEngine.isRasterInput(photo.url) ? .sensor : .preview
        let state = record.state ?? PhotoEditState(settings: defaults, filmID: "")
        if state.settings.aiDenoiseEnabled { try RenderEngine.validateAIInput(photo.url) }
        let look: URL?, lookName: String
        if let recipeID = state.settings.masterRecipeID {
            guard let recipe = MasterRecipe.allRecipes.first(where: { $0.id == recipeID }), let url = recipe.lutURL() else {
                throw BatchExportFailure.missingLook
            }
            look = url; lookName = recipe.title
        } else if !state.filmID.isEmpty {
            guard let film = Film.independentRecipe(state.filmID) ?? films.first(where: {
                $0.id == state.filmID || "builtin:\($0.url.lastPathComponent)" == state.filmID
            }) else { throw BatchExportFailure.missingLook }
            look = film.url; lookName = film.name
        } else { look = nil; lookName = "中性" }
        let checksum = try look.map(BatchFrozenSettings.checksum)
        return .init(photo: photo, record: record, settings: state.settings, look: look,
            lookSHA256: checksum, lookName: lookName, editorRevision: file == photo.url ? editRevision : nil)
    }

    func freezeCollectionExport(_ review: MacCollectionExportReview) throws -> BatchExportJob {
        guard review.ready, !exporting, batchSelection.targets() == review.selection else { throw EditPersistenceConflict.changed }
        if let batch, batch.running || batch.validating || batch.previewing || !batch.job.started || batch.job.succeededCount != batch.job.selectedCount {
            throw RenderError.failed(L10n.text("请先完成或关闭现有批量任务。"))
        }
        func validateReview() throws {
            for snapshot in review.snapshots {
                let fresh = try collectionExportSnapshot(snapshot.photo)
                guard fresh.record == snapshot.record, fresh.settings == snapshot.settings,
                      fresh.look == snapshot.look, fresh.lookSHA256 == snapshot.lookSHA256,
                      fresh.editorRevision == snapshot.editorRevision else { throw EditPersistenceConflict.changed }
            }
        }
        try validateReview()
        let first = review.snapshots[0]
        var job = BatchExportJob(source: first.photo.url, settings: first.settings, look: nil, lookName: first.lookName)
        job.settingsMode = .perTargetFrozen; job.version = 3
        job.format = review.format; job.longEdge = review.longEdge; job.outputDirectory = review.directory
        var ownedLooks = [URL]()
        do {
            for (ordinal, snapshot) in review.snapshots.enumerated() {
                var item = try BatchExportItem(url: snapshot.photo.url)
                guard item.identity == snapshot.record.identity, item.resourceIdentifier == snapshot.photo.id else {
                    throw BatchExportFailure.changedInput
                }
                let look = try batchJournal.snapshotLook(snapshot.look, for: item.id)
                if let look { ownedLooks.append(look) }
                item.selected = true
                item.frozen = BatchFrozenSettings(ordinal: ordinal, settings: snapshot.settings, look: look,
                    lookSHA256: snapshot.lookSHA256, lookName: snapshot.lookName, outputFormat: review.format, longEdge: review.longEdge)
                try item.frozen!.verifyLook(); job.items.append(item)
            }
            try validateReview()
            try batchJournal.save(job)
        } catch {
            for look in ownedLooks { try? FileManager.default.removeItem(at: look) }
            throw error
        }
        if let prior = batch?.job { batchJournal.releaseResources(prior) }
        attachBatch(job)
        return job
    }
}
