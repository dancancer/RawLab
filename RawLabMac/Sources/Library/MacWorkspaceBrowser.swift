import AppKit
import SwiftUI

struct MacWorkspaceLibrary: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var navigation: MacWorkspaceBrowserState
    let selected: URL?
    let foldersOnly: Bool
    let open: (URL) -> Void
    let canApplySettings: Bool
    let applySettings: (URL, Bool) -> Void
    @State private var dropTarget = false

    var body: some View {
        let _ = localizationLocale
        GeometryReader { area in
            let rows = FolderRow.rows(in: library.roots)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(L10n.text("文件夹")).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 3)
                    Button { navigation.collapseAll(in: library) } label: {
                        Label(L10n.text("收起全部"), systemImage: "chevron.up.2")
                            .font(.caption)
                    }.buttonStyle(.borderless)
                        .disabled(!rows.contains { $0.folder.isExpandedInTree })
                        .accessibilityIdentifier("workspace.folders.collapseAll")
                    Button(action: library.addDirectories) { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).help(L10n.text("添加目录")).accessibilityLabel(L10n.text("添加目录"))
                        .accessibilityIdentifier("workspace.folders.add")
                }.padding(.horizontal, 10).frame(minHeight: 34)
                if rows.isEmpty {
                    Button(L10n.text("添加目录…"), action: library.addDirectories)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    folderTree(rows)
                        .frame(height: foldersOnly ? nil : min(area.size.height * 0.34, 220, CGFloat(rows.count * 28 + 8)))
                }
                if !foldersOnly {
                    Divider()
                    WorkspacePhotoHeader(library: library, navigation: navigation, selected: selected)
                    photoContent
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            library.addDirectories(urls)
        } isTargeted: { dropTarget = $0 }
        .overlay {
            if dropTarget { Rectangle().stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("文件树")).accessibilityIdentifier("workspace.library")
    }

    @ViewBuilder private var photoContent: some View {
        if let folder = navigation.folder, let location = navigation.location {
            WorkspacePhotoGrid(folder: folder, location: location, navigation: navigation, selected: selected, grid: false,
                open: open, canApplySettings: canApplySettings, applySettings: applySettings)
                .id(location)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func folderTree(_ rows: [FolderRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        folderRow(row)
                            .padding(.leading, CGFloat(min(row.path.count - 1, 8)) * 9)
                            .id(row.id)
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
            .accessibilityIdentifier("workspace.folders.scroll")
            .onChange(of: navigation.treeReveal, initial: true) { _, _ in
                if let id = navigation.location { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func folderRow(_ row: FolderRow) -> some View {
        let folder = row.folder
        let active = row.id == navigation.location
        return HStack(spacing: 2) {
            if folder.canExpand {
                Button(action: folder.toggle) {
                    Image(systemName: folder.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 22, height: 27).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(folder.url.lastPathComponent)
                    .accessibilityValue(L10n.text(folder.expanded ? "已展开" : "已收起"))
                    .accessibilityIdentifier("workspace.folder.disclosure.\(folder.url.lastPathComponent)")
            } else {
                Color.clear.frame(width: 22, height: 27).accessibilityHidden(true)
            }
            Button { navigation.browse(row.path) } label: {
                HStack(spacing: 6) {
                    Image(systemName: folder.error == nil ? "folder" : "exclamationmark.triangle")
                        .foregroundStyle(active ? Color.yellow : Color.secondary)
                    Text(folder.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if folder.loading { ProgressView().controlSize(.mini) }
                    if active { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.yellow) }
                }.font(.system(size: 12, weight: active ? .semibold : .regular))
                    .padding(.horizontal, 4).frame(height: 27)
                    .background(active ? Color.yellow.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(folder.url.path)
                .accessibilityLabel(folder.url.lastPathComponent).accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("workspace.folder.\(folder.url.lastPathComponent)")
                .contextMenu {
                    Button(L10n.text("在 Finder 中打开")) { NSWorkspace.shared.open(folder.url) }
                    Button(L10n.text("应用当前设置")) { applySettings(folder.url, true) }.disabled(!canApplySettings)
                    Button(L10n.text("重新读取目录"), action: folder.refresh)
                    if row.path.count == 1 {
                        Divider()
                        Button(L10n.text("从侧栏移除此目录")) { library.remove(folder) }
                    }
                }
        }
    }

    private struct FolderRow: Identifiable {
        let path: [PhotoFolder]
        var folder: PhotoFolder { path.last! }
        var id: MacWorkspaceBrowserState.Location { .init(root: path.first!.url, folder: folder.url) }

        static func rows(in roots: [PhotoFolder]) -> [Self] {
            var rows = [Self]()
            func append(_ folder: PhotoFolder, after parent: [PhotoFolder]) {
                let path = parent + [folder]
                rows.append(Self(path: path))
                if folder.expanded {
                    for child in folder.folders { append(child, after: path) }
                }
            }
            for root in roots { append(root, after: []) }
            return rows
        }
    }
}

struct MacWorkspaceSelection: View {
    @ObservedObject var library: PhotoLibrary
    @ObservedObject var navigation: MacWorkspaceBrowserState
    let selected: URL?
    let open: (URL) -> Void
    let canAdd: Bool
    let onAdd: ([URL]) -> Void
    let showTree: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let folder = navigation.folder, let location = navigation.location {
                WorkspacePhotoHeader(library: library, navigation: navigation, selected: selected, showTree: showTree)
                Divider()
                WorkspacePhotoGrid(folder: folder, location: location, navigation: navigation, selected: selected,
                    grid: true, open: open).id(location)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Button(L10n.text("添加目录…"), action: library.addDirectories)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !navigation.selection.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Text(L10n.format("已选 %@ 张", navigation.selection.count.formatted())).monospacedDigit()
                        .accessibilityIdentifier("workspace.selection.count")
                    Spacer()
                    Button(L10n.text("清空选择"), action: navigation.clearSelection)
                    Button(L10n.text("加入选片集合")) { onAdd(navigation.selection) }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!canAdd)
                        .accessibilityIdentifier("workspace.selection.add")
                }.padding(10).background(Color(nsColor: .windowBackgroundColor))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("选片")).accessibilityIdentifier("workspace.selection")
    }
}

private struct WorkspacePhotoHeader: View {
    let library: PhotoLibrary
    @ObservedObject var navigation: MacWorkspaceBrowserState
    let selected: URL?
    var showTree: () -> Void = {}

    var body: some View {
        if let folder = navigation.folder {
            WorkspaceFolderHeading(folder: folder, navigation: navigation, selected: selected, showTree: showTree) {
                guard let selected else { return }
                navigation.locate(selected, in: library) { NSWorkspace.shared.activateFileViewerSelecting([selected]) }
            }
        }
    }
}

private struct WorkspaceFolderHeading: View {
    @ObservedObject var folder: PhotoFolder
    @ObservedObject var navigation: MacWorkspaceBrowserState
    let selected: URL?
    let showTree: () -> Void
    let locate: () -> Void

    var body: some View {
        let path = navigation.path
        let breadcrumb = path.suffix(2).map { $0.url.lastPathComponent }.joined(separator: " / ")
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L10n.text("照片")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if !folder.loading && folder.error == nil {
                    Text(L10n.format("%@ 张照片", folder.photos.count.formatted())).font(.caption)
                        .foregroundStyle(.secondary).accessibilityIdentifier("workspace.photos.count")
                }
            }
            Text(breadcrumb).lineLimit(1).truncationMode(.middle).font(.caption.weight(.medium))
                .help(folder.url.path).accessibilityIdentifier("workspace.photos.path")
                .contextMenu {
                    Button(L10n.text("重新读取目录"), action: folder.refresh)
                }
            HStack(spacing: 9) {
                Button { navigation.goUp() } label: {
                    Label(L10n.text("上一级"), systemImage: "arrow.up").font(.caption)
                }.disabled(path.count < 2).accessibilityIdentifier("workspace.photos.up")
                Button {
                    navigation.revealInTree()
                    showTree()
                } label: { Image(systemName: "scope") }
                    .help(L10n.text("在目录树中定位")).accessibilityLabel(L10n.text("在目录树中定位"))
                    .accessibilityIdentifier("workspace.photos.revealFolder")
                Button(action: navigation.collapseBranch) { Image(systemName: "chevron.up.2") }
                    .help(L10n.text("收起分支")).accessibilityLabel(L10n.text("收起分支"))
                    .disabled(!path.contains(where: \.isExpandedInTree)).accessibilityIdentifier("workspace.photos.collapseBranch")
            }.buttonStyle(.borderless)
            if let selected, !navigation.containsDirectory(of: selected) {
                Button(action: locate) {
                    Label(L10n.text("正在编辑另一目录的照片"), systemImage: "location")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.photos.revealCurrent")
            }
        }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspacePhotoGrid: View {
    @ObservedObject var folder: PhotoFolder
    let location: MacWorkspaceBrowserState.Location
    @ObservedObject var navigation: MacWorkspaceBrowserState
    let selected: URL?
    let grid: Bool
    let open: (URL) -> Void
    var canApplySettings = false
    var applySettings: (URL, Bool) -> Void = { _, _ in }
    @State private var firstVisible: URL?

    var body: some View {
        Group {
            if folder.loading && folder.photos.isEmpty {
                ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在读取目录…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = folder.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("重新读取目录"), action: folder.load)
                }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if folder.photos.isEmpty {
                Text(L10n.text("无照片")).font(.caption).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                photos
            }
        }
    }

    private var photos: some View {
        let columns = grid ? [GridItem(.adaptive(minimum: 132, maximum: 208), spacing: 8)]
            : Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 2)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: grid ? 9 : 6) {
                ForEach(folder.photos, id: \.self) { url in
                    photoTile(url).id(url)
                }
            }.scrollTargetLayout().padding(grid ? 12 : 7)
        }.scrollPosition(id: $firstVisible, anchor: .top)
            .accessibilityIdentifier(grid ? "workspace.selection.scroll" : "workspace.photos.scroll")
            .onAppear { restoreAnchor() }
            .onChange(of: navigation.photoReveal) { _, _ in restoreAnchor() }
            .onChange(of: firstVisible) { _, next in
                if let next { navigation.remember(next, in: location, grid: grid) }
            }
            .onChange(of: folder.photos) { _, _ in restoreAnchor() }
    }

    private func restoreAnchor() {
        if let anchor = navigation.restoreAnchor(in: location, grid: grid, photos: folder.photos) {
            firstVisible = anchor
        }
    }

    private var mouseClick: NSEvent? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else { return nil }
        return event
    }

    private func photoTile(_ url: URL) -> some View {
        let active = selected?.standardizedFileURL == url.standardizedFileURL
        let checked = grid && navigation.includes(url)
        return Button {
            if grid {
                let event = mouseClick
                let extending = (event?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
                guard navigation.activate(url, in: folder.photos, extending: extending, mouseClickCount: event?.clickCount) else { return }
            }
            open(url)
        } label: {
            WorkspacePhotoTile(url: url, active: active, checked: checked, grid: grid)
        }.buttonStyle(.plain).help(url.lastPathComponent).accessibilityLabel(url.lastPathComponent)
            .accessibilityValue([
                checked ? L10n.text("已选") : nil,
                active ? L10n.text("当前照片") : nil
            ].compactMap { $0 }.joined(separator: " · "))
            .accessibilityAddTraits(checked || active ? .isSelected : [])
            .accessibilityIdentifier("workspace.photo.\(url.lastPathComponent)")
            .contextMenu {
                if grid { Button(L10n.text("单张微调")) { open(url) } }
                Button(L10n.text("在 Finder 中打开")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if !grid {
                    Button(L10n.text("应用当前设置")) { applySettings(url, false) }.disabled(!canApplySettings)
                }
            }
    }
}

private struct WorkspacePhotoTile: View {
    let url: URL
    let active: Bool
    let checked: Bool
    let grid: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Color.black.opacity(0.35).aspectRatio(1.55, contentMode: .fit)
                .overlay {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }.clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(active ? .yellow : .clear, lineWidth: 2) }
                .overlay(alignment: .topTrailing) {
                    if checked {
                        Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.black)
                            .padding(4).background(.yellow, in: RoundedRectangle(cornerRadius: 3)).padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if grid && active {
                        Text(L10n.text("当前照片")).font(.caption2)
                            .padding(4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                    }
                }
            Text(url.lastPathComponent).font(.system(size: grid ? 12 : 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(active ? Color.yellow : Color.primary)
        }.padding(2).frame(maxWidth: .infinity)
            .background(checked ? Color.yellow.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .task(id: url) {
                let loaded = await PhotoThumbnails.shared.image(for: url)
                if !Task.isCancelled { thumbnail = loaded }
            }
    }
}
