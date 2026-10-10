import SwiftUI
import AppKit

@main
struct RawLabMacApp: App {
    @StateObject private var model = EditorModel()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var aiSettings = AISettings()
    @Environment(\.openWindow) private var openWindow
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
        Window("RawLab Mac", id: "editor") {
            VStack(spacing: 0) {
                if let release = updates.available {
                    HStack {
                        Text("RawLab \(release.version) 已发布")
                        Spacer()
                        Button("查看更新") { openWindow(id: "about") }
                    }.padding(8)
                }
                EditorView(model: model, aiSettings: aiSettings)
            }.task { await updates.check(manual: false) }
        }
            .defaultSize(width: 1320, height: 850)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("关于 RawLab…") { openWindow(id: "about") }
                    Button("检查更新…") {
                        openWindow(id: "about")
                        Task { await updates.check(manual: true) }
                    }.disabled(updates.checking)
                }
                CommandGroup(replacing: .newItem) {
                    Button("打开 RAW…", action: model.openPanel).keyboardShortcut("o")
                    Button("导入外观…", action: model.importLUT)
                        .disabled(model.lookLibraryBusy || model.exporting)
                    Button("AI 仿色…") { NotificationCenter.default.post(name: .rawLabAIColorMatch, object: nil) }
                        .disabled(!model.canStartAI)
                    Button("AI 服务设置…") { openWindow(id: "ai-settings") }
                    Button("恢复 AI 仿色前的调整…") { model.restoreAIEditPanel() }
                        .disabled(!model.canRestoreAI || model.busy || model.exporting || model.lookLibraryBusy)
                    Divider()
                    Button("导出 JPEG…") { model.export(png: false) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm)
                    Button("使用当前调整批量导出…") {
                        if model.prepareBatch() { openWindow(id: "batch-export") }
                    }.disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm)
                    Button("查看批量任务…") { openWindow(id: "batch-export") }.disabled(model.batch == nil)
                }
            }
        Window("关于 RawLab", id: "about") { AboutView(updates: updates) }
            .windowResizability(.contentSize)
        Window("AI 服务设置", id: "ai-settings") { AISettingsView(settings: aiSettings) }
            .windowResizability(.contentSize)
        Window("批量导出", id: "batch-export") {
            if let batch = model.batch { BatchExportView(model: batch) }
        }.defaultSize(width: 1040, height: 720)
    }
}
