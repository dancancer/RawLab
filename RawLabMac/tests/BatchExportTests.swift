import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main struct BatchExportTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = ["one.ARW", "bad.ARW", "three.ARW"].map { root.appendingPathComponent($0) }
        for url in inputs { try Data(url.lastPathComponent.utf8).write(to: url) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("one-Velvia.jpg")
        try Data("existing".utf8).write(to: existing)
        var settings = Adjustments(); settings.exposure = 0.75
        settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        var job = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Velvia")
        job.longEdge = 2048
        let encodedJob = try JSONEncoder().encode(job)
        try check(try JSONDecoder().decode(BatchExportJob.self, from: encodedJob).longEdge == 2048,
                  "batch keeps the chosen export size")
        var legacyJob = try JSONSerialization.jsonObject(with: encodedJob) as! [String: Any]
        legacyJob.removeValue(forKey: "longEdge")
        try check(try JSONDecoder().decode(BatchExportJob.self, from: JSONSerialization.data(withJSONObject: legacyJob)).longEdge == nil,
                  "older batch tasks retain original export size")
        job.outputDirectory = output
        job.items = try inputs.map { try BatchExportItem(url: $0) }
        try check(job.items.allSatisfy { !$0.selected }, "candidates start unselected")
        for index in job.items.indices { job.items[index].selected = true }
        settings.exposure = -1
        let journal = BatchJournal(directory: root.appendingPathComponent("journal"))
        var calls: [String] = []
        try BatchExportRunner.run(job: &job, journal: journal, scope: .unfinished, shouldCancel: { false }) { input, snapshot, _, destination in
            calls.append(input.lastPathComponent)
            try check(snapshot.exposure == 0.75, "snapshot must not follow live edits")
            try check(snapshot.waveletSettings == WaveletDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100), "batch keeps frozen denoise settings")
            if input == inputs[1] { throw Failure(message: "invalid RAW") }
            try Data("rendered".utf8).write(to: destination)
        }
        try check(calls.count == 3, "one failure does not stop subsequent targets")
        try check(job.items.filter { $0.status == .succeeded }.count == 2, "two successful rows")
        try check(job.items[1].status == .failed, "failed row is explicit")
        try check(try String(contentsOf: existing, encoding: .utf8) == "existing", "never overwrite existing output")
        try check(job.items[0].output != existing, "collision gets another name")
        try check(try String(contentsOf: inputs[0], encoding: .utf8) == "one.ARW", "RAW remains untouched")
        calls.removeAll()
        try BatchExportRunner.run(job: &job, journal: journal, scope: .failed, shouldCancel: { false }) { input, _, _, destination in
            calls.append(input.lastPathComponent)
            try Data("retry".utf8).write(to: destination)
        }
        try check(calls == ["bad.ARW"], "retry must never repeat successful targets")
        try check(try journal.load()?.items.allSatisfy { $0.status == .succeeded } == true, "completion is journaled")
        var cancelled = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        cancelled.outputDirectory = output
        cancelled.items = try inputs.map { try BatchExportItem(url: $0) }
        for index in cancelled.items.indices { cancelled.items[index].selected = true }
        var stop = false
        try BatchExportRunner.run(job: &cancelled, journal: journal, scope: .unfinished, shouldCancel: { stop }) { _, _, _, destination in
            try Data("first".utf8).write(to: destination)
            stop = true
        }
        try check(cancelled.items[0].status == .succeeded && cancelled.items[1].status == .waiting,
                  "cancel retains completed output and leaves remaining inputs unprocessed")
        var interrupted = cancelled
        interrupted.items[1].status = .running
        try journal.save(interrupted)
        let restored = try journal.load()!
        try check(restored.settings.waveletSettings == settings.waveletSettings, "journal preserves denoise settings")
        try check(restored.interrupted && restored.items[1].status == .waiting, "running work restores as interrupted, never successful")
        try check(restored.items[0].status == .succeeded, "recovery preserves successful rows")
        var publishing = cancelled
        let published = output.appendingPathComponent("published.jpg")
        try Data("published".utf8).write(to: published)
        publishing.items[1].output = published
        publishing.items[1].completedIdentity = try OriginalFileIdentity(published)
        publishing.items[1].status = .publishing
        try journal.save(publishing)
        try check(try journal.load()?.items[1].status == .succeeded, "published-before-checkpoint output must not be duplicated")
        var brokenOutput = BatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        brokenOutput.outputDirectory = output
        brokenOutput.items = try inputs.map { try BatchExportItem(url: $0) }
        for index in brokenOutput.items.indices { brokenOutput.items[index].selected = true }
        var storageCalls = 0
        do {
            try BatchExportRunner.run(job: &brokenOutput, journal: journal, scope: .unfinished, shouldCancel: { false }) { _, _, _, _ in
                storageCalls += 1
                throw RenderError.outputIO
            }
            throw Failure(message: "output I/O failure must stop the batch")
        } catch RenderError.outputIO { }
        try check(storageCalls == 1, "global storage failure must not attempt remaining photos")
        try check(try journal.load()?.interrupted == true, "global failure persists interrupted state")
        var abandoned = cancelled
        abandoned.items[1].status = .running
        let temporary = output.appendingPathComponent(".rawlab-\(abandoned.id)-\(abandoned.items[1].id).\(abandoned.suffix)")
        try Data("partial output".utf8).write(to: temporary)
        try journal.save(abandoned)
        _ = try journal.load()
        try check(!FileManager.default.fileExists(atPath: temporary.path), "recovery removes abandoned partial output")
        print("PASS: snapshot, collisions, failure continuation, retry, cancel and durable recovery")
    }
}
