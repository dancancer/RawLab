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
        guard let source = editorEditSource else { return }
        retainEditMetadata(currentEditState(settings: settings))
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
        return persistEditCandidate(currentEditState(settings: settings), source: source)
    }

    func cancelQueuedSettingsSave() {
        editSaveWork?.cancel()
        editSaveWork = nil
        settingsSaveRevision = UUID()
    }

    func persistEditCandidate(_ candidate: PhotoEditState, source: EditorEditSource) -> Bool {
        guard editorEditSource == source else { return false }
        guard let expected = loadedEditRecord, expected.identity == source.identity, let session = adjustmentSession else {
            adjustmentReloadRequired = true
            editSaveState = .failed(L10n.text("调整记录已恢复，请重新选择照片载入。"))
            return false
        }
        let outcome = session.commitEdit(expected: expected, state: candidate, displayName: sourceDisplayName,
            defaultState:PhotoEditState(settings:sourceDefaultSettings),isCurrent:{ self.editorEditSource==source },
            validateSource: adjustmentSourceValidator)
        if let saved = outcome.saved {
            adjustmentReloadRequired = false
            loadedEditRecord = saved
            retainEditMetadata(saved.state ?? candidate)
            pendingSettings = nil
            adjustmentHistoryRevision = UUID()
            if outcome.status == .applied { setEditNotice(.saved) }
            return true
        }
        adjustmentReloadRequired = outcome.status == .conflict
        editSaveState = .failed(outcome.error?.localizedDescription ?? L10n.text("调整记录已恢复，请重新选择照片载入。"))
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

    func retrySave(settings: RawSettings) {
        if editPersistence == nil && pendingSettings == nil {
            do {
                editPersistence = try EditPersistence.appStore()
                adjustmentSession = editPersistence.map(IOSAdjustmentTransferSession.init(store:))
                editSaveState = .idle
                statusMessage = L10n.text("调整记录已恢复，请重新选择照片载入。")
            } catch { editSaveState = .failed(error.localizedDescription) }
            return
        }
        saveCurrentSettings(settings)
    }

    func resetCurrentSettings() throws {
        guard let sourceIdentity else { return }
        guard let editPersistence else { throw EditPersistenceError.corruptStore }
        try editPersistence.reset(sourceIdentity)
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard !previewRendering, !previewResizePending, !previewFailed, !isBusy else {
            completion(.failure(BatchExportError.global(L10n.text("请等待预览完成后导出。"))))
            return
        }
        guard isLookAvailable(for: settings) else {
            completion(.failure(BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))))
            return
        }
        let source = (file: sourceFile, kind: sourceKind, buffer: draftBuffer, orientation: sourceOrientation)
        guard let sourceFile = source.file, let sourceKind = source.kind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true
        exportQueue.async {
            sourceFile.withReadAccess { sourceURL in
                do {
                    let lutURL = self.lutURL(for: settings)
                    let data: Data

                    if let hdr=settings.hdr,settings.isHDREditing {
                        let pair=try self.processor.processHDR(url:sourceURL,settings:hdr,previewLongEdge:nil,exportLongEdge:longEdge)
                        let output=FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-\(UUID().uuidString).jpg")
                        defer { try? FileManager.default.removeItem(at:output) }
                        if keepHDR { try pair.exportJPEG(to:output) }
                        else { try pair.exportSDR(to:output,format:SONY2FUJI_OUTPUT_JPEG) }
                        data=try Data(contentsOf:output)
                    } else if sourceKind == .raw {
                        let result = try self.processor.processRaw(
                            url: sourceURL,
                            settings: settings,
                            previewLongEdge: nil,
                            lutURL: lutURL,
                            exportLongEdge: longEdge
                        )
                        let output = try self.processor.makeJPEGData(
                            from: result.buffer,
                            sourceURL: sourceURL,
                            orientation: result.orientation,
                            quality: 0.92
                        )
                        data = output
                    } else {
                        guard let sourceBuffer = source.buffer else { throw EditorError.noImageLoaded }
                        let outputBuffer = try self.processor.processBuffer(
                            buffer: sourceBuffer,
                            settings: settings,
                            previewLongEdge: nil,
                            lutURL: lutURL,
                            exportLongEdge: longEdge
                        )
                        let output = try self.processor.makeJPEGData(
                            from: outputBuffer,
                            sourceURL: sourceURL,
                            orientation: source.orientation,
                            quality: 0.92
                        )
                        data = output
                    }

                    DispatchQueue.main.async {
                        self.isBusy = false
                        completion(.success(data))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isBusy = false
                        completion(.failure(error))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
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
        let source = (file: sourceFile, kind: sourceKind, buffer: draftBuffer, orientation: sourceOrientation)
        guard let sourceFile = source.file, let sourceKind = source.kind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true
        let name = sourceFile.withReadAccess { $0.deletingPathExtension().lastPathComponent }
        let base = name.isEmpty ? "RawLab" : name
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-rendered-\(UUID().uuidString).dng")
        exportQueue.async {
            sourceFile.withReadAccess { sourceURL in
                do {
                    let lutURL = self.lutURL(for: settings)
                    if let hdr=settings.hdr,settings.isHDREditing {
                        let pair=try self.processor.processHDR(url:sourceURL,settings:hdr,previewLongEdge:nil,exportLongEdge:longEdge)
                        try pair.exportSDR(to:outputURL,format:SONY2FUJI_OUTPUT_DNG)
                    } else if sourceKind == .raw {
                        try self.processor.exportDNG(url: sourceURL, settings: settings, lutURL: lutURL,
                                                     outputURL: outputURL, exportLongEdge: longEdge)
                    } else {
                        guard let sourceBuffer = source.buffer else { throw EditorError.noImageLoaded }
                        try self.processor.exportDNG(buffer: sourceBuffer, settings: settings, lutURL: lutURL,
                                                     outputURL: outputURL, exportLongEdge: longEdge)
                    }
                    self.resultDelivery {
                        self.isBusy = false
                        completion(.success(outputURL))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.resultDelivery {
                        self.isBusy = false
                        completion(.failure(error))
                        self.updatePreviewSize(self.requestedPreviewLongEdge, settings: self.currentPreviewSettings)
                    }
                }
            }
        }
    }

    func runBundledSampleSmokeTest(settings: RawSettings) {
        guard let url = Bundle.main.url(forResource: sampleResourceName, withExtension: sampleResourceExtension) else {
            statusMessage = "Sample RAW not found in app bundle."
            return
        }

        statusMessage = nil
        isBusy = true
        sourceRevision = UUID()
        let lutURL = lutURL(for: settings)
        let sourceFile = PhotoSourceFile.externallyManaged(url)

        DispatchQueue.global(qos: .userInitiated).async {
            sourceFile.withReadAccess { url in
                do {
                    let rawPreview = try self.buildRawPreviewBase(url: url, geometry: settings.geometry, processing: settings.processing, lens: settings.lensSettings)
                    let previewResult = try self.processor.processRaw(
                        url: url,
                        settings: settings,
                        previewLongEdge: self.previewMaxDimension,
                        lutURL: lutURL
                    )
                    let previewImage = self.processor.makeUIImage(
                        from: previewResult.buffer,
                        orientation: previewResult.orientation ?? rawPreview.orientation
                    )
                    let previewHistogram = self.processor.computeRGBHistogram(from: previewResult.buffer)

                    let fullResult = try self.processor.processRaw(
                        url: url,
                        settings: settings,
                        previewLongEdge: nil,
                        lutURL: lutURL
                    )
                    let data = try self.processor.makeJPEGData(
                        from: fullResult.buffer,
                        sourceURL: url,
                        orientation: fullResult.orientation,
                        quality: 0.92
                    )

                    DispatchQueue.main.async {
                        self.sourceFile = sourceFile
                        self.sourceKind = .raw
                        self.sourceDisplayName = url.lastPathComponent
                        self.sourceOrientation = previewResult.orientation ?? rawPreview.orientation
                        self.draftBuffer = rawPreview.buffer
                        self.draftPreviewBuffer = rawPreview.previewBuffer
                        self.basePreviewImage = rawPreview.basePreviewImage
                        self.baseHistogram = rawPreview.baseHistogram
                        self.basePreviewGeometry = settings.geometry
                        self.basePreviewProcessing = settings.processing
                        self.lensInfo = previewResult.lensInfo
                        self.rawLUTID = settings.lutID
                        self.rawLUTApplied = settings.lutID != nil && settings.lutStrength > 0
                        self.previewImage = previewImage
                        self.nativeImageSize = previewResult.buffer.nativeSize
                        self.histogram = previewHistogram
                        self.hasImage = rawPreview.basePreviewImage != nil || previewImage != nil
                        self.isBusy = false
                        self.sourceRevision = UUID()
                        self.recordImportedComparison(settings: settings)
                        let sizeKB = Double(data.count) / 1024.0
                        let message = String(format: "Sample decode OK: %.1f KB JPEG", sizeKB)
                        self.statusMessage = message
                        self.writeSmokeTestResult("OK: \(message)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.statusMessage = error.localizedDescription
                        self.isBusy = false
                        self.previewImage = nil
                        self.basePreviewImage = nil
                        self.nativeImageSize = nil
                        self.draftPreviewBuffer = nil
                        self.draftBuffer = nil
                        self.sourceFile = nil
                        self.sourceKind = nil
                        self.sourceDisplayName = nil
                        self.sourceOrientation = nil
                        self.rawLUTID = nil
                        self.rawLUTApplied = false
                        self.hasImage = false
                        self.lensInfo = nil
                        self.histogram = nil
                        self.baseHistogram = nil
                        self.sourceRevision = UUID()
                        self.writeSmokeTestResult("FAIL: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
