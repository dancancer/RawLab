import AppKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

@main struct EditModelTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.ARW"), b = root.appendingPathComponent("b.ARW")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        func model() -> EditorModel {
            EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                        editDirectory: root.appendingPathComponent("edits"),
                        batchDirectory: root.appendingPathComponent("batch"))
        }
        let first = model()
        first.open(a)
        first.settings.exposure = 0.75
        try check(first.saveEdits(), "save must succeed")
        first.open(b)
        try check(first.settings.exposure == 0, "unseen photo does not inherit adjustments")
        let second = model()
        second.open(a)
        try check(second.settings.exposure == 0.75, "editor must restore from disk")
        second.settings.resetAll()
        try check(second.saveEdits(), "reset must save")
        let third = model(); third.open(a)
        try check(third.settings.exposure == 0, "editor restart restores reset")
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failing = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                                  editDirectory: blocked, batchDirectory: root.appendingPathComponent("batch2"))
        failing.open(a); failing.settings.exposure = 1
        try check(!failing.saveEdits() && failing.saveError != nil, "save failure must be visible")
        failing.open(b)
        try check(failing.file == a && failing.settings.exposure == 1, "failed save must not discard edits on photo switch")
        print("PASS: EditorModel persistent restore, unseen defaults, reset and failed-save protection")
        if CommandLine.arguments.count > 1 {
            let live = model()
            live.open(URL(fileURLWithPath: CommandLine.arguments[1]))
            func waitForRender() throws {
                let deadline = Date().addingTimeInterval(120)
                while live.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                try check(!live.busy && live.error == nil && live.result != nil, "real RAW render must complete")
            }
            try waitForRender()
            let original = live.neutral!.image
            try check(live.neutral!.isFullResolution, "original baseline provides native source geometry")
            live.settings.exposure = 1
            try waitForRender()
            try check(live.neutral!.image === original, "exposure must not replace the original image")
            live.settings.set(.temperature, to: 8000)
            try waitForRender()
            try check(live.neutral!.image === original, "white balance must not replace the original image")
            live.setInteracting(true)
            live.settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: true, luma: 65, chroma: 72, coarse: 100)
            let deadline = Date().addingTimeInterval(60)
            while live.result?.image.width != 1000 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try check(live.result?.image.width == 1000, "interactive proxy must publish while dragging")
            try check(live.neutral!.image === original && !live.result!.isFullResolution,
                      "interactive denoise must retain the same native original")
            live.setInteracting(false)
            try waitForRender()
            try check(live.neutral!.image === original, "exact denoise must retain the same original")
            print("PASS: Original is native and unchanged across exposure, WB and interactive/exact denoise")
        }
    }
}
