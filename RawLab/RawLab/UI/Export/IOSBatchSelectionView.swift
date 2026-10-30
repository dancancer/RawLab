import PhotosUI
import SwiftUI

struct IOSBatchSelectionView: View {
    @ObservedObject var model: RawEditorViewModel
    @ObservedObject var collection: IOSBatchSelection
    let settings: RawSettings
    let hasPendingBatch: Bool
    let resolveDraft: (String, Bool) -> Bool
    let editPhoto: (String) -> Void
    let showExistingBatch: () -> Void
    let created: (BatchExportJob, BatchJournalStore, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var loading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var message: String?
    @State private var sheet: CollectionSheet?
    private enum CollectionSheet: String, Identifiable { case synchronize, history, export; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                List {
                    Section {
                        Text(L10n.text("选择照片后同步所需调整，也可进入单张微调，再返回原集合。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            PhotosPicker(selection: $pickerItems, matching: .images, preferredItemEncoding: .current) {
                                Label(L10n.text("添加照片"), systemImage: "plus")
                            }.accessibilityIdentifier("collection.photos")
                            Spacer()
                            Button(L10n.text("从文件导入")) { showFiles = true }.accessibilityIdentifier("collection.files")
                        }
                        HStack {
                            Button(L10n.text("全选")) { collection.selection.selectAll(true) }
                            Spacer()
                            Button(L10n.text("清空选择")) { collection.selection.selectAll(false) }
                        }
                        Text(L10n.format("已选 %@ 张", String(collection.selection.selected.count)))
                    }
                    Section {
                        ForEach(collection.selection.ordered, id: \.self) { id in
                            if let stored = collection.photos[id] { photoRow(stored).id(id) }
                        }
                        if collection.selection.ordered.isEmpty { Text(L10n.text("尚未选择照片")) }
                    }
                    Section {
                        Button(L10n.text("同步调整")) { sheet = .synchronize }
                            .disabled(!model.hasImage || collection.selection.targets(excluding: model.sourceIdentity?.key).isEmpty)
                            .accessibilityIdentifier("collection.synchronize")
                        if collection.selection.targets(excluding: model.sourceIdentity?.key).isEmpty {
                            Text(L10n.text("来源照片不参与同步，请选择至少一张其他照片。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if collection.selection.lastSynchronization != nil {
                            Button(L10n.text("上次同步结果与历史")) { sheet = .history }.accessibilityIdentifier("collection.history")
                        }
                        Button(L10n.text("按每张调整导出…")) { sheet = .export }
                            .disabled(collection.selection.selected.isEmpty || hasPendingBatch).accessibilityIdentifier("collection.export")
                        if hasPendingBatch {
                            Text(L10n.text("请先完成或结束已有批量任务，再创建新任务。"))
                            Button(L10n.text("查看批量任务…"), action: showExistingBatch)
                        }
                    }
                    if loading { ProgressView(L10n.text("正在准备照片…")) }
                    if let message { Section { Text(message).foregroundStyle(.secondary) } }
                }
                .disabled(loading)
                .onAppear {
                    collection.refreshValidation()
                    if let id = collection.selection.returnPosition { scroll.scrollTo(id, anchor: .center) }
                }
            }
            .navigationTitle(L10n.text("批量编辑")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("关闭")) { dismiss() }.disabled(loading)
            } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: PhotoImportFile.supportedContentTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): loadTask = Task { await addFiles(urls) }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                loadTask = Task { await addPhotos(items) }
            }
            .onChange(of: sheet) { _, value in if value == nil { collection.refreshValidation() } }
            .sheet(item: $sheet) { kind in
                switch kind {
                case .synchronize:
                    IOSCollectionSyncView(model: model, collection: collection, settings: settings, resolveDraft: resolveDraft)
                case .history:
                    IOSAdjustmentTransferView(model: model, kind: .history, settings: settings,
                        focusedHistory: collection.selection.lastSynchronization)
                case .export:
                    IOSCollectionExportView(model: model, collection: collection, resolveDraft: resolveDraft, created: created)
                }
            }
        }.interactiveDismissDisabled(loading)
            .onDisappear { loadTask?.cancel() }
    }

    private func photoRow(_ stored: IOSCollectionPhoto) -> some View {
        HStack(spacing: 12) {
            Toggle(L10n.text("选择"), isOn: Binding(get: { collection.selection.selected.contains(stored.id) }, set: {
                collection.selection.select(stored.id, $0)
            })).labelsHidden().toggleStyle(.button).accessibilityIdentifier("collection.select.\(stored.id)")
            if let file = stored.photo.file { BatchPhotoThumbnail(sourceFile: file).frame(width: 54, height: 54) }
            VStack(alignment: .leading) {
                Text(stored.photo.displayName).lineLimit(2)
                if let error = collection.failures[stored.id] ?? stored.error?.localizedDescription { Text(error).font(.caption).foregroundStyle(.orange) }
                Button(L10n.text("单张微调")) { editPhoto(stored.id) }.disabled(stored.error != nil || collection.failures[stored.id] != nil)
                    .accessibilityIdentifier("collection.edit.\(stored.id)")
            }
            Spacer(minLength: 0)
            Button { collection.remove(stored.id) } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel(L10n.format("移除 %@", stored.photo.displayName))
        }.buttonStyle(.borderless)
    }

    @MainActor private func addPhotos(_ items: [PhotosPickerItem]) async {
        loading = true
        defer { loading = false; pickerItems = [] }
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                let source = try await PhotoImportFile.load(from: item)
                defer { PhotoImportFile.release(source.url) }
                let identity = item.itemIdentifier.flatMap { $0.isEmpty ? nil : PhotoIdentity(resourceIdentifier: $0) }
                let photo = try await model.retainAdjustmentPhoto(source, identity: identity)
                guard !Task.isCancelled else { return }
                collection.append(photo)
            } catch { appendFailure(L10n.text("选择照片…"), error) }
        }
    }
    @MainActor private func addFiles(_ urls: [URL]) async {
        loading = true
        defer { loading = false }
        for url in urls {
            guard !Task.isCancelled else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try PhotoImportFile.retainSource(url)
                defer { PhotoImportFile.release(source.url) }
                let photo = try await model.retainAdjustmentPhoto(source)
                guard !Task.isCancelled else { return }
                collection.append(photo)
            } catch { appendFailure(url.lastPathComponent, error) }
        }
    }
    private func appendFailure(_ name: String, _ error: Error) {
        guard !Task.isCancelled else { return }
        collection.append(.init(identity: .init(resourceIdentifier: "unreadable:\(UUID())"), displayName: name,
            file: nil, isRaw: false, error: error))
    }
}

private struct IOSCollectionSyncView: View {
    @ObservedObject var model: RawEditorViewModel
    @ObservedObject var collection: IOSBatchSelection
    let settings: RawSettings
    let resolveDraft: (String, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "custom"
    @State private var fields: Set<AdjustmentTransferField>
    @State private var synchronization: IOSCollectionSynchronization?
    @State private var message: String?
    private var sourceSettings: RawSettings {
        model.loadedEditRecord?.state?.settings ?? model.sourceDefaultSettings
    }
    init(model: RawEditorViewModel, collection: IOSBatchSelection, settings: RawSettings,
         resolveDraft: @escaping (String, Bool) -> Bool) {
        self.model=model; self.collection=collection; self.settings=settings; self.resolveDraft=resolveDraft
        let source=model.loadedEditRecord?.state?.settings ?? model.sourceDefaultSettings
        _fields=State(initialValue:source.isHDREditing ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common)
    }
    var body: some View {
        Group {
            if let synchronization {
                IOSAdjustmentTransferView(model: model, kind: .paste, settings: settings, synchronization: synchronization)
            } else {
                NavigationStack {
                    Form {
                        IOSAdjustmentScopeEditor(scope: $scope, fields: $fields,
                            preview: Result { try model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields), settings: sourceSettings) },
                            lookName: model.adjustmentSummaryLookName, errorMessage: { model.adjustmentErrorMessage($0) }, titleKey: "同步范围", sourceName: model.sourceDisplayName,
                                                 allowed: sourceSettings.isHDREditing ? AdjustmentTransferField.hdrSupported : AdjustmentTransferField.legacyFields)
                        Section {
                            Text(L10n.format("目标：%@ 张照片", String(collection.selection.targets(excluding: model.sourceIdentity?.key).count)))
                            Text(L10n.text("来源照片不参与同步。"))
                            if let key = model.sourceIdentity?.key, !model.adjustmentTargetIsCurrent(key) {
                                Text(L10n.text("来源有未提交调整，请先应用或放弃。"))
                                Button(L10n.text("应用草稿并继续")) { resolveSource(key, true) }
                                Button(L10n.text("放弃草稿并继续")) { resolveSource(key, false) }
                            }
                            Button(L10n.text("检查目标")) {
                                do {
                                    synchronization = try model.captureCollectionSynchronization(
                                        scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields), settings: sourceSettings)
                                } catch { message = model.adjustmentErrorMessage(error) }
                            }.disabled((try? model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields), settings: sourceSettings)) == nil || collection.selection.targets(excluding: model.sourceIdentity?.key).isEmpty
                                || model.sourceIdentity.map { !model.adjustmentTargetIsCurrent($0.key) } != false)
                                .accessibilityIdentifier("collection.sync.prepare")
                        }
                        if let message { Section { Text(message) } }
                    }
                    .navigationTitle(L10n.text("同步调整")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } } }
                }
            }
        }.onChange(of:sourceSettings.isHDREditing) { _, isHDR in
            fields=isHDR ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common
        }
    }
    private func resolveSource(_ key: String, _ apply: Bool) {
        message = resolveDraft(key, apply) ? nil : model.collectionDraftFailure
    }
}

private struct IOSCollectionExportView: View {
    @ObservedObject var model: RawEditorViewModel
    @ObservedObject var collection: IOSBatchSelection
    let resolveDraft: (String, Bool) -> Bool
    let created: (BatchExportJob, BatchJournalStore, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var format = BatchOutputFormat.jpeg
    @State private var longEdge: Int?
    @State private var sizeValid = true
    @State private var skipped = Set<String>()
    private var review: IOSCollectionExportReview? { model.collectionExportReview }
    private var busy: Bool { model.collectionExportPreparing || model.collectionExportFreezing }
    private var targetCount: Int { collection.selection.targets().filter { !skipped.contains($0) }.count }
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.text("将按每张照片已保存的调整导出。跳过只影响本次导出。"))
                    Picker(L10n.text("格式"), selection: $format) {
                        ForEach([BatchOutputFormat.jpeg, .renderedDNG], id: \.self) { Text($0.title).tag($0) }
                    }
                    ExportSizePicker(longEdge: $longEdge, onValidityChanged: { sizeValid = $0 })
                }
                Section {
                    ForEach(collection.selection.targets(), id: \.self) { id in
                        if let photo = collection.photos[id] { target(photo) }
                    }
                }
                Section {
                    Button(L10n.format("开始导出 %@ 张", String(targetCount)), action: start)
                        .disabled(!sizeValid || targetCount == 0 || busy)
                        .accessibilityIdentifier("collection.export.start")
                    if targetCount == 0 {
                        Text(L10n.text("没有可处理目标，请重新选择照片。"))
                    }
                    if busy { ProgressView(L10n.text("正在准备导出…")).accessibilityIdentifier("collection.export.checking") }
                    if let message = model.collectionExportError ?? message { Text(message).foregroundStyle(.orange) }
                }
            }.disabled(busy)
                .navigationTitle(L10n.text("按每张调整导出…")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text(busy ? "取消检查" : "取消")) {
                        let close = !busy || model.collectionExportFreezing
                        invalidate()
                        if close { dismiss() }
                    }.accessibilityIdentifier("collection.export.cancel")
                } }
                .onAppear { invalidate() }
                .onDisappear { model.cancelCollectionExportPreparation() }
                .onChange(of: format) { _, _ in invalidate() }
                .onChange(of: longEdge) { _, _ in invalidate() }
                .onChange(of: skipped) { _, _ in invalidate() }
                .onChange(of: collection.selection.selected) { _, _ in invalidate() }
                .onChange(of: model.sourceRevision) { _, _ in invalidate() }
                .onChange(of: model.adjustmentHistoryRevision) { _, _ in model.cancelCollectionExportPreparation() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { invalidate() } }
        }.interactiveDismissDisabled(busy)
    }
    private func target(_ photo: IOSCollectionPhoto) -> some View {
        let row = review?.rows.first { $0.id == photo.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text(photo.photo.displayName).fontWeight(.medium)
            Toggle(L10n.text("跳过"), isOn: Binding(get: { skipped.contains(photo.id) }, set: {
                if $0 { skipped.insert(photo.id) } else { skipped.remove(photo.id) }
            })).accessibilityIdentifier("collection.export.skip.\(photo.id)")
            if !model.adjustmentTargetIsCurrent(photo.id) {
                Text(L10n.text("有未提交调整。"))
                HStack {
                    Button(L10n.text("应用草稿")) { resolve(photo.id, true) }
                    Button(L10n.text("放弃草稿")) { resolve(photo.id, false) }
                }.disabled(skipped.contains(photo.id))
            }
            if let error = row?.error ?? photo.error { Text(model.adjustmentErrorMessage(error)).font(.footnote).foregroundStyle(.orange) }
            if let row, let settings = row.settings {
                Text(L10n.text(row.lookName ?? "中性")).font(.callout)
                DisclosureGroup(L10n.text("全部调整")) { IOSBatchSettingsRows(settings: settings) }
            }
        }.buttonStyle(.borderless)
    }
    private func resolve(_ id: String, _ apply: Bool) {
        invalidate()
        if !resolveDraft(id, apply) { message = model.collectionDraftFailure }
        else { message = nil }
    }
    private func invalidate() {
        model.cancelCollectionExportPreparation(); message = nil
    }
    private func start() {
        message = nil
        model.startCollectionExport(skipping: skipped, format: format, longEdge: longEdge, completed: created)
    }
}

struct IOSBatchSettingsRows: View {
    let settings: RawSettings
    var body: some View {
        ForEach(BatchSettingsSummary.headline(settings) + BatchSettingsSummary.details(settings), id: \.title) { row in
            HStack(alignment: .firstTextBaseline) { Text(row.title); Spacer(); Text(row.value).foregroundStyle(.secondary) }.font(.callout)
        }
    }
}
