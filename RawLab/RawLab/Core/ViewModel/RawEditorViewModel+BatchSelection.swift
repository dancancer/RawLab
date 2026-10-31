import Foundation

struct IOSCollectionSynchronization {
    let sourceIdentity: PhotoIdentity
    let sourceName: String
    let payload: AdjustmentTransferPayload
    let photos: [IOSAdjustmentPhoto]
}

extension RawEditorViewModel {
    var collectionDraftFailure: String {
        if case .failed(let reason) = editSaveState { return reason }
        return L10n.text("预览尚未就绪，请稍后重试。")
    }

    func validateCollectionActive(_ key: String) throws {
        guard sourceIdentity?.key == key else { return }
        guard adjustmentTargetIsCurrent(key), !adjustmentReloadRequired else { throw AdjustmentTransferError.draftRequiresPreflight }
        guard let record = loadedEditRecord, try editPersistence?.versionedState(for: record.identity) == record else {
            throw EditPersistenceConflict.changed
        }
        try adjustmentSourceValidator?()
    }

    func captureCollectionSynchronization(scope: AdjustmentTransferScope, settings: RawSettings) throws -> IOSCollectionSynchronization {
        guard let identity = sourceIdentity, let record = loadedEditRecord else { throw EditPersistenceError.corruptStore }
        try validateCollectionActive(identity.key)
        let state = record.state ?? PhotoEditState(settings: sourceDefaultSettings)
        guard currentEditState(settings: settings).hasSameAdjustments(as: state) else { throw EditPersistenceConflict.changed }
        let context = adjustmentContext(identifier: identity.key, isRaw: sourceKind == .raw, whiteBalance: rawWhiteBalance)
        let payload = try IOSAdjustmentTransfer.capture(scope: scope, snapshot: state, context: context)
        let photos = batchSelection.selection.targets(excluding: identity.key).compactMap { key -> IOSAdjustmentPhoto? in
            guard let stored = batchSelection.photos[key] else { return nil }
            var photo = stored.photo
            photo.validateSource = { try stored.validate() }
            return photo
        }
        return .init(sourceIdentity: identity, sourceName: sourceDisplayName ?? "", payload: payload, photos: photos)
    }

    func prepareCollectionExport(skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                                  completion: @escaping (Result<IOSCollectionExportReview, Error>) -> Void) {
        guard let store = editPersistence else { completion(.failure(EditPersistenceError.corruptStore)); return }
        let collection = batchSelection.exportInput
        let looks = lutMap
        let active = collectionActiveValidator()
        adjustmentQueue.async {
            let review = collection.prepareExport(store: store, skipping: skipping, format: format, longEdge: longEdge,
                probeHDR: { try HDRSourceInfo.probe($0) != nil },
                validateActive: active, resolveLook: { settings in
                    if let id = settings.masterRecipeID {
                        let recipe = MasterRecipe.recipe(for: id)
                        return (recipe?.lutURL(), recipe?.name)
                    }
                    guard let id = settings.lutID else { return (nil, nil) }
                    if id.hasPrefix("recipe-lut:") {
                        let recipe = MasterRecipe.recipe(for: String(id.dropFirst("recipe-lut:".count)))
                        return (recipe?.lutURL(), recipe?.name)
                    }
                    return (looks[id]?.sourceURL, looks[id]?.name)
                })
            self.resultDelivery { completion(.success(review)) }
        }
    }

    func cancelCollectionExportPreparation() {
        collectionExportGeneration = UUID()
        collectionExportPreparing = false
        collectionExportReview = nil; collectionExportError = nil
    }

    func startCollectionExport(skipping: Set<String>, format: BatchOutputFormat, longEdge: Int?,
                               completed: @escaping (BatchExportJob, BatchJournalStore, Bool) -> Void) {
        guard !collectionExportPreparing, !collectionExportFreezing else { return }
        cancelCollectionExportPreparation()
        let generation = collectionExportGeneration, source = sourceRevision, revision = settingsSaveRevision
        let selection = batchSelection.selection.targets()
        let isCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.collectionExportGeneration == generation && self.sourceRevision == source &&
                self.settingsSaveRevision == revision && self.batchSelection.selection.targets() == selection
        }
        collectionExportPreparing = true
        prepareCollectionExport(skipping: skipping, format: format, longEdge: longEdge) { [weak self] result in
            guard let self, self.collectionExportGeneration == generation else { return }
            guard isCurrent() else {
                self.collectionExportPreparing = false
                self.collectionExportError = self.adjustmentErrorMessage(EditPersistenceConflict.changed)
                return
            }
            do {
                let review = try result.get()
                self.collectionExportReview = review
                guard review.ready else { self.collectionExportPreparing = false; return }
                self.collectionExportFreezing = true
                self.freezeCollectionExport(review, isCurrent: isCurrent) { result in
                    self.collectionExportFreezing = false
                    self.collectionExportPreparing = false
                    switch result {
                    case .success(let value):
                        // 发布后交接不能被页面取消吞掉；过期请求只取消自动启动权。
                        completed(value.0, value.1, isCurrent())
                    case .failure(let error):
                        if self.collectionExportGeneration == generation {
                            self.collectionExportReview = nil
                            self.collectionExportError = self.adjustmentErrorMessage(error)
                        }
                    }
                }
            } catch {
                self.collectionExportPreparing = false
                self.collectionExportError = self.adjustmentErrorMessage(error)
            }
        }
    }

    func freezeCollectionExport(_ review: IOSCollectionExportReview, isCurrent: @escaping () -> Bool = { true },
                                 completion: @escaping (Result<(BatchExportJob, BatchJournalStore), Error>) -> Void) {
        guard let store = editPersistence else { completion(.failure(EditPersistenceError.corruptStore)); return }
        let collection = batchSelection.exportInput, active = collectionActiveValidator(isCurrent: isCurrent, review: review)
        let makeJournal = makeCollectionJournal
        adjustmentQueue.async {
            let result = Result {
                let journal = try makeJournal()
                return (try collection.freeze(review, store: store, journal: journal, validateActive: active), journal)
            }
            self.resultDelivery { completion(result) }
        }
    }

    private func collectionActiveValidator(isCurrent: @escaping () -> Bool = { true },
                                           review: IOSCollectionExportReview? = nil) -> (String) throws -> Void {
        { [weak self] key in
            let check = {
                guard let self, isCurrent() else { throw CocoaError(.userCancelled) }
                if let review {
                    guard self.batchSelection.selection.targets() == review.selection,
                          self.batchSelection.photos[key]?.photo.file == review.rows.first(where: { $0.id == key })?.photo.photo.file else {
                        throw EditPersistenceConflict.changed
                    }
                }
                try self.validateCollectionActive(key)
            }
            if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
        }
    }
}
