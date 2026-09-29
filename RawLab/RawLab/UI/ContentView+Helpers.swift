import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ContentView {
    var editingLocked: Bool { isImporting || isSaving }
    var editorBusy: Bool { viewModel.isBusy || editingLocked }
    var selectedFilmName: String {
        viewModel.availableLUTs.first { $0.id == settings.lutID }?.name ?? "中性"
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
                var updated = settings
                adjustment.setValue(value, in: &updated)
                applySettingsChange(updated)
            }
        )
    }

    func reset(_ adjustment: AdjustmentKind) {
        var updated = settings
        adjustment.reset(in: &updated)
        applySettingsChange(updated)
    }

    func setSliderEditing(_ editing: Bool) {
        isAdjustingSlider = editing
        if !editing {
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
        }
    }

    func photoImportButton(isEnabled: Bool) -> some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Image(systemName: "photo.badge.plus")
        }
        .accessibilityLabel("导入照片")
        .help("从照片图库导入")
        .accessibilityIdentifier("editor.import")
        .disabled(!isEnabled)
    }

    func importFromPhotoItem(_ item: PhotosPickerItem) async {
        isImporting = true
        showingBefore = false
        do {
            let source = try await loadPhotoSource(from: item)
            await MainActor.run {
                viewModel.importImage(from: source, settings: settings)
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

    func loadPhotoSource(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        let supportsRaw = item.supportedContentTypes.contains { $0.conforms(to: .rawImage) }
        if supportsRaw, let file = try await item.loadTransferable(type: RawPhotoFile.self) {
            return .raw(file.url)
        }

        if let file = try await item.loadTransferable(type: ImagePhotoFile.self) {
            return .raster(file.url)
        }

        throw PhotoImportError.unsupportedItem
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
