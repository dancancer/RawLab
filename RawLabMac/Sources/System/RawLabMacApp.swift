import SwiftUI
import AppKit

@main
struct RawLabMacApp: App {
    @NSApplicationDelegateAdaptor(RawLabMacDelegate.self) private var appDelegate
    @AppStorage(L10n.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @StateObject private var runtime = MacUpdateRuntime()
    @Environment(\.openWindow) private var openWindow
    init() {
        SystemMenuLanguage.apply(UserDefaults.standard.string(forKey: L10n.preferenceKey))
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--smoke" {
            do {
                let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let engine = try RenderEngine()
                guard let film = Film.bundled().first(where: { $0.name == "PROVIA" }) else {
                    throw RenderError.failed("PROVIA resource missing")
                }
                var sceneSettings = Adjustments()
                sceneSettings.exposureMode = .scene
                let neutral = try engine.render(input, settings: sceneSettings, lut: nil, edge: 1200)!
                let rendered = try engine.render(input, settings: sceneSettings, lut: film.url, edge: 1200)!
                var matchedSettings = Adjustments()
                matchedSettings.exposureMode = .preview
                let matched = try engine.render(input, settings: matchedSettings, lut: film.url, edge: 1200)!
                let restored = try engine.render(input, settings: sceneSettings, lut: film.url, edge: 1200)!
                guard (restored.image.dataProvider!.data! as Data) == (rendered.image.dataProvider!.data! as Data),
                      restored.baselineEV == rendered.baselineEV,
                      abs(matched.baselineEV-rendered.baselineEV) > 0.01 else {
                    throw RenderError.failed("Exposure mode cache isolation failed")
                }
                _ = try engine.render(input, settings: sceneSettings, lut: nil, edge: nil, output: output.appendingPathComponent("neutral.jpg"))
                _ = try engine.render(input, settings: sceneSettings, lut: film.url, edge: nil, output: output.appendingPathComponent("PROVIA.png"))
                _ = try engine.render(input, settings: sceneSettings, lut: film.url, edge: nil, output: output.appendingPathComponent("PROVIA.jpg"))
                guard (neutral.image.dataProvider!.data! as Data) != (rendered.image.dataProvider!.data! as Data), rendered.image.width > 0 else {
                    throw RenderError.failed("Film transform produced no change")
                }
                let png = try Data(contentsOf: output.appendingPathComponent("PROVIA.png"))
                guard png.count > 24, png[24] == 16 else { throw RenderError.failed("Not a sixteen-bit PNG") }
                let report: [String: Any] = ["input": input.path, "width": rendered.image.width,
                    "height": rendered.image.height, "film": film.name, "filmCount": Film.bundled().count,
                    "baselineEV": rendered.baselineEV, "metadataEV": rendered.metadataEV,
                    "previewMatchEV": matched.baselineEV, "exposureMode": sceneSettings.exposureMode.rawValue,
                    "highlights": rendered.highlights.map { $0 as Any } ?? NSNull(),
                    "shadows": rendered.shadows.map { $0 as Any } ?? NSNull(), "pngBits": png[24]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent("result.json"))
                print("PASS: \(input.lastPathComponent) -> \(output.path)")
                exit(0)
            } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        #if RAWLAB_RUM
        UsageRUM.configure()
        #endif
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        Window("RawLab Mac", id: "editor") {
            Group {
                if let model = runtime.model, let updates = runtime.controller {
                    VStack(spacing: 0) {
                        UpdateAvailabilityBanner(updates: updates, legacy: runtime.legacy) { showUpdateWindow("update-prompt") }
                        EditorView(model: model)
                            .disabled(updates.preparingInstallation || [.installing, .pendingRestart].contains(updates.state.phase))
                    }
                } else if let error = runtime.startupError {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.text(error == "other_instance" ? "请先退出其他 RawLab 实例" : "更新恢复需要处理，编辑暂未开放")).font(.headline)
                        if let updates = runtime.controller { SoftwareUpdateView(updates: updates, legacy: runtime.legacy) }
                        else { Text(L10n.text("请保留现有应用和数据，处理问题后重新启动。")) }
                    }.padding(24)
                } else { ProgressView(L10n.text("正在检查启动状态…")) }
            }.task { await runtime.start(delegate: appDelegate); if runtime.model != nil { UsageAnalytics.shared.beginSession() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    UsageAnalytics.shared.endSession()
                }
                .onChange(of: languagePreference) { _, preference in SystemMenuLanguage.apply(preference) }
                .environment(\.locale, selectedLocale)
        }.defaultSize(width: 1320, height: 850)
            .commands {
                if let model = runtime.model, !installationActive { AdjustmentCommands(model: model) }
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.text("软件更新…")) { showUpdateWindow("software-update") }.disabled(runtime.controller == nil)
                    Picker(L10n.text("语言"), selection: $languagePreference) {
                        ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
                    }.id(languagePreference)
                }
                CommandGroup(replacing: .appInfo) {
                    Button(L10n.text("关于 RawLab…")) { openWindow(id: "about") }
                    Button(L10n.text("检查更新…")) {
                        showUpdateWindow("update-prompt")
                        guard let updates = runtime.controller else { return }
                        if updates.unavailableReason != nil { Task { await runtime.legacy.check(manual: true) } }
                        else { updates.check(manual: true) }
                    }.disabled(runtime.controller == nil)
                }
                CommandGroup(replacing: .newItem) {
                    if let model = runtime.model, !installationActive {
                        Button(L10n.text("打开照片"), action: model.openPanel).keyboardShortcut("o")
                        Button(L10n.text("导入外观…"), action: model.importLUT)
                            .disabled(model.lookLibraryBusy || model.exporting || model.geometryDraft != nil)
                        Divider()
                        Button(L10n.text("导出 JPEG…")) { model.export(png: false) }
                            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
                        Button(L10n.text("导出渲染型 DNG…")) { model.export(format: .renderedDNG) }.disabled(!model.canExport)
                        Button(L10n.text("使用当前调整批量导出…")) {
                            if model.prepareBatch() { openWindow(id: "batch-export") }
                        }.disabled(!model.canExport)
                        Button(L10n.text("批量编辑…")) { openWindow(id: "batch-selection") }.disabled(model.exporting)
                        Button(L10n.text("查看批量任务…")) { openWindow(id: "batch-export") }.disabled(model.batch == nil)
                    }
                }
            }
        Window(L10n.text("关于 RawLab"), id: "about") { AboutView(currentVersion: runtime.legacy.currentVersion).environment(\.locale, selectedLocale) }
            .windowResizability(.contentSize)
        Window(L10n.text("软件更新"), id: "software-update") {
            if let updates = runtime.controller { SoftwareUpdateView(updates: updates, legacy: runtime.legacy).environment(\.locale, selectedLocale) }
        }.defaultSize(width: 560, height: 600)
        Window(L10n.text("RawLab 更新"), id: "update-prompt") {
            if let updates = runtime.controller { SoftwareUpdateView(updates: updates, legacy: runtime.legacy, settings: false).environment(\.locale, selectedLocale) }
        }.defaultSize(width: 560, height: 520)
        Window(L10n.text("批量编辑"), id: "batch-selection") {
            if let model = runtime.model { BatchSelectionView(model: model).disabled(installationActive).environment(\.locale, selectedLocale) }
        }.defaultSize(width: 1040, height: 720)
        Window(L10n.text("批量导出"), id: "batch-export") {
            if let batch = runtime.model?.batch { BatchExportView(model: batch).disabled(installationActive).environment(\.locale, selectedLocale) }
            else { BatchExportEmptyView().environment(\.locale, selectedLocale) }
        }.defaultSize(width: 1040, height: 720)
    }

    private var installationActive: Bool { runtime.controller.map { $0.preparingInstallation || [.installing, .pendingRestart].contains($0.state.phase) } ?? false }

    private func showUpdateWindow(_ id: String) {
        ParameterValueField.preserveInputsForUpdateNavigation()
        openWindow(id: id)
    }

    private var selectedLocale: Locale {
        Locale(identifier: AppLanguage.resolve(preference: languagePreference, preferredLanguages: Locale.preferredLanguages).rawValue)
    }
}

// ----------------------------------------------------------------------------
//  系统自带的菜单项（编辑、窗口、服务、退出、关闭等）按本应用的 AppleLanguages 选语言，
//  只改 RawLab.language 时菜单栏会中英混排。界面语言选定后同步写入，跟随系统时只撤掉
//  自己写过的值，不动用户在"系统设置"里为本应用选的语言。启动时最先执行；运行中切换
//  语言，系统菜单在下次启动时跟上
// ----------------------------------------------------------------------------
enum SystemMenuLanguage {
    static let managedKey = "RawLab.appleLanguagesManaged"

    static func apply(_ preference: String?, defaults: UserDefaults = .standard) {
        if let language = AppLanguage(rawValue: preference ?? ""), language != .system {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
            defaults.set(true, forKey: managedKey)
        } else if defaults.bool(forKey: managedKey) {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: managedKey)
        }
    }
}

private struct UpdateAvailabilityBanner: View {
    @ObservedObject var updates: DesktopUpdateController
    @ObservedObject var legacy: UpdateChecker
    var open: () -> Void
    var body: some View {
        if let version = updates.state.phase == .available ? updates.state.release?.version :
            (updates.unavailableReason != nil ? legacy.available?.version : nil) {
            HStack {
                Text(L10n.format("RawLab %@ 已发布", version))
                Spacer()
                Button(L10n.text("查看更新"), action: open)
            }.padding(8)
        }
    }
}
