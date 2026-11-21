import RawLabKit
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

    func showQuickPresets() { coordinator.showQuickPresets() }
    func closeQuickPresets() { coordinator.closeQuickPresets() }

    func undoQuickPreset() {
        cancelSliderInteraction()
        viewModel.undoQuickPreset(settings: settings)
    }

    func queuePresetAction(_ action: IOSAdjustmentAction) { coordinator.queuePresetAction(action) }
    func finishAdjustmentSheet() { coordinator.finishAdjustmentSheet() }
    func requestAdjustmentAction(_ action: IOSAdjustmentAction) { coordinator.requestAdjustmentAction(action) }
    func continueAdjustmentAction() { coordinator.continueAdjustmentAction() }
}
