import AppKit
import SwiftUI

private struct EffectsPreview: View {
    @ObservedObject var model: EditorModel
    let tool: AdjustmentParameter

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let neutral = model.neutral, let result = model.result {
                    Image(decorative: neutral.image, scale: 1).resizable().scaledToFit()
                    Image(decorative: result.image, scale: 1).resizable().scaledToFit()
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
            AdjustmentDock(model: model, selected: .constant(tool), resetVersion: 0)
                .frame(height: 166)
        }.preferredColorScheme(.dark)
    }
}

@main
struct PhotoEffectsPresentationTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func waitForRender(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<1200 {
            if !model.busy && model.result != nil { break }
            if let error = model.error { throw RenderError.failed(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !model.busy, model.result != nil else { throw RenderError.failed("Render timed out") }
    }

    // ------------------------------------------------------------------------
    //  调整栏为效果面板要的高度，必须放得下面板全部内容（含底部提示）
    //  颗粒工具曾在按下时要 288，面板出现时又被改回 252，提示被截掉
    // ------------------------------------------------------------------------
    @MainActor static func checkRequestedHeights(_ model: EditorModel) async throws {
        for tool in [AdjustmentParameter.vignetteAmount, .grainAmount] {
            var requested: CGFloat = 0
            let dock = AdjustmentDock(model: model, selected: .constant(tool), resetVersion: 0,
                                      onPreferredHeight: { requested = $0 })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: dock)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            window.orderOut(nil)
            let content = NSHostingView(rootView: PhotoEffectsControls(model: model, tool: tool).frame(width: 1100))
            let needed = AdjustmentPanelLayout.chrome + content.fittingSize.height
            guard requested >= needed else {
                throw RenderError.failed("\(tool.rawValue) asks for \(requested) pt but needs \(needed) pt")
            }
            print("PASS: \(tool.rawValue) panel asks for \(Int(requested)) pt, content needs \(Int(needed)) pt")
        }
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effects-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
                                editDirectory: root.appendingPathComponent("edits"),
                                batchDirectory: root.appendingPathComponent("batch"))
        model.open(URL(fileURLWithPath: CommandLine.arguments[1]))
        try await waitForRender(model)
        // 默认强度为 0，面板底部带提示：这是打开工具时最常见的状态
        try await checkRequestedHeights(model)
        model.settings.setEffect(.vignetteAmount, to: -55)
        model.settings.setEffect(.vignetteHighlights, to: 60)
        model.settings.setEffect(.grainAmount, to: 45)
        model.settings.setEffect(.grainSize, to: 60)
        try await waitForRender(model)
        // Reserve the editor's maximum 300-point file browser at both window sizes.
        for (name, size) in [("compact", NSSize(width: 650, height: 550)), ("wide", NSSize(width: 1140, height: 830))] {
            for tool in [AdjustmentParameter.vignetteAmount, .grainAmount] {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: EffectsPreview(model: model, tool: tool))
                window.center(); window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                let path = output.appendingPathComponent("mac-effects-\(tool.rawValue)-\(name).png")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), path.path]
                try capture.run(); capture.waitUntilExit()
                window.orderOut(nil)
                guard capture.terminationStatus == 0 else { throw RenderError.failed("Screenshot failed") }
                print("CAPTURE: \(tool.rawValue) \(name); \(path.path)")
            }
        }
    }
}
