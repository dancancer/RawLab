import AppKit
import SwiftUI

// 可见测试窗口复用生产 EditorView；固定内容尺寸用于真实滚动/无障碍验收。
@main
struct MacWorkspaceInteractionApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-workspace-ui-\(UUID())")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
                                editDirectory: directory.appendingPathComponent("edits"),
                                batchDirectory: directory.appendingPathComponent("batch"))
        let host = NSHostingView(rootView: EditorView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RawLab Workspace Acceptance"
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((model, window)) { app.run() }
        try? FileManager.default.removeItem(at: directory)
    }
}
