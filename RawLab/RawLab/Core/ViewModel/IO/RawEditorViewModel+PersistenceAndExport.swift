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
        guard sourceIdentity != nil else { return }
        pendingSettings = settings
        editSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveCurrentSettings(settings) }
        editSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @discardableResult func saveCurrentSettings(_ settings: RawSettings) -> Bool {
        editSaveWork?.cancel()
        guard let sourceIdentity, pendingSettings != nil else { return true }
        do {
            if editPersistence == nil { editPersistence = try EditPersistence.appStore() }
            try editPersistence!.save(sourceIdentity, state: PhotoEditState(settings: settings))
            pendingSettings = nil
            setEditNotice(.saved)
            return true
        } catch {
            editSaveState = .failed(error.localizedDescription)
            return false
        }
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
        guard let sourceURL, let sourceKind, let sourceIdentity else { return nil }
        return BatchSourceSnapshot(identity: sourceIdentity,
                                   sourceURL: sourceURL,
                                   displayName: sourceDisplayName ?? sourceURL.lastPathComponent,
                                   sourceKind: sourceKind == .raw ? .raw : .raster,
                                   settings: settings)
    }

    func exportJPEG(settings: RawSettings, longEdge: Int? = nil,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        guard !previewRendering, !previewResizePending, !isBusy else {
            completion(.failure(BatchExportError.global(L10n.text("请等待预览完成后导出。"))))
            return
        }
        guard isLookAvailable(for: settings) else {
            completion(.failure(BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))))
            return
        }
        guard let sourceURL, let sourceKind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lutURL = self.lutURL(for: settings)
                let data: Data

                if sourceKind == .raw {
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
                    let raster = try self.processor.loadRasterBuffer(url: sourceURL, applyingOrientation: true)
                    let outputBuffer = try self.processor.processBuffer(
                        buffer: raster.buffer,
                        settings: settings,
                        previewLongEdge: nil,
                        lutURL: lutURL,
                        exportLongEdge: longEdge
                    )
                    let output = try self.processor.makeJPEGData(
                        from: outputBuffer,
                        sourceURL: sourceURL,
                        orientation: raster.orientation,
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

    func exportDNG(settings: RawSettings, longEdge: Int? = nil,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        guard isLookAvailable(for: settings) else {
            completion(.failure(BatchExportError.global(L10n.text("所选外观不可用，请重新选择外观。"))))
            return
        }
        guard let sourceURL, let sourceKind else {
            completion(.failure(EditorError.noImageLoaded))
            return
        }
        guard ExportSize.isValid(longEdge) else {
            completion(.failure(Sony2FujiProcessor.ProcessorError.invalidExportSize))
            return
        }

        isBusy = true
        let base = sourceURL.deletingPathExtension().lastPathComponent.isEmpty
            ? "RawLab" : sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-rendered-\(UUID().uuidString).dng")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lutURL = self.lutURL(for: settings)
                if sourceKind == .raw {
                    try self.processor.exportDNG(url: sourceURL, settings: settings, lutURL: lutURL,
                                                 outputURL: outputURL, exportLongEdge: longEdge)
                } else {
                    let raster = try self.processor.loadRasterBuffer(url: sourceURL, applyingOrientation: true)
                    try self.processor.exportDNG(buffer: raster.buffer, settings: settings, lutURL: lutURL,
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

    func runBundledSampleSmokeTest(settings: RawSettings) {
        guard let url = Bundle.main.url(forResource: sampleResourceName, withExtension: sampleResourceExtension) else {
            statusMessage = "Sample RAW not found in app bundle."
            return
        }

        statusMessage = nil
        isBusy = true
        sourceRevision = UUID()
        let lutURL = lutURL(for: settings)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rawPreview = try self.buildRawPreviewBase(url: url, geometry: settings.geometry)
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
                let previewHistogram = self.processor.computeHistogram(
                    from: previewResult.buffer,
                    bins: self.histogramBins
                )

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
                    self.sourceURL = url
                    self.sourceKind = .raw
                    self.sourceDisplayName = url.lastPathComponent
                    self.sourceOrientation = previewResult.orientation ?? rawPreview.orientation
                    self.draftBuffer = rawPreview.buffer
                    self.draftPreviewBuffer = rawPreview.previewBuffer
                    self.basePreviewImage = rawPreview.basePreviewImage
                    self.baseHistogram = rawPreview.baseHistogram
                    self.basePreviewGeometry = settings.geometry
                    self.lensInfo = previewResult.lensInfo
                    self.rawLUTID = settings.lutID
                    self.rawLUTApplied = settings.lutID != nil && settings.lutStrength > 0
                    self.previewImage = previewImage
                    self.nativeImageSize = previewResult.buffer.nativeSize
                    self.histogram = previewHistogram
                    self.hasImage = rawPreview.basePreviewImage != nil || previewImage != nil
                    self.isBusy = false
                    self.sourceRevision = UUID()
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
                    self.sourceURL = nil
                    self.sourceKind = nil
                    self.sourceDisplayName = nil
                    self.sourceOrientation = nil
                    self.rawLUTID = nil
                    self.rawLUTApplied = false
                    self.hasImage = false
                    self.lensInfo = nil
                    self.histogram = []
                    self.baseHistogram = []
                    self.sourceRevision = UUID()
                    self.writeSmokeTestResult("FAIL: \(error.localizedDescription)")
                }
            }
        }
    }
}
