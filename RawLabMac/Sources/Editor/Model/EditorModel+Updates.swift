import Foundation

extension EditorModel {
    var updateDataFailures: [String] {
        var items: [String] = []
        if editStore == nil { items.append("edits") }
        if lookLibrary?.isReadable != true { items.append("looks") }
        if updateJournalLoadFailed { items.append("journal") }
        if !presetStore.isReadable { items.append("presets") }
        return items
    }
    var updateDataHealthy: Bool {
        updateDataFailures.isEmpty
    }
    @MainActor func registerUpdateGate(_ gate: UpdateInstallGate) {
        gate.register(self, status: { [weak self] in
            guard let model = self else { return UpdateSessionStatus() }
            let batch = model.batch
            return UpdateSessionStatus(draft: model.geometryDraft != nil || ParameterValueField.hasPendingInputs || model.scheduler.interacting,
                unsaved: model.dirty || model.hasPendingEditCommits, saveFailed: model.saveError != nil || model.editStore == nil,
                tasksRunning: model.workerActive || model.busy || model.exporting || model.aiState.isRunning || model.lookLibraryBusy ||
                    batch?.running == true || batch?.stopping == true || batch?.validating == true || batch?.previewing == true,
                journalFailed: model.updateJournalLoadFailed || batch?.updateJournalFailed == true,
                presetsFailed: !model.presetStore.isReadable,
                looksFailed: model.lookLibrary?.isReadable != true)
        }, save: { [weak self] in
            guard let model = self else { return true }
            guard model.saveEdits(), !model.updateJournalLoadFailed else { return false }
            return model.batch?.prepareForUpdate() ?? true
        })
    }
}
