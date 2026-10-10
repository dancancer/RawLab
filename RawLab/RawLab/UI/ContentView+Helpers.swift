import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ContentView {
    var editingLocked: Bool { isImporting || isSaving || batchModel?.isRunning == true }
    var editorBusy: Bool { viewModel.isBusy || viewModel.isLoadingLUTs || editingLocked }
    var selectedFilmName: String {
        viewModel.availableLUTs.first { $0.id == settings.lutID }?.name ?? (settings.lutID == nil ? "中性" : "外观不可用")
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

    func exportJPEG() {
        isSaving = true
        viewModel.exportJPEG(settings: settings) { result in
            switch result {
            case .success(let data):
                saveToPhotoLibrary(data)
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
                var updated = viewModel.sourceKind == .raw && (adjustment == .temperature || adjustment == .tint)
                    ? manualWhiteBalanceSettings : settings
                adjustment.setValue(value, in: &updated)
                if viewModel.sourceKind == .raw,
                   adjustment == .temperature || adjustment == .tint {
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
            updated.whiteBalanceMode = .camera
            if let whiteBalance = viewModel.rawWhiteBalance {
                updated.temperature = whiteBalance.temperature
                updated.tint = whiteBalance.tint
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
            updated.tint = whiteBalance.tint
        }
        updated.whiteBalanceMode = mode
        if mode == .camera, let whiteBalance = viewModel.rawWhiteBalance {
            updated.temperature = whiteBalance.temperature
            updated.tint = whiteBalance.tint
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
        .accessibilityLabel("导入照片")
        .help("从照片图库导入")
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
                viewModel.importImage(from: source, identity: identity, settings: .default) { restored in
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
            viewModel.statusMessage = "请先导入一张 RAW 照片。"
            return
        }
        guard source.sourceKind == .raw else {
            viewModel.statusMessage = "批量导出目前仅支持 RAW 照片。"
            return
        }
        batchModel = BatchExportModel(source: source, editor: viewModel)
        batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false }
        showingBatchExport = true
    }

    func recoverBatchExport() {
        do {
            let journal = try BatchJournalStore.appStore()
            if let job = try journal.pendingJobs().first {
                batchModel = BatchExportModel(job: job, journalStore: journal)
                batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
            }
        } catch { viewModel.statusMessage = "无法恢复批量任务：\(error.localizedDescription)" }
    }

    func loadPhotoSource(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        try await PhotoImportFile.load(from: item)
    }

    func saveToPhotoLibrary(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    viewModel.statusMessage = "无法保存照片，请在系统设置中允许添加照片。"
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
                        viewModel.statusMessage = "已保存到照片。"
                    } else {
                        viewModel.statusMessage = "保存失败，请重试。"
                    }
                }
            })
        }
    }
}
