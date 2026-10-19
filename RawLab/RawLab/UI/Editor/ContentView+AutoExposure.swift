import SwiftUI

extension ContentView {
    func autoExposure() {
        guard viewModel.hasImage, !autoExposing, !viewModel.isBusy else { return }
        let snapshot = settings, revision = settingsRevision, sourceRevision = viewModel.sourceRevision
        let sourceFile = viewModel.sourceKind == .raw ? viewModel.sourceFile : nil
        let buffer = viewModel.draftBuffer
        let processor = viewModel.processor
        autoExposing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                if let sourceFile {
                    return try sourceFile.withReadAccess { try processor.autoExposure(url: $0, buffer: buffer, settings: snapshot) }
                }
                return try processor.autoExposure(url: nil, buffer: buffer, settings: snapshot)
            }
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
