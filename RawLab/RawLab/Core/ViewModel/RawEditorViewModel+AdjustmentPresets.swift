import Foundation

enum IOSQuickPresetState {
    case idle, preparing(AdjustmentPreset), saved(AdjustmentPreset, UUID), unchanged(AdjustmentPreset), undone(AdjustmentPreset)
    case failed(AdjustmentPreset, String), undoFailed(AdjustmentPreset, UUID, String)
    var isPreparing: Bool { if case .preparing = self { return true }; return false }
}

extension RawEditorViewModel {
    func closeQuickPresets() { quickPresetsVisible = false }

    func cancelQuickPreset() {
        if quickPresetState.isPreparing { cancelAdjustmentPreparation() }
        quickPresetGeneration = UUID()
        quickPresetState = .idle
    }

    func applyPresetToCurrentPhoto(_ preset: AdjustmentPreset, settings: RawSettings) {
        guard quickPresetsVisible, hasImage, !isBusy, !adjustmentPreparing, !quickPresetState.isPreparing,
              let source = editorEditSource, let photo = currentAdjustmentPhoto else { return }
        do {
            guard saveCurrentSettings(settings), !hasAdjustmentDraft, !adjustmentReloadRequired,
                  adjustmentTargetIsCurrent(photo.id), let session = adjustmentSession,
                  let expected = loadedEditRecord, expected.identity == source.identity,
                  currentEditState(settings: settings).hasSameAdjustments(as: expected.state ?? PhotoEditState(settings: sourceDefaultSettings)) else {
                throw AdjustmentTransferError.draftRequiresPreflight
            }
            guard try editPersistence?.versionedState(for: source.identity) == expected else { throw EditPersistenceConflict.changed }
            let generation = UUID(), revision = settingsSaveRevision
            quickPresetGeneration = generation
            quickPresetState = .preparing(preset)
            prepareAdjustmentPaste(preset.payload, photos: [photo], action: .preset) { [weak self] result in
                guard let self, self.quickPresetGeneration == generation, self.quickPresetsVisible else { return }
                guard self.editorEditSource == source, self.settingsSaveRevision == revision,
                      self.adjustmentSession === session, self.adjustmentTargetIsCurrent(photo.id) else {
                    self.cancelQuickPreset(); return
                }
                do {
                    let operation = try result.get()
                    if let error = operation.targets.first?.error { throw error }
                    guard operation.targets.count == 1, operation.targets.first?.original == expected,
                          self.loadedEditRecord == expected else { throw EditPersistenceConflict.changed }
                    let outcomes = self.applyAdjustmentPaste(operation, skipping: [])
                    guard let outcome = outcomes.first, let saved = outcome.saved, self.loadedEditRecord == saved else {
                        throw outcomes.first?.error ?? EditPersistenceConflict.changed
                    }
                    switch outcome.status {
                    case .applied: self.quickPresetState = .saved(preset, operation.id)
                    case .unchanged: self.quickPresetState = .unchanged(preset)
                    default: throw outcome.error ?? EditPersistenceConflict.changed
                    }
                } catch { self.quickPresetState = .failed(preset, self.quickPresetErrorMessage(error)) }
            }
        } catch { quickPresetState = .failed(preset, quickPresetErrorMessage(error)) }
    }

    func undoQuickPreset(settings: RawSettings) {
        let preset: AdjustmentPreset, transaction: UUID
        switch quickPresetState {
        case .saved(let value, let id), .undoFailed(let value, let id, _): preset = value; transaction = id
        default: return
        }
        guard quickPresetsVisible, !isBusy, !hasAdjustmentDraft, saveCurrentSettings(settings) else { return }
        let results = performAdjustmentHistory(undo: true, transactionID: transaction)
        if let outcome = results.first, outcome.status == .applied, outcome.saved == loadedEditRecord {
            quickPresetState = .undone(preset)
        } else { quickPresetState = .undoFailed(preset, transaction, adjustmentErrorMessage(results.first?.error)) }
    }

    private func quickPresetErrorMessage(_ error: Error) -> String {
        switch error as? AdjustmentTransferError {
        case .incompatible(let field) where field == "hdr.relative_white_balance":
            return L10n.text("此预设包含 HDR 相对白平衡，当前编辑模式不支持。")
        case .incompatible(let field) where field.hasPrefix("select white balance mode"):
            return L10n.text("请将白平衡模式、色温和色调一起保存，再应用此预设。")
        case .incompatible(let field) where field == "target camera white balance unavailable":
            return L10n.text("此照片没有可用的相机白平衡校准。")
        case .incompatible: return L10n.text("此预设与当前照片不兼容，请选择其他预设。")
        case .unrepresentable: return L10n.text("此预设无法保留照片的其他调整，请选择其他预设。")
        default: return adjustmentErrorMessage(error)
        }
    }

    func previewAdjustmentPayload(scope: AdjustmentTransferScope, settings: RawSettings) throws -> AdjustmentTransferPayload {
        guard let source = editorEditSource, let record = loadedEditRecord,
              record.identity == source.identity, !adjustmentReloadRequired,
              adjustmentTargetIsCurrent(source.identity.key) else { throw AdjustmentTransferError.draftRequiresPreflight }
        let committed = record.state ?? PhotoEditState(settings: sourceDefaultSettings)
        return try IOSAdjustmentTransfer.previewCapture(scope: scope, snapshot: currentEditState(settings: settings),
            committed: committed, context: adjustmentContext(identifier: source.identity.key,
                isRaw: sourceKind == .raw, whiteBalance: rawWhiteBalance))
    }

    func adjustmentSummaryLookName(kind: String, id: String) -> String? {
        if kind == "recipe" || kind == "recipe_lut" {
            guard let recipe = MasterRecipe.recipe(for: id), let url = recipe.lutURL(),
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return L10n.text(recipe.name)
        }
        let reference = kind == "builtin"
            ? lutMap.values.first { !$0.isCustom && $0.sourceURL.lastPathComponent == id } : lutMap[id]
        guard let reference, FileManager.default.isReadableFile(atPath: reference.sourceURL.path) else { return nil }
        return reference.name
    }

    func capturePresetAdjustments(scope: AdjustmentTransferScope, settings: RawSettings) throws -> AdjustmentTransferPayload {
        guard let source = editorEditSource, adjustmentSession != nil,
              adjustmentTargetIsCurrent(source.identity.key) else { throw AdjustmentTransferError.draftRequiresPreflight }
        guard let expected = loadedEditRecord, expected.identity == source.identity,
              let persistence = editPersistence, try persistence.versionedState(for: source.identity) == expected else {
            adjustmentReloadRequired = true
            editSaveState = .failed(adjustmentErrorMessage(EditPersistenceConflict.changed))
            throw EditPersistenceConflict.changed
        }
        let snapshot = currentEditState(settings: settings)
        guard snapshot.hasSameAdjustments(as: expected.state ?? PhotoEditState(settings: sourceDefaultSettings)) else {
            throw AdjustmentTransferError.draftRequiresPreflight
        }
        let context = adjustmentContext(identifier: source.identity.key, isRaw: sourceKind == .raw, whiteBalance: rawWhiteBalance)
        try adjustmentSourceValidator?()
        // 保存预设复用纯 capture，不能改变当前复制内容或照片历史。
        return try IOSAdjustmentTransfer.capture(scope: scope, snapshot: snapshot, context: context)
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
            if error is EditPersistenceConflict { return adjustmentErrorMessage(error) }
            if error is AdjustmentTransferError { return adjustmentErrorMessage(error) }
            return L10n.format("预设操作未完成：%@", error.localizedDescription)
        }
    }
}
