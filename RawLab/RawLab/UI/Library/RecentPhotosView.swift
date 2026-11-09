import SwiftUI

struct RecentPhotosView: View {
    @ObservedObject var library: IOSPhotoPreviewLibrary
    @ObservedObject var model: RawEditorViewModel
    @Binding var filter: PhotoEditFilter
    @Binding var scrollID: String?
    let open: (RecentPhoto) -> Void
    let importPhoto: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var visible: [RecentPhoto] {
        library.photos.filter { filter.includes(library.edited[$0.id]) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.text("编辑状态"), selection: $filter) {
                    ForEach(PhotoEditFilter.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10)
                    .accessibilityIdentifier("recents.filter")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.text("仅显示在本机用 RawLab 打开过的照片。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = library.error {
                            Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("recents.error")
                        }
                        if visible.isEmpty {
                            ContentUnavailableView {
                                Label(L10n.text(library.photos.isEmpty ? "尚无最近打开的照片" : "没有符合筛选的照片"), systemImage: "photo.on.rectangle")
                            } description: {
                                Text(L10n.text(library.photos.isEmpty ? "导入并打开一张照片后，可在这里继续编辑。" : "试试其他编辑状态。"))
                            } actions: {
                                if library.photos.isEmpty { Button(L10n.text("导入照片"), action: importPhoto).buttonStyle(.borderedProminent) }
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 200), spacing: 10)], spacing: 16) {
                                ForEach(visible) { photo in
                                    Button { open(photo) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            IOSPhotoThumbnail(input: .recent(photo), library: library, model: model)
                                                .aspectRatio(1, contentMode: .fit)
                                            Text(photo.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityIdentifier("recents.photo.\(photo.id)")
                                        .contextMenu {
                                            Button(L10n.text("打开")) { open(photo) }
                                            Button(L10n.text("从最近打开中移除"), role: .destructive) {
                                                Task { await library.remove(photo, editDirectory: model.editPersistence?.directory) }
                                            }
                                        }
                                }
                            }.scrollTargetLayout()
                        }
                        if !library.photos.isEmpty {
                            Text(L10n.text("保留最近 100 张照片及约 2 GB 本机副本。移除记录不会删除原照片或调整。"))
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    }.padding(16)
                }.scrollPosition(id: $scrollID, anchor: .top).accessibilityIdentifier("recents.grid")
            }
            .navigationTitle(L10n.text("最近打开")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: importPhoto) { Image(systemName: "photo.badge.plus") }
                        .accessibilityLabel(L10n.text("导入照片"))
                }
            }
        }
        .task { await library.reload(editDirectory: model.editPersistence?.directory) }
    }
}

enum PhotoEditFilter: String, CaseIterable, Identifiable {
    case all, edited, unedited
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .edited: "已编辑"; case .unedited: "未编辑" } }
    func includes(_ edited: Bool?) -> Bool {
        switch self { case .all: true; case .edited: edited == true; case .unedited: edited == false }
    }
}

enum IOSPhotoThumbnailInput {
    case recent(RecentPhoto)
    case source(IOSPhotoPreviewSource)
    var identity: PhotoIdentity { switch self { case .recent(let photo): photo.identity; case .source(let photo): photo.identity } }
    var isRaw: Bool { switch self { case .recent(let photo): photo.isRaw; case .source(let photo): photo.isRaw } }
}

struct IOSPhotoThumbnail: View {
    let input: IOSPhotoThumbnailInput
    @ObservedObject var library: IOSPhotoPreviewLibrary
    @ObservedObject var model: RawEditorViewModel
    @State private var image: UIImage?
    @State private var edited: Bool?
    @State private var notice: String?
    private enum ImageOrigin { case none, original, previous, adjusted }
    @State private var origin = ImageOrigin.none
    private var requestID: String {
        "\(input.identity.key):\(input.identity.contentIdentifier ?? ""):\(library.revision):\(model.adjustmentHistoryRevision):\(model.isLoadingLUTs):\(library.isEditorBusy)"
    }
    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo").foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if edited == true {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(5).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                if let notice {
                    Text(L10n.text(notice)).font(.system(size: 9)).lineLimit(2).foregroundStyle(.white)
                        .padding(3).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(edited.map { L10n.text($0 ? "已编辑" : "未编辑") } ?? L10n.text("预览待更新"))
            .accessibilityValue(notice.map { L10n.text($0) } ?? "")
            .task(id: requestID, priority: .utility) { await load() }
    }

    @MainActor private func load() async {
        do {
            if case .recent(let photo) = input, image == nil, let previous = await library.lastPreview(for: photo) {
                try Task.checkCancellation()
                image = previous; notice = "上次预览"; origin = .previous
            }
            guard let directory = model.editPersistence?.directory else { notice = "预览未更新"; return }
            let record = try await library.record(for: input.identity, editDirectory: directory)
            try Task.checkCancellation()
            let modified = IOSPhotoPreviewPlan.isEdited(record, isRaw: input.isRaw)
            edited = modified
            let source: IOSPhotoPreviewSource
            switch input {
            case .recent(let photo):
                source = try await library.source(for: photo)
            case .source(let photo): source = photo
            }
            try Task.checkCancellation()
            if !modified || image == nil {
                let original = await library.original(source)
                try Task.checkCancellation()
                if let original { image = original; origin = .original }
            }
            if modified { notice = origin == .original ? "原始预览" : origin == .previous ? "上次预览" : "预览待更新" }
            else { notice = origin == .previous ? "上次预览" : image == nil ? "预览未更新" : nil }
            if (modified || origin != .original), !library.isEditorBusy, !model.isLoadingLUTs {
                let image = try await library.image(source, record: record,
                    look: record.state.flatMap { model.lutURL(for: $0.settings) }, editDirectory: directory)
                try Task.checkCancellation()
                self.image = image; origin = modified ? .adjusted : .original; notice = nil
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled { notice = "预览未更新" }
        }
    }
}
