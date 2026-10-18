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
