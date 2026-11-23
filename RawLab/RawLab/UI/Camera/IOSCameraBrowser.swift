import RawLabKit
import SwiftUI

struct IOSCameraBrowser: View {
    @ObservedObject var model: IOSCameraController
    let openOriginal: (CameraStoredOriginal) -> Void
    let history: () -> Void
    let storage: () -> Void
    let reconnect: () -> Void
    let resume: (CameraTransferJob) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var format = "all"
    @State private var day: String?
    @State private var onlySelected = false
    @State private var filters = false
    @State private var showJPEG = false
    @State private var previewAsset: CameraRemoteAsset?
    private var visible: [CameraRemoteAsset] {
        model.manualAssets.filter { asset in
            (format == "all" || asset.snapshot.kind.lowercased() == format) &&
            (day == nil || Self.dayKey(asset.snapshot) == day) &&
            (!onlySelected || model.selection.contains(asset.id))
        }
    }
    private var hiddenSelection: Bool { model.selection.subtracting(Set(visible.map(\.id))).count > 0 }
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize { modePicker.pickerStyle(.menu) }
                else { modePicker.pickerStyle(.segmented) }
            }.frame(minHeight: 44).padding(.horizontal, 14).disabled(model.busy)
                .accessibilityIdentifier("camera.import.mode")
            if model.importPreferences.incremental {
                IOSCameraIncrementalImport(model: model, history: history, reconnect: reconnect, resume: resume)
            } else { manualBrowser }
        }
        .background(Color(white: 0.10)).navigationTitle(model.device?.model ?? L10n.text("从相机导入"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.text("重新扫描"), action: model.refreshImport).disabled(!model.connected || model.busy)
                    Button(L10n.text("JPEG 保存")) { showJPEG = true }
                        .disabled(model.busy)
                        .accessibilityIdentifier("camera.jpeg.settings")
                    Divider()
                    Button(L10n.text("导入记录"), action: history)
                    Button(L10n.text("保存位置"), action: storage)
                    Button(L10n.text("更换相机"), action: reconnect)
                    Button(L10n.text("断开连接")) { model.stop() }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(L10n.text("更多"))
            }
        }
        .sheet(isPresented: $filters) {
            IOSCameraFilters(format: $format, day: $day, onlySelected: $onlySelected,
                days: Array(Set(model.assets.compactMap { Self.dayKey($0.snapshot) })).sorted(by: >))
        }
        .sheet(isPresented: $showJPEG) {
            IOSCameraJPEGSettings(draft: model.importPreferences.jpeg, apply: model.setJPEGOptions)
        }
        .sheet(item: $previewAsset) { asset in
            let currentIndex = visible.firstIndex(where: { $0.id == asset.id })
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(asset.snapshot.size), countStyle: .file)
            let indexText = currentIndex.map { "\($0 + 1) / \(visible.count)" }
            let detail = [asset.snapshot.kind, sizeText, indexText].compactMap { $0 }.joined(separator: " · ")
            let isSelected = model.selection.contains(asset.id)
            IOSCameraPreview(model: model, name: asset.snapshot.name, detail: detail) {
                HStack(spacing: 12) {
                    Button {
                        if let idx = currentIndex, idx > 0 {
                            let prev = visible[idx - 1]
                            model.showPreview(prev)
                            previewAsset = prev
                        }
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .disabled(currentIndex == nil || currentIndex == 0)
                    .accessibilityLabel(L10n.text("上一张"))

                    Spacer(minLength: 4)

                    if let original = model.original(for: asset) {
                        Button(L10n.text("打开编辑")) { previewAsset = nil; openOriginal(original) }
                            .frame(minHeight: 44)
                    }
                    if isSelected {
                        Button(L10n.text("取消选中")) { model.selection.remove(asset.id) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .disabled(model.busy)
                    } else {
                        Button(L10n.text("选中")) { model.selection.insert(asset.id) }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.black)
                            .frame(minHeight: 44)
                            .disabled(model.busy)
                    }

                    Spacer(minLength: 4)

                    Button {
                        if let idx = currentIndex, idx + 1 < visible.count {
                            let next = visible[idx + 1]
                            model.showPreview(next)
                            previewAsset = next
                        }
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .disabled(currentIndex.map { $0 + 1 >= visible.count } ?? true)
                    .accessibilityLabel(L10n.text("下一张"))
                }
            }
        }
    }
    private var modePicker: some View {
        Picker(L10n.text("导入方式"), selection: Binding(get: { model.importPreferences.incremental }, set: model.setIncrementalMode)) {
            Text(L10n.text("手动选片")).tag(false)
            Text(L10n.text("增量导入")).tag(true)
        }
    }
    private var manualBrowser: some View {
        let visibleIDs = visible.map(\.id)
        let allSelected = IOSCameraLayoutPolicy.allVisibleSelected(visibleIDs: visibleIDs, selection: model.selection)
        let filterTokens = IOSCameraLayoutPolicy.activeFilterTokens(
            format: format, day: day, onlySelected: onlySelected, selectedLabel: L10n.text("查看已选")
        )
        let hasActiveFilters = !filterTokens.isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(visible.count)").font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                if hasActiveFilters {
                    Button {
                        format = "all"; day = nil; onlySelected = false
                    } label: {
                        HStack(spacing: 4) {
                            Text(filterTokens.joined(separator: " · "))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(.yellow)
                        .background(Color.yellow.opacity(0.14), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 36)
                    .accessibilityLabel(L10n.text("清除筛选"))
                }
                Spacer(minLength: 4)
                Button { filters = true } label: {
                    Label(L10n.text("筛选照片"), systemImage: "line.3.horizontal.decrease")
                        .foregroundStyle(hasActiveFilters ? Color.yellow : Color.primary)
                        .frame(minHeight: 40)
                }.accessibilityIdentifier("camera.filter")
                Button(L10n.text(allSelected ? "取消全选" : "全选")) {
                    IOSCameraLayoutPolicy.toggleVisibleSelection(visibleIDs: visibleIDs, selection: &model.selection)
                }
                .frame(minHeight: 40)
                .disabled(visible.isEmpty || model.busy)
                .accessibilityIdentifier("camera.select.all")
            }.font(.callout).padding(.horizontal, 14)
            if model.importPreferences.jpeg.adjust {
                Button { showJPEG = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3").font(.caption)
                        Text(L10n.text("JPEG 保存") + " · " + IOSCameraJPEGSettings.summary(for: model.importPreferences.jpeg))
                            .font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .padding(.horizontal, 14).padding(.bottom, 6)
                .accessibilityIdentifier("camera.jpeg.adjusted")
            }
            Divider()
            if !model.connected {
                HStack {
                    Text(L10n.text("相机连接已断开。已保存的照片仍可查看。")).font(.caption)
                    Spacer(); Button(L10n.text("重新连接"), action: reconnect)
                }.padding(12).background(Color(white: 0.17))
            }
            if let notice = model.notice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                    if model.photoLibraryPermissionDenied {
                        Button(L10n.text("系统权限设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)
            } else if model.lastSavedToPhotoLibraryCount > 0 || !model.lastManualImportOriginals.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(model.lastSavedToPhotoLibraryCount > 0
                         ? L10n.format("已保存 %d 张照片到手机相册", model.lastSavedToPhotoLibraryCount)
                         : L10n.format("已保存 %d 张", model.lastManualImportOriginals.count))
                        .font(.caption)
                    Spacer()
                    if model.lastManualImportOriginals.count == 1, let single = model.lastManualImportOriginals.first {
                        Button(L10n.text("打开编辑")) { openOriginal(single) }
                            .font(.caption.weight(.semibold))
                    } else {
                        Button(L10n.text("导入记录"), action: history)
                            .font(.caption.weight(.semibold))
                    }
                    Button { model.dismissPhotoLibraryBanner() } label: { Image(systemName: "xmark") }
                        .frame(minWidth: 32, minHeight: 32)
                        .accessibilityLabel(L10n.text("关闭"))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(white: 0.16))
            }
            GeometryReader { geometry in
                let columns = IOSCameraLayoutPolicy.gridColumns(forWidth: geometry.size.width)
                ScrollView {
                    if model.assets.isEmpty {
                        ContentUnavailableView(L10n.text(model.listingLimitExceeded ? "已到上限" : "相机中没有可导入的 RAW 或 JPEG 照片。"),
                                               systemImage: "photo.on.rectangle")
                            .frame(minHeight: geometry.size.height)
                    } else if visible.isEmpty {
                        ContentUnavailableView(L10n.text("没有符合筛选条件的照片。"), systemImage: "line.3.horizontal.decrease")
                            .frame(minHeight: geometry.size.height)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 10) {
                            ForEach(visible) { asset in tile(asset) }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }.accessibilityIdentifier("camera.photo.grid")
            }
            if model.phase == .receiving { transferProgress }
            else if !model.selection.isEmpty { selectionBar }
        }
    }
    private func tile(_ asset: CameraRemoteAsset) -> some View {
        let selected = model.selection.contains(asset.id)
        let saved = model.original(for: asset) != nil
        return Button {
            if selected { model.selection.remove(asset.id) } else { model.selection.insert(asset.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.06))
                        .aspectRatio(1.5, contentMode: .fit)
                        .overlay {
                            if let image = model.thumbnails[asset.id] {
                                Image(uiImage: image).resizable().scaledToFit()
                            } else {
                                Image(systemName: "photo").foregroundStyle(.secondary.opacity(0.6))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(selected ? Color.yellow : Color.black.opacity(0.55))
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.black)
                        } else {
                            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(asset.snapshot.kind)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
                .overlay(alignment: .bottomTrailing) {
                    if saved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.yellow)
                            .background(Color.black.opacity(0.6), in: Circle())
                            .padding(5)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? Color.yellow : Color.clear, lineWidth: 2)
                }
                Text(asset.snapshot.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel(asset.snapshot.name + " · " + asset.snapshot.kind)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("camera.photo")
            .onAppear { model.thumbnail(asset) }
            .onLongPressGesture {
                guard !model.busy else { return }
                model.showPreview(asset); previewAsset = asset
            }
    }
    private var selectionBar: some View {
        VStack(spacing: 2) {
            if hiddenSelection {
                Button(L10n.text("包含筛选范围外的已选照片")) { onlySelected = true; format = "all"; day = nil }
                    .font(.caption).frame(minHeight: 44)
            }
            if !model.selectionAllowed {
                Text(L10n.text("每次最多选择 64 个原件，总大小不超过 2 GiB。")).font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button { model.selection = [] } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(L10n.text("清空选择")).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.selectedAssets.count)").font(.headline).monospacedDigit()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.selectionBytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                if let asset = model.selectedAssets.first, model.selectedAssets.count == 1 {
                    Button { model.showPreview(asset); previewAsset = asset } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .frame(width: 44, height: 44).accessibilityLabel(L10n.text("放大预览"))
                        .accessibilityIdentifier("camera.preview.open")
                }
                Spacer(minLength: 0)
                Button(L10n.text("从相机导入")) { model.importSelected() }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).frame(minHeight: 44)
                    .disabled(!model.selectionAllowed || !model.connected || model.busy)
                    .accessibilityIdentifier("camera.import.start")
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(Color(white: 0.16))
    }
    private var transferProgress: some View {
        VStack(spacing: 6) {
            if let progress = model.progress {
                ProgressView(value: Double(progress.bytes), total: Double(progress.total))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(progress.bytes), countStyle: .file))
                    Text("/"); Text(ByteCountFormatter.string(fromByteCount: Int64(progress.total), countStyle: .file))
                    Spacer(); Button(L10n.text("停止导入")) { model.stop() }
                }.font(.caption)
            } else { HStack { ProgressView(); Text(L10n.text("正在接收原件")).font(.callout); Spacer() } }
            Text(L10n.text("导入时请保持 RawLab 在前台。")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color(white: 0.16)).accessibilityIdentifier("camera.import.progress")
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
    static func dayKey(_ asset: CameraAssetSnapshot) -> String? {
        if asset.format == 0, let milliseconds = Double(asset.created), (946684800000...4102444800000).contains(milliseconds) {
            return dateFormatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        }
        let digits = String(asset.created.prefix(8))
        guard digits.count == 8, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return String(digits.prefix(4)) + "-" + String(digits.dropFirst(4).prefix(2)) + "-" + String(digits.suffix(2))
    }
}

private struct IOSCameraFilters: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var format: String
    @Binding var day: String?
    @Binding var onlySelected: Bool
    let days: [String]
    @State private var draftFormat = "all"
    @State private var draftDay: String?
    @State private var draftSelected = false
    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("照片格式")) {
                    Picker(L10n.text("照片格式"), selection: $draftFormat) {
                        Text(L10n.text("全部")).tag("all"); Text("RAW").tag("raw"); Text("JPEG").tag("jpeg")
                    }.pickerStyle(.segmented)
                    Toggle(L10n.text("查看已选"), isOn: $draftSelected)
                }
                Section(L10n.text("拍摄日期")) {
                    Button { draftDay = nil } label: { HStack { Text(L10n.text("全部日期")); Spacer(); if draftDay == nil { Image(systemName: "checkmark") } } }
                    ForEach(days, id: \.self) { value in
                        Button { draftDay = value } label: { HStack { Text(value); Spacer(); if draftDay == value { Image(systemName: "checkmark") } } }
                    }
                }
            }.navigationTitle(L10n.text("筛选照片")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("应用")) { format = draftFormat; day = draftDay; onlySelected = draftSelected; dismiss() }
                            .accessibilityIdentifier("camera.filter.apply")
                    }
                }
        }.onAppear { draftFormat = format; draftDay = day; draftSelected = onlySelected }
    }
}

struct IOSCameraPreview<Actions: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: IOSCameraController
    let name: String
    var detail: String? = nil
    @ViewBuilder let actions: () -> Actions
    @State private var viewing = PhotoViewingState()
    @State private var viewport = PhotoViewport()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = model.preview {
                    ZoomablePhoto(image: image, referenceImage: nil, label: name, viewing: $viewing, viewport: $viewport,
                        nativePixelSize: image.cgImage.map { CGSize(width: $0.width, height: $0.height) })
                        .accessibilityIdentifier("camera.preview.image")
                } else if model.previewLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView(L10n.text("预览不可用"), systemImage: "photo") }
                VStack(spacing: 2) {
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(L10n.text("预览图，可双指缩放")).font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 6).padding(.horizontal, 12)
                HStack { actions() }.frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal)
            }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        }
    }
}

struct IOSCameraHistory: View {
    @ObservedObject var model: IOSCameraController
    let openOriginal: (CameraStoredOriginal) -> Void
    let resume: (CameraTransferJob) -> Void
    @State private var previewOriginal: CameraStoredOriginal?
    var body: some View {
        List {
            if !model.unfinishedJobs.isEmpty {
                Section(L10n.text("上次导入未完成")) {
                    ForEach(model.unfinishedJobs) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.camera.model).font(.headline)
                            Text("\(job.savedCount) / \(job.items.count)").font(.caption).monospacedDigit()
                            Button(L10n.text("继续未完成")) { resume(job) }.disabled(model.busy)
                        }
                    }
                }
            }
            Section(L10n.text("已导入")) {
                if model.originals.isEmpty { Text(L10n.text("还没有导入记录")).foregroundStyle(.secondary) }
                ForEach(model.originals) { original in
                    HStack(spacing: 12) {
                        Button { model.showPreview(original); previewOriginal = original } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07))
                                if let image = model.thumbnails[original.id.uuidString] { Image(uiImage: image).resizable().scaledToFit() }
                                else { Image(systemName: "photo").foregroundStyle(.secondary) }
                            }.frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text("放大预览"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(original.name).font(.callout).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(original.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            if original.jpegSource != nil {
                                Text(L10n.text("JPEG 已调整")).font(.caption).foregroundStyle(.secondary)
                            }
                            if original.photoLibraryAssetID != nil {
                                Text(L10n.text("已保存到相册")).font(.caption).foregroundStyle(.secondary)
                            }
                            if original.availability != .available {
                                Text(L10n.text("原片不可用")).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                        Button { openOriginal(original) } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.text("打开编辑")).accessibilityIdentifier("camera.original.edit")
                            .disabled(original.availability != .available)
                    }.onAppear { model.thumbnail(original) }
                }
            }
            if let notice = model.notice { Section { Text(notice).foregroundStyle(.orange).font(.callout) } }
        }.navigationTitle(L10n.text("导入记录")).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $previewOriginal) { original in
                IOSCameraPreview(model: model, name: original.name,
                                 detail: ByteCountFormatter.string(fromByteCount: Int64(original.size), countStyle: .file)) {
                    Button(L10n.text("打开编辑")) { previewOriginal = nil; openOriginal(original) }
                        .disabled(original.availability != .available)
                }
            }
    }
}
