import AppKit
import UniformTypeIdentifiers

extension EditorModel {
    @discardableResult func addCollectionPhotos(_ urls: [URL], selectExisting: Bool = false) -> [URL] {
        var accepted: [URL] = []
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
                if selectExisting { batchSelection.select(photo.id, true) }
                accepted.append(url)
            } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        collectionError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return accepted
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
        do {
            let restored = try committedEdit.state ?? PhotoEditState(settings: RenderEngine.defaultSettings(for: photo.url, sourceIsHDR: sourceIsHDR), filmID: "")
            restoreAdjustmentState(restored)
        } catch { saveError = error.localizedDescription; return false }
        normalizeAdjustmentNavigation()
        dirty = false; saveError = nil; editRevision = UUID(); schedule(forceExact: true)
        return true
    }

    func prepareCollectionSource(onStay: @escaping () -> Void = {}, onFailure: @escaping () -> Void = {},
                                 completion: @escaping () -> Void) {
        guard !exporting else { onFailure(); return }
        guard ParameterValueField.resolvePendingInputs() else { onStay(); return }
        let ready = { [weak self] in
            guard let self else { return }
            if self.scheduler.interacting { self.setInteracting(false) }
            guard self.saveEdits() else { onFailure(); return }
            completion()
        }
        if geometryDraft != nil { requestLeavingGeometryDraft(ready, onStay: onStay) } else { ready() }
    }

    func captureCollectionSynchronization(scope: AdjustmentTransferScope) throws -> MacCollectionSynchronization {
        guard let file, !exporting, !aiState.isRunning, !ParameterValueField.hasPendingInputs,
              geometryDraft == nil else { throw AdjustmentTransferError.draftRequiresPreflight }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { throw AdjustmentTransferError.draftRequiresPreflight }
        guard let committedEdit, try OriginalFileIdentity(file) == committedEdit.identity else {
            throw AdjustmentCommitError.photoChanged
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

    private func collectionExportPreparation(skipping: Set<String>, format: ExportFormat, longEdge: Int?,
                                             directory: URL, adaptiveJPEG: Bool = false) throws -> MacCollectionExportPreparation {
        let session = try requireAdjustmentSession()
        let selection = batchSelection.targets()
        return MacCollectionExportPreparation(selection: selection, photos: batchSelectionPhotos,
            drafts: Set(selection.filter(collectionHasDraft)), activeFile: file, activeRecord: committedEdit,
            activeRevision: editRevision, activeAIBusy: aiState.isRunning, store: editStore!, films: films,
            skipped: skipping, format: format, longEdge: longEdge, directory: directory, adaptiveJPEG: adaptiveJPEG,
            probeHDRSource: probeHDRSource, editGeneration: session.editGeneration(for:))
    }

    func prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?,
                                 directory: URL, adaptiveJPEG: Bool = false) throws -> MacCollectionExportReview {
        try collectionExportPreparation(skipping: skipping, format: format, longEdge: longEdge, directory: directory,
                                        adaptiveJPEG: adaptiveJPEG).prepare()
    }

    func cancelCollectionExportPreparation() {
        collectionExportGeneration = UUID()
        collectionExportPreparing = false; collectionExportReview = nil; collectionExportError = nil
    }

    func startCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, directory: URL, adaptiveJPEG: Bool = false,
                               completed: @escaping (UUID) -> Void = { _ in }) {
        guard !collectionExportPreparing, !exporting else { return }
        cancelCollectionExportPreparation()
        do {
            let input = try collectionExportPreparation(skipping: skipping, format: format, longEdge: longEdge, directory: directory,
                                                       adaptiveJPEG: adaptiveJPEG)
            let generation = collectionExportGeneration, source = sourceRevision, revision = editRevision
            let prepare = prepareCollectionExportOperation
            collectionExportPreparing = true
            collectionExportQueue.async { [weak self] in
                let result = Result { try prepare(input) }
                DispatchQueue.main.async {
                    guard let self, self.collectionExportGeneration == generation else { return }
                    self.collectionExportPreparing = false
                    guard self.sourceRevision == source, self.editRevision == revision,
                          self.batchSelection.targets() == input.selection else {
                        self.collectionExportError = self.adjustmentErrorMessage(AdjustmentCommitError.expired)
                        return
                    }
                    do {
                        let review = try result.get()
                        self.collectionExportReview = review
                        guard review.ready else { return }
                        let job = try self.freezeCollectionExport(review)
                        _ = self.batch?.start()
                        completed(job.id)
                    } catch {
                        self.collectionExportReview = nil
                        self.collectionExportError = self.adjustmentErrorMessage(error)
                    }
                }
            }
        } catch { collectionExportError = adjustmentErrorMessage(error) }
    }

    var collectionExportBlockedByTask: Bool {
        guard let batch else { return false }
        return batch.running || batch.validating || batch.previewing || !batch.job.started ||
            batch.job.succeededCount != batch.job.selectedCount
    }

    func freezeCollectionExport(_ review: MacCollectionExportReview) throws -> BatchExportJob {
        guard review.ready, !exporting, batchSelection.targets() == review.selection else { throw AdjustmentCommitError.expired }
        if collectionExportBlockedByTask {
            throw RenderError.failed(L10n.text("请先完成或关闭现有批量任务。"))
        }
        let session = try requireAdjustmentSession()
        func validateReview() throws {
            for snapshot in review.snapshots {
                try snapshot.photo.validate()
                guard !collectionHasDraft(snapshot.photo.id),
                      session.editGeneration(for: snapshot.photo.url) == snapshot.editGeneration,
                      snapshot.editorRevision == nil || (file == snapshot.photo.url && editRevision == snapshot.editorRevision) else {
                    throw AdjustmentCommitError.expired
                }
                guard try snapshot.look.map(BatchFrozenSettings.checksum) == snapshot.lookSHA256 else { throw BatchExportFailure.missingLook }
            }
        }
        try validateReview()
        let first = review.snapshots[0]
        var job = BatchExportJob(source: first.photo.url, settings: first.settings, look: nil, lookName: first.lookName)
        job.settingsMode = .perTargetFrozen; job.version = 3
        job.format = review.adaptiveJPEG ? .jpeg : review.format; job.longEdge = review.longEdge; job.outputDirectory = review.directory
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
                item.noticeKey = snapshot.noticeKey
                item.frozen = BatchFrozenSettings(ordinal: ordinal, settings: snapshot.settings, look: look,
                    lookSHA256: snapshot.lookSHA256, lookName: snapshot.lookName,
                    outputFormat: review.adaptiveJPEG ? (snapshot.settings.isHDREditing ? .hdrJPEG : .jpeg) : review.format,
                    longEdge: review.longEdge)
                try item.frozen!.verifyLook(); job.items.append(item)
            }
            try validateReview()
            try batchJournal.save(job)
        } catch {
            _ = batchJournal.consumeQuarantinedError()
            for look in ownedLooks { try? FileManager.default.removeItem(at: look) }
            throw error
        }
        if let quarantined = batchJournal.consumeQuarantinedError() {
            self.error = L10n.format("无法读取上次批量任务：%@", String(describing: quarantined.localizedDescription))
        }
        if let prior = batch?.job { batchJournal.releaseResources(prior) }
        attachBatch(job)
        return job
    }
}
