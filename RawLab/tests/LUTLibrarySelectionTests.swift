import Foundation

@main
@MainActor struct LUTLibrarySelectionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.png")
        try Data([1, 2, 3, 4]).write(to: original)
        let selection = IOSLUTLibrarySelection()
        var acquired: IOSLUTLibraryPhoto?
        let retained = try PhotoImportFile.retain(original)
        selection.load(using: { .raster(retained) }) { acquired = $0 }
        await wait { !selection.loading }
        precondition(acquired?.name == "source.png")
        selection.cancel()
        let copy = root.appendingPathComponent("preview.png")
        try acquired!.copy(to: copy)
        let copiedBytes = try Data(contentsOf: copy), originalBytes = try Data(contentsOf: original)
        precondition(copiedBytes == originalBytes)
        precondition(FileManager.default.fileExists(atPath: retained.path))
        acquired = nil
        precondition(!FileManager.default.fileExists(atPath: retained.path), "Acquired source outlived its owner")

        var resume: CheckedContinuation<PhotoImportSource, Never>?
        let cancelled = try PhotoImportFile.retain(original)
        var publications = 0
        selection.load(using: { await withCheckedContinuation { resume = $0 } }) { _ in publications += 1 }
        await wait { resume != nil }
        selection.cancel()
        resume!.resume(returning: .raster(cancelled)); resume = nil
        await wait { !FileManager.default.fileExists(atPath: cancelled.path) }
        precondition(publications == 0 && !selection.loading)

        let obsolete = try PhotoImportFile.retain(original)
        selection.load(using: { await withCheckedContinuation { resume = $0 } }) { _ in publications += 1 }
        await wait { resume != nil }
        let latest = try PhotoImportFile.retain(original)
        selection.load(using: { .raster(latest) }) { acquired = $0; publications += 1 }
        await wait { !selection.loading }
        resume!.resume(returning: .raster(obsolete)); resume = nil
        await wait { !FileManager.default.fileExists(atPath: obsolete.path) }
        precondition(publications == 1 && acquired != nil)
        acquired = nil
        precondition(!FileManager.default.fileExists(atPath: latest.path))
        selection.load(using: { throw PhotoImportError.loadFailed }) { _ in publications += 1 }
        await wait { !selection.loading }
        precondition(selection.error != nil && publications == 1, "Failed acquisition published a photo")
        print("PASS: library source ownership, cancellation and superseded-result cleanup")
    }

    private static func wait(_ completed: () -> Bool) async {
        for _ in 0..<200 {
            if completed() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(completed(), "Library selection operation timed out")
    }
}
