import Foundation
import ImageIO
import UIKit

enum ImageSourceKind {
    case raw
    case raster
}

enum EditorError: LocalizedError {
    case noImageLoaded
    case renderFailed
    case sampleNotFound

    var errorDescription: String? {
        switch self {
        case .noImageLoaded:
            return L10n.text("No image loaded.")
        case .renderFailed:
            return L10n.text("Image render failed.")
        case .sampleNotFound:
            return L10n.text("Sample RAW not found.")
        }
    }
}

extension RawEditorViewModel {
    struct RawPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: [CGFloat]
        let lutID: String?
        let lutApplied: Bool
        let orientation: CGImagePropertyOrientation?
        let rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance?
    }

    struct RasterPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: [CGFloat]
        let orientation: CGImagePropertyOrientation?
    }

    func buildRawPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings()) throws -> RawPreviewBase {
        let rawBase = try processor.processRaw(
            url: url,
            settings: .default,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rawBase.buffer,
            settings: .default,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        var neutral = RawSettings.default
        neutral.geometry = geometry
        let comparison = geometry.isIdentity ? rawBase : try processor.processRaw(
            url: url, settings: neutral, previewLongEdge: previewMaxDimension, lutURL: nil)
        let basePreviewImage = processor.makeUIImage(from: comparison.buffer, orientation: .up)
        let baseHistogram = processor.computeHistogram(from: comparison.buffer, bins: histogramBins)

        return RawPreviewBase(
            buffer: rawBase.buffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            lutID: nil,
            lutApplied: false,
            orientation: rawBase.orientation,
            rawWhiteBalance: rawBase.rawWhiteBalance
        )
    }

    func buildRasterPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings()) throws -> RasterPreviewBase {
        let rasterBase = try processor.loadRasterBuffer(url: url, applyingOrientation: true)
        let baseBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: .default,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: .default,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        var neutral = RawSettings.default
        neutral.geometry = geometry
        let comparison = geometry.isIdentity ? baseBuffer : try processor.processBuffer(
            buffer: rasterBase.buffer, settings: neutral, previewLongEdge: previewMaxDimension, lutURL: nil)
        let basePreviewImage = processor.makeUIImage(from: comparison, orientation: .up)
        let baseHistogram = processor.computeHistogram(from: comparison, bins: histogramBins)

        return RasterPreviewBase(
            buffer: rasterBase.buffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            orientation: rasterBase.orientation
        )
    }
}

extension RawEditorViewModel {
    @discardableResult
    func importImage(
        from source: PhotoImportSource,
        identity: PhotoIdentity? = nil,
        settings: RawSettings = .default,
        onImported: (() -> Void)? = nil,
        onSettingsRestored: ((RawSettings) -> Void)? = nil
    ) -> UUID {
        statusMessage = nil
        isBusy = true
        let importRevision = UUID()
        activeImportRevision = importRevision
        sourceRevision = importRevision
        invalidatePreviewRequests()
        previewLongEdge = Int(previewMaxDimension)
        requestedPreviewLongEdge = previewLongEdge

        let sourceKind: ImageSourceKind = source.isRaw ? .raw : .raster

        DispatchQueue.global(qos: .userInitiated).async {
            defer { PhotoImportFile.release(source.url) }
            let didStart = source.url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    source.url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let resolvedIdentity = identity ?? (try? PhotoIdentity.fallback(for: source.url))
                let record = resolvedIdentity.flatMap { self.editPersistence?.state(for: $0) }
                let restoredSettings = record?.settings ?? .default
                let missingLook = !self.isLookAvailable(for: restoredSettings)
                let localURL = try self.copyToCache(source.url, identity: resolvedIdentity)
                if sourceKind == .raw {
                    let rawBase = try self.buildRawPreviewBase(url: localURL, geometry: restoredSettings.geometry)
                    let lutURL = self.lutURL(for: restoredSettings)
                    let previewResult = try self.processor.processRaw(
                        url: localURL,
                        settings: restoredSettings,
                        previewLongEdge: self.previewMaxDimension,
                        lutURL: lutURL,
                        viewportPreview: true
                    )
                    let adjustedImage = self.processor.makeUIImage(
                        from: previewResult.buffer,
                        orientation: previewResult.orientation ?? rawBase.orientation
                    )
                    let adjustedHistogram = self.processor.computeHistogram(
                        from: previewResult.buffer,
                        bins: self.histogramBins
                    )

                    self.resultDelivery {
                        guard self.activeImportRevision == importRevision else { return }
                        self.invalidatePreviewRequests()
                        self.activeImportRevision = nil
                        self.sourceURL = localURL
                        self.sourceKind = sourceKind
                        self.sourceIdentity = resolvedIdentity
                        self.sourceDisplayName = source.displayName
                        self.restoredSettings = restoredSettings
                        self.currentPreviewSettings = restoredSettings
                        self.pendingSettings = nil
                        self.sourceOrientation = previewResult.orientation ?? rawBase.orientation
                        self.draftBuffer = rawBase.buffer
                        self.draftPreviewBuffer = rawBase.previewBuffer
                        self.basePreviewImage = rawBase.basePreviewImage
                        self.baseHistogram = rawBase.baseHistogram
                        self.basePreviewGeometry = restoredSettings.geometry
                        self.rawWhiteBalance = previewResult.rawWhiteBalance ?? rawBase.rawWhiteBalance
                        self.lensInfo = previewResult.lensInfo
                        self.rawLUTID = restoredSettings.lutID
                        self.rawLUTApplied = restoredSettings.lutID != nil && restoredSettings.lutStrength > 0
                        self.previewImage = adjustedImage
                        self.nativeImageSize = previewResult.buffer.nativeSize
                        self.histogram = adjustedHistogram
                        self.hasImage = rawBase.basePreviewImage != nil || adjustedImage != nil
                        self.isBusy = false
                        self.sourceRevision = UUID()
                        if self.editPersistence != nil { self.setEditNotice(record == nil ? .idle : .restored) }
                        onSettingsRestored?(restoredSettings)
                        if self.hasImage && adjustedImage != nil { onImported?() }
                        if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                        if adjustedImage == nil {
                            self.statusMessage = L10n.text("Preview render failed.")
                        }
                    }
                } else {
                    let rasterBase = try self.buildRasterPreviewBase(url: localURL, geometry: restoredSettings.geometry)
                    let adjustedBuffer = try self.processor.processBuffer(
                        buffer: rasterBase.buffer,
                        settings: restoredSettings,
                        previewLongEdge: self.previewMaxDimension,
                        lutURL: self.lutURL(for: restoredSettings)
                    )
                    let adjustedImage = self.processor.makeUIImage(
                        from: adjustedBuffer,
                        orientation: rasterBase.orientation
                    )
                    let adjustedHistogram = self.processor.computeHistogram(
                        from: adjustedBuffer,
                        bins: self.histogramBins
                    )

                    self.resultDelivery {
                        guard self.activeImportRevision == importRevision else { return }
                        self.invalidatePreviewRequests()
                        self.activeImportRevision = nil
                        self.sourceURL = localURL
                        self.sourceKind = sourceKind
                        self.sourceIdentity = resolvedIdentity
                        self.sourceDisplayName = source.displayName
                        self.restoredSettings = restoredSettings
                        self.currentPreviewSettings = restoredSettings
                        self.pendingSettings = nil
                        self.sourceOrientation = rasterBase.orientation
                        self.draftBuffer = rasterBase.buffer
                        self.draftPreviewBuffer = rasterBase.previewBuffer
                        self.basePreviewImage = rasterBase.basePreviewImage
                        self.baseHistogram = rasterBase.baseHistogram
                        self.basePreviewGeometry = restoredSettings.geometry
                        self.rawLUTID = nil
                        self.rawLUTApplied = false
                        self.rawWhiteBalance = nil
                        self.lensInfo = nil
                        self.previewImage = adjustedImage
                        self.nativeImageSize = adjustedBuffer.nativeSize
                        self.histogram = adjustedHistogram
                        self.hasImage = rasterBase.basePreviewImage != nil || adjustedImage != nil
                        self.isBusy = false
                        self.sourceRevision = UUID()
                        if self.editPersistence != nil { self.setEditNotice(record == nil ? .idle : .restored) }
                        onSettingsRestored?(restoredSettings)
                        if self.hasImage && adjustedImage != nil { onImported?() }
                        if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                        if adjustedImage == nil {
                            self.statusMessage = L10n.text("Preview render failed.")
                        }
                    }
                }
            } catch {
                self.resultDelivery {
                    guard self.activeImportRevision == importRevision else { return }
                    self.invalidatePreviewRequests()
                    self.activeImportRevision = nil
                    self.statusMessage = error.localizedDescription
                    self.isBusy = false
                    self.previewImage = nil
                    self.basePreviewImage = nil
                    self.nativeImageSize = nil
                    self.draftPreviewBuffer = nil
                    self.draftBuffer = nil
                    self.sourceURL = nil
                    self.sourceKind = nil
                    self.sourceIdentity = nil
                    self.sourceDisplayName = nil
                    self.sourceOrientation = nil
                    self.rawLUTID = nil
                    self.rawLUTApplied = false
                    self.rawWhiteBalance = nil
                    self.lensInfo = nil
                    self.editSaveState = .idle
                    self.hasImage = false
                    self.histogram = []
                    self.baseHistogram = []
                    self.sourceRevision = UUID()
                }
            }
        }
        return importRevision
    }

    func cancelImageImport(_ requestID: UUID? = nil) {
        guard let activeImportRevision,
              requestID == nil || requestID == activeImportRevision else { return }
        self.activeImportRevision = nil
        invalidatePreviewRequests()
        sourceRevision = UUID()
        isBusy = false
    }

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

private extension RawEditorViewModel {
    func copyToCache(_ sourceURL: URL, identity: PhotoIdentity?) throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        let identityName = identity?.key.replacingOccurrences(of: "/", with: "_")
        let fileName = (identityName ?? UUID().uuidString) +
            (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")
        let destinationURL = cacheDir.appendingPathComponent(fileName)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func writeSmokeTestResult(_ message: String) {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)
        let resultURL = cacheDir.appendingPathComponent("smoke_test.txt")

        do {
            if !fileManager.fileExists(atPath: cacheDir.path) {
                try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
            try message.data(using: .utf8)?.write(to: resultURL)
        } catch {
            return
        }
    }
}
