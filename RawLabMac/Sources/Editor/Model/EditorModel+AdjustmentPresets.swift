import AppKit

extension EditorModel {
    var canUsePresetPhoto: Bool {
        file != nil && !exporting && !lookLibraryBusy && !aiState.isRunning && !geometryDraftDeparturePending
    }

    func preparePresetAction(_ action: @escaping () -> Void) {
        guard canUsePresetPhoto, ParameterValueField.resolvePendingInputs() else { return }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { return }
        if geometryDraft != nil { requestLeavingGeometryDraft(action) }
        else { action() }
    }

    func capturePresetAdjustments(scope: AdjustmentTransferScope) throws -> AdjustmentTransferPayload {
        guard canUsePresetPhoto, let file, geometryDraft == nil else { throw AdjustmentTransferError.draftRequiresPreflight }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { throw AdjustmentTransferError.draftRequiresPreflight }
        guard let committedEdit, let editStore, try editStore.versionedState(for: file) == committedEdit else {
            throw EditPersistenceConflict.changed
        }
        // 预设保存不能借用 session.copy；剪贴板与库是两个独立用户动作。
        return try MacAdjustmentTransfer.capture(scope: scope, snapshot: editState(settings: settings),
            context: adjustmentTransferContext(for: file))
    }

    func previewAdjustmentPayload(scope: AdjustmentTransferScope) throws -> AdjustmentTransferPayload {
        guard canUsePresetPhoto, let file, let committedEdit,
              committedEdit.identity.path == file.resolvingSymlinksInPath().standardizedFileURL.path,
              !dirty, geometryDraft == nil, !scheduler.interacting,
              !ParameterValueField.hasPendingInputs, saveError == nil else {
            throw AdjustmentTransferError.draftRequiresPreflight
        }
        return try MacAdjustmentTransfer.previewCapture(scope: scope, snapshot: editState(settings: settings),
            committed: committedEdit.state, context: adjustmentTransferContext(for: file))
    }

    func adjustmentSummaryLookName(kind: String, id: String) -> String? {
        if kind == "recipe" || kind == "recipe_lut" {
            guard let recipe = MasterRecipe.recipe(for: id), let url = recipe.lutURL(),
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return recipe.title
        }
        return films.first { (kind == "builtin" ? $0.url.lastPathComponent == id : $0.managedID == id) &&
            FileManager.default.isReadableFile(atPath: $0.url.path) }?.name
    }

    func presetErrorMessage(_ error: Error) -> String {
        switch error as? AdjustmentPresetError {
        case .emptyName: return L10n.text("请输入预设名称。")
        case .duplicateName: return L10n.text("同名预设已存在，请使用其他名称。")
        case .changed: return L10n.text("预设已变化，请重新载入列表后重试。")
        case .corruptLibrary: return L10n.text("预设库无法读取，原文件保持不变。请从备份恢复后重试。")
        case .unsupportedVersion: return L10n.text("此预设库来自更新版本，请更新应用后重试。")
        case .identityCollision: return L10n.text("无法创建新的预设标识，请重试。")
        case nil:
            if error is AdjustmentTransferError || error is EditPersistenceConflict { return adjustmentErrorMessage(error) }
            return L10n.format("预设操作未完成：%@", error.localizedDescription)
        }
    }
}
