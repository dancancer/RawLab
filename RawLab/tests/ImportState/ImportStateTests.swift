import Foundation
import ImageIO
import UIKit

@main
struct ImportStateTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure.message(message) }
        assertions += 1
        print("PASS: \(message)")
    }
    private static func deliver(_ completions: [() -> Void]) throws {
        try check(Thread.isMainThread, "Completed results are manually released on the main thread")
        completions.forEach { $0() }
    }
    private static func importCurrent(_ f: Fixture, url: URL, identity: PhotoIdentity,
                                      restored: ((RawSettings) -> Void)? = nil) throws {
        f.model.importImage(from: .raster(url), identity: identity, onSettingsRestored: restored)
        try deliver(f.collector.take())
        try check(f.model.hasImage && !f.model.isBusy && f.model.sourceIdentity == identity &&
                  f.model.sourceDisplayName == url.lastPathComponent, "Current generated raster publishes its source and finishes import")
        try check(f.model.previewImage != nil && f.model.basePreviewImage != nil && f.model.nativeImageSize != nil &&
                  !f.model.histogram.isEmpty && !f.model.baseHistogram.isEmpty, "Current raster publishes pixels, dimensions and both histograms")
    }
    private static func renderHeld(_ f: Fixture, settings: RawSettings) throws -> [() -> Void] {
        f.model.updatePreview(settings: settings, includeHistogram: true, quality: .final, histogramDelay: 0)
        // Render work can enqueue its histogram behind the first barrier.
        f.model.renderQueue.sync {}
        f.model.renderQueue.sync {}
        return try f.collector.take()
    }
    private static func normalFlow(_ f: Fixture) throws {
        var restored: [RawSettings] = []
        try importCurrent(f, url: f.aURL, identity: f.aIdentity) { restored.append($0) }
        try check(restored == [f.aSettings], "A restores exactly A's persisted settings once")
        let original = PublishedContent(f.model)
        var changed = f.aSettings
        changed.exposure = 0.7; changed.geometry.cropX = 0.2; changed.geometry.cropWidth = 0.6
        let results = try renderHeld(f, settings: changed)
        try check(f.model.previewRendering, "Normal preview stays pending until publication")
        try deliver(results)
        try check(!f.model.previewRendering && f.model.previewImage?.pngData() != original.preview &&
                  f.model.histogram != original.histogram, "Normal edit publishes new pixels and histogram and finishes")
        try check(f.model.nativeImageSize != original.nativeSize && f.model.basePreviewGeometry == changed.geometry &&
                  f.model.sourceIdentity == f.aIdentity, "Normal geometry updates dimensions/comparison and preserves source ownership")
    }
    private static func lateSuccess(_ f: Fixture) throws {
        var aCallbacks: [RawSettings] = [], bCallbacks: [RawSettings] = []
        f.model.importImage(from: .raster(f.aURL), identity: f.aIdentity) { aCallbacks.append($0) }
        let a = try f.collector.take()
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity) { bCallbacks.append($0) }
        let b = try f.collector.take()
        try check(f.model.isBusy && !f.model.hasImage, "Unpublished A stays out of the pending B source")
        try deliver(b)
        let publishedB = PublishedContent(f.model), revision = f.model.sourceRevision
        try check(publishedB.identity == f.bIdentity && publishedB.restored == f.bSettings && bCallbacks == [f.bSettings],
                  "B publishes and restores exactly B's own settings")
        try deliver(a)
        try check(PublishedContent(f.model) == publishedB && f.model.sourceRevision == revision &&
                  !f.model.isBusy && f.model.statusMessage == nil, "Late A success cannot replace B's pixels/source/geometry/histograms/status")
        try check(aCallbacks.isEmpty && bCallbacks == [f.bSettings], "Rejected A success cannot invoke its settings-restored callback")
    }
    private static func lateFailure(_ f: Fixture, whileBPending: Bool) throws {
        var failedCallbacks = 0, bCallbacks: [RawSettings] = []
        f.model.importImage(from: .raster(f.missingURL), identity: f.aIdentity) { _ in failedCallbacks += 1 }
        let failure = try f.collector.take()
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity) { bCallbacks.append($0) }
        let b = try f.collector.take()
        if whileBPending {
            try deliver(failure)
            try check(f.model.isBusy && !f.model.hasImage && f.model.statusMessage == nil && f.model.sourceURL == nil,
                      "Old failure cannot clear pending B's busy state or report an error for B")
            try deliver(b)
        } else {
            try deliver(b)
            let publishedB = PublishedContent(f.model), revision = f.model.sourceRevision
            try deliver(failure)
            try check(PublishedContent(f.model) == publishedB && f.model.sourceRevision == revision &&
                      !f.model.isBusy && f.model.statusMessage == nil, "Old failure after B cannot clear B's source or preview")
        }
        try check(f.model.sourceIdentity == f.bIdentity && bCallbacks == [f.bSettings] && failedCallbacks == 0,
                  "Late failure preserves B's restoration and never restores A")
    }
    private static func cancelledImport(_ f: Fixture, fails: Bool) throws {
        try importCurrent(f, url: f.aURL, identity: f.aIdentity)
        let publishedA = PublishedContent(f.model)
        var callbacks = 0
        let request = f.model.importImage(from: .raster(fails ? f.missingURL : f.bURL), identity: f.bIdentity) { _ in callbacks += 1 }
        let held = try f.collector.take()
        try check(f.model.isBusy && PublishedContent(f.model) == publishedA, "Pending B keeps already loaded A visible")
        f.model.cancelImageImport(request)
        let revision = f.model.sourceRevision
        try check(!f.model.isBusy && PublishedContent(f.model) == publishedA, "Cancel before B publishes preserves A's complete loaded content")
        try deliver(held)
        try check(PublishedContent(f.model) == publishedA && f.model.sourceRevision == revision &&
                  !f.model.isBusy && f.model.statusMessage == nil && callbacks == 0,
                  "Cancelled B \(fails ? "failure" : "success") cannot publish or restore settings later")
        try importCurrent(f, url: f.bURL, identity: f.bIdentity)
        try check(f.model.restoredSettings == f.bSettings, "Normal B import works after cancellation")
    }
    private static func oldCancellation(_ f: Fixture) throws {
        let request = f.model.importImage(from: .raster(f.aURL), identity: f.aIdentity)
        let a = try f.collector.take()
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity)
        let b = try f.collector.take()
        f.model.cancelImageImport(request)
        try check(f.model.isBusy, "Cancelling an old request cannot cancel the current B import")
        try deliver(b)
        let publishedB = PublishedContent(f.model)
        try deliver(a)
        try check(f.model.sourceIdentity == f.bIdentity && PublishedContent(f.model) == publishedB && !f.model.isBusy,
                  "B survives old-request cancellation and late A success")
    }
    private static func busyPreview(_ f: Fixture) throws {
        try importCurrent(f, url: f.aURL, identity: f.aIdentity)
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity)
        let b = try f.collector.take()
        let pending = PublishedContent(f.model)
        let previewEdge = f.model.previewLongEdge, requestedEdge = f.model.requestedPreviewLongEdge
        var changed = f.aSettings
        changed.exposure = 1.1
        f.model.updatePreview(settings: changed, histogramDelay: 0)
        f.model.schedulePreviewUpdate(settings: changed, delay: 0, includeHistogram: true)
        f.model.updatePreviewSize(640, settings: changed)
        changed.lutID = "missing-import-state-test-look"
        f.model.updatePreview(settings: changed, histogramDelay: 0)
        // A wrongly scheduled zero-delay main work item gets a chance to run.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        f.model.renderQueue.sync {}; f.model.renderQueue.sync {}
        try check(f.model.isBusy && !f.model.previewRendering && !f.model.previewResizePending && f.collector.count == 0,
                  "Import lock rejects immediate, scheduled and unavailable-look preview requests")
        try check(PublishedContent(f.model) == pending && f.model.statusMessage == nil,
                  "Rejected busy edits cannot publish old-source pixels or clear the lock")
        try check(f.model.previewLongEdge == previewEdge && f.model.requestedPreviewLongEdge == requestedEdge,
                  "Old preview size notifications cannot change B's pending import viewport")
        try deliver(b)
        try check(f.model.sourceIdentity == f.bIdentity && !f.model.isBusy, "B still finishes normally after busy edit rejection")
    }
    private static func latePreview(_ f: Fixture, fails: Bool) throws {
        try importCurrent(f, url: f.aURL, identity: f.aIdentity)
        var aEdit = f.aSettings
        aEdit.exposure = 1.25; aEdit.geometry.cropWidth = 0.5
        if fails {
            // Negative IO fixture: exercise the real RAW error path without a
            // private RAW. This is publication testing, not RAW correctness.
            f.model.sourceKind = .raw
            f.model.sourceURL = f.missingURL.deletingPathExtension().appendingPathExtension("raw")
        }
        let old = try renderHeld(f, settings: aEdit)
        try check(old.count >= (fails ? 2 : 3), "Old render holds \(fails ? "error/finish" : "image/histogram/finish") results")
        f.model.importImage(from: .raster(f.bURL), identity: f.bIdentity)
        try deliver(f.collector.take())
        let publishedB = PublishedContent(f.model)
        var bEdit = f.bSettings; bEdit.exposure = 0.55
        let current = try renderHeld(f, settings: bEdit)
        let revision = f.model.sourceRevision
        try check(f.model.previewRendering && f.model.sourceIdentity == f.bIdentity, "B has its own active preview before old results are released")
        try deliver(old)
        try check(PublishedContent(f.model) == publishedB && f.model.sourceRevision == revision &&
                  f.model.previewRendering && f.model.statusMessage == nil && !f.model.isBusy,
                  "Old \(fails ? "error/finish" : "image/histogram/finish") cannot alter B or finish B's newer preview")
        try deliver(current)
        try check(!f.model.previewRendering && f.model.previewImage?.pngData() != publishedB.preview &&
                  f.model.histogram != publishedB.histogram && f.model.sourceIdentity == f.bIdentity,
                  "B's preview and histogram still publish normally after old results are rejected")
    }
    private static func cropSessions() throws {
        let initial = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let a = UUID(), b = UUID()
        for handle in CropHandle.allCases {
            let moved = CropInteraction.dragging(initial, handle: handle,
                                                translation: CGSize(width: 0.06, height: -0.04),
                                                canvasSize: CGSize(width: 800, height: 600), ratio: nil)
            try check(moved != initial, "\(handle): the unlocked handle has a nonzero crop movement")
            var session = CropDragSession()
            try check(session.update(rect: initial, sourceRevision: a, isEnabled: true) == initial, "\(handle): unlocked touch acquires its starting crop")
            try check(session.update(rect: moved, sourceRevision: a, isEnabled: true) == initial, "\(handle): continuous updates keep the same starting crop")
            try check(session.update(rect: moved, sourceRevision: a, isEnabled: false) == nil &&
                      session.startingRect == nil && session.isCancelled, "\(handle): lock cancels an active drag")
            try check(session.update(rect: moved, sourceRevision: a, isEnabled: true) == nil, "\(handle): unlocking does not resume the cancelled touch")
            try check(!session.cancel() && !session.end(), "\(handle): cancelled cleanup is idempotent")
            try check(session.update(rect: moved, sourceRevision: a, isEnabled: true) == moved, "\(handle): new touch works after cancellation")
            try check(session.update(rect: initial, sourceRevision: b, isEnabled: true) == nil &&
                      session.isCancelled && session.startingRect == nil, "\(handle): source switch cancels an active drag")
            _ = session.end()
            try check(session.update(rect: initial, sourceRevision: b, isEnabled: true) == initial &&
                      session.end() && !session.end(), "\(handle): new source supports a fresh touch and exactly one active end")
            var locked = CropDragSession()
            try check(locked.update(rect: initial, sourceRevision: a, isEnabled: false) == nil &&
                      locked.startingRect == nil, "\(handle): locked touch cannot acquire a crop")
            _ = locked.end()
            try check(locked.update(rect: initial, sourceRevision: a, isEnabled: true) == initial &&
                      locked.cancel() && !locked.cancel(), "\(handle): explicit cancel reports active state once")
        }
    }
    private static func loaderTask(_ probe: AsyncLoaderProbe, gated: Bool = false) -> Task<Void, Never> {
        Task.detached {
            if gated { probe.awaitGate() }
            do { probe.finish(.success(try await PhotoImportFile.loadSource(using: { try await probe.load() }))) }
            catch { probe.finish(.failure(error)) }
        }
    }
    private static func isCancelled(_ result: Result<PhotoImportSource, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }
    private static func asyncLoader(_ f: Fixture) throws {
        let before = AsyncLoaderProbe()
        let beforeTask = loaderTask(before, gated: true)
        beforeTask.cancel(); before.openGate()
        let beforeResult = try before.waitForResult()
        try check(isCancelled(beforeResult) && before.numberOfCalls == 0, "Cancellation before acquisition never calls the source loader")

        let retainedA = try PhotoImportFile.retain(f.aURL)
        let retainedB = try PhotoImportFile.retain(f.bURL)
        defer { PhotoImportFile.release(retainedA); PhotoImportFile.release(retainedB) }
        let old = AsyncLoaderProbe(), current = AsyncLoaderProbe()
        let oldTask = loaderTask(old)
        try old.waitForRequest()
        oldTask.cancel()
        let currentTask = loaderTask(current)
        try current.waitForRequest()
        try current.resume(with: .raster(retainedB))
        let currentResult = try current.waitForResult()
        if case .success(let source) = currentResult {
            try check(source.url == retainedB && FileManager.default.fileExists(atPath: retainedB.path),
                      "New B loader returns and retains ownership of B's actual acquired file")
        } else { throw TestFailure.message("Current B source loader failed") }
        try old.resume(with: .raster(retainedA))
        let oldResult = try old.waitForResult()
        try check(isCancelled(oldResult) && !FileManager.default.fileExists(atPath: retainedA.path),
                  "Cancelled A acquisition rejects its late file and releases its retained bytes")
        try check(FileManager.default.fileExists(atPath: retainedB.path), "Old A cancellation cannot release current B's file")
        _ = currentTask
    }
    private static func resizeBeforeDNG(_ f: Fixture, succeeds: Bool) throws {
        try importCurrent(f, url: f.aURL, identity: f.aIdentity)
        let original = PublishedContent(f.model)
        let originalEdge = f.model.previewLongEdge
        var settings = f.aSettings
        settings.denoise.apply(.clean)
        f.model.updatePreviewSize(640, settings: settings)
        try check(originalEdge == 1280 && f.model.previewResizePending && f.model.previewLongEdge == originalEdge &&
                  f.model.requestedPreviewLongEdge == 640,
                  "DNG \(succeeds ? "success" : "failure"): denoise resize queues before export starts")

        if !succeeds { f.model.draftBuffer = nil }
        var exportResult: Result<URL, Error>?
        var exportedURL: URL?
        defer { if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) } }
        f.model.exportDNG(settings: settings, longEdge: 64) { result in exportResult = result }
        try check(f.model.isBusy && exportResult == nil,
                  "DNG \(succeeds ? "success" : "failure"): actual export starts while resize is pending")
        let heldExport = try f.collector.take()
        // The real 0.2-second resize timer expires while the completed export
        // result is held. Do not directly perform or recreate its work item.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        f.model.renderQueue.sync {}
        try check(f.model.isBusy && exportResult == nil && !f.model.previewResizePending &&
                  f.model.previewResizeWorkItem == nil && !f.model.previewRendering &&
                  f.model.previewLongEdge == originalEdge && f.model.requestedPreviewLongEdge == 640 &&
                  f.model.lastPreviewRequest == nil && f.collector.count == 0,
                  "DNG \(succeeds ? "success" : "failure"): busy resize expires without consuming its requested edge or queuing a preview")
        try check(f.model.previewImage?.pngData() == original.preview && f.model.histogram == original.histogram,
                  "DNG \(succeeds ? "success" : "failure"): pending export preserves the loaded preview and histogram")

        // The expired resize no longer owns a work item, so a same-edge
        // notification can retain the latest settings during the busy export.
        var latest = settings
        latest.exposure = 0.9
        f.model.updatePreviewSize(640, settings: latest)
        try check(f.model.isBusy && f.model.currentPreviewSettings == latest &&
                  f.model.previewLongEdge == originalEdge && f.model.requestedPreviewLongEdge == 640,
                  "DNG \(succeeds ? "success" : "failure"): latest busy settings are retained without consuming the resize")
        try deliver(heldExport)
        guard let exportResult else { throw TestFailure.message("Held DNG result did not invoke completion") }
        switch exportResult {
        case .success(let url):
            exportedURL = url
            try check(succeeds, "DNG success is delivered only for the valid source")
            let bytes = try Data(contentsOf: url)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            try bytes.write(to: f.aURL.deletingLastPathComponent().appendingPathComponent("exported-result.dng"))
            try check(source != nil && hasDNGVersionAndSize(bytes, longEdge: 64),
                      "DNG success writes a recognized TIFF container with DNG version and final dimensions")
        case .failure(let error):
            var expectedFailure = false
            if let editorError = error as? EditorError,
               case .noImageLoaded = editorError { expectedFailure = true }
            try check(!succeeds && expectedFailure,
                      "DNG missing-buffer export delivers the expected no-image failure")
        }
        try check(!f.model.isBusy && f.model.previewResizePending &&
                  f.model.previewLongEdge == originalEdge && f.model.requestedPreviewLongEdge == 640,
                  "DNG \(succeeds ? "success" : "failure"): completion requeues the outstanding resize after clearing busy")

        // This drains only newly collected publications. It lets the real
        // resize and histogram deadlines run and waits for observable output.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline &&
            (f.model.lastPreviewRequest?.longEdge != 640 || f.model.previewRendering ||
             f.model.previewImage?.pngData() == original.preview || f.model.histogram == original.histogram) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            f.model.renderQueue.sync {}
            if f.collector.count > 0 { try deliver(f.collector.take()) }
        }
        try check(f.model.lastPreviewRequest?.longEdge == 640 &&
                  f.model.lastPreviewRequest?.settings == latest && f.model.previewLongEdge == 640,
                  "DNG \(succeeds ? "success" : "failure"): replay renders the requested edge with the latest settings")
        try check(!f.model.previewRendering && !f.model.previewResizePending && !f.model.isBusy &&
                  f.model.previewImage?.pngData() != original.preview && f.model.histogram != original.histogram &&
                  f.model.sourceIdentity == f.aIdentity && f.model.nativeImageSize != nil,
                  "DNG \(succeeds ? "success" : "failure"): replay publishes normal pixels/histogram/finish and preserves A")
    }
    private static func hasDNGVersionAndSize(_ bytes: Data, longEdge: Int) -> Bool {
        // Linear rendered DNG is a TIFF container. ImageIO recognizes this
        // fixture's container but does not expose a per-image DNG dictionary.
        guard bytes.count >= 8 else { return false }
        let little = bytes[0] == 0x49 && bytes[1] == 0x49
        guard little || (bytes[0] == 0x4d && bytes[1] == 0x4d) else { return false }
        func integer(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { value, index in
                let shift = little ? index : count - index - 1
                return value | (Int(bytes[offset + index]) << (shift * 8))
            }
        }
        guard integer(2, 2) == 42 else { return false }
        let directory = integer(4, 4)
        guard directory <= bytes.count - 2 else { return false }
        let count = integer(directory, 2)
        guard count <= (bytes.count - directory - 2) / 12 else { return false }
        var width = 0, height = 0, hasVersion = false
        for index in 0..<count {
            let entry = directory + 2 + index * 12
            let tag = integer(entry, 2), type = integer(entry + 2, 2)
            let values = integer(entry + 4, 4)
            if (tag == 256 || tag == 257) && values == 1 && (type == 3 || type == 4) {
                let dimension = integer(entry + 8, type == 3 ? 2 : 4)
                if tag == 256 { width = dimension } else { height = dimension }
            }
            if tag == 50706 && type == 1 && values == 4 { hasVersion = bytes[entry + 8] == 1 }
        }
        return hasVersion && width > 0 && height > 0 && max(width, height) == longEdge
    }
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else { throw TestFailure.message("Pass an isolated output directory and optional RAW fixture") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try check(Thread.isMainThread, "Import state harness starts on the main thread")
        try ImportCacheLifetimeTests.run(root: root.appendingPathComponent("cache-lifetime"))
        let raw = CommandLine.arguments.dropFirst(2).first.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        try ExportCacheLifetimeTests.run(root: root.appendingPathComponent("export-cache-lifetime"), rawURL: raw)
        try cropSessions()
        try normalFlow(Fixture(directory: root.appendingPathComponent("normal")))
        try lateSuccess(Fixture(directory: root.appendingPathComponent("late-success")))
        try lateFailure(Fixture(directory: root.appendingPathComponent("failure-pending")), whileBPending: true)
        try lateFailure(Fixture(directory: root.appendingPathComponent("failure-after")), whileBPending: false)
        try cancelledImport(Fixture(directory: root.appendingPathComponent("cancel-success")), fails: false)
        try cancelledImport(Fixture(directory: root.appendingPathComponent("cancel-failure")), fails: true)
        try oldCancellation(Fixture(directory: root.appendingPathComponent("old-cancel")))
        try busyPreview(Fixture(directory: root.appendingPathComponent("busy-preview")))
        try latePreview(Fixture(directory: root.appendingPathComponent("late-preview")), fails: false)
        try latePreview(Fixture(directory: root.appendingPathComponent("late-preview-error")), fails: true)
        try asyncLoader(Fixture(directory: root.appendingPathComponent("loader")))
        try resizeBeforeDNG(Fixture(directory: root.appendingPathComponent("resize-before-dng-success")), succeeds: true)
        try resizeBeforeDNG(Fixture(directory: root.appendingPathComponent("resize-before-dng-failure")), succeeds: false)
        print("PASS: import state regression suite (\(assertions) assertions)")
    }
}
