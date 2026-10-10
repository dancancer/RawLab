import SwiftUI

struct FileBrowser: View {
    @ObservedObject var library: PhotoLibrary
    let selected: URL?
    let open: (URL) -> Void
    var canApplySettings = false
    var applySettings: (URL, Bool) -> Void = { _, _ in }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件夹").font(.headline)
                Spacer()
                Button(action: library.addDirectories) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("添加目录").accessibilityLabel("添加目录")
            }.padding(14)
            Divider()
            if library.roots.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.secondary)
                    Button("添加目录…", action: library.addDirectories)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 目录和照片行共用原生列表，避免嵌套网格重新估算高度时改变滚动位置。
                List {
                    ForEach(FileBrowserRow.rows(in: library.roots)) { row in
                        browserRow(row)
                            .padding(.leading, CGFloat(row.depth) * 8)
                            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                            .listRowSeparator(.hidden)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func browserRow(_ row: FileBrowserRow) -> some View {
        switch row.content {
        case .folder(let folder):
            FolderHeading(folder: folder)
                .contextMenu {
                    fileActions(folder.url, directory: true)
                    Divider()
                    Button("从侧栏移除此目录") { library.remove(row.root) }
                }
        case .photos(let first, let second):
            HStack(spacing: 8) {
                PhotoThumbnail(url: first, selected: selected == first) { open(first) }
                    .overlay { PhotoContextMenu(url: first, canApply: canApplySettings) { applySettings(first, false) } }
                if let second {
                    PhotoThumbnail(url: second, selected: selected == second) { open(second) }
                        .overlay { PhotoContextMenu(url: second, canApply: canApplySettings) { applySettings(second, false) } }
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }.frame(height: 101)
        case .error(let folder, let message):
            HStack(alignment: .top) {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: folder.load) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("重新读取目录").accessibilityLabel("重新读取目录")
            }
        case .empty:
            Text("无 RAW 照片").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
        }
    }

    @ViewBuilder private func fileActions(_ url: URL, directory: Bool) -> some View {
        Button {
            if directory { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            Label("在 Finder 中打开", systemImage: "folder")
        }
        Button { applySettings(url, directory) } label: {
            Label("应用当前设置", systemImage: "slider.horizontal.3")
        }.disabled(!canApplySettings)
    }
}

// List 会合并同一行的 SwiftUI 菜单；让每张缩略图独立命中右键目标。
private struct PhotoContextMenu: NSViewRepresentable {
    let url: URL
    let canApply: Bool
    let apply: () -> Void

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) {
        view.url = url; view.canApply = canApply; view.apply = apply
    }

    final class MenuView: NSView {
        var url: URL?
        var canApply = false
        var apply: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { showMenu(event) }
        override func mouseDown(with event: NSEvent) { showMenu(event) }
        private func showMenu(_ event: NSEvent) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let open = menu.addItem(withTitle: "在 Finder 中打开", action: #selector(openInFinder), keyEquivalent: "")
            open.target = self
            let copy = menu.addItem(withTitle: "应用当前设置", action: #selector(applyCurrentSettings), keyEquivalent: "")
            copy.target = self; copy.isEnabled = canApply
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        @objc private func openInFinder() { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        @objc private func applyCurrentSettings() { apply?() }
    }
}

struct FileBrowserRow: Identifiable {
    enum Content {
        case folder(PhotoFolder)
        case photos(URL, URL?)
        case error(PhotoFolder, String)
        case empty
    }
    enum ID: Hashable {
        case folder(URL, URL)
        case photos(URL, URL)
        case message(URL, URL)
    }
    let id: ID
    let root: PhotoFolder
    let depth: Int
    let content: Content

    static func rows(in roots: [PhotoFolder]) -> [Self] {
        var rows: [Self] = []
        func append(_ folder: PhotoFolder, root: PhotoFolder, depth: Int) {
            rows.append(Self(id: .folder(root.url, folder.url), root: root, depth: depth, content: .folder(folder)))
            guard folder.expanded else { return }
            if let error = folder.error {
                rows.append(Self(id: .message(root.url, folder.url), root: root, depth: depth, content: .error(folder, error)))
            }
            for child in folder.folders { append(child, root: root, depth: depth + 1) }
            for index in stride(from: 0, to: folder.photos.count, by: 2) {
                let first = folder.photos[index]
                let second = index + 1 < folder.photos.count ? folder.photos[index + 1] : nil
                rows.append(Self(id: .photos(root.url, first), root: root, depth: depth, content: .photos(first, second)))
            }
            if !folder.loading && folder.error == nil && folder.photos.isEmpty && folder.folders.isEmpty {
                rows.append(Self(id: .message(root.url, folder.url), root: root, depth: depth, content: .empty))
            }
        }
        for root in roots { append(root, root: root, depth: 0) }
        return rows
    }
}

private struct FolderHeading: View {
    @ObservedObject var folder: PhotoFolder
    var body: some View {
        Button(action: folder.toggle) {
            HStack(spacing: 7) {
                Image(systemName: folder.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Image(systemName: folder.expanded ? "folder.fill" : "folder").foregroundStyle(.secondary)
                Text(folder.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if folder.loading { ProgressView().controlSize(.mini) }
            }.font(.system(size: 12, weight: .medium)).frame(height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(folder.url.path)
            .accessibilityValue(folder.expanded ? "已展开" : "已收起")
    }
}

private struct PhotoThumbnail: View {
    let url: URL
    let selected: Bool
    let action: () -> Void
    @State private var image: NSImage?
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Color.black.opacity(0.35)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().padding(3)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }.frame(height: 82).clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2) }
                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 11))
                    .foregroundStyle(selected ? Color.yellow : Color.primary).lineLimit(1).truncationMode(.middle)
                    .frame(height: 14)
            }.frame(minWidth: 0, maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).help(url.lastPathComponent).accessibilityLabel(url.lastPathComponent)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: url) {
                let loaded = await PhotoThumbnails.shared.image(for: url)
                if !Task.isCancelled { image = loaded }
            }
    }
}
