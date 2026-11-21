import RawLabKit
import SwiftUI

extension ContentView {
    var currentPhotoPreviewSource: IOSPhotoPreviewSource? {
        guard let identity = viewModel.sourceIdentity, let file = viewModel.sourceFile, let kind = viewModel.sourceKind else { return nil }
        return .init(identity: identity, file: file, displayName: viewModel.sourceDisplayName ?? file.displayName, isRaw: kind == .raw)
    }

    func showRecentPhotos() {
        coordinator.showRecentPhotos()
    }

    func recordRecentPhoto() {
        guard let source = currentPhotoPreviewSource, viewModel.hasImage, viewModel.activeImportRevision == nil else { return }
        let image = viewModel.previewImage
        let directory = viewModel.editPersistence?.directory
        Task { await photoPreviews.recordOpened(source, preview: image, editDirectory: directory) }
    }

    func cacheCurrentPhotoPreview() {
        guard !isEditorDraftActive, !viewModel.previewFailed, let source = currentPhotoPreviewSource,
              let record = viewModel.loadedEditRecord, let saved = record.state,
              let request = viewModel.acceptedPreviewRequest, request.quality == .final,
              saved.hasSameAdjustments(as: viewModel.currentEditState(settings: request.settings)),
              let image = viewModel.previewImage, let directory = viewModel.editPersistence?.directory,
              let completed = viewModel.completedPreviewCache.last(where: { $0.previewImage === image && $0.key.settings == request.settings }),
              completed.key.lut == viewModel.previewLUTIdentity(for: viewModel.lutURL(for: request.settings)) else { return }
        let look = viewModel.lutURL(for: request.settings)
        Task { await photoPreviews.accept(source, record: record, image: image, look: look, editDirectory: directory) }
    }

    func finishRecentPhotos() {
        coordinator.finishRecentPhotos { photo in
            Task { await openRecentPhoto(photo) }
        }
    }

    @MainActor func openRecentPhoto(_ photo: RecentPhoto) async {
        guard !editorBusy, !isEditorDraftActive, viewModel.saveCurrentSettings(settings) else { return }
        coordinator.isImporting = true
        do {
            let source = try await photoPreviews.source(for: photo)
            try Task.checkCancellation()
            try await resolveLegacyAssetEdit(for: source.identity)
            try Task.checkCancellation()
            let input = source.file.withReadAccess { PhotoImportSource(url: $0, isRaw: source.isRaw, originalName: source.displayName) }
            viewModel.importImage(from: input, identity: source.identity, retainedInput: source.file,
                diagnosticContext: ["entryPoint": "recentPhotos"], onImported: { UsageAnalytics.shared.record(.photoImported) }) { restored in
                    settings = restored
                    if restored.isHDREditing {
                        coordinator.selectedGroup = .light
                        coordinator.selectedAdjustment = .exposure
                        coordinator.selectedHDRRenditionTool = nil
                    }
                }
        } catch is CancellationError {
            coordinator.isImporting = false
        } catch {
            coordinator.isImporting = false
            coordinator.recentFailedPhoto = photo
            coordinator.recentOpenError = error.localizedDescription
        }
    }
}
