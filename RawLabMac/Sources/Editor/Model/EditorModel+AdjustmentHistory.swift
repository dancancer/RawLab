import AppKit

struct AdjustmentHistoryRequest {
    let transactionID: UUID
    let photo: URL?
    let undo: Bool
}

extension EditorModel {
    func requireAdjustmentSession() throws -> AdjustmentTransferSession {
        if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
        if adjustmentSession == nil { adjustmentSession = AdjustmentTransferSession(store: editStore!) }
        return adjustmentSession!
    }

    var canUndoAdjustment: Bool {
        file.map { adjustmentSession?.canUndoPhoto($0) == true } == true && !exporting && geometryDraft == nil && adjustmentSheet == nil
    }
    var canRedoAdjustment: Bool {
        file.map { adjustmentSession?.canRedoPhoto($0) == true } == true && !exporting && geometryDraft == nil && adjustmentSheet == nil
    }

    // 一个正式提交入口；失败保留当前 UI / 草稿，成功回执成为下一次保存的前态。
    @discardableResult func commitAdjustment(_ candidate: PhotoEditState) -> Bool {
        guard let file else { return false }
        do {
            let session = try requireAdjustmentSession()
            if committedEdit?.identity.path != file.resolvingSymlinksInPath().standardizedFileURL.path {
                committedEdit = try editStore!.versionedState(for: file)
            }
            let outcome = session.commitEdit(expected: committedEdit!, state: candidate)
            guard let saved = outcome.saved else {
                throw outcome.error ?? AdjustmentTransferError.incompatible("save")
            }
            committedEdit = saved
            adjustmentHistoryRevision &+= 1
            saveError = nil; saveStatusKey = "调整已保存"
            clearSaveStatusLater()
            return true
        } catch {
            saveError = L10n.format("调整未保存：%@", adjustmentErrorMessage(error))
            return false
        }
    }

    func beginAdjustmentInteraction() {
        guard geometryDraft == nil else { return }
        _ = saveEdits()
        interactionEntry = editState(settings: settings)
        interactionWasDirty = dirty
        saveWork?.cancel()
    }

    func finishAdjustmentInteraction() {
        interactionEntry = nil
        if geometryDraft == nil { _ = saveEdits() }
    }

    func cancelAdjustmentInteraction() {
        guard let entry = interactionEntry else { return }
        saveWork?.cancel()
        scheduler.setInteracting(false)
        restoreAdjustmentState(entry)
        dirty = interactionWasDirty
        interactionEntry = nil
        if dirty { _ = saveEdits() }
        schedule(forceExact: true)
    }

    func undoAdjustment() { changeAdjustmentHistory(undo: true) }
    func redoAdjustment() { changeAdjustmentHistory(undo: false) }

    private func changeAdjustmentHistory(undo: Bool) {
        guard geometryDraft == nil, !exporting, adjustmentSheet == nil, let file,
              ParameterValueField.resolvePendingInputs() else { return }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits(), let session = adjustmentSession else { return }
        guard let id = session.photoHistoryID(file, undo: undo) else { return }
        let request = AdjustmentHistoryRequest(transactionID: id, photo: file, undo: undo)
        performAdjustmentHistory(request)
        if adjustmentOutcomes.contains(where: { [.failed, .blocked, .conflict].contains($0.status) }) {
            pendingAdjustmentHistory = request
            adjustmentSheet = .history
        }
    }

    func acceptAdjustmentOutcomes(_ outcomes: [AdjustmentTransferOutcome]) {
        adjustmentOutcomes = outcomes
        adjustmentHistoryRevision &+= 1
        let path = file?.resolvingSymlinksInPath().standardizedFileURL.path
        if !dirty, geometryDraft == nil,
           let saved = outcomes.first(where: { $0.targetID == path && $0.saved != nil })?.saved,
           let file, (try? editStore?.versionedState(for: file)) == saved {
            committedEdit = saved
            var defaults = Adjustments()
            defaults.exposureMode = RenderEngine.isRasterInput(file) ? .sensor : .preview
            restoreAdjustmentState(saved.state ?? PhotoEditState(settings: defaults, filmID: ""))
            dirty = false; saveError = nil
            saveWork?.cancel()
            editRevision = UUID()
            schedule(forceExact: true)
        }
    }

    func restoreAdjustmentState(_ snapshot: PhotoEditState) {
        let camera = settings.asShotWhiteBalance, support = settings.supportsRawNoiseReduction
        updatingMetadata = true
        settings = snapshot.settings
        settings.resolveWhiteBalance(camera)
        settings.resolveRawNoiseReductionSupport(support)
        selectedFilmID = snapshot.settings.masterRecipeID != nil ? "" :
            films.first(where: { $0.id == snapshot.filmID || "builtin:\($0.url.lastPathComponent)" == snapshot.filmID })?.id ?? snapshot.filmID
        updatingMetadata = false
    }

    func adjustmentErrorMessage(_ error: Error?) -> String {
        if error is EditPersistenceConflict { return L10n.text("照片或调整已变化，请重新检查目标。") }
        switch error as? AdjustmentTransferError {
        case .emptyScope: return L10n.text("没有可复制的调整，请选择其他范围。")
        case .draftRequiresPreflight: return L10n.text("请先应用或放弃未完成的输入和几何草稿。")
        case .missingLook: return L10n.text("目标所需的外观不可用，请先导入外观。")
        case .unrepresentable: return L10n.text("目标无法保留未选参数，请调整复制范围。")
        case .incompatible: return L10n.text("所选调整与目标不兼容，请调整范围或跳过目标。")
        case .unsupportedVersion, .invalidPayload: return L10n.text("调整内容无法读取，请重新复制。")
        case nil: return error?.localizedDescription ?? L10n.text("操作未完成，请重试。")
        }
    }
}
