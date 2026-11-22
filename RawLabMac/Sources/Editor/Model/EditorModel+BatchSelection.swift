import RawLabKit
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
                let input = file.flatMap { (try? MacBatchExportItem.resourceKey($0)) == (try? MacBatchExportItem.resourceKey(url)) ? $0 : nil } ?? url
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
        return dirty || hasPendingEditCommits || geometryDraft != nil || scheduler.interacting || ParameterValueField.hasPendingInputs
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
        _ = editStore?.flushPendingCommits()
        guard let committedEdit else { return false }
        do {
            let restored = try committedEdit.state ?? MacPhotoEditState(settings: RenderEngine.defaultSettings(for: photo.url, sourceIsHDR: sourceIsHDR), filmID: "")
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
        let sourceIdentity = try MacBatchExportItem.resourceKey(file)
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
                                             directory: URL, adaptiveJPEG: Bool = false,
                                             outputSharpening: OutputSharpening = .off) throws -> MacCollectionExportPreparation {
        _ = editStore?.flushPendingCommits()
        let session = try requireAdjustmentSession()
        let selection = batchSelection.targets()
        return MacCollectionExportPreparation(selection: selection, photos: batchSelectionPhotos,
            drafts: Set(selection.filter(collectionHasDraft)), activeFile: file, activeRecord: committedEdit,
            activeRevision: editRevision, activeAIBusy: aiState.isRunning, store: editStore!, films: films,
            skipped: skipping, format: format, longEdge: longEdge, outputSharpening: outputSharpening,
            directory: directory, adaptiveJPEG: adaptiveJPEG,
            probeHDRSource: probeHDRSource, editGeneration: session.editGeneration(for:))
    }

    func prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?,
                                 directory: URL, adaptiveJPEG: Bool = false,
                                 outputSharpening: OutputSharpening = .off) throws -> MacCollectionExportReview {
        try collectionExportPreparation(skipping: skipping, format: format, longEdge: longEdge, directory: directory,
                                        adaptiveJPEG: adaptiveJPEG, outputSharpening: outputSharpening).prepare()
    }

    func cancelCollectionExportPreparation() {
        collectionExportGeneration = UUID()
        collectionExportPreparing = false; collectionExportReview = nil; collectionExportError = nil
    }

    func startCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, directory: URL, adaptiveJPEG: Bool = false,
                               outputSharpening: OutputSharpening = .off,
                               observeFreezeStage: ((String, Bool) -> Void)? = nil,
                               completed: @escaping (UUID) -> Void = { _ in }) {
        guard !collectionExportPreparing, !exporting else { return }
        cancelCollectionExportPreparation()
        do {
            _ = editStore?.flushPendingCommits()
            let input = try collectionExportPreparation(skipping: skipping, format: format, longEdge: longEdge, directory: directory,
                                                       adaptiveJPEG: adaptiveJPEG, outputSharpening: outputSharpening)
            let generation = collectionExportGeneration, source = sourceRevision, revision = editRevision
            let prepare = prepareCollectionExportOperation
            let session = try requireAdjustmentSession(), journal = batchJournal
            collectionExportPreparing = true
            collectionExportQueue.async { [weak self] in
                let result: Result<(MacCollectionExportReview, MacFrozenCollectionExport?), Error> = Result { try prepare(input) }.flatMap { review in
                    guard review.ready else { return .success((review, nil)) }
                    // 冻结（前后双遍全集重验 + 每目标 look 副本拷贝）留在后台队列，主线程只接收结果。
                    return Result { try MacCollectionExportFreeze(session: session, drafts: input.drafts,
                        activeFile: input.activeFile, activeRevision: input.activeRevision, journal: journal,
                        observeStage: observeFreezeStage).freeze(review) }.map { (review, Optional($0)) }
                }
                DispatchQueue.main.async {
                    guard let self, self.collectionExportGeneration == generation else {
                        Self.releaseFrozenLooks(result)   // 取消后的迟到冻结不 attach，look 副本当场释放，日志保持未写。
                        return
                    }
                    self.collectionExportPreparing = false
                    _ = self.editStore?.flushPendingCommits()
                    guard self.sourceRevision == source, self.editRevision == revision,
                          self.batchSelection.targets() == input.selection else {
                        Self.releaseFrozenLooks(result)
                        self.collectionExportReview = nil
                        self.collectionExportError = self.adjustmentErrorMessage(AdjustmentCommitError.expired)
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.collectionExportReview = nil
                        self.collectionExportError = self.adjustmentErrorMessage(error)
                    case .success((let review, nil)):
                        self.collectionExportReview = review   // 未就绪：只呈现确认表，不冻结。
                    case .success((let review, let frozen?)):
                        self.collectionExportReview = review
                        do {
                            // 与 UI 状态原子的复核保留在主线程：会话代次、实时草稿与批次占用随 attach 一次判定。
                            guard review.snapshots.allSatisfy({ !self.collectionHasDraft($0.photo.id)
                                    && session.editGeneration(for: $0.photo.url) == $0.editGeneration }) else { throw AdjustmentCommitError.expired }
                            guard !self.collectionExportBlockedByTask else {
                                throw RenderError.failed(L10n.text("请先完成或关闭现有批量任务。"))
                            }
                            let job = try self.attachFrozenCollectionExport(frozen, snapshots: review.snapshots)
                            self.collectionExportReview = nil
                            self.collectionExportError = nil
                            _ = self.batch?.start()
                            completed(job.id)
                        } catch {
                            Self.releaseFrozenLooks(.success((review, frozen)))
                            self.collectionExportReview = nil
                            self.collectionExportError = self.adjustmentErrorMessage(error)
                        }
                    }
                }
            }
        } catch { collectionExportError = adjustmentErrorMessage(error) }
    }

    private static func releaseFrozenLooks(_ result: Result<(MacCollectionExportReview, MacFrozenCollectionExport?), Error>) {
        if case .success((_, let frozen?)) = result {
            for look in frozen.ownedLooks { try? FileManager.default.removeItem(at: look) }
        }
    }

    var collectionExportBlockedByTask: Bool {
        guard let batch else { return false }
        return batch.running || batch.validating || batch.previewing || !batch.job.started ||
            batch.job.succeededCount != batch.job.selectedCount
    }

    // 主线程同步冻结（模型测试与直接调用方使用）：与异步路径共用冻结核心，语义一致——
    // 前后双遍全集重验、look 副本拷贝、日志落盘、隔离提示、上一任务释放与 attach。
    func freezeCollectionExport(_ review: MacCollectionExportReview) throws -> MacBatchExportJob {
        _ = editStore?.flushPendingCommits()
        guard review.ready, !exporting, batchSelection.targets() == review.selection else { throw AdjustmentCommitError.expired }
        if collectionExportBlockedByTask {
            throw RenderError.failed(L10n.text("请先完成或关闭现有批量任务。"))
        }
        let session = try requireAdjustmentSession()
        let frozen = try MacCollectionExportFreeze(session: session,
            drafts: Set(review.snapshots.map(\.photo.id).filter { collectionHasDraft($0) }),
            activeFile: file, activeRevision: editRevision, journal: batchJournal).freeze(review)
        return try attachFrozenCollectionExport(frozen, snapshots: review.snapshots)
    }

    // 日志落盘、隔离提示、上一任务释放与 attach 在主线程一次完成，与 UI 切换保持原子。
    private func attachFrozenCollectionExport(_ frozen: MacFrozenCollectionExport,
                                              snapshots: [MacCollectionExportReview.Snapshot] = []) throws -> MacBatchExportJob {
        do {
            guard !(editStore?.hasPendingCommits == true || adjustmentSession?.hasPendingCommits == true) else {
                throw AdjustmentCommitError.expired
            }
            if let activeFile = file {
                let activePath = activeFile.resolvingSymlinksInPath().standardizedFileURL.path
                let activeID = try? MacBatchExportItem.resourceKey(activeFile)
                if let activeItem = frozen.job.items.first(where: { $0.identity.path == activePath || (activeID != nil && $0.resourceIdentifier == activeID) }) {
                    let hasActiveDraft = activeItem.resourceIdentifier.map(collectionHasDraft) ??
                        (dirty || hasPendingEditCommits || geometryDraft != nil || scheduler.interacting || ParameterValueField.hasPendingInputs)
                    guard !dirty, !hasActiveDraft,
                          let committedEdit, committedEdit.identity == activeItem.identity else {
                        throw AdjustmentCommitError.expired
                    }
                    if let snapshot = snapshots.first(where: { $0.photo.id == activeItem.resourceIdentifier }),
                       snapshot.record != committedEdit {
                        throw AdjustmentCommitError.expired
                    }
                    if let store = editStore, (try store.readState(for: activeFile)) != committedEdit {
                        throw AdjustmentCommitError.expired
                    }
                }
            }
            try batchJournal.save(frozen.job)
        } catch {
            _ = batchJournal.consumeQuarantinedError()
            for look in frozen.ownedLooks { try? FileManager.default.removeItem(at: look) }
            throw error
        }
        if let quarantined = batchJournal.consumeQuarantinedError() {
            self.error = L10n.format("无法读取上次批量任务：%@", String(describing: quarantined.localizedDescription))
        }
        if let prior = batch?.job { batchJournal.releaseResources(prior) }
        attachBatch(frozen.job)
        return frozen.job
    }
}
