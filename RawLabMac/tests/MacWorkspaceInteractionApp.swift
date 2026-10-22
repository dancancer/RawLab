import AppKit
import Combine
import SwiftUI

// 可见测试窗口复用生产 EditorView；固定内容尺寸用于真实滚动/无障碍验收。
@main
struct MacWorkspaceInteractionApp {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let environment = ProcessInfo.processInfo.environment
        if let language = environment["RAWLAB_PARAMETER_LANGUAGE"] {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language, "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
        }
        let directory = environment["RAWLAB_PARAMETER_STATE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-workspace-ui-\(UUID())")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
                                editDirectory: directory.appendingPathComponent("edits"),
                                batchDirectory: directory.appendingPathComponent("batch"))
        let geometryEvents = model.$geometryDraft.sink { draft in
            if let geometry = draft?.geometry {
                print("GEOMETRY_STATE straighten=\(geometry.straightenDegrees) width=\(geometry.cropWidth) horizontal=\(geometry.perspectiveHorizontal)")
            } else { print("GEOMETRY_STATE nil") }
        }
        let settingEvents = model.$settings.dropFirst().sink {
            print("SETTING_STATE exposure=\($0.exposure) redHue=\($0.hslSettings.value(.hue, channel: 0))")
        }
        let textSize: DynamicTypeSize = environment["RAWLAB_PARAMETER_LARGE_TEXT"] == "1" ? .accessibility3 : .large
        let host = NSHostingView(rootView: EditorView(model: model).dynamicTypeSize(textSize))
        var initialLoad: AnyCancellable?
        if let source = environment["RAWLAB_PARAMETER_SOURCE"] {
            if environment["RAWLAB_PARAMETER_LEGACY_HSL"] == "1" {
                initialLoad = model.$result.first(where: { $0 != nil }).sink { _ in
                    // A valid persisted, off-grid desktop value must survive real UI navigation.
                    let json = "{\"hue\":[0.05,0,0,0,0,0,0,0],\"saturation\":[0,0,0,0,0,0,0,0],\"lightness\":[0,0,0,0,0,0,0,0]}"
                    model.settings.hsl = try! JSONDecoder().decode(HSLSettings.self, from: Data(json.utf8))
                    model.selectAdjustmentTool(.hsl)
                }
            }
            model.open(URL(fileURLWithPath: source))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Double(environment["RAWLAB_PARAMETER_WIDTH"] ?? "950") ?? 950, height: Double(environment["RAWLAB_PARAMETER_HEIGHT"] ?? "620") ?? 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RawLab Workspace Acceptance"
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((model, window, initialLoad, geometryEvents, settingEvents)) { app.run() }
        try? FileManager.default.removeItem(at: directory)
    }
}
