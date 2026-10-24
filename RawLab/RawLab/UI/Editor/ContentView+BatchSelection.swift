import SwiftUI

enum IOSCollectionNavigation { case edit(String), returnToCollection }

extension ContentView {
    func openBatchSelection() {
        cancelHSLTarget()
        if let photo = viewModel.currentAdjustmentPhoto { viewModel.batchSelection.append(photo) }
        showingBatchSelection = true
    }

    func finishBatchSelection() {
        if let model = queuedCollectionBatch {
            queuedCollectionBatch = nil
            batchModel = model
            batchModel?.onUsage = { UsageAnalytics.shared.record($0) }
            batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
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
            do {
                try stored.validate()
                guard let file = stored.photo.file else { throw CocoaError(.fileReadNoSuchFile) }
                if viewModel.sourceIdentity?.key == id {
                    _ = viewModel.batchSelection.selection.beginEditing(id)
                    return
                }
                isImporting = true
                file.withReadAccess { url in
                    viewModel.importImage(from: stored.photo.isRaw ? .raw(url) : .raster(url), identity: stored.photo.identity, onSettingsRestored: { restored in
                        settings = restored
                        viewModel.sourceDisplayName = stored.photo.displayName
                        _ = viewModel.batchSelection.selection.beginEditing(id)
                    })
                }
            } catch { viewModel.statusMessage = error.localizedDescription }
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
        guard viewModel.reloadSavedAdjustments() else { return false }
        if let restored = viewModel.adjustmentRestoredSettings {
            settings = restored
            viewModel.adjustmentRestoredSettings = nil
        }
        return true
    }
}
