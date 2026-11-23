import RawLabKit
import AppKit

struct PendingExternalReload: Equatable {
    let record: MacPhotoEditRecord
    let fingerprint: FileStatFingerprint?
}

extension EditorModel {
    var hasUnsavedManualDraft: Bool {
        dirty || geometryDraft != nil || scheduler.interacting || interactionEntry != nil ||
            ParameterValueField.hasPendingInputs || (saveWork != nil && saveWork?.isCancelled == false)
    }

    var hasActiveExternalReloadBanner: Bool {
        pendingExternalReload != nil
    }

    func startExternalStoreWatcher() {
        externalStoreWatcher?.stop()
        let editsURL = editDirectory.appendingPathComponent("edits.json")
        let presetsURL = presetDirectory.appendingPathComponent("presets.json")
        let expectedEditsPath = ExternalStoreFileWatcher.canonicalTargetPath(for: editsURL)
        let expectedPresetsPath = ExternalStoreFileWatcher.canonicalTargetPath(for: presetsURL)

        externalStoreWatcher = ExternalStoreFileWatcher(urls: [editsURL, presetsURL]) { [weak self] changedURL in
            let work = { [weak self] in
                guard let self else { return }
                let changedPath = ExternalStoreFileWatcher.canonicalTargetPath(for: changedURL)
                if changedPath == expectedPresetsPath {
                    self.handleExternalPresetsFileChange(resolvedPath: expectedPresetsPath)
                } else if changedPath == expectedEditsPath {
                    self.handleExternalEditsFileChange()
                }
            }
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }

    func handleExternalPresetsFileChange(resolvedPath: String? = nil) {
        let presetsURL = presetDirectory.appendingPathComponent("presets.json")
        let path = resolvedPath ?? ExternalStoreFileWatcher.canonicalTargetPath(for: presetsURL)
        let currentFingerprint = FileStatFingerprint(resolvedPath: path)
        if let lastWrite = presetStore.lastWriteFingerprint, let currentFingerprint, lastWrite == currentFingerprint {
            return
        }
        presetLibraryRevision &+= 1
    }

    func flushDeferredExternalEditsCheckIfNeeded() {
        guard deferredExternalEditsCheck, !hasPendingEditCommits else { return }
        deferredExternalEditsCheck = false
        handleExternalEditsFileChange()
    }

    func handleExternalEditsFileChange() {
        guard let file else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: editDirectory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return
        }
        let editsURL = editDirectory.appendingPathComponent("edits.json")
        let resolvedEditsPath = ExternalStoreFileWatcher.canonicalTargetPath(for: editsURL)
        let currentFingerprint = FileStatFingerprint(resolvedPath: resolvedEditsPath)
        if let editStore, let lastWrite = editStore.lastWriteFingerprint,
           let currentFingerprint, lastWrite == currentFingerprint {
            return
        }
        if hasPendingEditCommits {
            deferredExternalEditsCheck = true
            return
        }
        guard let store = try? (editStore ?? MacEditPersistence(directory: editDirectory)) else { return }
        if editStore == nil { editStore = store }
        guard let diskRecord = try? store.readState(for: file) else { return }
        evaluateExternalEditsRecord(diskRecord, fingerprint: currentFingerprint)
    }

    func evaluateExternalEditsRecord(_ diskRecord: MacPhotoEditRecord, fingerprint: FileStatFingerprint? = nil) {
        guard let file else { return }
        let activePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard diskRecord.identity.path == activePath else { return }
        guard let currentIdentity = try? OriginalFileIdentity(file), currentIdentity == diskRecord.identity else { return }

        let targetState = try? diskRecord.state ?? MacPhotoEditState(
            settings: RenderEngine.defaultSettings(for: file, sourceIsHDR: sourceIsHDR),
            filmID: ""
        )

        if !hasUnsavedManualDraft {
            if let targetState, editState(settings: settings) == targetState {
                if committedEdit?.state == diskRecord.state {
                    pendingExternalReload = nil
                    return
                }
            }
            pendingExternalReload = nil
            applyExternalReloadRecord(diskRecord)
            return
        }

        if diskRecord.state == committedEdit?.state {
            return
        }
        if let fingerprint, dismissedExternalReloadFingerprints.contains(fingerprint),
           pendingExternalReload == nil {
            return
        }
        pendingExternalReload = PendingExternalReload(record: diskRecord, fingerprint: fingerprint)
    }

    func keepCurrentManualDraftOnExternalUpdate() {
        if let fp = pendingExternalReload?.fingerprint {
            dismissedExternalReloadFingerprints.insert(fp)
        }
        pendingExternalReload = nil
    }

    func reloadFromExternalUpdate() {
        guard let pending = pendingExternalReload else { return }
        pendingExternalReload = nil
        dismissedExternalReloadFingerprints.removeAll()
        ParameterValueField.cancelPendingInputs()
        if geometryDraft != nil {
            cancelGeometryDraft()
        }
        saveWork?.cancel()
        saveWork = nil
        interactionEntry = nil
        interactionWasDirty = false
        scheduler.setInteracting(false)
        dirty = false
        applyExternalReloadRecord(pending.record)
    }

    private func applyExternalReloadRecord(_ diskRecord: MacPhotoEditRecord) {
        guard let file, let session = try? requireAdjustmentSession() else { return }
        let expected = committedEdit ?? MacPhotoEditRecord(identity: diskRecord.identity, state: nil)
        let outcome = session.adoptExternalReload(expected: expected, reloaded: diskRecord)
        guard outcome.status == .applied || outcome.status == .unchanged else { return }

        guard let targetState = try? diskRecord.state ?? MacPhotoEditState(
            settings: RenderEngine.defaultSettings(for: file, sourceIsHDR: sourceIsHDR),
            filmID: ""
        ) else { return }

        let previous = committedEdit?.state
        committedEdit = outcome.saved ?? diskRecord
        restoreAdjustmentState(targetState)
        recordSavedLookChange(from: previous, to: targetState)
        dirty = false
        saveError = nil
        saveWork?.cancel()
        pendingAllResetRevision = nil
        adjustmentHistoryRevision &+= 1
        editRevision = UUID()
        schedule(forceExact: true)
        invalidateEditedThumbnail(for: file)
    }
}
