import RawLabKit
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
            let source = model.file.flatMap { try? MacBatchExportItem.resourceKey($0) }
            let count = model.batchSelection.targets(excluding: source).count
            Text(L10n.format("目标：%@ 张照片", String(count))).fontWeight(.medium)
            Text(L10n.text("来源已排除。未选中的调整保持每张照片的原值。")).foregroundStyle(.secondary)
            if count == 0 { Text(L10n.text("没有可同步的目标。请返回集合，选择来源以外的照片。")).foregroundStyle(.secondary) }
            AdjustmentScopeEditor(scope: $scope, fields: $fields,
                                  preview: Result { try model.previewAdjustmentPayload(scope: scope == "all" ? .all : scope == "modified" ? .modified : .custom(fields)) },
                                  lookName: model.adjustmentSummaryLookName, errorMessage: { model.adjustmentErrorMessage($0) },
                                  allowed:model.adjustmentTransferFields)
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
        }.padding(24).frame(width: 580).tint(.yellow).preferredColorScheme(.dark)
    }
}

private struct BatchCollectionExportView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var format = ExportFormat.jpeg
    @State private var adaptiveJPEG = false
    @State private var longEdge: Int?
    @State private var outputSharpening: OutputSharpening = .off
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    Picker(L10n.text("格式"), selection: Binding<ExportFormat?>(
                        get: { adaptiveJPEG ? nil : format },
                        set: { value in adaptiveJPEG = value == nil; format = value ?? .jpeg })) {
                        Text(L10n.text("HDR 照片用 HDR JPEG，其余用 JPEG")).tag(nil as ExportFormat?)
                        ForEach(ExportFormat.allCases.filter { $0 != .hdrHEIF || HDRImage.heifExportAvailable }) { Text($0.title).tag(Optional($0)) }
                    }.frame(width: 340).accessibilityIdentifier("collection.export.format")
                    Spacer(minLength: 12)
                    Button(directory?.lastPathComponent ?? L10n.text("选择输出文件夹")) { chooseDirectory() }
                }
                HStack(alignment: .top, spacing: 24) {
                    ExportSizePicker(longEdge: $longEdge).frame(width: 260, alignment: .leading)
                    OutputSharpeningPicker(outputSharpening: Binding(
                        get: { (!adaptiveJPEG && format == .renderedDNG) ? .off : outputSharpening },
                        set: { outputSharpening = $0 }
                    ))
                    .frame(width: 240, alignment: .leading)
                    .disabled(!adaptiveJPEG && format == .renderedDNG)
                    Spacer(minLength: 0)
                }
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
        }.padding(24).frame(width: 870).tint(.yellow).preferredColorScheme(.dark)
        .onAppear { invalidate() }
        .onDisappear { model.cancelCollectionExportPreparation() }
        .onChange(of: format) { _, _ in invalidate() }
        .onChange(of: adaptiveJPEG) { _, _ in invalidate() }
        .onChange(of: longEdge) { _, _ in invalidate() }
        .onChange(of: outputSharpening) { _, _ in invalidate() }
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
                if let notice = snapshot.noticeKey {
                    Text(L10n.text(notice)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(L10n.format("%@ · 曝光 %@ · 查看最终调整", L10n.text(snapshot.lookName), AdjustmentParameter.exposure.spec.display(AdjustmentParameter.exposure.value(from:snapshot.settings)))) {
                    MacBatchSettingsSummaryView(settings: snapshot.settings).padding(.top, 8)
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
        model.startCollectionExport(skipping: skipped, format: format, longEdge: longEdge, directory: directory,
                                    adaptiveJPEG: adaptiveJPEG,
                                    outputSharpening: (!adaptiveJPEG && format == .renderedDNG) ? .off : outputSharpening,
                                    completed: { _ in
            dismiss(); openWindow(id: "batch-export")
        })
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK { directory = panel.url; invalidate() }
    }
}

struct MacBatchSettingsSummaryView: View {
    let settings: Adjustments
    var perPhotoAdaptive = false
    var omitTopSummaryFields = false

    static func showsSDRBaselineHeaders(for settings: Adjustments, omitTopSummaryFields: Bool = false) -> Bool {
        !settings.isHDREditing && !omitTopSummaryFields
    }

    static func summaryParameters(for settings: Adjustments, omitTopSummaryFields: Bool = false) -> [AdjustmentParameter] {
        let curve = settings.editingCurveSettings
        return AdjustmentParameter.allCases.filter { parameter in
            if settings.isHDREditing { return parameter.hdrKeyPath != nil }
            if omitTopSummaryFields && parameter == .exposure { return false }
            return curve.mode == .legacy || parameter != .toneCurve
        }
    }

    var body: some View {
        let curve = settings.editingCurveSettings
        let hsl = settings.editingHSLSettings
        let grading = settings.editingGradingSettings
        VStack(alignment: .leading, spacing: 7) {
            if settings.isHDREditing, let hdr = settings.hdr {
                Text("HDR · " + L10n.text("相对白平衡"))
                if let sha = hdr.lookSettings.sha256, !sha.isEmpty {
                    summary(hdr.lookSettings.name ?? "HDR LUT", String(format: "%.0f%%", hdr.lookSettings.strength * 100), rawTitle: true)
                }
                if hdr.cameraDevelopmentSettings.lensDistortion || hdr.cameraDevelopmentSettings.lensTCA ||
                    hdr.cameraDevelopmentSettings.lensVignetting || hdr.cameraDevelopmentSettings.fbddLevel != 0 ||
                    hdr.cameraDevelopmentSettings.cameraProfile != nil {
                    summary("HDR RAW", L10n.text("开启"), rawTitle: true)
                }
                if settings.hdrCameraAIEnabled {
                    summary("AI 降噪", enabled(true))
                }
            } else if Self.showsSDRBaselineHeaders(for: settings, omitTopSummaryFields: omitTopSummaryFields) {
                Text(L10n.text("曝光基准") + " · " + settings.exposureMode.title)
                Text(L10n.text("白平衡") + " · " + settings.whiteBalanceMode.title)
            }
            ForEach(Self.summaryParameters(for: settings, omitTopSummaryFields: omitTopSummaryFields)) { parameter in
                let spec = parameter.spec(for: settings)
                let adaptive = perPhotoAdaptive && !settings.isHDREditing && parameter.isWhiteBalance && settings.whiteBalanceMode == .asShot
                HStack {
                    Text(spec.title)
                    Spacer()
                    Text(adaptive ? L10n.text("按每张照片") : spec.display(parameter.value(from: settings))).monospacedDigit()
                }
            }
            if settings.isHDREditing, let hdr = settings.hdr {
                DisclosureGroup(L10n.text("HDR 输出与 SDR 底图")) {
                    let rendition = hdr.renditionSettings
                    summary("HDR 亮度上限", String(format: "%+.2f EV", rendition.peakLimitEV))
                    summary("SDR 底图曝光", String(format: "%+.2f EV", rendition.sdrExposureEV))
                    summary("SDR 底图对比度", number(rendition.sdrContrast) + "%")
                    summary("SDR 底图饱和度", number(rendition.sdrSaturation) + "%")
                }
            }
            if !curve.isDefault {
                DisclosureGroup(L10n.format("多点曲线（%d 个控制点）", curve.labeledPoints.count)) {
                    if curve.applyToLuminosity {
                        summary("仅作用于明度", enabled(true))
                    }
                    ForEach(Array(curve.labeledPoints.enumerated()), id: \.offset) { index, point in
                        summary(point.channel.shortLabel + " · " + L10n.format("控制点 %d", index + 1),
                                String(format: "%.2f → %.2f", locale: L10n.locale, point.point.x, point.point.y),
                                rawTitle: true)
                    }
                    if !curve.parametric.isDefault {
                        summary("高光", number(curve.parametric.highlights) + "%")
                        summary("亮部", number(curve.parametric.lights) + "%")
                        summary("暗部", number(curve.parametric.darks) + "%")
                        summary("阴影", number(curve.parametric.shadows) + "%")
                        summary("阴影拆分", String(format: "%.0f%%", curve.parametric.splitShadow * 100))
                        summary("中间调拆分", String(format: "%.0f%%", curve.parametric.splitMidtone * 100))
                        summary("高光拆分", String(format: "%.0f%%", curve.parametric.splitHighlight * 100))
                    }
                }
            }
            DisclosureGroup(L10n.text("HSL")) {
                ForEach(0..<8, id: \.self) { channel in
                    HStack {
                        Text(L10n.text(HSLSettings.channelNames[channel]))
                        Spacer()
                        Text(HSLAxis.allCases.map { $0.title + " " + number(hsl.value($0, channel: channel)) }.joined(separator: " · "))
                    }
                }
            }
            DisclosureGroup(L10n.text("颜色分级")) {
                ForEach(ColorGradingZone.allCases) { zone in
                    HStack {
                        Text(zone.title)
                        Spacer()
                        Text(L10n.text("色相") + " " + number(grading[zone].hue) + "° · " +
                            L10n.text("饱和度") + " " + number(grading[zone].saturation) + " · " +
                            L10n.text("明亮度") + " " + number(grading[zone].luminance))
                    }
                }
                HStack {
                    Text(L10n.text("全局"))
                    Spacer()
                    Text(L10n.text("色相") + " " + number(grading.global.hue) + "° · " +
                        L10n.text("饱和度") + " " + number(grading.global.saturation) + " · " +
                        L10n.text("明亮度") + " " + number(grading.global.luminance))
                }
                summary("融合", number(grading.blending) + "%")
                summary("平衡", number(grading.balance))
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
                    let lens = settings.lensSettings
                    summary("镜头匹配", lens.mode == .automatic && perPhotoAdaptive
                        ? "\(L10n.text("自动")) · \(L10n.text("按每张照片"))"
                        : L10n.text(lens.mode == .automatic ? "自动" : "手动"))
                    summary("畸变矫正", enabled(lens.distortion))
                    summary("横向色差", enabled(lens.tca))
                    summary("暗角校正", enabled(lens.vignetting))
                    summary("自动裁边", enabled(lens.autoCrop))
                }
            }
            if !settings.isHDREditing {
                DisclosureGroup(L10n.text("降噪")) {
                    summary("AI 降噪", enabled(settings.aiDenoiseEnabled))
                    if settings.aiDenoiseEnabled {
                        summary("AI 降噪强度", number(settings.aiDenoiseStrength) + "%")
                    }
                    summary("RAW 降噪", number(settings.rawNoiseReduction))
                    summary("色度降噪", number(Double(settings.chromaNoiseReduction)))
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
    private func summary(_ title: String, _ value: String, rawTitle: Bool = false) -> some View {
        HStack { Text(rawTitle ? title : L10n.text(title)); Spacer(); Text(value).monospacedDigit() }
    }
}
