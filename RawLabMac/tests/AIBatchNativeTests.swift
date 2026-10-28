import AppKit
import SwiftUI
import Combine

@main struct AIBatchNativeTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; print("PASS: \(message)")
    }
    static func wait(_ message: String, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(240)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(done(), message)
    }
    static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        check(caches.path.hasPrefix(root.path), "Native AI acceptance uses an isolated cache")
        check(RenderEngine.bundledAIModel != nil, "Test application resolves the bundled complete AI package")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let raster = root.appendingPathComponent("raster.png")
        let ordinary = try RenderEngine()
        _ = try ordinary.render(raw, settings: Adjustments(), lut: nil, edge: nil, output: raster, exportLongEdge: 128)
        var settings = Adjustments(); settings.aiDenoiseEnabled = true
        var job = BatchExportJob(source: raw, settings: settings, look: nil, lookName: "Neutral")
        job.outputDirectory = output; job.longEdge = 512; job.format = .png
        let batch = BatchExportModel(job: job, journal: BatchJournal(directory: root.appendingPathComponent("journal")))
        let started = Date()
        batch.add([raw, raster])
        wait("AI batch preflight completed") { !batch.validating }
        check(batch.job.items.first(where: { $0.input == raw })?.selected == true &&
              batch.job.items.first(where: { $0.input == raw })?.validationError == nil,
              "RAW is accepted without preparing AI during preflight")
        check(batch.job.items.first(where: { $0.input == raster })?.selected == false &&
              batch.job.items.first(where: { $0.input == raster })?.validationError != nil,
              "AI raster target is excluded during preflight")
        let preflightSeconds = Date().timeIntervalSince(started)
        print("AI_PREFLIGHT_SECONDS=\(preflightSeconds)")
        check(preflightSeconds < 5, "AI preflight performs only input and capability checks")
        check(batch.canRun, "Accepted RAW remains exportable")
        let host = NSHostingView(rootView: BatchExportView(model: batch))
        host.frame = NSRect(x: 0, y: 0, width: 1040, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        var sawProgress = false
        var capturedProgress = false
        let progressSubscription = batch.$aiProgress.sink { value in
            if value != nil && !sawProgress {
                sawProgress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    host.layoutSubtreeIfNeeded()
                    check(batch.aiProgress != nil, "Native batch view receives the active AI progress")
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let captures = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : root
                    try! FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: captures.appendingPathComponent("batch-ai-progress.png"))
                    capturedProgress = true; batch.cancel()
                }
            }
        }
        batch.start()
        wait("AI batch cancellation completed") { !batch.running }
        withExtendedLifetime(progressSubscription) {}
        progressSubscription.cancel()
        check(sawProgress && capturedProgress, "AI preparation publishes progress in the rendered native batch view")
        check(batch.job.cancelled && batch.job.failedCount == 0 && batch.job.items.first(where: { $0.input == raw })?.status == .waiting,
              "Cancelling AI preparation keeps the RAW item retryable")
        let exportStarted = Date(); batch.start()
        wait("AI batch export completed") { !batch.running }
        check(batch.job.succeededCount == 1 && batch.job.failedCount == 0, "Preflight and real AI batch export agree")
        let result = batch.job.items.first(where: { $0.input == raw })!.output!
        check(FileManager.default.fileExists(atPath: result.path), "AI batch publishes its rendered output")
        print("AI_BATCH_SECONDS=\(Date().timeIntervalSince(exportStarted))")
        let cached = try RenderEngine()
        var inference = false
        let progress = AIPreparation { phase, done, total in
            if (phase == 2 || phase == 3) && (done != 1 || total != 1) { inference = true }
        }
        try cached.prepareAI(raw, settings: settings, progress: progress)
        check(!inference && cached.lastAIBackend.contains("CoreML"), "New render session reuses the complete GPU result")
        _ = try cached.render(raw, settings: settings, lut: nil, edge: 512)
        let collection = EditorModel(lookDirectory: root.appendingPathComponent("collection-looks"),
            editDirectory: root.appendingPathComponent("collection-edits"), batchDirectory: root.appendingPathComponent("collection-batch"),
            presetDirectory: root.appendingPathComponent("collection-presets"))
        collection.addCollectionPhotos([raw])
        try collection.editStore!.save(raw, state: PhotoEditState(settings: settings, filmID: ""))
        let review = try collection.prepareCollectionExport(skipping: [], format: .png, longEdge: 256, directory: output)
        check(review.ready && review.snapshots.count == 1 && review.snapshots[0].settings.aiDenoiseEnabled,
              "Collection preflight retains enabled AI for the RAW target")
        let frozen = try collection.freezeCollectionExport(review)
        check(frozen.items[0].frozen?.settings.aiDenoiseEnabled == true, "Collection freeze preserves AI in the per-photo snapshot")
        collection.batch!.start()
        wait("AI collection batch export completed") { !collection.batch!.running }
        check(collection.batch!.job.succeededCount == 1 && collection.batch!.job.failedCount == 0,
              "Collection export prepares AI through the same batch runner")
        settings.aiDenoiseEnabled = false
        _ = try cached.render(raw, settings: settings, lut: nil, edge: 512)
        check(cached.lastAIBackend.isEmpty, "Disabling AI releases the active AI result and producer state")
    }
}
