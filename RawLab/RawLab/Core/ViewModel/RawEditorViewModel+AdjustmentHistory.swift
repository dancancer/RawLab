import Foundation

struct IOSAdjustmentInteraction {
    let source: EditorEditSource
    let before: RawSettings
}

struct IOSAdjustmentHistoryRequest {
    let transactionID: UUID
    let photo: PhotoIdentity?
    let undo: Bool
}

private struct IOSAdjustmentSourceStamp: Equatable {
    let size: UInt64
    let modified: Date
    let number: UInt64

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        self.size = size.uint64Value; self.modified = modified; self.number = number.uint64Value
    }
}

extension RawEditorViewModel {
    var sourceDefaultSettings: RawSettings {
        get throws {
            guard let source = editorEditSource else { throw EditPersistenceError.corruptStore }
            return try source.file.withReadAccess { try processor.defaultSettings(for: $0, isRaw: sourceKind == .raw) }
        }
    }
    static func adjustmentSourceValidation(_ file: PhotoSourceFile) throws -> () throws -> Void {
        let original = try file.withReadAccess { try IOSAdjustmentSourceStamp($0) }
        return {
            guard try file.withReadAccess({ try IOSAdjustmentSourceStamp($0) }) == original else {
                throw AdjustmentCommitError.photoChanged
            }
        }
    }

    func acceptImportedEditRecord(_ record: PhotoEditRecord?, settings: RawSettings) {
        loadedEditRecord = record
        processingMigrationReceipt = record.flatMap { try? editPersistence?.processingMigration(for: $0.identity) }
        adjustmentInteraction = nil
        adjustmentInteractionRejected = false
        adjustmentRestoredSettings = nil
        includeIndependentRecipeLook(settings)
        retainEditMetadata(record?.state ?? PhotoEditState(settings: settings, updatedAt: Date(timeIntervalSince1970: 0)))
        if let source = editorEditSource {
            do { adjustmentSourceValidator = try Self.adjustmentSourceValidation(source.file) }
            catch { adjustmentSourceValidator = { throw error } }
            if let validate = adjustmentSourceValidator { adjustmentSession?.refreshSource(source.identity, validate: validate) }
        }
        adjustmentHistoryRevision = UUID()
    }

    @discardableResult
    func beginAdjustmentInteraction(settings: RawSettings) -> Bool {
        cancelProcessingMigration()
        guard !isBusy, !hasAdjustmentDraft, adjustmentInteraction == nil, let source = editorEditSource else { return false }
        guard saveCurrentSettings(settings) else { adjustmentInteractionRejected = true; return false }
        adjustmentInteractionRejected = false
        adjustmentInteraction = IOSAdjustmentInteraction(source: source, before: settings)
        cancelQueuedSettingsSave()
        return true
    }

    @discardableResult
    func endAdjustmentInteraction(settings: RawSettings) -> Bool {
        defer { adjustmentInteractionRejected = false }
        guard let interaction = adjustmentInteraction else { return !adjustmentInteractionRejected }
        adjustmentInteraction = nil
        guard interaction.source == editorEditSource else { return false }
        queueSettingsSave(settings)
        return saveCurrentSettings(settings)
    }

    func cancelAdjustmentInteraction() -> RawSettings? {
        let interaction = adjustmentInteraction
        adjustmentInteraction = nil
        adjustmentInteractionRejected = false
        guard let interaction, interaction.source == editorEditSource else { return nil }
        cancelQueuedSettingsSave()
        pendingSettings = nil
        pendingResetMigrationClear = nil
        if let record = loadedEditRecord?.state { retainEditMetadata(record) }
        persistedEditorSettings = PersistedEditorSettings(source: interaction.source, settings: interaction.before)
        committedPreviewSettings = interaction.before
        currentPreviewSettings = interaction.before
        return interaction.before
    }

    var canUndoAdjustment: Bool { sourceIdentity.map { adjustmentSession?.canUndoPhoto($0) == true } ?? false }
    var canRedoAdjustment: Bool { sourceIdentity.map { adjustmentSession?.canRedoPhoto($0) == true } ?? false }

    func adjustmentTargetIsCurrent(_ identity: String) -> Bool {
        guard sourceIdentity?.key == identity else { return true }
        return !isBusy && pendingSettings == nil && adjustmentInteraction == nil && !hasAdjustmentDraft && !hasFailedDraftSave
    }

    @discardableResult
    func performAdjustmentHistory(undo: Bool, transactionID: UUID? = nil, wholeTransaction: Bool = false,
                                  skipping: Set<String> = []) -> [IOSAdjustmentTransferOutcome] {
        guard let session = adjustmentSession, let identity = sourceIdentity,
              let id = transactionID ?? session.photoHistoryID(identity, undo: undo) else { return [] }
        let request = IOSAdjustmentHistoryRequest(transactionID: id, photo: wholeTransaction ? nil : identity, undo: undo)
        adjustmentHistoryRequest = request
        return executeAdjustmentHistory(request, skipping: skipping)
    }

    @discardableResult
    func executeAdjustmentHistory(_ request: IOSAdjustmentHistoryRequest,
                                  skipping: Set<String> = []) -> [IOSAdjustmentTransferOutcome] {
        guard let session = adjustmentSession else { return [] }
        let guardCurrent: (String) -> Bool = { [weak self] in self?.adjustmentTargetIsCurrent($0) == true }
        let results: [IOSAdjustmentTransferOutcome]
        if let photo = request.photo {
            results = request.undo
                ? session.undoPhoto(photo, transactionID: request.transactionID, isCurrent: guardCurrent)
                : session.redoPhoto(photo, transactionID: request.transactionID, isCurrent: guardCurrent)
        } else {
            results = request.undo
                ? session.undoTransaction(request.transactionID, skipping: skipping, isCurrent: guardCurrent)
                : session.redoTransaction(request.transactionID, skipping: skipping, isCurrent: guardCurrent)
        }
        acceptAdjustmentOutcomes(results)
        adjustmentHistoryResults = results
        return results
    }

    func acceptAdjustmentOutcomes(_ results: [IOSAdjustmentTransferOutcome]) {
        for result in results where result.status == .applied || result.status == .unchanged {
            guard let saved = result.saved, saved.identity == sourceIdentity,
                  adjustmentTargetIsCurrent(result.targetID),
                  adjustmentSession?.isCurrentSave(saved) == true else { continue }
            if !quickPresetState.isPreparing { cancelQuickPreset() }
            // 旧操作的缓存回执不能覆盖后来已保存的编辑或尚未保存的界面。
            if let state = saved.state {
                includeIndependentRecipeLook(state.settings)
                recordSavedLookChange(from: loadedEditRecord?.state, to: state)
            }
            loadedEditRecord = saved
            pendingResetMigrationClear = nil
            let state: PhotoEditState
            do { state = try saved.state ?? PhotoEditState(settings:sourceDefaultSettings,updatedAt:Date(timeIntervalSince1970:0)) }
            catch { editSaveState = .failed(adjustmentErrorMessage(error)); continue }
            retainEditMetadata(state)
            includeIndependentRecipeLook(state.settings)
            committedPreviewSettings = state.settings
            currentPreviewSettings = state.settings
            if let source = editorEditSource { persistedEditorSettings = PersistedEditorSettings(source: source, settings: state.settings) }
            adjustmentRestoredSettings = state.settings
            setEditNotice(.saved)
        }
        adjustmentHistoryRevision = UUID()
    }

    func adjustmentErrorMessage(_ error: Error?) -> String {
        if let error = error as? AdjustmentCommitError {
            switch error {
            case .photoChanged: return L10n.text("原始文件已被替换，请重新选择照片。")
            case .expired: return L10n.text("此操作已过期，请重新操作。")
            case .historyOrder: return L10n.text("请按历史顺序撤销或重做。")
            }
        }
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
