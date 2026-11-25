import RawLabKit
import Foundation
import ImageIO
import UIKit

extension RawEditorViewModel {
    func consumeRestoredSettings(_ settings: RawSettings) -> Bool {
        let matches = restoredSettings == settings
        restoredSettings = nil
        return matches
    }

    func queueSettingsSave(_ settings: RawSettings) {
        cancelProcessingMigration()
        if quickPresetState.isPreparing { cancelQuickPreset() }
        guard let source = editorEditSource else { return }
        let candidate = currentEditState(settings: settings)
        if let pending = pendingResetMigrationClear {
            if !pending.queued, pending.source == source, pending.state.hasSameAdjustments(as: candidate) {
                pendingResetMigrationClear = (pending.source, pending.state, true)
            } else {
                pendingResetMigrationClear = nil
            }
        }
        retainEditMetadata(candidate)
        pendingSettings = settings
        cancelQueuedSettingsSave()
        guard adjustmentInteraction == nil else { return }
        let revision = settingsSaveRevision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.editorEditSource == source, self.settingsSaveRevision == revision else { return }
            _ = self.saveCurrentSettings(settings)
        }
        editSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @discardableResult func saveCurrentSettings(_ settings: RawSettings) -> Bool {
        cancelQueuedSettingsSave()
        guard adjustmentInteraction == nil else { return false }
        guard !hasFailedDraftSave else { return false }
        guard let source = editorEditSource, pendingSettings != nil else { return true }
        let candidate = currentEditState(settings: settings)
        let clearsMigration = pendingResetMigrationClear.map {
            $0.source == source && $0.state.hasSameAdjustments(as: candidate)
        } == true
        if !clearsMigration { pendingResetMigrationClear = nil }
        return persistEditCandidate(candidate, source: source, clearsProcessingMigration: clearsMigration)
    }

    func cancelQueuedSettingsSave() {
        editSaveWork?.cancel()
        editSaveWork = nil
        settingsSaveRevision = UUID()
    }

    func persistEditCandidate(_ candidate: PhotoEditState, source: EditorEditSource,
                              clearsProcessingMigration: Bool = false) -> Bool {
        guard editorEditSource == source else { return false }
        let expected: PhotoEditRecord
        let defaults: PhotoEditState?
        do {
            let store = try requireEditPersistence()
            expected = try loadedEditRecord ?? store.readState(for: source.identity)
            if let quarantined = store.consumeQuarantinedError() {
                ErrorDiagnostics.log(quarantined, operation: .editPersistence, stage: "quarantineStore")
            }
            guard expected.identity == source.identity else { return false }
            loadedEditRecord = expected
            defaults = try expected.state == nil ? PhotoEditState(settings:sourceDefaultSettings) : nil
        } catch { editSaveState = .failed(adjustmentErrorMessage(error)); return false }
        guard let session = adjustmentSession else { return false }
        let outcome = session.commitEdit(expected: expected, state: candidate, displayName: sourceDisplayName,
            defaultState:defaults, clearsProcessingMigration: clearsProcessingMigration,
            isCurrent:{ self.editorEditSource==source },
            validateSource: adjustmentSourceValidator)
        if let saved = outcome.saved {
            if clearsProcessingMigration {
                pendingResetMigrationClear = nil
                processingMigrationReceipt = nil
            }
            if let state = saved.state { recordSavedLookChange(from: expected.state, to: state) }
            loadedEditRecord = saved
            retainEditMetadata(saved.state ?? candidate)
            pendingSettings = nil
            adjustmentHistoryRevision = UUID()
            if outcome.status == .applied { setEditNotice(.saved) }
            return true
        }
        if let error = outcome.error { ErrorDiagnostics.log(error, operation: .editPersistence, stage: "saveEdits") }
        editSaveState = .failed(outcome.error.map(adjustmentErrorMessage) ?? L10n.text("调整未保存，请重试。"))
        return false
    }

    func setEditNotice(_ state: EditSaveState) {
        editSaveState = state
        let noticeID = UUID()
        editNoticeID = noticeID
        guard state == .saved || state == .restored else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.editNoticeID == noticeID && self?.editSaveState == state { self?.editSaveState = .idle }
        }
    }

    private func requireEditPersistence() throws -> EditPersistence {
        if editPersistence == nil { editPersistence = try openEditPersistence() }
        guard let store = editPersistence else { throw EditPersistenceError.corruptStore }
        if let quarantined = store.consumeQuarantinedError() {
            ErrorDiagnostics.log(quarantined, operation: .editPersistence, stage: "quarantineStore")
        }
        if adjustmentSession == nil { adjustmentSession = IOSAdjustmentTransferSession(store: store) }
        return store
    }

    func restoreCommittedSettings() throws -> RawSettings {
        guard let source = editorEditSource else { throw EditPersistenceError.corruptStore }
        let store = try requireEditPersistence()
        let record = try loadedEditRecord ?? store.readState(for: source.identity)
        if let quarantined = store.consumeQuarantinedError() {
            ErrorDiagnostics.log(quarantined, operation: .editPersistence, stage: "quarantineStore")
        }
        guard record.identity == source.identity else { throw AdjustmentCommitError.photoChanged }
        let restored = try record.state?.settings ?? sourceDefaultSettings
        cancelQueuedSettingsSave()
        pendingSettings = nil
        pendingResetMigrationClear = nil
        failedDraftSource = nil
        adjustmentInteraction = nil
        adjustmentInteractionRejected = false
        hasAdjustmentDraft = false
        loadedEditRecord = record
        retainEditMetadata(record.state ?? PhotoEditState(settings: restored, updatedAt: Date(timeIntervalSince1970: 0)))
        persistedEditorSettings = PersistedEditorSettings(source: source, settings: restored)
        committedPreviewSettings = restored
        currentPreviewSettings = restored
        setEditNotice(record.state == nil ? .idle : .restored)
        return restored
    }

    func retrySave(settings: RawSettings) {
        do {
            _ = try requireEditPersistence()
            if loadedEditRecord == nil, editorEditSource != nil, pendingSettings == nil {
                adjustmentRestoredSettings = try restoreCommittedSettings()
                return
            }
            if pendingSettings == nil {
                editSaveState = .idle
                return
            }
            saveCurrentSettings(settings)
        } catch {
            ErrorDiagnostics.log(error, operation: .editPersistence, stage: "reopenStore")
            editSaveState = .failed(adjustmentErrorMessage(error))
        }
    }

    func resetCurrentSettings() throws {
        guard let sourceIdentity else { return }
        guard let editPersistence else { throw EditPersistenceError.corruptStore }
        try editPersistence.reset(sourceIdentity)
        pendingResetMigrationClear = nil
        processingMigrationReceipt = nil
        setEditNotice(.saved)
    }

    func currentBatchSource(settings: RawSettings) -> BatchSourceSnapshot? {
        guard let sourceFile, let sourceKind, let sourceIdentity else { return nil }
        return BatchSourceSnapshot(identity: sourceIdentity,
                                   sourceFile: sourceFile,
                                   displayName: sourceDisplayName ?? sourceFile.displayName,
                                   sourceKind: sourceKind == .raw ? .raw : .raster,
                                   settings: settings)
    }

    func exportJPEG(settings: RawSettings, longEdge: Int? = nil, keepHDR: Bool = true,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        exportPhoto(settings: settings, longEdge: longEdge, format: settings.isHDREditing && keepHDR ? .hdrJPEG : .jpeg,
                    completion: completion)
    }

    func exportPhoto(settings: RawSettings, longEdge: Int?, format: BatchOutputFormat,
                     outputSharpening: OutputSharpening = .off,
                     completion: @escaping (Result<Data, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let hdrFormat = format.hdrPhotoFormat else {
            completion(.failure(CocoaError(.fileWriteUnsupportedScheme)))
            return
        }
        if format.requiresHDR && !settings.isHDREditing {
            completion(.failure(BatchExportError.target(format.hdrRequiredMessage)))
            return
        }
        do { try format.validateHDRHEIF() }
        catch { completion(.failure(error)); return }
        guard !previewRendering, !previewResizePending, !previewFailed, !isBusy else {
            completion(.failure(BatchExportError.global(L10n.text("请等待预览完成后导出。"))))
            return
        }
        guard isLookAvailable(for: settings) else {
            completion(.failure(BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))))
            return
        }
        let source = (
            file: sourceFile,
            kind: sourceKind,
            hasBuffer: draftBuffer != nil,
            fullBuffer: draftBuffer.flatMap { (!$0.isProxy && $0.hasFullBitDepth) ? $0 : nil },
            orientation: sourceOrientation
        )
        guard let sourceFile = source.file, let sourceKind = source.kind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true
        clearDetailState(releaseRaster: true, keepRequest: true)
        renderQueue.async { [weak self] in
            self?.processor.clearHDRSessionCache()
        }
        let cancellation = ExportCancellation()
        if settings.isHDREditing {
            hdrExportCancellation = cancellation
            isExportingHDR = true
            isStoppingHDRExport = false
            hdrExportProgress = 0
        }
        exportQueue.async {
            sourceFile.withReadAccess { sourceURL in
                do {
                    let lutURL = self.lutURL(for: settings)
                    let data: Data

                    if let hdr=settings.hdr,settings.isHDREditing {
                        let output=FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-\(UUID().uuidString).\(format.suffix)")
                        defer { try? FileManager.default.removeItem(at:output) }
                        var lastPercent = -1
                        let progressLock = NSLock()
                        try self.processor.exportHDR(url: sourceURL, settings: hdr, output: output, longEdge: longEdge,
                            outputSharpening: outputSharpening,
                            processing: settings.processing, proRAWDecodeVersion: settings.proRAWDecodeVersion, format: hdrFormat,
                            progress: { [weak self] fraction in
                                let clamped = min(1.0, max(0.0, fraction))
                                let bucket = Int((clamped * 100.0).rounded())
                                progressLock.lock()
                                let shouldEmit = bucket != lastPercent
                                if shouldEmit { lastPercent = bucket }
                                progressLock.unlock()
                                guard shouldEmit else { return }
                                self?.resultDelivery {
                                    guard let self, self.hdrExportCancellation === cancellation else { return }
                                    self.hdrExportProgress = max(self.hdrExportProgress ?? 0, clamped)
                                }
                            },
                            cancelled: { cancellation.isCancelled })
                        data=try Data(contentsOf:output)
                    } else if sourceKind == .raw {
                        if format == .png {
                            let output = FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-\(UUID().uuidString).png")
                            defer { try? FileManager.default.removeItem(at: output) }
                            try self.processor.exportPNG(
                                url: sourceURL,
                                settings: settings,
                                lutURL: lutURL,
                                outputURL: output,
                                exportLongEdge: longEdge,
                                outputSharpening: outputSharpening
                            )
                            data = try Data(contentsOf: output)
                        } else {
                            let result = try self.processor.processRaw(
                                url: sourceURL,
                                settings: settings,
                                previewLongEdge: nil,
                                lutURL: lutURL,
                                exportLongEdge: longEdge,
                                outputSharpening: outputSharpening
                            )
                            let output = try self.processor.makeJPEGData(
                                from: result.buffer,
                                sourceURL: sourceURL,
                                orientation: result.orientation,
                                quality: 0.92,
                                sourceIsRaw: true
                            )
                            data = output
                        }
                    } else {
                        guard source.hasBuffer else { throw EditorError.noImageLoaded }
                        data = try autoreleasepool {
                            let sourceBuffer = try source.fullBuffer ?? self.processor.loadRasterBuffer(url: sourceURL).buffer
                            if format == .png {
                                let output = FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-\(UUID().uuidString).png")
                                defer { try? FileManager.default.removeItem(at: output) }
                                try self.processor.exportPNG(
                                    buffer: sourceBuffer,
                                    settings: settings,
                                    lutURL: lutURL,
                                    sourceURL: sourceURL,
                                    outputURL: output,
                                    exportLongEdge: longEdge,
                                    outputSharpening: outputSharpening
                                )
                                return try Data(contentsOf: output)
                            }
                            let outputBuffer = try self.processor.processBuffer(
                                buffer: sourceBuffer,
                                settings: settings,
                                previewLongEdge: nil,
                                lutURL: lutURL,
                                exportLongEdge: longEdge,
                                outputSharpening: outputSharpening
                            )
                            return try self.processor.makeJPEGData(
                                from: outputBuffer,
                                sourceURL: sourceURL,
                                orientation: source.orientation,
                                quality: 0.92
                            )
                        }
                    }

                    self.resultDelivery {
                        self.isBusy = false
                        self.isExportingHDR = false
                        self.isStoppingHDRExport = false
                        self.hdrExportProgress = nil
                        self.hdrExportCancellation = nil
                        if !cancellation.isCancelled {
                            DiagnosticCenter.recordBreadcrumb(
                                category: "export",
                                stage: "exportCompleted",
                                message: "Single photo export completed",
                                context: ["format": format.suffix, "hdr": String(settings.isHDREditing)]
                            )
                        }
                        completion(cancellation.isCancelled ? .failure(CancellationError()) : .success(data))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                        if let req = self.lastDetailRequest { self.scheduleDetailRender(for: req) }
                    }
                } catch {
                    self.resultDelivery {
                        self.isBusy = false
                        self.isExportingHDR = false
                        self.isStoppingHDRExport = false
                        self.hdrExportProgress = nil
                        self.hdrExportCancellation = nil
                        completion(.failure(error))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                        if let req = self.lastDetailRequest { self.scheduleDetailRender(for: req) }
                    }
                }
            }
        }
    }

    func exportDNG(settings: RawSettings, longEdge: Int? = nil,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isLookAvailable(for: settings) else {
            completion(.failure(BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))))
            return
        }
        let source = (
            file: sourceFile,
            kind: sourceKind,
            hasBuffer: draftBuffer != nil,
            fullBuffer: draftBuffer.flatMap { (!$0.isProxy && $0.hasFullBitDepth) ? $0 : nil },
            orientation: sourceOrientation
        )
        guard let sourceFile = source.file, let sourceKind = source.kind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true
        clearDetailState(releaseRaster: true, keepRequest: true)
        renderQueue.async { [weak self] in
            self?.processor.clearHDRSessionCache()
        }
        let cancellation = ExportCancellation()
        if settings.isHDREditing {
            hdrExportCancellation = cancellation
            isExportingHDR = true
            isStoppingHDRExport = false
            hdrExportProgress = 0
        }
        let name = sourceFile.withReadAccess { $0.deletingPathExtension().lastPathComponent }
        let base = name.isEmpty ? "RawLab" : name
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-rendered-\(UUID().uuidString).dng")
        exportQueue.async {
            sourceFile.withReadAccess { sourceURL in
                do {
                    let lutURL = self.lutURL(for: settings)
                    if let hdr=settings.hdr,settings.isHDREditing {
                        var lastPercent = -1
                        let progressLock = NSLock()
                        try self.processor.exportHDRDNG(url: sourceURL, settings: hdr, output: outputURL, longEdge: longEdge,
                            processing: settings.processing, proRAWDecodeVersion: settings.proRAWDecodeVersion,
                            progress: { [weak self] fraction in
                                let clamped = min(1.0, max(0.0, fraction))
                                let bucket = Int((clamped * 100.0).rounded())
                                progressLock.lock()
                                let shouldEmit = bucket != lastPercent
                                if shouldEmit { lastPercent = bucket }
                                progressLock.unlock()
                                guard shouldEmit else { return }
                                self?.resultDelivery {
                                    guard let self, self.hdrExportCancellation === cancellation else { return }
                                    self.hdrExportProgress = max(self.hdrExportProgress ?? 0, clamped)
                                }
                            },
                            cancelled: { cancellation.isCancelled })
                        if cancellation.isCancelled { throw CancellationError() }
                    } else if sourceKind == .raw {
                        try self.processor.exportDNG(url: sourceURL, settings: settings, lutURL: lutURL,
                                                     outputURL: outputURL, exportLongEdge: longEdge)
                    } else {
                        guard source.hasBuffer else { throw EditorError.noImageLoaded }
                        try autoreleasepool {
                            let sourceBuffer = try source.fullBuffer ?? self.processor.loadRasterBuffer(url: sourceURL).buffer
                            try self.processor.exportDNG(buffer: sourceBuffer, settings: settings, lutURL: lutURL,
                                                         outputURL: outputURL, exportLongEdge: longEdge)
                        }
                    }
                    self.resultDelivery {
                        self.isBusy = false
                        self.isExportingHDR = false
                        self.isStoppingHDRExport = false
                        self.hdrExportProgress = nil
                        self.hdrExportCancellation = nil
                        DiagnosticCenter.recordBreadcrumb(
                            category: "export",
                            stage: "exportDNGCompleted",
                            message: "Rendered DNG export completed",
                            context: ["hdr": String(settings.isHDREditing)]
                        )
                        completion(.success(outputURL))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                        if let req = self.lastDetailRequest { self.scheduleDetailRender(for: req) }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.resultDelivery {
                        self.isBusy = false
                        self.isExportingHDR = false
                        self.isStoppingHDRExport = false
                        self.hdrExportProgress = nil
                        self.hdrExportCancellation = nil
                        completion(.failure(error))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                        if let req = self.lastDetailRequest { self.scheduleDetailRender(for: req) }
                    }
                }
            }
        }
    }
}
