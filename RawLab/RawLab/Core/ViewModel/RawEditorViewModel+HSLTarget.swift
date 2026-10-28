import UIKit

extension RawEditorViewModel {
    var hslTargetRevision: HSLTargetRevision? {
        guard acceptedPreviewFrameID != nil, acceptedPreviewRequest != nil else { return nil }
        return HSLTargetRevision(source: hslSourceRevision, request: hslFrameRevision)
    }
    func sampleHSL(point: CGPoint, settings: RawSettings, revision: HSLTargetRevision,
                   completion: @escaping (HSLTargetSample) -> Void) {
        func unavailable(_ reason: HSLTargetAvailability) -> HSLTargetSample {
            HSLTargetSample(revision: revision, availability: reason, rgb: [], weights: [], preview: true)
        }
        guard !isBusy, !previewRendering, !previewResizePending, !previewFailed, !hasAdjustmentDraft,
              let request = acceptedPreviewRequest, request.settings == settings, hslTargetRevision == revision else {
            completion(unavailable(.stale)); return
        }
        let file = sourceFile, raw = sourceKind == .raw, input = draftBuffer ?? draftPreviewBuffer
        let source = sourceRevision, look = lutURL(for: settings)
        renderQueue.async { [weak self] in
            guard let self else { return }
            var sample = unavailable(.failed)
            do {
                if raw, let file {
                    try file.withReadAccess { url in
                        sample = try self.processor.sampleHSL(url: url, buffer: nil, settings: request.settings,
                            previewLongEdge: CGFloat(request.longEdge), lutURL: look, interactive: request.quality == .interactive,
                            revision: revision, point: point)
                    }
                } else if let input {
                    sample = try self.processor.sampleHSL(url: nil, buffer: input, settings: request.settings,
                        previewLongEdge: CGFloat(request.longEdge), lutURL: look, interactive: request.quality == .interactive,
                        revision: revision, point: point)
                }
            } catch { sample = unavailable(.failed) }
            let result = sample
            self.resultDelivery {
                completion(self.sourceRevision == source && self.hslTargetRevision == revision ? result : unavailable(.stale))
            }
        }
    }
}
