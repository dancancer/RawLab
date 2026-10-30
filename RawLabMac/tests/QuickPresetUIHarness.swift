import SwiftUI

// 只替换测试应用入口，真实 EditorView、模型、prepare/CAS/history 与渲染器均使用产品源码。
@main struct QuickPresetUIHarness: App {
    @StateObject private var model: EditorModel
    private let fixture: URL

    init() {
        fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let editor = EditorModel()
        let payload = try! AdjustmentTransferPayload(source: .init(identifier: "quick-ui-fixture",
            isRaw: !RenderEngine.isRasterInput(fixture), processingVersion: 2, recipe: nil), values: ["light.exposure": .number(0.7)])
        if (try? editor.presetStore.list().isEmpty) == true {
            _ = try! editor.presetStore.create(name: "Delayed exposure +0.70", payload: payload)
        }
        let prepare = editor.prepareQuickPresetOperation
        let delay = min(30, max(0, Double(ProcessInfo.processInfo.environment["RAWLAB_QUICK_TEST_DELAY"] ?? "15") ?? 15))
        editor.prepareQuickPresetOperation = { session, payload, targets in
            let result = try prepare(session, payload, targets)
            // 后台延迟提供稳定的取消窗口，不改变预检结果，也不绕过正式保存守卫。
            Thread.sleep(forTimeInterval: delay)
            return result
        }
        _model = StateObject(wrappedValue: editor)
    }

    var body: some Scene {
        WindowGroup {
            EditorView(model: model).onAppear {
                if model.file == nil { model.open(fixture); model.showQuickPresets() }
            }
        }.defaultSize(width: 950, height: 620)
    }
}
