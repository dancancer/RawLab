import AppKit

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
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
        third.settings.exposure = 1.25
        let originalB = try Data(contentsOf: b)
        try check(third.applyCurrentSettings(to: [b, b]) == 1, "apply current settings deduplicates targets")
        let applied = model(); applied.open(b)
        try check(applied.settings.exposure == 1.25 && third.file == a && third.settings.exposure == 1.25,
                  "context action persists target settings without opening the target or changing the source")
        try check(try Data(contentsOf: b) == originalB, "apply settings leaves RAW bytes intact")
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
            while live.result.map({ max($0.image.width, $0.image.height) }) != 1000 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try check(live.result.map { max($0.image.width, $0.image.height) } == 1000, "interactive proxy long edge must publish while dragging")
            try check(live.neutral!.image === original && !live.result!.isFullResolution,
                      "interactive denoise must retain the same native original")
            live.setInteracting(false)
            try waitForRender()
            try check(live.neutral!.image === original, "exact denoise must retain the same original")
            print("PASS: Original is native and unchanged across exposure, WB and interactive/exact denoise")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            var fieldAppeared = false
            var changedSize = false
            func hasPixelField(_ view: NSView) -> Bool {
                if let field = view as? NSTextField, field.isEditable { return true }
                return view.subviews.contains { hasPixelField($0) }
            }
            let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
                MainActor.assumeIsolated {
                guard let panel = app.modalWindow as? NSSavePanel else { return }
                if !changedSize {
                    live.exportLongEdge = 2048
                    changedSize = true
                } else {
                    fieldAppeared = panel.accessoryView.map { hasPixelField($0) } ?? false
                    panel.cancel(nil)
                    timer.invalidate()
                }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            live.export(png: false)
            timer.invalidate()
            try check(fieldAppeared, "save-panel size accessory must update when the chosen long edge changes")
            print("PASS: Save-panel size accessory updates its numeric input")
        }
    }
}
