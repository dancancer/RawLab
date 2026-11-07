import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LUTCompatibilityDialog {
    @MainActor
    static func present(source: URL, draft: LUTCompatibility, photo: LUTPreviewSource?,
                        finish: @escaping (LUTCompatibility?) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 840),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("兼容导入")
        window.minSize = NSSize(width: 620, height: 600)
        window.isReleasedWhenClosed = false
        let parent = NSApp.mainWindow
        window.contentView = NSHostingView(rootView: MacLUTCompatibilityView(fileName: source.lastPathComponent,
            sourceURL: source, draft: draft, initialPhoto: photo) { value in
            if let parent, parent.attachedSheet == window { parent.endSheet(window) }
            window.orderOut(nil)
            window.contentView = nil
            finish(value)
        })
        if let parent, parent.attachedSheet == nil { parent.beginSheet(window) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
    }
}

private struct MacLUTCompatibilityView: View {
    let fileName: String
    let sourceURL: URL
    let draft: LUTCompatibility
    let initialPhoto: LUTPreviewSource?
    let finish: (LUTCompatibility?) -> Void
    @State private var choosingPhoto = false
    @State private var selectedPhoto: ((LUTPreviewSource) -> Void)?

    var body: some View {
        LUTCompatibilityView(fileName: fileName, sourceURL: sourceURL, draft: draft, initialPhoto: initialPhoto,
            chooseLibraryPhoto: { completion in selectedPhoto = completion; choosingPhoto = true }, finish: finish)
            .sheet(isPresented: $choosingPhoto) {
                LUTPhotoLibraryPicker { photo in
                    if let photo { selectedPhoto?(LUTPreviewSource(url: photo)) }
                    selectedPhoto = nil; choosingPhoto = false
                }
            }
    }
}

private struct LUTPhotoLibraryPicker: View {
    // 从同一持久化目录列表建立独立视图，浏览和选择不会改变主窗口的照片或展开状态。
    @StateObject private var library = PhotoLibrary()
    @State private var selected: URL?
    let finish: (URL?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text("从照片库选择")).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            FileBrowser(library: library, selected: selected, open: { selected = $0 }, selectionOnly: true)
            Divider()
            HStack {
                Button(L10n.text("取消")) { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("使用此照片")) { finish(selected) }
                    .buttonStyle(.borderedProminent).disabled(selected == nil).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("look.compatibility.library.confirm")
            }.padding(16)
        }.frame(width: 620, height: 560).tint(.yellow)
            .accessibilityIdentifier("look.compatibility.library")
            .onAppear { for root in library.roots { root.expanded = true; root.load() } }
    }
}

enum DCPImportOptionsDialog {
    @MainActor
    static func present(source: URL, reason: DCPCompilerError,
                        finish: @escaping (DCPImportOptions?) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.text("DCP 导入选项")
        window.isReleasedWhenClosed = false
        let parent = NSApp.mainWindow
        window.contentView = NSHostingView(rootView: MacDCPImportOptionsView(source: source, reason: reason) { options in
            if let parent, parent.attachedSheet == window { parent.endSheet(window) }
            window.orderOut(nil)
            window.contentView = nil
            finish(options)
        })
        if let parent, parent.attachedSheet == nil { parent.beginSheet(window) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
    }
}

private struct MacDCPImportOptionsView: View {
    let source: URL
    let reason: DCPCompilerError
    let finish: (DCPImportOptions?) -> Void
    @State private var curveData: Data?
    @State private var curveFileName: String?
    @State private var omitAutomaticBlack = false
    @State private var errorMessage: String?

    private var requiresToneCurve: Bool { reason == .missingToneCurve }
    private var requiresAutomaticBlackChoice: Bool { reason == .automaticBlack }
    private var canImport: Bool {
        (!requiresToneCurve || curveData != nil) && (!requiresAutomaticBlackChoice || omitAutomaticBlack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(source.lastPathComponent).font(.headline)
            Text(reason.localizedDescription).foregroundStyle(.secondary)
            Divider()
            if requiresToneCurve {
                HStack {
                    Text(L10n.text("色调曲线（JSON）"))
                    Spacer()
                    Button(curveFileName ?? L10n.text("选择曲线文件…")) { chooseCurve() }
                }
            }
            Toggle(L10n.text("省略自动黑位"), isOn: $omitAutomaticBlack)
            Spacer()
            HStack {
                Button(L10n.text("取消")) { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("导入外观")) {
                    finish(DCPImportOptions(toneCurveJSON: curveData,
                                            omitAutomaticBlack: omitAutomaticBlack))
                }.buttonStyle(.borderedProminent).disabled(!canImport).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 300)
        .alert(L10n.text("DCP 导入选项"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.text("确定")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func chooseCurve() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1024 * 1024 else {
                errorMessage = L10n.text("DCP 文件或外观数据超过安全大小限制。")
                return
            }
            curveData = data
            curveFileName = url.lastPathComponent
        } catch {
            errorMessage = L10n.text("无法读取外观文件。")
        }
    }
}
