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

    func buildRawPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings(),
                             processing: ProcessingIdentity = .current) throws -> RawPreviewBase {
        var neutral = RawSettings.default
        neutral.processing = processing
        let rawBase = try processor.processRaw(
            url: url,
            settings: neutral,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rawBase.buffer,
            settings: neutral,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
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

    func buildRasterPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings(),
                                processing: ProcessingIdentity = .current) throws -> RasterPreviewBase {
        var neutral = RawSettings.default
        neutral.processing = processing
        let rasterBase = try processor.loadRasterBuffer(url: url, applyingOrientation: true)
        let baseBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: neutral,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: neutral,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
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
        let input = sourceFile.flatMap { $0.matches(source.url) ? $0 : nil }
            ?? .externallyManaged(source.url)

        importQueue.async {
            input.withReadAccess { inputURL in
                defer { PhotoImportFile.release(inputURL) }
                let didStart = inputURL.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        inputURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let resolvedIdentity = identity ?? (try? PhotoIdentity.fallback(for: inputURL))
                    let record = resolvedIdentity.flatMap { self.editPersistence?.state(for: $0) }
                    let restoredSettings = record?.settings ?? .default
                    let missingLook = !self.isLookAvailable(for: restoredSettings)
                    let sourceFile = try PhotoSourceFile.copy(inputURL)
                    try sourceFile.withReadAccess { localURL in
                        if sourceKind == .raw {
                            let rawBase = try self.buildRawPreviewBase(url: localURL, geometry: restoredSettings.geometry, processing: restoredSettings.processing)
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
                                self.sourceFile = sourceFile
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
                                self.basePreviewProcessing = restoredSettings.processing
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
                                self.retainEditMetadata(record ?? PhotoEditState(settings: restoredSettings))
                                self.persistedEditorSettings = nil
                                self.failedDraftSource = nil
                                if self.editPersistence != nil { self.setEditNotice(record == nil ? .idle : .restored) }
                                onSettingsRestored?(restoredSettings)
                                if self.hasImage && adjustedImage != nil { onImported?() }
                                if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                                if adjustedImage == nil {
                                    self.statusMessage = L10n.text("无法生成预览")
                                }
                            }
                        } else {
                            let rasterBase = try self.buildRasterPreviewBase(url: localURL, geometry: restoredSettings.geometry, processing: restoredSettings.processing)
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
                                self.sourceFile = sourceFile
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
                                self.basePreviewProcessing = restoredSettings.processing
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
                                self.retainEditMetadata(record ?? PhotoEditState(settings: restoredSettings))
                                self.persistedEditorSettings = nil
                                self.failedDraftSource = nil
                                if self.editPersistence != nil { self.setEditNotice(record == nil ? .idle : .restored) }
                                onSettingsRestored?(restoredSettings)
                                if self.hasImage && adjustedImage != nil { onImported?() }
                                if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                                if adjustedImage == nil {
                                    self.statusMessage = L10n.text("无法生成预览")
                                }
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
                        self.sourceFile = nil
                        self.sourceKind = nil
                        self.sourceIdentity = nil
                        self.editRecordMetadata = nil
                        self.persistedEditorSettings = nil
                        self.failedDraftSource = nil
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
}
