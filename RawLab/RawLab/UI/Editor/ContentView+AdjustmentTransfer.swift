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
    }

    func requestAdjustmentAction(_ action: IOSAdjustmentAction) {
        guard !editorBusy, viewModel.hasImage else { return }
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
