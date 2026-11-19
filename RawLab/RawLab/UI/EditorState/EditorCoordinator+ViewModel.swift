import RawLabKit
import Foundation

extension BatchExportModel: EditorBatchExportHandle {}

extension RawEditorViewModel: EditorCoordinatorBackend {
    var quickPresetStateIsPreparing: Bool { quickPresetState.isPreparing }
    var hasActiveAdjustmentInteraction: Bool { adjustmentInteraction != nil }
    var isRawSource: Bool { sourceKind == .raw }

    var cameraWhiteBalance: (temperature: Double, tint: Double, isCalibrated: Bool)? {
        guard let rawWhiteBalance else { return nil }
        return (rawWhiteBalance.temperature, rawWhiteBalance.tint, rawWhiteBalance.isCalibrated)
    }

    func updateCoordinatorPreview(settings: RawSettings, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality) {
        let vmQuality: RawEditorViewModel.PreviewQuality = quality == .interactive ? .interactive : .final
        updatePreview(
            settings: settings,
            includeHistogram: includeHistogram,
            quality: vmQuality,
            histogramDelay: nil
        )
    }

    func scheduleCoordinatorPreviewUpdate(settings: RawSettings, delay: TimeInterval, includeHistogram: Bool, quality: EditorCoordinatorPreviewQuality) {
        let vmQuality: RawEditorViewModel.PreviewQuality = quality == .interactive ? .interactive : .final
        schedulePreviewUpdate(
            settings: settings,
            delay: delay,
            includeHistogram: includeHistogram,
            quality: vmQuality,
            histogramDelay: nil
        )
    }

    func returnBatchSelectionToCollection() {
        batchSelection.selection.returnToCollection()
    }

    func clearAdjustmentHistoryRequest() {
        adjustmentHistoryResults = []
        adjustmentHistoryRequest = nil
    }

    func performAdjustmentHistoryStep(undo: Bool) -> [IOSAdjustmentTransferOutcome] {
        performAdjustmentHistory(undo: undo)
    }

    func cancelActiveImageImport() {
        cancelImageImport()
    }

    func appendCurrentBatchSelectionPhoto() {
        if let photo = currentAdjustmentPhoto {
            batchSelection.append(photo)
        }
    }
}
