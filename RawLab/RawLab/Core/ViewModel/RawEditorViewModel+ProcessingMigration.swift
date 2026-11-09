import Foundation

extension RawEditorViewModel {
    var processingMigrationStatus: String? {
        if matchingProcessing { return "正在匹配原画面…" }
        switch processingMigrationReceipt?.status {
        case .migrated: return "已自动升级，原设置已保留。"
        case .kept: return "画面差异较大，已保留旧版本。"
        case .rolledBack: return "已回退，保留旧版本。"
        case nil: return nil
        }
    }

    func cancelProcessingMigration() {
        processingMigrationCancellation?.cancel()
        processingMigrationCancellation = nil
        matchingProcessing = false
    }

    func startProcessingMigrationIfNeeded(settings: RawSettings) {
        guard let source = editorEditSource, let store = editPersistence else { return }
        processingMigrationReceipt = try? store.processingMigration(for: source.identity)
        guard settings.processing.version < 3, settings.masterRecipeID == nil, !settings.isHDREditing,
              !sourceIsHDR, hasImage, !isBusy, !isExportingHDR, !hasAdjustmentDraft,
              adjustmentInteraction == nil, processingMigrationAttemptSource != sourceRevision,
              let expected = loadedEditRecord, let original = expected.state else { return }
        if let receipt = processingMigrationReceipt,
           !receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) { return }
        let revision = sourceRevision, opening = activeImportRevision, saveRevision = settingsSaveRevision
        let look = lutURL(for: settings), lookIdentity = previewLUTIdentity(for: lutURL(for: settings))
        guard settings.lutID == nil || look != nil else { return }
        let isRaw = sourceKind == .raw
        let cancellation = ProcessingMigrationCancellation()
        let renderer = Sony2FujiProcessor(gpuMode: processor.gpuMode, lensDatabaseURL: processor.lensDatabaseURL)
        let validate = adjustmentSourceValidator
        processingMigrationAttemptSource = revision
        processingMigrationCancellation = cancellation
        matchingProcessing = true
        Self.processingMigrationQueue.async { [weak self] in
            let outcome = Result {
                try validate?()
                let result = try source.file.withReadAccess { url in
                    try renderer.migrateProcessing(url: url, isRaw: isRaw, settings: settings, lutURL: look, cancellation: cancellation)
                }
                try validate?()
                return result
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.processingMigrationCancellation === cancellation else { return }
                self.processingMigrationCancellation = nil
                self.matchingProcessing = false
                guard !cancellation.isCancelled, self.editorEditSource == source, self.sourceRevision == revision,
                      self.activeImportRevision == opening, self.settingsSaveRevision == saveRevision,
                      self.currentPreviewSettings == settings, self.pendingSettings == nil,
                      !self.isBusy, !self.isExportingHDR, !self.hasAdjustmentDraft, self.adjustmentInteraction == nil,
                      self.previewLUTIdentity(for: self.lutURL(for: settings)) == lookIdentity,
                      case .success(let fitted) = outcome else { return }
                do {
                    try validate?()
                    var candidate: PhotoEditState?
                    if fitted.accepted && fitted.quality.passes {
                        var adjusted = original.settings
                        let p = fitted.parameters
                        adjusted.processing = .current
                        adjusted.exposure = p.exposure; adjusted.contrast = p.contrast
                        adjusted.highlights = p.highlights; adjusted.shadows = p.shadows; adjusted.saturation = p.saturation
                        adjusted.blackPoint = p.blackPoint * 100; adjusted.whitePoint = p.whitePoint * 100
                        adjusted.vibrance = p.vibrance * 100; adjusted.clarity = p.clarity * 100; adjusted.dehaze = p.dehaze * 100
                        guard EditorAdjustmentRules.valid(adjusted) else { return }
                        candidate = original.replacing(settings: adjusted, preservingFilmID: original.filmID).withUpdatedAt(Date())
                    }
                    let saved = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: fitted.quality)
                    self.acceptProcessingMigration(saved, source: source, publish: candidate != nil)
                } catch { self.editSaveState = .failed(self.adjustmentErrorMessage(error)) }
            }
        }
    }

    private func acceptProcessingMigration(_ record: PhotoEditRecord, source: EditorEditSource, publish: Bool) {
        loadedEditRecord = record
        adjustmentSession?.adoptProcessingMigration(record)
        processingMigrationReceipt = try? editPersistence?.processingMigration(for: source.identity)
        adjustmentHistoryRevision = UUID()
        guard publish, let state = record.state else { return }
        retainEditMetadata(state)
        pendingSettings = nil
        currentPreviewSettings = state.settings
        committedPreviewSettings = state.settings
        persistedEditorSettings = PersistedEditorSettings(source: source, settings: state.settings)
        adjustmentRestoredSettings = state.settings
        setEditNotice(.saved)
    }

    // UI 先确认恢复完整旧设置；这里仍校验保存状态和原图，避免过期弹窗覆盖新照片。
    func rollbackProcessingMigration(settings: RawSettings) {
        guard processingMigrationReceipt?.status == .migrated, !matchingProcessing, !isBusy,
              !isExportingHDR, !hasAdjustmentDraft, adjustmentInteraction == nil,
              let source = editorEditSource, let store = editPersistence, saveCurrentSettings(settings),
              let expected = loadedEditRecord else { return }
        cancelProcessingMigration()
        do {
            try adjustmentSourceValidator?()
            let saved = try store.rollbackProcessingMigration(expected: expected)
            acceptProcessingMigration(saved, source: source, publish: true)
        } catch { editSaveState = .failed(adjustmentErrorMessage(error)) }
    }
}
