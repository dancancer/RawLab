import AppKit
import Foundation

@main
struct ProgressiveRenderTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func main() throws {
        guard CommandLine.arguments.count >= 3 else {
            fatalError("usage: progressive-render RAW LUT")
        }
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let lut = URL(fileURLWithPath: CommandLine.arguments[2])
        let model = EditorModel()
        model.films = [Film(name: "PROVIA", url: lut)]
        model.selectedFilmID = lut.path
        model.updatePreviewLongEdge(1600)
        model.open(raw)

        try wait(for: "initial settled viewport preview", timeout: 120) {
            guard !model.busy, let result = model.result else { return false }
            return model.status.hasPrefix("预览 ") && max(result.image.width, result.image.height) == 1600
        }

        model.setInteracting(true)
        model.settings.set(.temperature, to: 6000)
        model.settings.set(.temperature, to: 8000)
        try wait(for: "interactive viewport preview", timeout: 120) {
            guard model.busy, let result = model.result else { return false }
            return model.status.hasPrefix("交互预览") && max(result.image.width, result.image.height) == 1600
        }
        check(model.settings.temperature == 8000, "the latest slider setting remains authoritative")

        model.setInteracting(false)
        try wait(for: "release settled viewport preview", timeout: 120) {
            guard !model.busy, let result = model.result else { return false }
            return model.status.hasPrefix("预览 ") && max(result.image.width, result.image.height) == 1600
        }

        guard let final = model.result else { fatalError("FAIL: final result missing") }
        let engine = try RenderEngine()
        guard let expected = try engine.render(raw, settings: model.settings, lut: lut,
                                               edge: 1600, output: nil, interactive: false, viewportPreview: true) else {
            fatalError("FAIL: direct exact render missing")
        }
        check(final.image.width == expected.image.width && final.image.height == expected.image.height,
              "model and direct settled renders use the same viewport dimensions")
        check(final.histogram == expected.histogram,
              "model settled result matches a direct viewport render with the final settings")
    }

    private static func wait(for label: String, timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                print("PASS: \(label)")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        fatalError("FAIL: timed out waiting for \(label)")
    }
}
