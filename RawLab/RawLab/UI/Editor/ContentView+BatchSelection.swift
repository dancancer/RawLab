import RawLabKit
import SwiftUI

extension ContentView {
    func openBatchSelection() {
        coordinator.openBatchSelection()
    }

    func finishBatchSelection() {
        if coordinator.collectionBatchHandoff.promote(as: BatchExportModel.self, sceneIsActive: scenePhase == .active, configure: { model in
            batchModel = model
            testHooks.onBatchModelCreated?(model)
            model.onUsage = { UsageAnalytics.shared.record($0) }
            model.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
        }, start: { $0.start() }) != nil {
            showingBatchExport = true
        } else if let id = coordinator.queuedCollectionEdit {
            coordinator.queuedCollectionEdit = nil
            requestCollectionNavigation(.edit(id))
        } else if coordinator.queuedCollectionExistingBatch {
            coordinator.queuedCollectionExistingBatch = false
            showingBatchExport = true
        }
    }

    func requestCollectionNavigation(_ action: IOSCollectionNavigation) {
        coordinator.requestCollectionNavigation(action, onEdit: { openCollectionPhotoByID($0) })
    }

    func continueCollectionNavigation() {
        coordinator.continueCollectionNavigation(onEdit: { openCollectionPhotoByID($0) })
    }

    private func openCollectionPhotoByID(_ id: String) {
        guard let stored = viewModel.batchSelection.photos[id] else { return }
        coordinator.isImporting = true
        Task { await openCollectionPhoto(stored) }
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
                coordinator.isImporting = false
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
            coordinator.isImporting = false
        } catch {
            coordinator.isImporting = false
            viewModel.reportError(error, operation: .photoImport, stage: "readBatchSelection",
                                  context: ["entryPoint": "batchSelection"])
        }
    }

    func resolveCollectionDraft(_ key: String, apply: Bool) -> Bool {
        guard viewModel.sourceIdentity?.key == key, !editorBusy else { return false }
        if apply {
            return coordinator.resolveCollectionDraft(key, apply: true)
        }
        cancelSliderInteraction()
        discardEditorDraft()
        finishEditorTool()
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
