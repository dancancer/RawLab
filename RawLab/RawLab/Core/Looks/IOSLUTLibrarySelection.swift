import Foundation
import Combine

final class IOSLUTLibraryPhoto {
    private let source: PhotoImportSource
    var name: String { source.displayName }
    init(_ source: PhotoImportSource) { self.source = source }
    func copy(to destination: URL) throws { try FileManager.default.copyItem(at: source.url, to: destination) }
    deinit { PhotoImportFile.release(source.url) }
}

@MainActor
final class IOSLUTLibrarySelection: ObservableObject {
    @Published private(set) var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var request: UUID?

    func load(using acquire: @escaping () async throws -> PhotoImportSource,
              selected: @escaping (IOSLUTLibraryPhoto) -> Void) {
        cancel(); error = nil; loading = true
        let id = UUID(); request = id
        task = Task { [weak self] in
            do {
                let photo = IOSLUTLibraryPhoto(try await PhotoImportFile.loadSource(using: acquire))
                guard !Task.isCancelled, let self, self.request == id else { return }
                self.loading = false; self.task = nil; self.request = nil
                selected(photo)
            } catch {
                guard !Task.isCancelled, let self, self.request == id else { return }
                self.loading = false; self.task = nil; self.request = nil
                self.error = error.localizedDescription
            }
        }
    }
    func cancel() { request = nil; task?.cancel(); task = nil; loading = false }
    deinit { task?.cancel() }
}
