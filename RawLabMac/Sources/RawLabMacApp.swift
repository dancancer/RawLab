import SwiftUI
import AppKit

@main
struct RawLabMacApp: App {
    @StateObject private var model = EditorModel()
    init() {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--smoke" {
            do {
                let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let engine = try RenderEngine()
                guard let film = Film.bundled().first(where: { $0.name == "PROVIA" }) else {
                    throw RenderError.failed("PROVIA resource missing")
                }
                let neutral = try engine.render(input, settings: Adjustments(), lut: nil, edge: 1200)!
                let rendered = try engine.render(input, settings: Adjustments(), lut: film.url, edge: 1200)!
                var matchedSettings = Adjustments()
                matchedSettings.exposureMode = .preview
                let matched = try engine.render(input, settings: matchedSettings, lut: film.url, edge: 1200)!
                let restored = try engine.render(input, settings: Adjustments(), lut: film.url, edge: 1200)!
                guard restored.histogram == rendered.histogram,
                      restored.baselineEV == rendered.baselineEV,
                      abs(matched.baselineEV-rendered.baselineEV) > 0.01 else {
                    throw RenderError.failed("Exposure mode cache isolation failed")
                }
                _ = try engine.render(input, settings: Adjustments(), lut: nil, edge: nil, output: output.appendingPathComponent("neutral.jpg"))
                _ = try engine.render(input, settings: Adjustments(), lut: film.url, edge: nil, output: output.appendingPathComponent("PROVIA.png"))
                _ = try engine.render(input, settings: Adjustments(), lut: film.url, edge: nil, output: output.appendingPathComponent("PROVIA.jpg"))
                guard neutral.histogram != rendered.histogram, rendered.image.width > 0 else {
                    throw RenderError.failed("Film transform produced no change")
                }
                let png = try Data(contentsOf: output.appendingPathComponent("PROVIA.png"))
                guard png.count > 24, png[24] == 16 else { throw RenderError.failed("Not a sixteen-bit PNG") }
                let report: [String: Any] = ["input": input.path, "width": rendered.image.width,
                    "height": rendered.image.height, "film": film.name, "filmCount": Film.bundled().count,
                    "baselineEV": rendered.baselineEV, "metadataEV": rendered.metadataEV,
                    "previewMatchEV": matched.baselineEV, "exposureMode": ExposureMode.scene.rawValue,
                    "highlights": rendered.highlights, "shadows": rendered.shadows, "pngBits": png[24]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent("result.json"))
                print("PASS: \(input.lastPathComponent) -> \(output.path)")
                exit(0)
            } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        Window("RawLab Mac", id: "editor") { EditorView(model: model) }
            .defaultSize(width: 1320, height: 850)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("打开 RAW…", action: model.openPanel).keyboardShortcut("o")
                    Button("导入外观…", action: model.importLUT)
                        .disabled(model.lookLibraryBusy || model.exporting)
                    Divider()
                    Button("导出 JPEG…") { model.export(png: false) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy)
                }
            }
    }
}
