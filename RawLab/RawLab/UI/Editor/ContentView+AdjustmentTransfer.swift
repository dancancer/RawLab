import SwiftUI

extension ContentView {
    @ViewBuilder var adjustmentTransferMenu: some View {
        Button(L10n.text("复制调整")) { requestAdjustmentAction(.copy) }
            .accessibilityIdentifier("adjustment.copy.open")
        Button(L10n.text("粘贴调整")) { requestAdjustmentAction(.paste) }
            .disabled(viewModel.adjustmentSession?.clipboard == nil).accessibilityIdentifier("adjustment.paste.open")
        Button(L10n.text("撤销")) { requestAdjustmentAction(.undo) }
            .disabled(!viewModel.canUndoAdjustment).accessibilityIdentifier("adjustment.history.undo")
        Button(L10n.text("重做")) { requestAdjustmentAction(.redo) }
            .disabled(!viewModel.canRedoAdjustment).accessibilityIdentifier("adjustment.history.redo")
        Button(L10n.text("本次会话历史")) { requestAdjustmentAction(.history) }
            .accessibilityIdentifier("adjustment.history.open")
        Button(L10n.text("我的预设"), action: showQuickPresets)
            .accessibilityIdentifier("preset.library.open")
    }

    func showQuickPresets() {
        guard !editorBusy, viewModel.hasImage else { return }
        cancelSliderInteraction(); cancelHSLTarget()
        viewModel.quickPresetsVisible = true
        selectedGroup = .looks
        adjustmentsExpanded = true
    }

    func closeQuickPresets() {
        viewModel.closeQuickPresets()
        selectedGroup = EditorAdjustmentRules.groupFor(currentEditorTool)
    }

    func undoQuickPreset() {
        cancelSliderInteraction()
        viewModel.undoQuickPreset(settings: settings)
    }

    func queuePresetAction(_ action: IOSAdjustmentAction) {
        // 先关闭管理页，再由 editor 统一处理草稿确认，避免两个 sheet 同时展示。
        queuedPresetAction = action
        adjustmentSheet = nil
    }

    func finishAdjustmentSheet() {
        presetLibraryRevision = UUID()
        if let action = queuedPresetAction {
            queuedPresetAction = nil
            requestAdjustmentAction(action)
        } else if returnToPresetLibrary {
            returnToPresetLibrary = false
            applyingPreset = nil
            adjustmentSheet = .presets
        } else { applyingPreset = nil }
    }

    func requestAdjustmentAction(_ action: IOSAdjustmentAction) {
        guard !editorBusy, viewModel.hasImage else { return }
        if viewModel.quickPresetState.isPreparing { return }
        cancelSliderInteraction()
        pendingAdjustmentAction = action
        if isEditorDraftChanged { draftExitPresented = true; return }
        if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
        continueAdjustmentAction()
    }

    func continueAdjustmentAction() {
        guard let action = pendingAdjustmentAction, viewModel.saveCurrentSettings(settings) else { return }
        pendingAdjustmentAction = nil
        viewModel.hasAdjustmentDraft = false
        switch action {
        case .copy: adjustmentSheet = .copy
        case .paste: adjustmentSheet = .paste
        case .presetSave: adjustmentSheet = .presetSave
        case .presetApply(let preset):
            showQuickPresets()
            viewModel.applyPresetToCurrentPhoto(preset, settings: settings)
        case .presetApplyMultiple(let preset):
            applyingPreset = preset
            returnToPresetLibrary = true
            adjustmentSheet = .presetApply
        case .history:
            viewModel.adjustmentHistoryResults = []
            viewModel.adjustmentHistoryRequest = nil
            adjustmentSheet = .history
        case .undo, .redo:
            let results = viewModel.performAdjustmentHistory(undo: action == .undo)
            if results.contains(where: { [.failed, .blocked, .conflict].contains($0.status) }) { adjustmentSheet = .history }
        }
    }
}
