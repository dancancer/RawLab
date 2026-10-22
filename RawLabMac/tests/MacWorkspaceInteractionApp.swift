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
        if environment["RAWLAB_HISTOGRAM_UNAVAILABLE"] == "1" {
            model.engine = try! RenderEngine(statisticsProvider: { _ in nil })
        }
        let geometryEvents = model.$geometryDraft.sink { draft in
            if let geometry = draft?.geometry {
                print("GEOMETRY_STATE straighten=\(geometry.straightenDegrees) width=\(geometry.cropWidth) horizontal=\(geometry.perspectiveHorizontal)")
            } else { print("GEOMETRY_STATE nil") }
        }
        let settingEvents = model.$settings.dropFirst().sink {
            print("SETTING_STATE exposure=\($0.exposure) redHue=\($0.hslSettings.value(.hue, channel: 0))")
        }
        let textSize: DynamicTypeSize = environment["RAWLAB_PARAMETER_LARGE_TEXT"] == "1" ? .accessibility3 : .large
        let panFixture = environment["RAWLAB_VIEWING_PAN_FIXTURE"] == "1"
        let panState = MacViewingPanFixtureState()
        let panInterruptionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        panInterruptionWindow.title = "Pan focus interruption"
        weak var panWindow: NSWindow?
        var interrupted = false
        let panEvents = panState.$viewport.dropFirst().sink { value in
            print("VIEWPORT focus=\(value.focus.x),\(value.focus.y)")
            if panFixture && !interrupted {
                interrupted = true
                print("NATIVE_PAN_CANCEL_BEGIN key=\(panWindow?.isKeyWindow == true)")
                panInterruptionWindow.makeKeyAndOrderFront(nil)
                print("NATIVE_PAN_CANCEL publishedFocus=\(value.focus.x),\(value.focus.y)")
                DispatchQueue.main.async {
                    panWindow?.makeKeyAndOrderFront(nil)
                    panInterruptionWindow.orderOut(nil)
                    print("NATIVE_PAN_RESUME key=\(panWindow?.isKeyWindow == true)")
                }
            }
        }
        let root = panFixture ? AnyView(MacViewingPanFixture(state: panState)) : AnyView(EditorView(model: model))
        let host = NSHostingView(rootView: root.dynamicTypeSize(textSize))
        var initialLoad: AnyCancellable?
        if !panFixture, let source = environment["RAWLAB_PARAMETER_SOURCE"] {
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
        window.title = panFixture ? "RawLab Viewing Pan Acceptance" : "RawLab Workspace Acceptance"
        panWindow = window
        let pointerEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            if panFixture { print("POINTER type=\(event.type.rawValue) point=\(event.locationInWindow) key=\(window.isKeyWindow)") }
            return event
        }
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((model, window, panInterruptionWindow, initialLoad, geometryEvents, settingEvents, panEvents, pointerEvents)) { app.run() }
        if let pointerEvents { NSEvent.removeMonitor(pointerEvents) }
        try? FileManager.default.removeItem(at: directory)
    }
}
