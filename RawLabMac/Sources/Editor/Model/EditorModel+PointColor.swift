import AppKit
import RawLabKit
import RawLabNative

extension EditorModel {
    var pointColorEyedropperActive: Bool {
        pointColorEyedropperEnabled && adjustmentNavigation.tool == .pointColor &&
            adjustmentNavigation.expandedGroup != nil && geometryDraft == nil &&
            pendingGeometryPresentation == nil && !exporting && adjustmentSheet == nil &&
            !settings.isHDREditing
    }

    func samplePointColor(atOutputPoint point: CGPoint) {
        guard pointColorEyedropperActive, ParameterValueField.commitPendingInputs(), !busy else { return }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else {
            cancelPointColorEyedropper()
            return
        }
        guard let sample = sampleInspectionAfter(atOutputPoint: point) else {
            cancelPointColorEyedropper()
            return
        }
        let swatch = PointColorSwatch.fromSample(sample)
        var next = settings.pointColorSettings
        let maxSwatches = AdjustmentFieldSpec.SubFields.PointColor.maxSwatches
        if next.swatches.count < maxSwatches {
            next.swatches.append(swatch)
            selectedPointColorSwatchIndex = next.swatches.count - 1
        } else {
            let targetIndex = min(max(selectedPointColorSwatchIndex, 0), maxSwatches - 1)
            next.swatches[targetIndex] = swatch
            selectedPointColorSwatchIndex = targetIndex
        }
        setInteracting(true)
        settings.pointColorSettings = next
        setInteracting(false)
        pointColorEyedropperEnabled = false
    }

    func cancelPointColorEyedropper() {
        pointColorEyedropperEnabled = false
    }
}
