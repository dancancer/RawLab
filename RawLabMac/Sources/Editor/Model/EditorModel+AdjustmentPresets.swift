import AppKit

enum QuickPresetState {
    case idle, preparing(AdjustmentPreset), saved(AdjustmentPreset, UUID), unchanged(AdjustmentPreset), undone(AdjustmentPreset)
    case failed(AdjustmentPreset, String), undoFailed(AdjustmentPreset, UUID, String)
    var isPreparing: Bool { if case .preparing = self { return true }; return false }
}

extension EditorModel {
    var canUsePresetPhoto: Bool {
        file != nil && !exporting && !lookLibraryBusy && !aiState.isRunning && !geometryDraftDeparturePending
    }

    @discardableResult func preparePresetAction(onStay: @escaping () -> Void = {}, _ action: @escaping () -> Void) -> Bool {
        guard canUsePresetPhoto, ParameterValueField.resolvePendingInputs() else { return false }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { return false }
        if geometryDraft != nil { requestLeavingGeometryDraft(action, onStay: onStay) }
        else { action() }
        return true
    }

    func showQuickPresets() {
        guard file != nil, !exporting, !importing, !lookLibraryBusy else { return }
        cancelHSLTarget()
        if [.colorGrading, .toneCurve].contains(adjustmentNavigation.tool) { cancelAdjustmentInteraction() }
        adjustmentNavigation.selectTool(.film)
        quickPresetsVisible = true
    }

    func closeQuickPresets() {
        let wasVisible = quickPresetsVisible
        quickPresetsVisible = false
        cancelQuickPreset()
        if wasVisible && geometryDraft != nil { adjustmentNavigation.selectTool(geometryDraftTab == .lens ? .lens : .geometry) }
    }

    func cancelQuickPreset() {
        quickPresetGeneration = UUID()
        quickPresetState = .idle
    }

    func applyPresetToCurrentPhoto(_ preset: AdjustmentPreset) {
        guard quickPresetsVisible, canUsePresetPhoto, !importing, !quickPresetState.isPreparing, let file else { return }
        let source = sourceRevision, generation = UUID()
        quickPresetGeneration = generation
        let accepted = preparePresetAction(onStay: { [weak self] in
            if self?.quickPresetGeneration == generation { self?.cancelQuickPreset() }
        }) { [weak self] in
            guard let self, self.quickPresetsVisible, self.quickPresetGeneration == generation,
                  self.sourceRevision == source, self.file == file else { return }
            do {
                let session = try self.requireAdjustmentSession()
                guard let expected = self.committedEdit, try self.editStore!.versionedState(for: file) == expected else {
                    throw EditPersistenceConflict.changed
                }
                let revision = self.editRevision
                let targets = self.adjustmentTransferTargets([file], payload: preset.payload)
                let prepare = self.prepareQuickPresetOperation
                self.quickPresetState = .preparing(preset)
                self.quickPresetQueue.async { [weak self] in
                    let result = Result { try prepare(session, preset.payload, targets) }
                    DispatchQueue.main.async {
                        guard let self, self.quickPresetGeneration == generation, self.quickPresetsVisible else { return }
                        guard self.sourceRevision == source, self.file == file, self.editRevision == revision,
                              self.adjustmentSession === session, !self.importing, !self.exporting, !self.dirty,
                              self.geometryDraft == nil, !self.scheduler.interacting, !self.aiState.isRunning else {
                            self.cancelQuickPreset(); return
                        }
                        do {
                            let operation = try result.get()
                            if let error = operation.targets.first?.error { throw error }
                            guard operation.targets.count == 1, operation.targets.first?.original == expected,
                                  self.committedEdit == expected else { throw EditPersistenceConflict.changed }
                            self.applyAdjustmentPaste(operation)
                            guard let outcome = self.adjustmentOutcomes.first, let saved = outcome.saved,
                                  self.committedEdit == saved else {
                                throw self.adjustmentOutcomes.first?.error ?? EditPersistenceConflict.changed
                            }
                            switch outcome.status {
                            case .applied: self.quickPresetState = .saved(preset, operation.id)
                            case .unchanged: self.quickPresetState = .unchanged(preset)
                            default: throw outcome.error ?? EditPersistenceConflict.changed
                            }
                        } catch { self.quickPresetState = .failed(preset, self.quickPresetErrorMessage(error)) }
                    }
                }
            } catch { self.quickPresetState = .failed(preset, self.quickPresetErrorMessage(error)) }
        }
        if !accepted { quickPresetState = .failed(preset, saveError ?? adjustmentErrorMessage(AdjustmentTransferError.draftRequiresPreflight)) }
    }

    private func quickPresetErrorMessage(_ error: Error) -> String {
        switch error as? AdjustmentTransferError {
        case .incompatible(let field) where field == "hdr.relative_white_balance":
            return L10n.text("此预设包含 HDR 相对白平衡，当前编辑模式不支持。")
        case .incompatible(let field) where field.hasPrefix("select white balance mode"):
            return L10n.text("请将白平衡模式、色温和色调一起保存，再应用此预设。")
        case .incompatible(let field) where field == "target camera white balance unavailable":
            return L10n.text("此照片没有可用的相机白平衡校准。")
        case .incompatible(let field) where !field.hasPrefix("ai."):
            return L10n.text("此预设与当前照片不兼容，请选择其他预设。")
        case .unrepresentable:
            return L10n.text("此预设无法保留照片的其他调整，请选择其他预设。")
        default: return adjustmentErrorMessage(error)
        }
    }

    func undoQuickPreset() {
        let preset: AdjustmentPreset, transaction: UUID
        switch quickPresetState {
        case .saved(let value, let id), .undoFailed(let value, let id, _): preset = value; transaction = id
        default: return
        }
        guard quickPresetsVisible, canUsePresetPhoto, geometryDraft == nil,
              ParameterValueField.resolvePendingInputs(), saveEdits() else { return }
        changeAdjustmentTransaction(transaction, undo: true)
        if let outcome = adjustmentOutcomes.first, outcome.status == .applied, outcome.saved == committedEdit {
            quickPresetState = .undone(preset)
        } else {
            quickPresetState = .undoFailed(preset, transaction, adjustmentErrorMessage(adjustmentOutcomes.first?.error))
        }
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
