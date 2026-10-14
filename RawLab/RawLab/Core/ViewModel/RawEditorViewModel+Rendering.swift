import CoreGraphics
import Foundation
import UIKit

extension RawEditorViewModel {
    func updatePreviewSize(_ edge: Int, settings: RawSettings) {
        guard hasImage, edge > 0,
              edge != requestedPreviewLongEdge || (edge != previewLongEdge && previewResizeWorkItem == nil) else { return }
        currentPreviewSettings = settings
        requestedPreviewLongEdge = min(Int(previewMaxDimension), edge)
        guard !isBusy else { return }
        previewResizeWorkItem?.cancel()
        previewResizePending = false
        guard requestedPreviewLongEdge != previewLongEdge else { return }
        let commit = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewResizePending = false
            self.previewResizeWorkItem = nil
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
        currentPreviewSettings = settings
        if !settings.denoise.enabled, previewResizeWorkItem != nil {
            previewResizeWorkItem?.cancel()
            previewResizeWorkItem = nil
            previewResizePending = false
            previewLongEdge = requestedPreviewLongEdge
        }
        let maxDimension = previewLongEdge
        let request = PreviewRequest(settings: settings, quality: quality,
                                     includeHistogram: includeHistogram, longEdge: maxDimension)
        if request == lastPreviewRequest, !previewRendering { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard isLookAvailable(for: settings) else {
            setLatestRenderID(UUID())
            previewRendering = false
            isBusy = false
            statusMessage = L10n.text("所选外观不可用，请重新选择外观。")
            return
        }

        lastPreviewRequest = request
        previewRendering = true

        let renderID = UUID()
        setLatestRenderID(renderID)
        cancelHistogramWorkItem()

        let finalHistogramDelay = histogramDelay ?? ((includeHistogram && quality == .final) ? self.histogramDelay : 0)
        let lutURL = lutURL(for: settings)
        let existingDraftBuffer = draftBuffer
        let existingDraftPreview = draftPreviewBuffer
        let existingOrientation = sourceOrientation
        let usesRaw = sourceKind == .raw
        let sourceURL = self.sourceURL
        let comparisonChanged = basePreviewGeometry != settings.geometry

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    if self.isLatestRenderID(renderID) { self.previewRendering = false }
                }
            }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            if usesRaw {
                guard let sourceURL else {
                    return
                }

                do {
                    let comparison = comparisonChanged ? try self.renderComparison(
                        url: sourceURL, buffer: nil, geometry: settings.geometry) : nil
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

                    DispatchQueue.main.async {
                        guard self.isLatestRenderID(renderID) else {
                            return
                        }
                        self.previewImage = previewImage
                        self.nativeImageSize = result.buffer.nativeSize
                        if let comparison { self.applyComparison(comparison, geometry: settings.geometry) }
                        self.lensInfo = result.lensInfo
                        if self.sourceOrientation == nil {
                            self.sourceOrientation = result.orientation
                        }
                    }

                    if includeHistogram {
                        self.scheduleHistogramUpdate(
                            for: result.buffer,
                            renderID: renderID,
                            delay: finalHistogramDelay
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.isLatestRenderID(renderID) else {
                            return
                        }
                        self.statusMessage = error.localizedDescription
                    }
                }
                return
            }

            let inputBuffer = existingDraftBuffer ?? existingDraftPreview
            guard let inputBuffer else {
                return
            }

            let outputBuffer: Sony2FujiProcessor.Buffer
            let comparison: (UIImage?, [CGFloat])?
            do {
                comparison = comparisonChanged ? try self.renderComparison(
                    url: nil, buffer: inputBuffer, geometry: settings.geometry) : nil
                outputBuffer = try self.processor.processBuffer(
                    buffer: inputBuffer,
                    settings: settings,
                    previewLongEdge: CGFloat(maxDimension),
                    lutURL: lutURL,
                    interactive: quality == .interactive,
                    viewportPreview: true
                )
            } catch {
                DispatchQueue.main.async {
                    guard self.isLatestRenderID(renderID) else {
                        return
                    }
                    self.statusMessage = error.localizedDescription
                }
                return
            }

            let previewImage = self.processor.makeUIImage(from: outputBuffer, orientation: .up)

            DispatchQueue.main.async {
                guard self.isLatestRenderID(renderID) else {
                    return
                }
                self.previewImage = previewImage
                self.nativeImageSize = outputBuffer.nativeSize
                if let comparison { self.applyComparison(comparison, geometry: settings.geometry) }
                self.lensInfo = nil
            }

            if includeHistogram {
                self.scheduleHistogramUpdate(
                    for: outputBuffer,
                    renderID: renderID,
                    delay: finalHistogramDelay
                )
            }
        }
        previewWorkItem = workItem
        renderQueue.async(execute: workItem)
    }

    func renderComparison(url: URL?, buffer: Sony2FujiProcessor.Buffer?,
                          geometry: GeometrySettings) throws -> (UIImage?, [CGFloat]) {
        var neutral = RawSettings.default
        neutral.geometry = geometry
        let output: Sony2FujiProcessor.Buffer
        if let url {
            output = try processor.processRaw(url: url, settings: neutral,
                previewLongEdge: previewMaxDimension, lutURL: nil).buffer
        } else if let buffer {
            output = try processor.processBuffer(buffer: buffer, settings: neutral,
                previewLongEdge: previewMaxDimension, lutURL: nil)
        } else { throw EditorError.noImageLoaded }
        return (processor.makeUIImage(from: output, orientation: .up),
                processor.computeHistogram(from: output, bins: histogramBins))
    }

    func applyComparison(_ comparison: (UIImage?, [CGFloat]), geometry: GeometrySettings) {
        basePreviewImage = comparison.0
        baseHistogram = comparison.1
        basePreviewGeometry = geometry
    }

    func schedulePreviewUpdate(
        settings: RawSettings,
        delay: TimeInterval,
        includeHistogram: Bool,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        currentPreviewSettings = settings
        previewWorkItem?.cancel()
        setLatestRenderID(UUID())
        previewRendering = true

        let workItem = DispatchWorkItem { [weak self] in
            self?.updatePreview(
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
        delay: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            let histogram = self.computeHistogram(from: buffer, bins: self.histogramBins)
            DispatchQueue.main.async {
                guard self.isLatestRenderID(renderID) else {
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
