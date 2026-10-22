import CoreGraphics
import Foundation
import UIKit

extension RawEditorViewModel {
    func updatePreviewSize(_ edge: Int, settings: RawSettings) {
        guard activeImportRevision == nil, hasImage, edge > 0,
              edge != requestedPreviewLongEdge || (edge != previewLongEdge && previewResizeWorkItem == nil) else { return }
        currentPreviewSettings = settings
        requestedPreviewLongEdge = min(Int(previewMaxDimension), edge)
        guard !isBusy else { return }
        previewResizeWorkItem?.cancel()
        previewResizePending = false
        guard requestedPreviewLongEdge != previewLongEdge else { return }
        let sourceRevision = self.sourceRevision
        let commit = DispatchWorkItem { [weak self] in
            guard let self, self.sourceRevision == sourceRevision, self.activeImportRevision == nil else { return }
            self.previewResizePending = false
            self.previewResizeWorkItem = nil
            guard !self.isBusy else { return }
            self.previewLongEdge = self.requestedPreviewLongEdge
            self.updatePreview(settings: self.currentPreviewSettings)
        }
        previewResizeWorkItem = commit
        if settings.denoise.enabled {
            previewResizePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: commit)
        } else {
            commit.perform()
        }
    }

    func updatePreview(
        settings: RawSettings,
        includeHistogram: Bool = true,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        guard !isBusy else { return }
        currentPreviewSettings = settings
        if !settings.denoise.enabled, previewResizeWorkItem != nil {
            previewResizeWorkItem?.cancel()
            previewResizeWorkItem = nil
            previewResizePending = false
            previewLongEdge = requestedPreviewLongEdge
        }
        let maxDimension = previewLongEdge
        let referenceSettings = committedPreviewSettings ?? settings
        let referenceKey = comparisonKey(settings: referenceSettings, longEdge: maxDimension)
        let comparisonChanged = comparisonReferenceKey != referenceKey
        let request = PreviewRequest(settings: settings, quality: quality,
                                     includeHistogram: includeHistogram, longEdge: maxDimension)
        if request == lastPreviewRequest, !previewRendering, !previewFailed, !comparisonChanged { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard isLookAvailable(for: settings) else {
            setLatestRenderID(UUID())
            previewRendering = false
            previewFailed = true
            isBusy = false
            statusMessage = L10n.text("所选外观不可用，请重新选择外观。")
            return
        }

        lastPreviewRequest = request
        previewRendering = true
        previewFailed = false

        let renderID = UUID()
        let sourceRevision = self.sourceRevision
        setLatestRenderID(renderID)
        cancelHistogramWorkItem()

        let finalHistogramDelay = histogramDelay ?? ((includeHistogram && quality == .final) ? self.histogramDelay : 0)
        let lutURL = lutURL(for: settings)
        let existingDraftBuffer = draftBuffer
        let existingDraftPreview = draftPreviewBuffer
        let existingOrientation = sourceOrientation
        let usesRaw = sourceKind == .raw
        let sourceFile = self.sourceFile

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer {
                self.resultDelivery {
                    if self.sourceRevision == sourceRevision && self.isLatestRenderID(renderID) {
                        self.previewRendering = false
                    }
                }
            }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            if usesRaw {
                guard let sourceFile else {
                    self.resultDelivery {
                        guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else { return }
                        self.previewFailed = true
                    }
                    return
                }

                sourceFile.withReadAccess { sourceURL in
                    do {
                        let comparison = comparisonChanged ? try self.renderComparison(
                            url: sourceURL, buffer: nil, geometry: referenceSettings.geometry, processing: referenceSettings.processing,
                            lens: referenceSettings.lensSettings, longEdge: maxDimension) : nil
                        let result = try self.processor.processRaw(
                            url: sourceURL,
                            settings: settings,
                            previewLongEdge: CGFloat(maxDimension),
                            lutURL: lutURL,
                            interactive: quality == .interactive,
                            viewportPreview: true
                        )
                        let previewImage = self.processor.makeUIImage(
                            from: result.buffer,
                            orientation: result.orientation ?? existingOrientation
                        )

                        self.resultDelivery {
                            guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                                return
                            }
                            self.previewImage = previewImage
                            self.acceptedPreviewFrameID = renderID
                            self.histogram = []
                            self.nativeImageSize = result.buffer.nativeSize
                            if let comparison {
                                self.applyComparison(comparison, geometry: referenceSettings.geometry, processing: referenceSettings.processing,
                                                     lens: referenceSettings.lensSettings, key: referenceKey)
                            }
                            self.lensInfo = result.lensInfo
                            if self.sourceOrientation == nil {
                                self.sourceOrientation = result.orientation
                            }
                        }

                        if includeHistogram {
                            self.scheduleHistogramUpdate(
                                for: result.buffer,
                                renderID: renderID,
                                sourceRevision: sourceRevision,
                                delay: finalHistogramDelay
                            )
                        }
                    } catch {
                        self.resultDelivery {
                            guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                                return
                            }
                            self.previewFailed = true
                            self.statusMessage = error.localizedDescription
                        }
                    }
                }
                return
            }

            let inputBuffer = existingDraftBuffer ?? existingDraftPreview
            guard let inputBuffer else {
                self.resultDelivery {
                    guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else { return }
                    self.previewFailed = true
                }
                return
            }

            let outputBuffer: Sony2FujiProcessor.Buffer
            let comparison: (UIImage?, [CGFloat])?
            do {
                comparison = comparisonChanged ? try self.renderComparison(
                    url: nil, buffer: inputBuffer, geometry: referenceSettings.geometry, processing: referenceSettings.processing,
                            lens: referenceSettings.lensSettings, longEdge: maxDimension) : nil
                outputBuffer = try self.processor.processBuffer(
                    buffer: inputBuffer,
                    settings: settings,
                    previewLongEdge: CGFloat(maxDimension),
                    lutURL: lutURL,
                    interactive: quality == .interactive,
                    viewportPreview: true
                )
            } catch {
                self.resultDelivery {
                    guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                        return
                    }
                    self.previewFailed = true
                    self.statusMessage = error.localizedDescription
                }
                return
            }

            let previewImage = self.processor.makeUIImage(from: outputBuffer, orientation: .up)

            self.resultDelivery {
                guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                    return
                }
                self.previewImage = previewImage
                self.acceptedPreviewFrameID = renderID
                self.histogram = []
                self.nativeImageSize = outputBuffer.nativeSize
                if let comparison {
                    self.applyComparison(comparison, geometry: referenceSettings.geometry, processing: referenceSettings.processing,
                                         lens: referenceSettings.lensSettings, key: referenceKey)
                }
                self.lensInfo = nil
            }

            if includeHistogram {
                self.scheduleHistogramUpdate(
                    for: outputBuffer,
                    renderID: renderID,
                    sourceRevision: sourceRevision,
                    delay: finalHistogramDelay
                )
            }
        }
        previewWorkItem = workItem
        renderQueue.async(execute: workItem)
    }

    func renderComparison(url: URL?, buffer: Sony2FujiProcessor.Buffer?,
                          geometry: GeometrySettings, processing: ProcessingIdentity,
                          lens: LensCorrectionSettings = LensCorrectionSettings(), longEdge: Int? = nil) throws -> (UIImage?, [CGFloat]) {
        var neutral = RawSettings.default
        neutral.geometry = geometry
        neutral.processing = processing
        neutral.lensCorrection = lens
        let output: Sony2FujiProcessor.Buffer
        if let url {
            output = try processor.processRaw(url: url, settings: neutral,
                previewLongEdge: CGFloat(longEdge ?? Int(previewMaxDimension)), lutURL: nil, viewportPreview: true).buffer
        } else if let buffer {
            output = try processor.processBuffer(buffer: buffer, settings: neutral,
                previewLongEdge: CGFloat(longEdge ?? Int(previewMaxDimension)), lutURL: nil, viewportPreview: true)
        } else { throw EditorError.noImageLoaded }
        return (processor.makeUIImage(from: output, orientation: .up),
                processor.computeHistogram(from: output, bins: histogramBins))
    }

    func applyComparison(_ comparison: (UIImage?, [CGFloat]), geometry: GeometrySettings, processing: ProcessingIdentity,
                         lens: LensCorrectionSettings = LensCorrectionSettings(), key: ComparisonReferenceKey? = nil) {
        basePreviewImage = comparison.0
        baseHistogram = comparison.1
        basePreviewGeometry = geometry
        basePreviewProcessing = processing
        basePreviewLens = lens
        comparisonReferenceKey = key
    }

    func comparisonKey(settings: RawSettings, longEdge: Int) -> ComparisonReferenceKey {
        ComparisonReferenceKey(sourceRevision: sourceRevision, file: sourceFile, identity: sourceIdentity,
                               kind: sourceKind, processing: settings.processing, geometry: settings.geometry,
                               lens: settings.lensSettings, longEdge: longEdge)
    }

    func retryPreview(settings: RawSettings) {
        guard !isBusy, !previewRendering, !previewResizePending else { return }
        lastPreviewRequest = nil
        updatePreview(settings: settings)
    }

    func recordImportedComparison(settings: RawSettings) {
        committedPreviewSettings = settings
        basePreviewLens = settings.lensSettings
        comparisonReferenceKey = comparisonKey(settings: settings, longEdge: Int(previewMaxDimension))
        acceptedPreviewFrameID = UUID()
        previewFailed = false
    }

    func schedulePreviewUpdate(
        settings: RawSettings,
        delay: TimeInterval,
        includeHistogram: Bool,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        guard !isBusy else { return }
        currentPreviewSettings = settings
        previewWorkItem?.cancel()
        setLatestRenderID(UUID())
        previewRendering = true

        let sourceRevision = self.sourceRevision
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.sourceRevision == sourceRevision, !self.isBusy else { return }
            self.updatePreview(
                settings: settings,
                includeHistogram: includeHistogram,
                quality: quality,
                histogramDelay: histogramDelay
            )
        }
        previewWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }
}

extension RawEditorViewModel {
    func invalidatePreviewRequests() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewResizeWorkItem?.cancel()
        previewResizeWorkItem = nil
        previewResizePending = false
        cancelHistogramWorkItem()
        setLatestRenderID(UUID())
        lastPreviewRequest = nil
        previewRendering = false
        previewFailed = false
        comparisonReferenceKey = nil
        acceptedPreviewFrameID = nil
    }

    func setLatestRenderID(_ renderID: UUID) {
        renderStateLock.lock()
        latestRenderID = renderID
        renderStateLock.unlock()
    }

    func isLatestRenderID(_ renderID: UUID) -> Bool {
        renderStateLock.lock()
        let isLatest = latestRenderID == renderID
        renderStateLock.unlock()
        return isLatest
    }

    func cancelHistogramWorkItem() {
        renderStateLock.lock()
        histogramWorkItem?.cancel()
        histogramWorkItem = nil
        renderStateLock.unlock()
    }

    func setHistogramWorkItem(_ workItem: DispatchWorkItem) {
        renderStateLock.lock()
        histogramWorkItem?.cancel()
        histogramWorkItem = workItem
        renderStateLock.unlock()
    }

    func scheduleHistogramUpdate(
        for buffer: Sony2FujiProcessor.Buffer,
        renderID: UUID,
        sourceRevision: UUID,
        delay: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            let histogram = self.computeHistogram(from: buffer, bins: self.histogramBins)
            self.resultDelivery {
                guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID),
                      self.acceptedPreviewFrameID == renderID else {
                    return
                }
                self.histogram = histogram
            }
        }

        setHistogramWorkItem(workItem)

        if delay > 0 {
            renderQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            renderQueue.async(execute: workItem)
        }
    }

    func computeHistogram(from buffer: Sony2FujiProcessor.Buffer, bins: Int) -> [CGFloat] {
        processor.computeHistogram(from: buffer, bins: bins)
    }
}
