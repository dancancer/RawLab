import Foundation

extension EditorModel {
    var updateDataHealthy: Bool {
        editStore != nil && lookLibrary != nil && !updateJournalLoadFailed && (try? presetStore.list()) != nil
    }
    @MainActor func registerUpdateGate(_ gate: UpdateInstallGate) {
        gate.register(self, status: { [weak self] in
            guard let model = self else { return UpdateSessionStatus() }
            let batch = model.batch
            return UpdateSessionStatus(draft: model.geometryDraft != nil || ParameterValueField.hasPendingInputs || model.scheduler.interacting,
                unsaved: model.dirty, saveFailed: model.saveError != nil || model.editStore == nil,
                tasksRunning: model.workerActive || model.busy || model.exporting || model.aiState.isRunning || model.lookLibraryBusy ||
                    batch?.running == true || batch?.stopping == true || batch?.validating == true || batch?.previewing == true,
                journalFailed: model.updateJournalLoadFailed || batch?.updateJournalFailed == true)
        }, save: { [weak self] in
            guard let model = self else { return true }
            guard model.saveEdits(), !model.updateJournalLoadFailed else { return false }
            return model.batch?.prepareForUpdate() ?? true
        })
    }
}
