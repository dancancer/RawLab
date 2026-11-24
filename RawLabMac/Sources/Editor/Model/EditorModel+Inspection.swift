import CoreGraphics
import Foundation
import RawLabKit
import RawLabNative

extension EditorModel {
    var inspectionAfterImage: CGImage? {
        result?.hdr?.sdrImage ?? result?.image
    }

    var inspectionBeforeImage: CGImage? {
        neutral?.hdr?.sdrImage ?? neutral?.image
    }

    var effectiveInspectionSourceSize: CGSize? {
        if let sourceNativeSize { return sourceNativeSize }
        guard let image = inspectionAfterImage else { return nil }
        let outputSize = CGSize(
            width: CGFloat(result?.nativeWidth ?? image.width),
            height: CGFloat(result?.nativeHeight ?? image.height)
        )
        return GeometryCoordinateMapper.inferSourceSize(outputSize: outputSize, geometry: settings.geometrySettings)
    }

    func updateInspectionHover(_ outputPoint: CGPoint?) {
        if inspection.liveOutputPoint != outputPoint {
            inspection.liveOutputPoint = outputPoint
        }
    }

    @discardableResult
    func pinInspectionAnchor(atOutputPoint point: CGPoint? = nil) -> InspectionAnchor? {
        guard let sourceSize = effectiveInspectionSourceSize else { return nil }
        let targetOut = point ?? inspection.liveOutputPoint ?? CGPoint(x: 0.5, y: 0.5)
        guard let srcPoint = GeometryCoordinateMapper.outputNormToSourceNorm(
            targetOut,
            sourceSize: sourceSize,
            geometry: settings.geometrySettings
        ) else { return nil }
        return inspection.pinAnchor(atSourcePoint: srcPoint)
    }

    func inspectionDisplayPoint(for anchor: InspectionAnchor) -> CGPoint? {
        guard let sourceSize = effectiveInspectionSourceSize else { return nil }
        return GeometryCoordinateMapper.sourceNormToOutputNorm(
            anchor.sourcePoint,
            sourceSize: sourceSize,
            geometry: settings.geometrySettings
        )
    }

    func inspectionMarkerPoints() -> [(index: Int, point: CGPoint, selected: Bool)] {
        guard geometryDraft == nil else { return [] }
        return inspection.anchors.enumerated().compactMap { idx, anchor in
            guard let pt = inspectionDisplayPoint(for: anchor) else { return nil }
            return (idx + 1, pt, inspection.selectedAnchorID == anchor.id)
        }
    }

    func sampleInspectionAfter(atOutputPoint point: CGPoint) -> InspectionColorSample? {
        guard let image = inspectionAfterImage else { return nil }
        return InspectionSamplerCache.shared.sample(image, atNormalized: point, radiusPixels: 1)
    }

    func sampleInspectionBefore(atOutputPoint point: CGPoint) -> InspectionColorSample? {
        guard let image = inspectionBeforeImage else { return nil }
        return InspectionSamplerCache.shared.sample(image, atNormalized: point, radiusPixels: 1)
    }

    func inspectionLiveSample(showingBefore: Bool) -> InspectionColorSample? {
        guard geometryDraft == nil else { return nil }
        if let live = inspection.liveOutputPoint {
            return showingBefore ? sampleInspectionBefore(atOutputPoint: live) : sampleInspectionAfter(atOutputPoint: live)
        }
        if let selectedID = inspection.selectedAnchorID,
           let anchor = inspection.anchors.first(where: { $0.id == selectedID }),
           let out = inspectionDisplayPoint(for: anchor) {
            return showingBefore ? sampleInspectionBefore(atOutputPoint: out) : sampleInspectionAfter(atOutputPoint: out)
        }
        return nil
    }

    func inspectionLuminanceCursor(showingBefore: Bool) -> Double? {
        inspectionLiveSample(showingBefore: showingBefore)?.luminance
    }
}
