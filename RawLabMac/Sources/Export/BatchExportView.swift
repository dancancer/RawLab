import SwiftUI
import AppKit

struct BatchExportView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: BatchExportModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showPreview = false
    @State private var confirmDiscard = false

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.title2).fontWeight(.semibold)
                    Text(model.summary).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !model.job.started && model.job.mode == .uniformFrozen {
                    Button(action: model.addFiles) { Label(L10n.text("添加照片"), systemImage: "plus") }
                    Button(L10n.text("全选")) { model.selectAll(true) }.disabled(model.job.items.isEmpty)
                    Button(L10n.text("全不选")) { model.selectAll(false) }.disabled(model.job.selectedCount == 0)
                }
            }.padding(20)
            if model.validating {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在检查照片…")) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
            }
            if model.job.started {
                ProgressView(value: Double(model.job.succeededCount + model.job.failedCount),
                             total: Double(max(1, model.job.selectedCount)))
                    .tint(.yellow).padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(L10n.text("关闭提示")).accessibilityLabel(L10n.text("关闭提示"))
                }.padding(12).background(Color(nsColor: .controlBackgroundColor))
            }
            Divider()
            HStack(spacing: 0) {
                targetList.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView { sourceAndOutput.padding(20) }.frame(width: 340)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .navigationTitle(L10n.text("批量导出"))
        .sheet(isPresented: $showPreview) { previewSheet }
        .onDisappear { model.cancel() }
        .alert(L10n.text("结束此批量任务？"), isPresented: $confirmDiscard) {
            Button(L10n.text("保留任务"), role: .cancel) {}
            Button(L10n.text("结束任务"), role: .destructive) {
                if model.discardTask() { dismissWindow(id: "batch-export") }
            }
        } message: { Text(L10n.text("已导出的文件会保留。剩余照片不再继续导出。")) }
    }

    private var targetList: some View {
        Group {
            if model.job.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(L10n.text("尚未选择照片"))
                    Button(L10n.text("选择照片…"), action: model.addFiles)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.job.items) { item in
                    HStack(spacing: 12) {
                        if !model.job.started && model.job.mode == .uniformFrozen {
                            Toggle(L10n.format("选择 %@", String(describing: item.input.lastPathComponent)), isOn: Binding(
                                get: { item.selected }, set: { model.select(item.id, $0) }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(model.validating || item.validationError != nil)
                        }
                        Button { model.inspect(item); showPreview = true } label: {
                            BatchThumbnail(url: item.input).frame(width: 76, height: 64)
                        }.buttonStyle(.plain).disabled(model.running)
                            .help(L10n.text("查看应用后的效果")).accessibilityLabel(L10n.format("检查 %@ 的效果", String(describing: item.input.lastPathComponent)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if model.job.started {
                                Label(item.status.title, systemImage: statusSymbol(item.status))
                                    .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                                if let error = item.error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            } else if let failure = item.validationError {
                                Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
                            } else {
                                Text(item.input.deletingLastPathComponent().path).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).help(item.input.path)
                        if !model.job.started && model.job.mode == .uniformFrozen {
                            Button { model.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).help(L10n.text("从列表移除")).accessibilityLabel(L10n.format("移除 %@", String(describing: item.input.lastPathComponent)))
                        } else if item.status == .succeeded, let output = item.output {
                            Button { model.reveal(output) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).help(L10n.text("显示成片")).accessibilityLabel(L10n.format("显示 %@", String(describing: output.lastPathComponent)))
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.plain)
            }
        }
    }

    private var sourceAndOutput: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.job.mode == .perTargetFrozen {
                Text(L10n.text("每张照片自己的最终调整")).font(.headline)
                Text(L10n.text("任务已冻结。之后的照片编辑不会改变本次导出。")).foregroundStyle(.secondary)
                ForEach(model.job.items) { item in
                    if let frozen = item.frozen {
                        DisclosureGroup(item.input.lastPathComponent + " · " + L10n.text(frozen.lookName)) {
                            BatchSettingsSummary(settings: frozen.settings)
                        }
                    }
                }
            } else {
            Text(L10n.text("调整来源")).font(.headline)
            HStack(spacing: 12) {
                BatchThumbnail(url: model.job.source).frame(width: 96, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.job.source.lastPathComponent).lineLimit(2).truncationMode(.middle)
                    Text(L10n.format("%@ · %@%%", L10n.text(model.job.lookName), String(describing: Int(model.job.settings.strength * 100))))
                        .foregroundStyle(.secondary)
                }
            }
            valueRow(L10n.text("曝光"), AdjustmentParameter.exposure.spec.display(model.job.settings.exposure))
            valueRow(L10n.text("白平衡"), model.job.settings.whiteBalanceMode.title)
            valueRow(L10n.text("曝光基准"), model.job.settings.exposureMode.title)
            DisclosureGroup(L10n.text("全部调整")) {
                VStack(spacing: 10) {
                    // 曝光已在上方摘要中，这里不再重复
                    ForEach(AdjustmentParameter.allCases.filter { $0 != .exposure && (model.job.settings.curveSettings.isDefault || $0 != .toneCurve) }) { parameter in
                        let spec = parameter.spec(for: model.job.settings)
                        valueRow(spec.title, parameter.isWhiteBalance && model.job.settings.whiteBalanceMode == .asShot
                                 ? L10n.text("按每张照片") : spec.display(model.job.settings[keyPath: spec.keyPath]))
                    }
                    if !model.job.settings.curveSettings.isDefault {
                        valueRow(L10n.text("曲线"), L10n.format("多点曲线（%d 个控制点）", model.job.settings.curveSettings.points.count))
                        ForEach(Array(model.job.settings.curveSettings.points.enumerated()), id: \.offset) { index, point in
                            valueRow(L10n.format("控制点 %d", index + 1), "\(point.x) → \(point.y)")
                        }
                    }
                    if let denoise = model.job.settings.waveletNoiseReduction {
                        valueRow(L10n.text("降噪"), denoise.enabled ? L10n.text("开启") : L10n.text("停用"))
                        valueRow(L10n.text("亮度降噪"), String(format: "%.0f", denoise.luma))
                        valueRow(L10n.text("色彩降噪"), String(format: "%.0f", denoise.chroma))
                        valueRow(L10n.text("粗色斑抑制"), String(format: "%.0f", denoise.coarse))
                    }
                    let lens = model.job.settings.lensSettings
                    valueRow(L10n.text("镜头匹配"), lens.mode == .automatic ? "\(L10n.text("自动")) · \(L10n.text("按每张照片"))" : L10n.text("手动"))
                    valueRow(L10n.text("畸变矫正"), lens.distortion ? L10n.text("开启") : L10n.text("停用"))
                    valueRow(L10n.text("横向色差"), lens.tca ? L10n.text("开启") : L10n.text("停用"))
                    valueRow(L10n.text("自动裁边"), lens.autoCrop ? L10n.text("开启") : L10n.text("停用"))
                }.padding(.top, 12)
            }
            }
            Divider().padding(.vertical, 4)
            Text(L10n.text("输出")).font(.headline)
            Picker(L10n.text("格式"), selection: Binding(get: { model.job.format }, set: model.setFormat)) {
                ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
            }.pickerStyle(.segmented).labelsHidden().id(localizationLocale.identifier)
                .disabled(model.job.started || model.job.mode == .perTargetFrozen).accessibilityIdentifier("batch.format")
            ExportSizePicker(longEdge: Binding(get: { model.job.longEdge }, set: model.setLongEdge))
                .disabled(model.job.started || model.job.mode == .perTargetFrozen)
            HStack {
                Text(L10n.text("保存到"))
                Spacer(minLength: 10)
                Text(model.job.outputDirectory?.lastPathComponent ?? L10n.text("未选择"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.job.outputDirectory?.path ?? L10n.text("选择输出文件夹"))
                Button(action: model.chooseDirectory) { Image(systemName: "folder") }
                    .help(L10n.text("选择输出文件夹")).accessibilityLabel(L10n.text("选择输出文件夹")).disabled(model.running || model.job.mode == .perTargetFrozen)
            }
            valueRow(L10n.text("重名文件"), L10n.text("自动添加序号"))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.job.started || model.job.mode == .perTargetFrozen ? "\(model.job.format.title) · \(model.job.longEdge.map { L10n.format("长边 %@ px", String(describing: $0)) } ?? L10n.text("原始尺寸"))" :
                 L10n.text("仅用于本次导出，保留各照片原有调整"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if model.running {
                Button(model.stopping ? L10n.text("正在停止…") : L10n.text("取消导出"), action: model.cancel).disabled(model.stopping)
            } else {
                Button(model.job.started ? L10n.text("关闭") : L10n.text("取消")) {
                    if model.job.started || model.discardDraft() { dismissWindow(id: "batch-export") }
                }.disabled(model.validating)
                if model.job.started && model.job.succeededCount != model.job.selectedCount {
                    Button(L10n.text("结束任务…")) { confirmDiscard = true }.disabled(model.previewing)
                }
                if model.job.succeededCount > 0 {
                    Button { model.reveal() } label: { Image(systemName: "folder") }
                        .help(L10n.text("打开文件夹")).accessibilityLabel(L10n.text("打开文件夹"))
                }
                if !model.job.started {
                    Button(L10n.format("导出 %@ 张", String(describing: model.job.selectedCount))) { model.start() }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                } else if model.job.remainingCount > 0 {
                    Button(L10n.format("继续未完成的 %@ 张", String(describing: model.job.selectedCount - model.job.succeededCount))) { model.start() }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                } else if model.job.failedCount > 0 {
                    Button(L10n.format("重试失败的 %@ 张", String(describing: model.job.failedCount))) { model.start(.failed) }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                }
            }
        }.controlSize(.large).padding(16)
    }

    private var previewSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text(model.previewFile?.lastPathComponent ?? L10n.text("效果预览")).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.text("关闭")) { showPreview = false }
            }
            if model.previewing { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let frame = model.preview {
                Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(model.error ?? L10n.text("无法生成预览")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(L10n.format("%@ · 本次导出效果", L10n.text(model.job.items.first { $0.input == model.previewFile }?.frozen?.lookName ?? model.job.lookName))).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 640, idealWidth: 800, minHeight: 440, idealHeight: 600)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private func statusSymbol(_ status: BatchItemStatus) -> String {
        switch status {
        case .waiting: return "clock"
        case .running, .publishing: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
}

// ----------------------------------------------------------------------------
//  还没有批量任务时（例如从"窗口"菜单打开）说明从哪里开始，而不是一片空白
// ----------------------------------------------------------------------------
struct BatchExportEmptyView: View {
    @Environment(\.locale) private var localizationLocale

    var body: some View {
        let _ = localizationLocale
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(L10n.text("没有批量任务")).font(.headline)
            Text(L10n.format("在编辑器中打开照片，然后选择“%@”。", L10n.text("使用当前调整批量导出…")))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(40).frame(minWidth: 900, minHeight: 620)
            .preferredColorScheme(.dark)
            .navigationTitle(L10n.text("批量导出"))
    }
}

struct BatchThumbnail: View {
    @Environment(\.locale) private var localizationLocale
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        let _ = localizationLocale
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: url) { image = await PhotoThumbnails.shared.image(for: url) }
    }
}
