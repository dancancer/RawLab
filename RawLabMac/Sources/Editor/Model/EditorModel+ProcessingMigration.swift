import AppKit

extension EditorModel {
    var processingMigrationStatus: String? {
        if matchingProcessing { return "正在匹配原画面…" }
        switch processingMigrationReceipt?.status {
        case .migrated: return "已自动升级，原设置已保留。"
        case .kept: return "画面差异较大，已保留旧版本。"
        case .rolledBack: return "已回退，保留旧版本。"
        case nil: return nil
        }
    }

    var canRollbackProcessingMigration: Bool {
        processingMigrationReceipt?.status == .migrated && !matchingProcessing && !importing &&
            !exporting && !scheduler.interacting && !aiState.isRunning && geometryDraft == nil
    }

    func cancelProcessingMigration() {
        processingMigrationCancellation?.cancel()
        processingMigrationCancellation = nil
        matchingProcessing = false
    }

    func startProcessingMigrationIfNeeded() {
        guard let file, result != nil, !busy, !importing, !dirty, !exporting, !autoExposing,
              !scheduler.interacting, !ParameterValueField.hasPendingInputs, !aiState.isRunning, geometryDraft == nil,
              !settings.isHDREditing, !settings.activeAIDenoise, settings.masterRecipeID == nil,
              settings.processing.version < 3, !sourceUsesSDRFallback,
              processingMigrationAttemptSource != sourceRevision,
              let expected = committedEdit, let original = expected.state,
              let store = editStore else { return }
        if let receipt = processingMigrationReceipt,
           !receipt.shouldAttempt(current: original, sourceVersion: original.settings.processing.version) { return }
        let snapshot = settings, source = sourceRevision, edit = editRevision, opening = pendingOpenID
        let look = selectedFilm?.url
        guard selectedFilmID.isEmpty || look != nil else { return }
        let lookIdentity = look.flatMap { try? OriginalFileIdentity($0) }
        guard look == nil || lookIdentity != nil else { return }
        let cancellation = ProcessingMigrationCancellation()
        processingMigrationAttemptSource = source
        processingMigrationCancellation = cancellation
        matchingProcessing = true
        Self.processingMigrationQueue.async { [weak self] in
            let outcome = Result {
                try expected.identity.requireCurrent()
                try lookIdentity?.requireCurrent()
                let result = try RenderEngine().migrateProcessing(file, settings: snapshot, lut: look, cancellation: cancellation)
                try expected.identity.requireCurrent()
                try lookIdentity?.requireCurrent()
                return result
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.processingMigrationCancellation === cancellation else { return }
                self.processingMigrationCancellation = nil
                self.matchingProcessing = false
                guard !cancellation.isCancelled, self.file == file, self.sourceRevision == source,
                      self.pendingOpenID == opening, self.editRevision == edit, self.settings == snapshot,
                      self.selectedFilm?.url == look, !self.dirty, !self.exporting,
                      !self.scheduler.interacting, !ParameterValueField.hasPendingInputs,
                      self.geometryDraft == nil, !self.aiState.isRunning,
                      case .success(let fitted) = outcome else { return }
                do {
                    try lookIdentity?.requireCurrent()
                    var candidate: PhotoEditState?
                    if fitted.accepted && fitted.quality.passes {
                        var adjusted = original.settings
                        let p = fitted.parameters
                        adjusted.processing = .current
                        adjusted.exposure = p.exposure
                        adjusted.contrast = (p.contrast - 1) * 100
                        adjusted.highlights = -p.highlights * 100
                        adjusted.shadows = p.shadows * 100
                        adjusted.saturation = (p.saturation - 1) * 100
                        adjusted.blackPoint = p.blackPoint * 100
                        adjusted.whitePoint = p.whitePoint * 100
                        adjusted.vibrance = p.vibrance * 100
                        adjusted.clarity = p.clarity * 100
                        adjusted.dehaze = p.dehaze * 100
                        candidate = PhotoEditState(settings: adjusted, filmID: original.filmID,
                            masterRecipeID: original.masterRecipeID)
                    }
                    let saved = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: fitted.quality)
                    self.committedEdit = saved
                    self.adjustmentSession?.adoptProcessingMigration(saved)
                    self.processingMigrationReceipt = try store.processingMigration(for: file)
                    if candidate != nil, let state = saved.state {
                        self.restoreAdjustmentState(state)
                        self.editRevision = UUID()
                        self.dirty = false
                        self.schedule(forceExact: true)
                    }
                } catch {
                    self.saveError = L10n.format("调整未保存：%@", self.adjustmentErrorMessage(error))
                }
            }
        }
    }

    func rollbackProcessingMigration() {
        guard canRollbackProcessingMigration, let file, ParameterValueField.resolvePendingInputs(),
              saveEdits(), let expected = committedEdit, let store = editStore else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("回到迁移前")
        alert.informativeText = L10n.text("将恢复迁移前的全部调整，之后的修改会被替换。")
        alert.addButton(withTitle: L10n.text("回到迁移前"))
        alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelProcessingMigration()
        do {
            let saved = try store.rollbackProcessingMigration(expected: expected)
            committedEdit = saved
            adjustmentSession?.adoptProcessingMigration(saved)
            processingMigrationReceipt = try store.processingMigration(for: file)
            if let state = saved.state { restoreAdjustmentState(state) }
            editRevision = UUID()
            dirty = false
            schedule(forceExact: true)
        } catch { saveError = L10n.format("调整未保存：%@", adjustmentErrorMessage(error)) }
    }
}
