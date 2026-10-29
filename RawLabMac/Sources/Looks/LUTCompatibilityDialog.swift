import AppKit
import SwiftUI

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
