import SwiftUI

extension ContentView {
    func autoExposure() {
        guard viewModel.hasImage, !autoExposing, !viewModel.isBusy else { return }
        let snapshot = settings, revision = settingsRevision, sourceRevision = viewModel.sourceRevision
        let url = viewModel.sourceKind == .raw ? viewModel.sourceURL : nil
        let cachedSource = viewModel.cachedSource
        let buffer = viewModel.draftBuffer
        let processor = viewModel.processor
        autoExposing = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { withExtendedLifetime(cachedSource) {} }
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
}
