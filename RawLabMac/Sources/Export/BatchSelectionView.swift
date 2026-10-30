import SwiftUI
import AppKit

struct BatchSelectionView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.openWindow) private var openWindow
    @State private var showScope = false
    @State private var showExport = false
    @State private var scope = "custom"
    @State private var fields: Set<AdjustmentTransferField>
    @State private var message: String?

    init(model: EditorModel) {
        self.model=model
        _fields=State(initialValue:model.settings.isHDREditing ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("批量编辑")).font(.title2.weight(.semibold))
                    Text(L10n.format("已选 %@ 张", String(model.batchSelection.selected.count))).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("添加照片…"), action: model.chooseCollectionPhotos)
                    .accessibilityIdentifier("collection.add")
                Button(L10n.text("全选")) { model.batchSelection.selectAll(true) }
                Button(L10n.text("全不选")) { model.batchSelection.selectAll(false) }
            }.padding(20)
            Divider()
            if model.batchSelection.ordered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.text("选择一组照片，再同步调整或逐张微调。"))
                    Button(L10n.text("选择照片…"), action: model.chooseCollectionPhotos)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(model.batchSelection.ordered, id: \.self) { id in
                        if let photo = model.batchSelectionPhotos[id] { photoRow(photo).id(id) }
                    }.listStyle(.plain)
                    .onAppear { if let id = model.batchSelection.returnPosition { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.batchSelection.current) { _, current in
                        if current == nil, let id = model.batchSelection.returnPosition { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            if let message = message ?? model.collectionError ?? model.saveError {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { collectionActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 10) { collectionActions }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(16)
        }.frame(minWidth: 840, minHeight: 580).preferredColorScheme(.dark)
        .sheet(isPresented: $showScope) { synchronizationScope }
        .sheet(isPresented: $showExport) { BatchCollectionExportView(model: model) }
        .sheet(item: Binding(get: { model.adjustmentSheetInCollection ? model.adjustmentSheet : nil },
            set: { model.adjustmentSheet = $0 })) { kind in
            AdjustmentTransferView(model: model, kind: kind)
        }
        .onChange(of:model.settings.isHDREditing, initial:true) { _, isHDR in
            fields=isHDR ? AdjustmentTransferField.hdrCommon : AdjustmentTransferField.common
        }
    }

    @ViewBuilder private var collectionActions: some View {
        if let id = model.batchSelection.lastSynchronization {
            Button(L10n.text("同步历史…")) {
                model.adjustmentOutcomes = []
                model.pendingAdjustmentHistory = .init(transactionID: id, photo: nil, undo: true)
                model.adjustmentSheetInCollection = true; model.adjustmentSheet = .history
            }.accessibilityIdentifier("collection.history")
        }
        Button(L10n.text("应用调整并保存到所选照片…")) {
            model.prepareCollectionSource { message = nil; showScope = true }
        }
            .disabled(model.file == nil || model.batchSelection.selected.isEmpty || model.exporting || model.adjustmentSheet != nil)
            .accessibilityIdentifier("collection.synchronize")
        Button(L10n.text("按各自调整导出…")) { showExport = true }
            .buttonStyle(.borderedProminent).tint(.yellow)
            .disabled(model.batchSelection.selected.isEmpty || model.exporting)
            .accessibilityIdentifier("collection.export")
    }

    private func photoRow(_ photo: MacCollectionPhoto) -> some View {
        HStack(spacing: 14) {
            Toggle(L10n.format("选择 %@", photo.url.lastPathComponent), isOn: Binding(
                get: { model.batchSelection.selected.contains(photo.id) }, set: { model.batchSelection.select(photo.id, $0) }))
                .labelsHidden().toggleStyle(.checkbox)
            BatchThumbnail(url: photo.url).frame(width: 82, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(photo.url.lastPathComponent).fontWeight(.medium)
                    PhotoLocationButton(url: photo.url)
                }
                if model.file == photo.url { Text(L10n.text("当前照片")).font(.caption).foregroundStyle(.secondary) }
                if let error = model.collectionFailure(photo.id) {
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
                } else if model.collectionHasDraft(photo.id) {
                    Text(L10n.text("尚有未保存的调整")).font(.callout).foregroundStyle(.yellow)
                }
            }
            Spacer()
            Button(L10n.text("单张微调")) { model.editCollectionPhoto(photo.id) { openWindow(id: "editor") } }
                .disabled(model.exporting || model.collectionFailure(photo.id) != nil)
                .accessibilityIdentifier("collection.edit.\(photo.id)")
            Button { model.batchSelection.remove(photo.id); model.batchSelectionPhotos.removeValue(forKey: photo.id) } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.plain).accessibilityLabel(L10n.format("移除 %@", photo.url.lastPathComponent))
        }.padding(.vertical, 8)
    }

    private var synchronizationScope: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("同步调整范围")).font(.title2.weight(.semibold))
            HStack {
                Text(L10n.format("来源：%@", model.file?.lastPathComponent ?? ""))
                if let url = model.file { PhotoLocationButton(url: url) }
            }
            let source = model.file.flatMap { try? BatchExportItem.resourceKey($0) }
            let count = model.batchSelection.targets(excluding: source).count
            Text(L10n.format("目标：%@ 张照片", String(count))).fontWeight(.medium)
            Text(L10n.text("来源已排除。未选中的调整保持每张照片的原值。")).foregroundStyle(.secondary)
            if count == 0 { Text(L10n.text("没有可同步的目标。请返回集合，选择来源以外的照片。")).foregroundStyle(.secondary) }
            AdjustmentScopeEditor(scope: $scope, fields: $fields,
                                  preview: Result { try model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)) },
                                  lookName: model.adjustmentSummaryLookName, errorMessage: { model.adjustmentErrorMessage($0) },
                                  allowed:model.settings.isHDREditing ? AdjustmentTransferField.hdrSupported : AdjustmentTransferField.legacyFields)
            if let file = model.file, let source, model.batchSelectionPhotos[source]?.url == file, model.collectionHasDraft(source) {
                Text(L10n.text("来源有未完成的调整，请先应用或放弃。"))
                HStack {
                    Button(L10n.text("应用并保存")) { _ = model.resolveCollectionDraft(source, apply: true) }
                    Button(L10n.text("放弃草稿")) { _ = model.resolveCollectionDraft(source, apply: false) }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.text("取消")) { showScope = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("查看目标")) {
                    do {
                        let selected: AdjustmentTransferScope = scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)
                        let sync = try model.captureCollectionSynchronization(scope: selected)
                        showScope = false
                        DispatchQueue.main.async {
                            model.adjustmentSheetPayload = sync.payload; model.adjustmentSheetTargets = sync.targets
                            model.adjustmentSheetExcludedSource = nil; model.adjustmentSheetExcludedIdentity = sync.sourceIdentity
                            model.pendingAdjustmentHistory = nil; model.adjustmentSheetInCollection = true
                            model.adjustmentSheet = .synchronize
                        }
                    } catch { message = model.adjustmentErrorMessage(error) }
                }.buttonStyle(.borderedProminent).disabled(count == 0 || (try? model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields))) == nil)
            }
        }.padding(24).frame(width: 580).tint(.yellow)
    }
}

private struct BatchCollectionExportView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var format = ExportFormat.jpeg
    @State private var longEdge: Int?
    @State private var directory: URL?
    @State private var skipped = Set<String>()
    @State private var message: String?
    private var review: MacCollectionExportReview? { model.collectionExportReview }
    private var targetCount: Int { model.batchSelection.targets().filter { !skipped.contains($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("按各自调整导出")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text(model.collectionExportPreparing ? "取消检查" : "取消")) {
                    if model.collectionExportPreparing { invalidate() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("collection.export.cancel")
            }
            Text(L10n.text("将按每张照片已保存的调整导出。跳过只影响本次导出。")).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Picker(L10n.text("格式"), selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }.frame(width: 220)
                ExportSizePicker(longEdge: $longEdge).frame(width: 240)
                Button(directory?.lastPathComponent ?? L10n.text("选择输出文件夹")) { chooseDirectory() }
            }
            if model.collectionExportBlockedByTask {
                HStack {
                    Text(L10n.text("已有批量任务，请先完成或结束该任务。")).foregroundStyle(.secondary)
                    Button(L10n.text("查看批量任务…")) { dismiss(); openWindow(id: "batch-export") }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.batchSelection.targets(), id: \.self) { id in
                        if let photo = model.batchSelectionPhotos[id] {
                            exportRow(photo)
                            Divider()
                        }
                    }
                }
            }.frame(minHeight: 230, maxHeight: 440)
            if model.collectionExportPreparing {
                ProgressView(L10n.text("正在准备导出…")).accessibilityIdentifier("collection.export.checking")
            }
            if let message = model.collectionExportError ?? message { Text(message).foregroundStyle(.secondary) }
            if targetCount == 0 {
                Text(L10n.text("没有可导出的照片。请取消部分跳过，或返回集合重新选择。")).foregroundStyle(.secondary)
            }
            HStack {
                if let review {
                    Text(L10n.format("最终导出：%@ 张", String(review.snapshots.count))).fontWeight(.medium)
                }
                Spacer()
                Button(L10n.format("开始导出 %@ 张", String(targetCount)), action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(directory == nil || targetCount == 0 || model.collectionExportPreparing || model.collectionExportBlockedByTask)
                    .accessibilityIdentifier("collection.export.start")
            }
        }.padding(24).frame(width: 780).tint(.yellow)
        .onAppear { invalidate() }
        .onDisappear { model.cancelCollectionExportPreparation() }
        .onChange(of: format) { _, _ in invalidate() }
        .onChange(of: longEdge) { _, _ in invalidate() }
        .onChange(of: model.batchSelection.selected) { _, _ in invalidate() }
        .onChange(of: model.sourceRevision) { _, _ in invalidate() }
        .onChange(of: model.adjustmentHistoryRevision) { _, _ in model.cancelCollectionExportPreparation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didHideNotification))) { _ in
            if model.collectionExportPreparing { invalidate() }
        }
    }

    private func exportRow(_ photo: MacCollectionPhoto) -> some View {
        let row = review?.rows.first { $0.id == photo.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(photo.url.lastPathComponent).fontWeight(.medium)
                PhotoLocationButton(url: photo.url)
                Spacer()
                Toggle(L10n.text("跳过本次导出"), isOn: Binding(get: { skipped.contains(photo.id) }, set: {
                    if $0 { skipped.insert(photo.id) } else { skipped.remove(photo.id) }; invalidate()
                })).toggleStyle(.checkbox).fixedSize()
            }
            if model.collectionHasDraft(photo.id), !skipped.contains(photo.id) {
                HStack {
                    Text(L10n.text("尚有未保存的调整"))
                    Button(L10n.text("应用并保存")) { resolve(photo.id, apply: true) }
                    Button(L10n.text("放弃草稿")) { resolve(photo.id, apply: false) }
                }
            }
            if let snapshot = row?.snapshot {
                DisclosureGroup(L10n.format("%@ · 曝光 %@ · 查看最终调整", L10n.text(snapshot.lookName), AdjustmentParameter.exposure.spec.display(AdjustmentParameter.exposure.value(from:snapshot.settings)))) {
                    BatchSettingsSummary(settings: snapshot.settings).padding(.top, 8)
                }
            }
            if let error = row?.error ?? model.collectionFailure(photo.id), !skipped.contains(photo.id) {
                Text(model.adjustmentErrorMessage(error)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func resolve(_ id: String, apply: Bool) {
        invalidate()
        if !model.resolveCollectionDraft(id, apply: apply) { message = model.saveError ?? L10n.text("请返回编辑器完成有效输入后重试。") }
        else { message = L10n.text("草稿已处理，请开始导出。") }
    }
    private func invalidate() {
        model.cancelCollectionExportPreparation(); message = nil
    }
    private func start() {
        guard let directory else { return }
        message = nil
        model.startCollectionExport(skipping: skipped, format: format, longEdge: longEdge, directory: directory) { _ in
            dismiss(); openWindow(id: "batch-export")
        }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK { directory = panel.url; invalidate() }
    }
}

struct BatchSettingsSummary: View {
    let settings: Adjustments
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if settings.isHDREditing {
                Text("HDR · "+L10n.text("相对白平衡"))
            } else {
            Text(L10n.text("曝光基准") + " · " + settings.exposureMode.title)
            Text(L10n.text("白平衡") + " · " + settings.whiteBalanceMode.title)
            }
            ForEach(AdjustmentParameter.allCases.filter { settings.isHDREditing ? $0.hdrKeyPath != nil : (settings.curveSettings.isDefault || $0 != .toneCurve) }) { parameter in
                let spec = parameter.spec(for: settings)
                HStack { Text(spec.title); Spacer(); Text(spec.display(parameter.value(from:settings))).monospacedDigit() }
            }
            if !settings.isHDREditing {
            if !settings.curveSettings.isDefault {
                DisclosureGroup(L10n.format("多点曲线（%d 个控制点）", settings.curveSettings.points.count)) {
                    ForEach(Array(settings.curveSettings.points.enumerated()), id: \.offset) { index, point in
                        summary(L10n.format("控制点 %d", index + 1), String(format: "%.2f → %.2f", locale: L10n.locale, point.x, point.y))
                    }
                }
            }
            DisclosureGroup(L10n.text("HSL")) {
                ForEach(0..<8, id: \.self) { channel in
                    HStack {
                        Text(L10n.text(HSLSettings.channelNames[channel]))
                        Spacer()
                        Text(HSLAxis.allCases.map { $0.title + " " + number(settings.hslSettings.value($0, channel: channel)) }.joined(separator: " · "))
                    }
                }
            }
            DisclosureGroup(L10n.text("颜色分级")) {
                ForEach(ColorGradingZone.allCases) { zone in
                    HStack {
                        Text(zone.title); Spacer()
                        Text(L10n.text("色相") + " " + number(settings.gradingSettings[zone].hue) + "° · " +
                            L10n.text("饱和度") + " " + number(settings.gradingSettings[zone].saturation))
                    }
                }
            }
            }
            DisclosureGroup(L10n.text("几何与镜头")) {
                let geometry = settings.geometrySettings
                summary("水平位置", number(geometry.cropX * 100) + "%")
                summary("垂直位置", number(geometry.cropY * 100) + "%")
                summary("宽度", number(geometry.cropWidth * 100) + "%")
                summary("高度", number(geometry.cropHeight * 100) + "%")
                summary("旋转", String(geometry.quarterTurns * 90) + "°")
                summary("水平翻转", enabled(geometry.flipHorizontal))
                summary("垂直翻转", enabled(geometry.flipVertical))
                summary("拉直", number(geometry.straightenDegrees) + "°")
                summary("水平透视", number(geometry.perspectiveHorizontal))
                summary("垂直透视", number(geometry.perspectiveVertical))
                if !settings.isHDREditing {
                summary("镜头匹配", L10n.text(settings.lensSettings.mode == .automatic ? "自动" : "手动"))
                summary("畸变矫正", enabled(settings.lensSettings.distortion))
                summary("横向色差", enabled(settings.lensSettings.tca))
                summary("自动裁边", enabled(settings.lensSettings.autoCrop))
                }
            }
            if !settings.isHDREditing {
            DisclosureGroup(L10n.text("降噪")) {
                summary("RAW 降噪", number(settings.rawNoiseReduction))
                summary("色度降噪", number(settings.chromaNoiseReduction ?? 0))
                summary("降噪", enabled(settings.waveletSettings.enabled))
                summary("亮度降噪", number(settings.waveletSettings.luma))
                summary("色彩降噪", number(settings.waveletSettings.chroma))
                summary("粗色斑抑制", number(settings.waveletSettings.coarse))
            }
            }
        }.font(.callout).foregroundStyle(.secondary)
    }
    private func number(_ value: Double) -> String { String(format: "%.2f", value) }
    private func enabled(_ value: Bool) -> String { L10n.text(value ? "开启" : "停用") }
    private func summary(_ title: String, _ value: String) -> some View {
        HStack { Text(L10n.text(title)); Spacer(); Text(value).monospacedDigit() }
    }
}
