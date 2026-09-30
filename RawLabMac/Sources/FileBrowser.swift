import SwiftUI

struct FileBrowser: View {
    @ObservedObject var library: PhotoLibrary
    let selected: URL?
    let open: (URL) -> Void
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
                            .contextMenu {
                                Button("从侧栏移除此目录") { library.remove(row.root) }
                            }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func browserRow(_ row: FileBrowserRow) -> some View {
        switch row.content {
        case .folder(let folder):
            FolderHeading(folder: folder)
        case .photos(let first, let second):
            HStack(spacing: 8) {
                PhotoThumbnail(url: first, selected: selected == first) { open(first) }
                if let second {
                    PhotoThumbnail(url: second, selected: selected == second) { open(second) }
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
