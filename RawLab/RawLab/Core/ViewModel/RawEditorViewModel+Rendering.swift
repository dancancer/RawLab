import CoreGraphics
import Foundation
import UIKit

extension RawEditorViewModel {
    func updatePreview(
        settings: RawSettings,
        includeHistogram: Bool = true,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        previewWorkItem?.cancel()
        previewWorkItem = nil

        let request = PreviewRequest(settings: settings, quality: quality, includeHistogram: includeHistogram)
        if request == lastPreviewRequest {
            return
        }
        lastPreviewRequest = request

        let renderID = UUID()
        setLatestRenderID(renderID)
        cancelHistogramWorkItem()

        let maxDimension = quality == .interactive ? interactivePreviewMaxDimension : previewMaxDimension
        let finalHistogramDelay = histogramDelay ?? ((includeHistogram && quality == .final) ? self.histogramDelay : 0)
        let lutURL = lutURL(for: settings)
        let existingDraftBuffer = draftBuffer
        let existingDraftPreview = draftPreviewBuffer
        let existingOrientation = sourceOrientation
        let usesRaw = sourceKind == .raw
        let sourceURL = self.sourceURL

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            if usesRaw {
                guard let sourceURL else {
                    return
                }

                do {
                    let result = try self.processor.processRaw(
                        url: sourceURL,
                        settings: settings,
                        previewLongEdge: maxDimension,
                        lutURL: lutURL,
                        interactive: quality == .interactive
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

            let inputBuffer = quality == .interactive ? (existingDraftPreview ?? existingDraftBuffer) : existingDraftBuffer
            guard let inputBuffer else {
                return
            }

            let outputBuffer: Sony2FujiProcessor.Buffer
            do {
                outputBuffer = try self.processor.processBuffer(
                    buffer: inputBuffer,
                    settings: settings,
                    previewLongEdge: maxDimension,
                    lutURL: lutURL,
                    interactive: quality == .interactive
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

            let previewImage = self.processor.makeUIImage(from: outputBuffer, orientation: existingOrientation)

            DispatchQueue.main.async {
                guard self.isLatestRenderID(renderID) else {
                    return
                }
                self.previewImage = previewImage
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

    func schedulePreviewUpdate(
        settings: RawSettings,
        delay: TimeInterval,
        includeHistogram: Bool,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        previewWorkItem?.cancel()

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
