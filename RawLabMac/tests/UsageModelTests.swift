import AppKit

@main struct UsageModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
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
        let invalid = root.appendingPathComponent("bad.ARW")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a raw photo".utf8).write(to: invalid)
        model.open(invalid)
        let deadline = Date().addingTimeInterval(15)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(!model.busy && model.result == nil && events.count == 1, "failed photo import does not count success")
        print("PASS: user-only film events and failed import")
        if CommandLine.arguments.count > 1 {
            model.open(URL(fileURLWithPath: CommandLine.arguments[1]))
            let deadline = Date().addingTimeInterval(120)
            while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(model.result != nil && events.filter { $0 == .photoImported }.count == 1, "usable preview counts one import")
            model.settings.exposure = 0.25
            let deadline2 = Date().addingTimeInterval(120)
            while model.busy && Date() < deadline2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(events.filter { $0 == .photoImported }.count == 1, "editing does not count import again")
            print("PASS: RAW import succeeds once, rendering adjustments do not repeat it")
            var job = BatchExportJob(source: URL(fileURLWithPath: CommandLine.arguments[1]), settings: Adjustments(), look: nil, lookName: "Private look name")
            job.outputDirectory = root; job.longEdge = 512
            var good = try BatchExportItem(url: job.source), bad = try BatchExportItem(url: invalid)
            good.selected = true; bad.selected = true
            job.items = [good, bad]
            var batchEvents: [UsageEvent] = []
            let batch = BatchExportModel(job: job, journal: BatchJournal(directory: root.appendingPathComponent("journal")),
                onUsage: { batchEvents.append($0) })
            func waitForBatch() {
                let deadline = Date().addingTimeInterval(120)
                while batch.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                check(!batch.running, "batch terminates")
            }
            batch.start(); waitForBatch()
            check(batchEvents == [.batchExportCompleted(succeeded: 1, failed: 1, outcome: .partial)], "batch reports publication successes and actual failed attempts once")
            batch.start(.failed); batch.cancel(); waitForBatch()
            check(batchEvents.last == .batchExportCompleted(succeeded: 0, failed: 0, outcome: .cancelled), "cancelled retry does not recount old successes or failures")
            batch.start(.failed); waitForBatch()
            check(batchEvents.count == 3 && batchEvents.last == .batchExportCompleted(succeeded: 0, failed: 1, outcome: .partial), "failed retry counts only this run")
            print("PASS: batch success, partial failure, cancellation and retry deltas")
        }
    }
}
