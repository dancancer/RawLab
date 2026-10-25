import AppKit

enum AdjustmentSheetKind: String, Identifiable {
    case copy, paste, history
    var id: String { rawValue }
}

extension EditorModel {
    func requestAdjustmentSheet(_ kind: AdjustmentSheetKind) {
        guard !exporting, !lookLibraryBusy, adjustmentSheet == nil, !geometryDraftDeparturePending,
              kind == .history || !aiState.isRunning,
              kind == .history || file != nil else { return }
        guard ParameterValueField.resolvePendingInputs() else { return }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { return }
        adjustmentSheetPayload = nil; adjustmentSheetTargets = nil
        adjustmentSheetExcludedSource = nil; pendingAdjustmentHistory = nil
        let show: () -> Void = { [weak self] in self?.adjustmentSheet = kind }
        if kind == .copy, geometryDraft != nil { requestLeavingGeometryDraft(show) }
        else { show() }
    }
    var availableAdjustmentLooks: Set<String> {
        var ids = Set(films.filter { FileManager.default.isReadableFile(atPath: $0.url.path) }
            .map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" })
        ids.formUnion(MasterRecipe.allRecipes.filter { $0.lutURL() != nil }.map { "recipe:\($0.id)" })
        return ids
    }

    func adjustmentTransferContext(for url: URL) -> MacAdjustmentTransferContext {
        MacAdjustmentTransferContext(identifier: url.resolvingSymlinksInPath().standardizedFileURL.path, isRaw: !RenderEngine.isRasterInput(url),
            availableLookIDs: availableAdjustmentLooks,
            defaultExposureMode: RenderEngine.isRasterInput(url) ? .sensor : .preview,
            hasUncommittedDraft: file == url && (geometryDraft != nil || dirty))
    }

    @discardableResult func copyAdjustments(scope: AdjustmentTransferScope) throws -> AdjustmentTransferPayload {
        guard !aiState.isRunning else { throw RenderError.failed(L10n.text("当前照片的设置尚不可用。")) }
        guard let file, geometryDraft == nil else { throw AdjustmentTransferError.draftRequiresPreflight }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { throw AdjustmentTransferError.draftRequiresPreflight }
        let payload = try requireAdjustmentSession().copy(scope: scope, snapshot: editState(settings: settings),
            context: adjustmentTransferContext(for: file))
        adjustmentClipboard = payload
        return payload
    }

    // 主线程模型/测试入口；界面的大批量预检使用独立队列执行只读 prepare。
    func prepareAdjustmentPaste(payload: AdjustmentTransferPayload, targets: [URL], excludingSource: String? = nil) throws -> PreparedAdjustmentTransfer {
        let session = try requireAdjustmentSession()
        return try session.prepare(payload: payload, targets: adjustmentTransferTargets(targets, payload: payload, excludingSource: excludingSource))
    }

    func adjustmentTransferTargets(_ urls: [URL], payload: AdjustmentTransferPayload, excludingSource: String? = nil) -> [AdjustmentTransferTarget] {
        let activePath = file?.resolvingSymlinksInPath().standardizedFileURL.path
        let revision = editRevision
        return urls.filter { $0.resolvingSymlinksInPath().standardizedFileURL.path != excludingSource }.map { url in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            var defaults = Adjustments()
            defaults.exposureMode = RenderEngine.isRasterInput(url) ? .sensor : .preview
            var context = adjustmentTransferContext(for: url)
            // 校验实际 native 请求；自动匹配结果只用于目标预检，不进入 payload。
            context.validateLensRequest = { lens in
                var request = Adjustments(); request.lensCorrection = lens
                let frame = try RenderEngine().render(url, settings: request, lut: nil, edge: 256)
                guard let info = frame?.lensInfo,
                      !lens.distortion || info.appliedDistortion,
                      !lens.tca || info.appliedTCA else { throw AdjustmentTransferError.incompatible("lens calibration") }
            }
            return AdjustmentTransferTarget(url: url, defaultState: PhotoEditState(settings: defaults, filmID: ""), context: context,
                isCurrent: { [weak self] in
                    let check = {
                        guard let self else { return false }
                        guard path != excludingSource else { return false }
                        if self.file?.resolvingSymlinksInPath().standardizedFileURL.path != path { return path != activePath }
                        return self.editRevision == revision && !self.dirty && self.geometryDraft == nil && !self.aiState.isRunning
                    }
                    return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
                }, resolveMetadata: { state in
                    guard !RenderEngine.isRasterInput(url) else { return state }
                    guard payload.source.recipe != nil || state.settings.masterRecipeID != nil ||
                          (payload[.rawDenoise]?.number ?? 0) > 0 else { return state }
                    let frame = try RenderEngine().render(url, settings: state.settings.neutralSettings, lut: nil, edge: 256)
                    guard let frame else { throw AdjustmentTransferError.incompatible("target metadata") }
                    var hydrated = state
                    hydrated.settings.resolveWhiteBalance(frame.asShotWhiteBalance)
                    hydrated.settings.resolveRawNoiseReductionSupport(frame.supportsRawNoiseReduction)
                    return hydrated
                })
        }
    }

    func applyAdjustmentPaste(_ operation: PreparedAdjustmentTransfer, skipping: Set<String> = []) {
        guard let session = adjustmentSession else { return }
        acceptAdjustmentOutcomes(session.apply(operation, skipping: skipping))
        if session.transactions.contains(where: { $0.id == operation.id }) { lastAdjustmentTransaction = operation.id }
    }

    func changeAdjustmentTransaction(_ id: UUID, undo: Bool, skipping: Set<String> = []) {
        performAdjustmentHistory(.init(transactionID: id, photo: nil, undo: undo), skipping: skipping)
    }

    func performAdjustmentHistory(_ request: AdjustmentHistoryRequest, skipping: Set<String> = []) {
        guard let session = adjustmentSession else { return }
        let current: (String) -> Bool = { [weak self] path in
            guard let self else { return false }
            return self.file?.resolvingSymlinksInPath().standardizedFileURL.path != path || (!self.dirty && self.geometryDraft == nil)
        }
        if let photo = request.photo {
            acceptAdjustmentOutcomes(request.undo ? session.undoPhoto(photo, transactionID: request.transactionID, isCurrent: current)
                : session.redoPhoto(photo, transactionID: request.transactionID, isCurrent: current))
        } else {
            acceptAdjustmentOutcomes(request.undo ? session.undoTransaction(request.transactionID, skipping: skipping, isCurrent: current)
                : session.redoTransaction(request.transactionID, skipping: skipping, isCurrent: current))
        }
    }
}
