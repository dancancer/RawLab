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
        let state = record.state ?? PhotoEditState(settings: .default)
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
        let collection = batchSelection
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

    func freezeCollectionExport(_ review: IOSCollectionExportReview,
                                 completion: @escaping (Result<(BatchExportJob, BatchJournalStore), Error>) -> Void) {
        guard let store = editPersistence else { completion(.failure(EditPersistenceError.corruptStore)); return }
        let collection = batchSelection, active = collectionActiveValidator()
        adjustmentQueue.async {
            let result = Result {
                let journal = try BatchJournalStore.appStore()
                return (try collection.freeze(review, store: store, journal: journal, validateActive: active), journal)
            }
            self.resultDelivery { completion(result) }
        }
    }

    private func collectionActiveValidator() -> (String) throws -> Void {
        { [weak self] key in
            let check = {
                guard let self else { throw CocoaError(.userCancelled) }
                try self.validateCollectionActive(key)
            }
            if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
        }
    }
}
