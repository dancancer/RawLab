import SwiftUI

// 使用产品页面和真实模型，只延后后台检查结果，稳定覆盖取消和失去前台的窗口。
@main struct BatchFlowUIHarness: App {
    @StateObject private var model: EditorModel

    init() {
        let editor = EditorModel()
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        editor.addCollectionPhotos(files)
        let prepare = editor.prepareCollectionExportOperation
        let delay = min(30, max(0, Double(ProcessInfo.processInfo.environment["RAWLAB_BATCH_TEST_DELAY"] ?? "15") ?? 15))
        editor.prepareCollectionExportOperation = { input in
            let result = try prepare(input)
            Thread.sleep(forTimeInterval: delay)
            return result
        }
        _model = StateObject(wrappedValue: editor)
    }

    var body: some Scene {
        WindowGroup {
            BatchSelectionView(model: model)
                .onAppear { trace("appear") }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in trace("resign") }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in trace("hide") }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trace("active") }
        }.defaultSize(width: 950, height: 620)
        Window(L10n.text("批量导出"), id: "batch-export") {
            BatchExportWindow(model: model)
        }.defaultSize(width: 950, height: 620)
    }

    private func trace(_ event: String) {
        NSLog("BatchFlowUI %@ active=%d hidden=%d checking=%d", event,
            NSApplication.shared.isActive, NSApplication.shared.isHidden, model.collectionExportPreparing)
    }
}
