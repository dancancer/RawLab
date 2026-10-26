import AppKit

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
              "Real RAW preflight prepares GPU AI before accepting the target")
        check(batch.job.items.first(where: { $0.input == raster })?.selected == false &&
              batch.job.items.first(where: { $0.input == raster })?.validationError != nil,
              "AI raster target is excluded during preflight")
        print("AI_PREFLIGHT_SECONDS=\(Date().timeIntervalSince(started))")
        check(batch.canRun, "Accepted RAW remains exportable")
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
        settings.aiDenoiseEnabled = false
        _ = try cached.render(raw, settings: settings, lut: nil, edge: 512)
        check(cached.lastAIBackend.isEmpty, "Disabling AI releases the active AI result and producer state")
    }
}
