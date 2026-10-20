import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct UsageModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func waitForRender(_ model: EditorModel, success: Bool) {
        // Include the debounce interval, not only an already-running request.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(!model.busy, "render terminates")
        check(success ? model.result != nil && model.error == nil : model.result == nil && model.error != nil,
              "render reaches the expected success or failure state")
    }
    static func raster(_ root: URL, name: String, type: UTType) throws -> URL {
        var bytes: [UInt8] = []
        for index in 0..<(16 * 12) {
            bytes += [UInt8(40 + index % 150), UInt8(50 + index % 140), 180, 255]
        }
        let pixels = Data(bytes)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 16, height: 12, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "raster fixture encodes")
        return url
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-usage-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [UsageEvent] = []
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"),
            batchDirectory: root.appendingPathComponent("batch"), onUsage: { events.append($0) })
        model.selectedFilmID = "restored-private-name"
        check(events.isEmpty, "restored state is not a user film selection")
        model.selectFilm("")
        check(events == [.filmSelected(.none)], "user selection records only a safe kind")
        model.selectFilm("")
        check(events.count == 1, "unchanged selection is not counted")
        model.selectFilm("unknown-private-path")
        check(events.count == 1, "invalid film identity is not an event")
        let builtIn = Film(name: "Private built-in name", url: root.appendingPathComponent("built-in.cube"))
        let custom = Film(name: "Private custom name", url: root.appendingPathComponent("custom.cube"), managedID: "private-id")
        model.films = [builtIn, custom]
        model.selectFilm(builtIn.id)
        model.selectFilm(custom.id)
        model.selectFilm("")
        check(events == [.filmSelected(.none), .filmSelected(.builtIn), .filmSelected(.custom), .filmSelected(.none)],
              "explicit film selection emits only neutral, built-in and custom kinds")
        let filmEvents = events
        let invalid = root.appendingPathComponent("bad.ARW")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a raw photo".utf8).write(to: invalid)
        fputs("[EXPECTED RAW FAILURE] UsageModelTests.failedImport: \(invalid.path) contains text, not a RAW photo. The next import must fail without emitting a success event.\n", stderr)
        model.open(invalid)
        waitForRender(model, success: false)
        check(events == filmEvents, "failed photo import does not count success")
        print("PASS: user-only film events and failed import")
        let png = try raster(root, name: "usage.png", type: .png)
        let jpeg = try raster(root, name: "usage.jpg", type: .jpeg)
        let invalidRaster = root.appendingPathComponent("corrupt.png")
        try Data("invalid image".utf8).write(to: invalidRaster)
        var importCount = 0
        for input in [png, jpeg] {
            model.open(input)
            waitForRender(model, success: true)
            importCount += 1
            check(events.filter { $0 == .photoImported }.count == importCount, "raster usable preview counts one import")
            model.settings.exposure = 0.4
            waitForRender(model, success: true)
            check(events.filter { $0 == .photoImported }.count == importCount, "raster edit does not repeat import")
            check(model.saveEdits(), "raster adjustments save in the private store")
        }
        model.open(invalidRaster)
        waitForRender(model, success: false)
        check(events.filter { $0 == .photoImported }.count == importCount, "corrupt raster does not count success")
        model.open(png)
        waitForRender(model, success: true)
        importCount += 1
        check(model.settings.exposure == 0.4 && events.filter { $0 == .photoImported }.count == importCount,
              "restored raster counts its new import once and restores edits")
        check(events.filter { if case .filmSelected = $0 { return true }; return false } == filmEvents,
              "rendering and history never masquerade as explicit film selection")
        let beforeRecipe = events
        let output = root.appendingPathComponent("not-rendered.png")
        let recipe = try RenderEngine().agentRecipe(png, settings: model.settings, lut: nil, output: output)
        check(!recipe.isEmpty && !FileManager.default.fileExists(atPath: output.path) && events == beforeRecipe,
              "Agent serialization neither publishes a file nor emits usage")
        print("PASS: JPEG/PNG import, rerender, corrupt input, history and Agent serialization usage boundaries")
        if CommandLine.arguments.count > 1 {
            fputs("[RAW SUCCESS REQUIRED] UsageModelTests.realRAW: \(CommandLine.arguments[1]) must render successfully; decoder failures for this input are not expected.\n", stderr)
            model.open(URL(fileURLWithPath: CommandLine.arguments[1]))
            waitForRender(model, success: true)
            importCount += 1
            check(events.filter { $0 == .photoImported }.count == importCount, "RAW usable preview counts one import")
            model.settings.exposure = 0.25
            waitForRender(model, success: true)
            check(events.filter { $0 == .photoImported }.count == importCount, "editing does not count import again")
            print("PASS: RAW import succeeds once, rendering adjustments do not repeat it")
            var job = BatchExportJob(source: URL(fileURLWithPath: CommandLine.arguments[1]), settings: Adjustments(), look: nil, lookName: "Private look name")
            job.outputDirectory = root; job.longEdge = 512
            var good = try BatchExportItem(url: job.source), rasterItem = try BatchExportItem(url: png), bad = try BatchExportItem(url: invalid)
            good.selected = true; rasterItem.selected = true; bad.selected = true
            job.items = [good, rasterItem, bad]
            var batchEvents: [UsageEvent] = []
            let batch = BatchExportModel(job: job, journal: BatchJournal(directory: root.appendingPathComponent("journal")),
                onUsage: { batchEvents.append($0) })
            func waitForBatch() {
                let deadline = Date().addingTimeInterval(120)
                while batch.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                check(!batch.running, "batch terminates")
            }
            fputs("[EXPECTED RAW FAILURE] UsageModelTests.mixedBatch: only \(invalid.path) is intentionally invalid; the real RAW and PNG must export successfully.\n", stderr)
            batch.start(); waitForBatch()
            check(batchEvents == [.batchExportCompleted(succeeded: 2, failed: 1, outcome: .partial)], "mixed RAW/raster batch reports published successes and actual failed attempts once")
            batch.start(.failed); batch.cancel(); waitForBatch()
            check(batchEvents.last == .batchExportCompleted(succeeded: 0, failed: 0, outcome: .cancelled), "cancelled retry does not recount old successes or failures")
            fputs("[EXPECTED RAW FAILURE] UsageModelTests.failedRetry: retrying the same invalid bad.ARW must report one failed item and no successful exports.\n", stderr)
            batch.start(.failed); waitForBatch()
            check(batchEvents.count == 3 && batchEvents.last == .batchExportCompleted(succeeded: 0, failed: 1, outcome: .partial), "failed retry counts only this run")
            print("PASS: batch success, partial failure, cancellation and retry deltas")
        }
    }
}
