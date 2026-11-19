import RawLabKit
import AppKit
import Combine

@main
enum BatchCancellationTests {
    enum ProbeError: Error { case stopped }

    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }

    static func wait(_ event: DispatchSemaphore, _ message: String) throws {
        try check(event.wait(timeout: .now() + 5) == .success, message)
    }

    static func finished(_ model: BatchExportModel) throws {
        let deadline = Date().addingTimeInterval(5)
        while model.previewing && Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        try check(!model.previewing, "latest preview completion is delivered")
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try (0..<4).map { index -> URL in
            let file = root.appendingPathComponent("\(index).x3f")
            try Data("original-\(index)".utf8).write(to: file)
            return file
        }
        switch ProcessInfo.processInfo.environment["RAWLAB_CANCELLATION_CASE"] {
        case "validation": try validationQueue(root, inputs)
        case "previews": try supersededPreviews(root, inputs)
        case "ai-start": try aiCancellation(root, inputs, action: "start")
        case "ai-close": try aiCancellation(root, inputs, action: "close")
        case "ai-replace": try aiCancellation(root, inputs, action: "replace")
        case "ai-cancel": try aiCancellation(root, inputs, action: "cancel")
        default:
            try validationQueue(root, inputs)
            try supersededPreviews(root, inputs)
            for action in ["start", "close", "replace", "cancel"] { try aiCancellation(root, inputs, action: action) }
        }
    }

    static func validationQueue(_ root: URL, _ inputs: [URL]) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let preview = DispatchSemaphore(value: 0)
        let model = BatchExportModel(job: MacBatchExportJob(source: inputs[0], settings: Adjustments(), look: nil, lookName: "Neutral"),
            journal: MacBatchJournal(directory: root.appendingPathComponent("validation-journal")),
            probeHDRSource: { _, _ in entered.signal(); release.wait(); return nil },
            resolveX3fMode: { _ in preview.signal(); throw ProbeError.stopped })
        model.add([inputs[0]])
        try wait(entered, "validation entered its active target")
        model.inspect(model.job.items[0])
        let independent = preview.wait(timeout: .now() + 2) == .success
        release.signal()
        try finished(model)
        let deadline = Date().addingTimeInterval(5)
        while model.validating && Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        try check(!model.validating, "validation drains after release")
        try check(independent, "preview reaches its target while validation is blocked")
    }

    static func supersededPreviews(_ root: URL, _ inputs: [URL]) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = [URL]()
        var job = MacBatchExportJob(source: inputs[0], settings: Adjustments(), look: nil, lookName: "Neutral")
        job.items = try inputs.map { try MacBatchExportItem(url: $0) }
        let model = BatchExportModel(job: job, journal: MacBatchJournal(directory: root.appendingPathComponent("journal")),
            resolveX3fMode: { url in
                lock.lock(); calls.append(url); let first = calls.count == 1; lock.unlock()
                if first { entered.signal(); release.wait() }
                throw ProbeError.stopped
            })
        model.inspect(job.items[0])
        try wait(entered, "first preview reached its target")
        model.inspect(job.items[1]); model.inspect(job.items[2]); model.closePreview()
        model.inspect(job.items[3])
        release.signal()
        try finished(model)
        lock.lock(); let visited = calls; lock.unlock()
        try check(visited == [inputs[0], inputs[3]],
            "superseded and closed queued previews do no target work (calls=\(visited.count), expected=2)")
        try check(model.previewFile == inputs[3] && model.preview == nil && model.error != nil,
            "only the latest generation publishes its preview result")
    }

    static func aiCancellation(_ root: URL, _ inputs: [URL], action: String) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var settings = Adjustments(); settings.aiDenoiseEnabled = true
        var job = MacBatchExportJob(source: inputs[0], settings: settings, look: nil, lookName: "Neutral")
        job.outputDirectory = root; job.items = [try MacBatchExportItem(url: inputs[0])]
        job.items[0].selected = true
        let lock = NSLock()
        var active: AIPreparation?, events = [String](), reports = [Int32]()
        let model = BatchExportModel(job: job, journal: MacBatchJournal(directory: root.appendingPathComponent("ai-\(action)")),
            resolveX3fMode: { _ in .legacy },
            prepareAI: { _, _, _, progress in
                lock.lock(); let first = events.isEmpty; events.append(first ? "preview-enter" : "next-enter")
                if first { active = progress }; lock.unlock()
                if first {
                    entered.signal(); release.wait()
                    let report = progress.report(phase: 2, completed: 1, total: 2)
                    lock.lock(); reports.append(report); events.append("preview-exit"); lock.unlock()
                    throw NSError(domain: "stale-preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "stale-preview"])
                }
                throw RenderError.aiCancelled
            })
        var staleWrites = 0
        let subscription = model.$error.sink { if $0 == "stale-preview" { staleWrites += 1 } }
        model.inspect(job.items[0])
        try wait(entered, "\(action): AI preview entered preparation")
        if action == "start" { try check(model.start(), "start accepts export during AI preview") }
        else if action == "close" { model.closePreview() }
        else if action == "cancel" { model.cancel() }
        else { model.inspect(job.items[0]) }
        lock.lock(); let cancelled = active?.isCancelled == true; lock.unlock()
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while (model.running || model.previewing) && Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        // close() clears visible state immediately; a subsequent preview is an event barrier for its worker.
        if action == "close" || action == "cancel" { model.inspect(job.items[0]); try finished(model) }
        lock.lock(); let observed = events, returned = reports; lock.unlock()
        try check(cancelled, "\(action): cancellation reaches the active AIPreparation")
        try check(returned == [0], "\(action): cancelled AI callback returns stop (reports=\(returned))")
        try check(observed == ["preview-enter", "preview-exit", "next-enter"],
            "\(action): cancelled AI preview drains before the next operation (events=\(observed))")
        try check(staleWrites == 0, "\(action): late AI failure cannot write to the next generation (writes=\(staleWrites))")
        withExtendedLifetime(subscription) {}
    }
}
