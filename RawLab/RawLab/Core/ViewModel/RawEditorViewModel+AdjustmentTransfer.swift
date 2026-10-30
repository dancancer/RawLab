import Foundation

extension RawEditorViewModel {
    func adjustmentContext(identifier: String, isRaw: Bool,
                           whiteBalance: Sony2FujiProcessor.RawWhiteBalance? = nil) -> IOSAdjustmentTransferContext {
        let available = lutMap.values.filter { FileManager.default.isReadableFile(atPath: $0.sourceURL.path) }
        let builtins = Dictionary(available.filter { !$0.isCustom }.map { ($0.sourceURL.lastPathComponent, $0.id) },
                                  uniquingKeysWith: { first, _ in first })
        let recipes = MasterRecipe.allRecipes.filter { $0.lutURL().map { FileManager.default.isReadableFile(atPath: $0.path) } == true }
        let lookIDs = Set(available.map { $0.isCustom ? $0.id : "builtin:\($0.sourceURL.lastPathComponent)" })
            .union(recipes.map { "recipe:\($0.id)" })
        return IOSAdjustmentTransferContext(identifier: identifier, isRaw: isRaw,
            sourceIsHDR:identifier==sourceIdentity?.key && sourceIsHDR,availableLookIDs: lookIDs,
            builtinLookIDs: builtins,
            cameraTemperature: whiteBalance?.isCalibrated == true ? whiteBalance?.temperature : nil,
            cameraTint: whiteBalance?.isCalibrated == true ? whiteBalance?.tint : nil)
    }

    func copyAdjustments(scope: AdjustmentTransferScope, settings: RawSettings) throws {
        guard let source = editorEditSource, let session = adjustmentSession,
              adjustmentTargetIsCurrent(source.identity.key) else { throw AdjustmentTransferError.draftRequiresPreflight }
        var context = adjustmentContext(identifier: source.identity.key, isRaw: sourceKind == .raw, whiteBalance: rawWhiteBalance)
        context.hasUncommittedDraft = hasAdjustmentDraft
        try adjustmentSourceValidator?()
        try session.copy(scope: scope, snapshot: currentEditState(settings: settings), context: context)
        adjustmentClipboardSourceName = sourceDisplayName ?? source.file.displayName
        adjustmentHistoryRevision = UUID()
    }

    var currentAdjustmentPhoto: IOSAdjustmentPhoto? {
        guard let identity = sourceIdentity, let file = sourceFile, let kind = sourceKind else { return nil }
        return .init(identity: identity, displayName: sourceDisplayName ?? file.displayName, file: file, isRaw: kind == .raw)
    }

    func prepareAdjustmentPaste(_ payload: AdjustmentTransferPayload, photos: [IOSAdjustmentPhoto],
                                action: IOSAdjustmentHistoryTransaction.Action = .paste,
                                completion: @escaping (Result<IOSPreparedAdjustmentTransfer, Error>) -> Void) {
        guard let session = adjustmentSession else { completion(.failure(EditPersistenceError.corruptStore)); return }
        let generation = UUID()
        adjustmentPreparationID = generation
        adjustmentPreparing = true
        let activeSource = editorEditSource, source = sourceRevision
        let contexts = photos.map { adjustmentContext(identifier: $0.id, isRaw: $0.isRaw) }
        let validateCurrent: (String) -> Bool = { [weak self] key in
            let check = {
                guard let self else { return false }
                return self.adjustmentPreparationID == generation && self.sourceRevision == source && self.adjustmentTargetIsCurrent(key) &&
                    (self.sourceIdentity?.key != key || self.editorEditSource == activeSource)
            }
            return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        }
        adjustmentQueue.async {
            let targets = zip(photos, contexts).map { photo, initial -> IOSAdjustmentTransferTarget in
                var context = initial
                var validation: (() throws -> Void)?
                do {
                    if let error = photo.error { throw error }
                    guard let file = photo.file else { throw CocoaError(.fileReadNoSuchFile) }
                    let original = try Self.adjustmentSourceValidation(file)
                    validation = { try photo.validateSource?(); try original() }
                    try validation?()
                    if photo.isRaw {
                        let saved = try self.editPersistence?.versionedState(for: photo.identity).state?.settings ?? .default
                        var neutral = RawSettings.default
                        neutral.processing = saved.processing
                        neutral.x3fMode = saved.x3fMode
                        let processor = Sony2FujiProcessor()
                        let result = try file.withReadAccess {
                            try processor.processRaw(url: $0, settings: neutral, previewLongEdge: 128, lutURL: nil)
                        }
                        if result.rawWhiteBalance?.isCalibrated == true {
                            context.cameraTemperature = result.rawWhiteBalance?.temperature
                            context.cameraTint = result.rawWhiteBalance?.tint
                        }
                        context.validateLensRequest = { lens in
                            let processor = Sony2FujiProcessor()
                            var settings = neutral
                            settings.lensCorrection = lens
                            let result = try file.withReadAccess {
                                try processor.processRaw(url: $0, settings: settings, previewLongEdge: 128, lutURL: nil)
                            }
                            guard let report = result.lensInfo,
                                  (!lens.distortion || report.appliedDistortion), (!lens.tca || report.appliedTCA) else {
                                throw AdjustmentTransferError.incompatible(result.lensInfo?.message ?? L10n.text("镜头配置"))
                            }
                        }
                    } else {
                        context.sourceIsHDR=try file.withReadAccess { try HDRSourceInfo.probe($0) != nil }
                        if context.sourceIsHDR {
                            _ = try file.withReadAccess { try Sony2FujiProcessor().processHDR(url:$0,settings:HDRSettings(),previewLongEdge:128) }
                        } else { _ = try file.withReadAccess { try Sony2FujiProcessor().loadRasterBuffer(url:$0) } }
                    }
                } catch { validation = { throw error } }
                var defaults=RawSettings.default
                if context.sourceIsHDR { defaults.hdr=HDRSettings() }
                return IOSAdjustmentTransferTarget(identity: photo.identity, displayName: photo.displayName,
                    defaultState: PhotoEditState(settings:defaults), context: context,
                    isCurrent: { validateCurrent(photo.id) }, validateSource: validation)
            }
            let result = Result { try session.prepare(payload: payload, targets: targets, action: action) }
            self.resultDelivery {
                guard self.adjustmentPreparationID == generation else { return }
                self.adjustmentPreparing = false
                completion(result)
            }
        }
    }

    func cancelAdjustmentPreparation() {
        adjustmentPreparationID = UUID()
        adjustmentPreparing = false
    }

    func applyAdjustmentPaste(_ operation: IOSPreparedAdjustmentTransfer, skipping: Set<String>) -> [IOSAdjustmentTransferOutcome] {
        let results = adjustmentSession?.apply(operation, skipping: skipping) ?? []
        acceptAdjustmentOutcomes(results)
        if operation.action == .synchronize {
            batchSelection.selection.recordSynchronization(operation.id, changed: results.contains { $0.status == .applied })
        }
        return results
    }

    func retainAdjustmentPhoto(_ source: PhotoImportSource, identity: PhotoIdentity? = nil) async throws -> IOSAdjustmentPhoto {
        try await withCheckedThrowingContinuation { continuation in
            adjustmentQueue.async {
                do {
                    let resolved = try identity ?? PhotoIdentity.fallback(for: source.url)
                    let file = try PhotoSourceFile.copy(source.url)
                    continuation.resume(returning: .init(identity: resolved, displayName: source.displayName, file: file, isRaw: source.isRaw))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
