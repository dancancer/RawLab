import Foundation

extension RawEditorViewModel {
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
        guard snapshot.hasSameAdjustments(as: expected.state ?? PhotoEditState(settings: .default)) else {
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
