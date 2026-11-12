import SwiftUI

enum IOSCollectionNavigation { case edit(String), returnToCollection }

extension ContentView {
    func openBatchSelection() {
        cancelHSLTarget()
        if let photo = viewModel.currentAdjustmentPhoto { viewModel.batchSelection.append(photo) }
        showingBatchSelection = true
    }

    func finishBatchSelection() {
        if collectionBatchHandoff.promote(sceneIsActive: scenePhase == .active, configure: { model in
            batchModel = model
            model.onUsage = { UsageAnalytics.shared.record($0) }
            model.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
        }) != nil {
            showingBatchExport = true
        } else if let id = queuedCollectionEdit {
            queuedCollectionEdit = nil
            requestCollectionNavigation(.edit(id))
        } else if queuedCollectionExistingBatch {
            queuedCollectionExistingBatch = false
            showingBatchExport = true
        }
    }

    func requestCollectionNavigation(_ action: IOSCollectionNavigation) {
        guard !editorBusy else { return }
        cancelSliderInteraction()
        pendingCollectionNavigation = action
        if isEditorDraftChanged { draftExitPresented = true; return }
        if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
        continueCollectionNavigation()
    }

    func continueCollectionNavigation() {
        guard let action = pendingCollectionNavigation, viewModel.saveCurrentSettings(settings) else { return }
        pendingCollectionNavigation = nil
        switch action {
        case .returnToCollection:
            viewModel.batchSelection.selection.returnToCollection()
            showingBatchSelection = true
        case .edit(let id):
            guard let stored = viewModel.batchSelection.photos[id] else { return }
            isImporting = true
            Task { await openCollectionPhoto(stored) }
        }
    }

    @MainActor
    private func openCollectionPhoto(_ stored: IOSCollectionPhoto) async {
        do {
            try stored.validate()
            guard let file = stored.photo.file else { throw CocoaError(.fileReadNoSuchFile) }
            let resolved = try await resolveLegacyAssetEdit(for: stored.photo.identity)
            try Task.checkCancellation()
            if resolved { try stored.validate() }
            if !resolved, viewModel.sourceIdentity == stored.photo.identity {
                _ = viewModel.batchSelection.selection.beginEditing(stored.id)
                isImporting = false
                return
            }
            file.withReadAccess { url in
                viewModel.importImage(from: stored.photo.isRaw ? .raw(url) : .raster(url), identity: stored.photo.identity,
                    retainedInput: file, diagnosticContext: ["entryPoint": "batchSelection"], onSettingsRestored: { restored in
                        settings = restored
                        viewModel.sourceDisplayName = stored.photo.displayName
                        _ = viewModel.batchSelection.selection.beginEditing(stored.id)
                    })
            }
        } catch is CancellationError {
            isImporting = false
        } catch {
            isImporting = false
            viewModel.reportError(error, operation: .photoImport, stage: "readBatchSelection",
                                  context: ["entryPoint": "batchSelection"])
        }
    }

    func resolveCollectionDraft(_ key: String, apply: Bool) -> Bool {
        guard viewModel.sourceIdentity?.key == key, !editorBusy else { return false }
        if apply {
            if viewModel.adjustmentInteraction != nil {
                guard viewModel.endAdjustmentInteraction(settings: settings) else { return false }
                isAdjustingSlider = false
            }
            if isEditorDraftChanged && !commitEditorDraft() { return false }
            if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
            viewModel.hasAdjustmentDraft = false
            return viewModel.saveCurrentSettings(settings)
        }
        cancelSliderInteraction()
        discardEditorDraft()
        activateEditorTool(.adjustment(.exposure))
        viewModel.hasAdjustmentDraft = false
        do {
            let restored = try viewModel.restoreCommittedSettings()
            settings = restored
            viewModel.updatePreview(settings: restored, includeHistogram: true, quality: .final)
            return true
        } catch {
            viewModel.reportError(error, operation: .editPersistence, stage: "restoreCommittedAdjustments")
            return false
        }
    }
}
