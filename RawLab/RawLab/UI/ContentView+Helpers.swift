import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileExportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let removeAfterExport: Bool
    let successMessage: String
    let cancelMessage: String
}

struct FileExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Bool) -> Void
        private var didComplete = false

        init(completion: @escaping (Bool) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(false)
        }

        private func finish(_ exported: Bool) {
            guard !didComplete else { return }
            didComplete = true
            completion(exported)
        }
    }
}

extension ContentView {
    func autoExposure() {
        guard viewModel.hasImage, !autoExposing, !viewModel.isBusy else { return }
        let snapshot = settings, revision = settingsRevision, sourceRevision = viewModel.sourceRevision
        let url = viewModel.sourceKind == .raw ? viewModel.sourceURL : nil
        let buffer = viewModel.draftBuffer
        let processor = viewModel.processor
        autoExposing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try processor.autoExposure(url: url, buffer: buffer, settings: snapshot) }
            DispatchQueue.main.async {
                autoExposing = false
                guard viewModel.sourceRevision == sourceRevision, settingsRevision == revision, settings == snapshot else { return }
                switch result {
                case .success(let ev):
                    var updated = settings
                    updated.exposure = ev
                    applySettingsChange(updated)
                case .failure(let error): viewModel.statusMessage = error.localizedDescription
                }
            }
        }
    }

    var editingLocked: Bool { isImporting || isSaving || batchModel?.isRunning == true }
    var editorBusy: Bool { viewModel.isBusy || viewModel.isLoadingLUTs || editingLocked }
    var selectedFilmName: String {
        settings.masterRecipe?.name ?? viewModel.availableLUTs.first { $0.id == settings.lutID }?.name ?? (settings.lutID == nil ? L10n.text("中性") : L10n.text("外观不可用"))
    }

    var currentPreviewImage: UIImage? {
        if showingBefore {
            return viewModel.basePreviewImage ?? viewModel.previewImage
        }
        return viewModel.previewImage ?? viewModel.basePreviewImage
    }

    var currentHistogram: [CGFloat] {
        if showingBefore {
            return viewModel.baseHistogram.isEmpty ? viewModel.histogram : viewModel.baseHistogram
        }
        return viewModel.histogram.isEmpty ? viewModel.baseHistogram : viewModel.histogram
    }

    func adjustmentProgress(_ adjustment: AdjustmentKind) -> Double {
        if adjustment == .tint && settings.masterRecipeID != nil { return settings.tint / 150 }
        if viewModel.sourceKind == .raw,
           adjustment == .temperature || adjustment == .tint {
            guard settings.whiteBalanceMode == .custom, let camera = viewModel.rawWhiteBalance else { return 0 }
            let isTemperature = adjustment == .temperature
            let origin = isTemperature ? RawSettings.reciprocalSliderValue(for: camera.temperature) : (camera.tint + 150) / 300
            let position = isTemperature ? RawSettings.reciprocalSliderValue(for: settings.temperature) : (settings.tint + 150) / 300
            let delta = position - origin
            let distance = delta < 0 ? origin : 1 - origin
            return distance > 0 ? min(1, max(-1, delta / distance)) : 0
        }
        return adjustment.progress(in: settings)
    }

    var manualWhiteBalanceSettings: RawSettings {
        guard viewModel.sourceKind == .raw, let camera = viewModel.rawWhiteBalance else { return settings }
        return settings.customWhiteBalance(cameraTemperature: camera.temperature, cameraTint: camera.tint)
    }

    func exportJPEG(longEdge: Int? = nil) {
        isSaving = true
        viewModel.exportJPEG(settings: settings, longEdge: longEdge) { result in
            switch result {
            case .success(let data):
                saveToPhotoLibrary(data)
            case .failure(let error):
                isSaving = false
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    func exportDNG(longEdge: Int? = nil) {
        isSaving = true
        viewModel.exportDNG(settings: settings, longEdge: longEdge) { result in
            switch result {
            case .success(let url):
                isSaving = false
                fileExportRequest = FileExportRequest(
                    urls: [url],
                    removeAfterExport: true,
                    successMessage: L10n.text("已导出渲染型 DNG。"),
                    cancelMessage: L10n.text("已生成渲染型 DNG，未另存到所选位置。")
                )
            case .failure(let error):
                isSaving = false
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    func applySettingsChange(_ newSettings: RawSettings) {
        settings = newSettings
    }

    func adjustmentBinding(_ adjustment: AdjustmentKind) -> Binding<Double> {
        Binding(
            get: { adjustment.value(from: settings) },
            set: { value in
                var updated = viewModel.sourceKind == .raw && (adjustment == .temperature || (adjustment == .tint && settings.masterRecipeID == nil))
                    ? manualWhiteBalanceSettings : settings
                adjustment.setValue(value, in: &updated)
                if viewModel.sourceKind == .raw,
                   (adjustment == .temperature || adjustment == .tint) && !(updated.masterRecipeID != nil && adjustment == .tint) {
                    updated.whiteBalanceMode = .custom
                }
                applySettingsChange(updated)
            }
        )
    }

    func reset(_ adjustment: AdjustmentKind) {
        var updated = settings
        adjustment.reset(in: &updated)
        if viewModel.sourceKind == .raw,
           adjustment == .temperature || adjustment == .tint {
            if let whiteBalance = viewModel.rawWhiteBalance {
                if adjustment == .temperature { updated.temperature = whiteBalance.temperature }
                else { updated.tint = updated.masterRecipeID == nil ? whiteBalance.tint : 0 }
                if updated.masterRecipeID != nil {
                    if adjustment == .temperature { updated.whiteBalanceMode = .camera }
                } else {
                    updated.whiteBalanceMode = updated.temperature == whiteBalance.temperature && updated.tint == whiteBalance.tint ? .camera : .custom
                }
            }
        }
        applySettingsChange(updated)
    }

    func setWhiteBalanceMode(_ mode: RawWhiteBalanceMode) {
        var updated = settings
        if mode == .custom,
           settings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            updated.temperature = whiteBalance.temperature
            if updated.masterRecipeID == nil { updated.tint = whiteBalance.tint }
        }
        updated.whiteBalanceMode = mode
        if mode == .camera, let whiteBalance = viewModel.rawWhiteBalance {
            updated.temperature = whiteBalance.temperature
            updated.tint = updated.masterRecipeID == nil ? whiteBalance.tint : 0
        }
        applySettingsChange(updated)
    }

    var displayedTemperature: Double {
        if viewModel.sourceKind == .raw,
           settings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            return whiteBalance.temperature
        }
        return settings.temperature
    }

    var displayedTint: Double {
        if settings.masterRecipeID != nil { return settings.tint }
        if viewModel.sourceKind == .raw,
           settings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            return whiteBalance.tint
        }
        return settings.tint
    }

    func reciprocalTemperatureBinding() -> Binding<Double> {
        Binding(
            get: { RawSettings.reciprocalSliderValue(for: displayedTemperature) },
            set: { value in
                var updated = manualWhiteBalanceSettings
                updated.temperature = RawSettings.temperature(forReciprocalSliderValue: value)
                updated.whiteBalanceMode = .custom
                applySettingsChange(updated)
            }
        )
    }

    func temperatureNumberBinding() -> Binding<Double> {
        Binding(
            get: { displayedTemperature },
            set: { value in
                guard value.isFinite else { return }
                var updated = manualWhiteBalanceSettings
                updated.temperature = min(max(value.rounded(), RawSettings.temperatureRange.lowerBound),
                                          RawSettings.temperatureRange.upperBound)
                updated.whiteBalanceMode = .custom
                applySettingsChange(updated)
            }
        )
    }

    func setSliderEditing(_ editing: Bool) {
        isAdjustingSlider = editing
        if !editing {
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
        }
    }

    func photoImportButton(isEnabled: Bool) -> some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
            Image(systemName: "photo.badge.plus")
        }
        .accessibilityLabel(L10n.text("导入照片"))
        .help(L10n.text("从照片图库导入"))
        .accessibilityIdentifier("editor.import")
        .disabled(!isEnabled)
    }

    func importFromPhotoItem(_ item: PhotosPickerItem) async {
        guard viewModel.saveCurrentSettings(settings) else { selectedPhotoItem = nil; return }
        isImporting = true
        showingBefore = false
        do {
            let source = try await loadPhotoSource(from: item)
            let identity = item.itemIdentifier.flatMap { $0.isEmpty ? nil : PhotoIdentity(resourceIdentifier: $0) }
                ?? (try? PhotoIdentity.fallback(for: source.url))
            await MainActor.run {
                viewModel.importImage(from: source, identity: identity, settings: .default,
                    onImported: { UsageAnalytics.shared.record(.photoImported) }) { restored in
                    settings = restored
                }
                selectedPhotoItem = nil
            }
        } catch {
            await MainActor.run {
                isImporting = false
                viewModel.statusMessage = error.localizedDescription
                selectedPhotoItem = nil
            }
        }
    }

    func openBatchExport() {
        if batchModel != nil { showingBatchExport = true; return }
        guard let source = viewModel.currentBatchSource(settings: settings) else {
            viewModel.statusMessage = L10n.text("请先导入一张 RAW 照片。")
            return
        }
        guard source.sourceKind == .raw else {
            viewModel.statusMessage = L10n.text("批量导出目前仅支持 RAW 照片。")
            return
        }
        batchModel = BatchExportModel(source: source, editor: viewModel)
        batchModel?.onUsage = { UsageAnalytics.shared.record($0) }
        batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false }
        showingBatchExport = true
    }

    func recoverBatchExport() {
        do {
            let journal = try BatchJournalStore.appStore()
            if let job = try journal.pendingJobs().first {
                batchModel = BatchExportModel(job: job, journalStore: journal)
                batchModel?.onUsage = { UsageAnalytics.shared.record($0) }
                batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
            }
        } catch { viewModel.statusMessage = L10n.format("无法恢复批量任务：%@", String(describing: error.localizedDescription)) }
    }

    func loadPhotoSource(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        try await PhotoImportFile.load(from: item)
    }

    func saveToPhotoLibrary(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    viewModel.statusMessage = L10n.text("无法保存照片，请在系统设置中允许添加照片。")
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    isSaving = false
                    if let error = error {
                        viewModel.statusMessage = error.localizedDescription
                    } else if success {
                        UsageAnalytics.shared.record(.exportCompleted)
                        viewModel.statusMessage = L10n.text("已保存到照片。")
                    } else {
                        viewModel.statusMessage = L10n.text("保存失败，请重试。")
                    }
                }
            })
        }
    }
}
