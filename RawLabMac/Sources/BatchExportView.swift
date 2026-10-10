import SwiftUI
import AppKit

struct BatchExportView: View {
    @ObservedObject var model: BatchExportModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.title2).fontWeight(.semibold)
                    Text(model.summary).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !model.job.started {
                    Button(action: model.addFiles) { Label("添加 RAW", systemImage: "plus") }
                    Button("全选") { model.selectAll(true) }.disabled(model.job.items.isEmpty)
                    Button("全不选") { model.selectAll(false) }.disabled(model.job.selectedCount == 0)
                }
            }.padding(20)
            if model.validating {
                HStack { ProgressView().controlSize(.small); Text("正在检查 RAW 照片…") }
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
                        .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
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
        .sheet(isPresented: $showPreview) { previewSheet }
        .onDisappear { model.cancel() }
    }

    private var targetList: some View {
        Group {
            if model.job.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("尚未选择 RAW")
                    Button("选择照片…", action: model.addFiles)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.job.items) { item in
                    HStack(spacing: 12) {
                        if !model.job.started {
                            Toggle("选择 \(item.input.lastPathComponent)", isOn: Binding(
                                get: { item.selected }, set: { model.select(item.id, $0) }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(model.validating || item.validationError != nil)
                        }
                        Button { model.inspect(item); showPreview = true } label: {
                            BatchThumbnail(url: item.input).frame(width: 76, height: 64)
                        }.buttonStyle(.plain).disabled(model.running)
                            .help("查看应用后的效果").accessibilityLabel("检查 \(item.input.lastPathComponent) 的效果")
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
                        if !model.job.started {
                            Button { model.remove(item.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).help("从列表移除").accessibilityLabel("移除 \(item.input.lastPathComponent)")
                        } else if item.status == .succeeded, let output = item.output {
                            Button { model.reveal(output) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).help("显示成片").accessibilityLabel("显示 \(output.lastPathComponent)")
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.plain)
            }
        }
    }

    private var sourceAndOutput: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("调整来源").font(.headline)
            HStack(spacing: 12) {
                BatchThumbnail(url: model.job.source).frame(width: 96, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.job.source.lastPathComponent).lineLimit(2).truncationMode(.middle)
                    Text("\(model.job.lookName) · \(Int(model.job.settings.strength * 100))%")
                        .foregroundStyle(.secondary)
                }
            }
            valueRow("曝光", String(format: "%+.2f EV", model.job.settings.exposure))
            valueRow("白平衡", model.job.settings.whiteBalanceMode.rawValue)
            valueRow("曝光基准", model.job.settings.exposureMode.rawValue)
            DisclosureGroup("全部调整") {
                VStack(spacing: 10) {
                    ForEach(AdjustmentParameter.allCases) { parameter in
                        let spec = parameter.spec(for: model.job.settings)
                        valueRow(spec.title, parameter.isWhiteBalance && model.job.settings.whiteBalanceMode == .asShot
                                 ? "按每张照片" : spec.text(model.job.settings[keyPath: spec.keyPath]) + spec.unit)
                    }
                    if let denoise = model.job.settings.waveletNoiseReduction {
                        valueRow("小波降噪", denoise.enabled ? "开启" : "关闭")
                        valueRow("亮度降噪", String(format: "%.0f", denoise.luma))
                        valueRow("色彩降噪", String(format: "%.0f", denoise.chroma))
                        valueRow("粗颗粒降噪", String(format: "%.0f", denoise.coarse))
                    }
                }.padding(.top, 12)
            }
            Divider().padding(.vertical, 4)
            Text("输出").font(.headline)
            Picker("格式", selection: Binding(get: { model.job.png }, set: model.setPNG)) {
                Text("JPEG").tag(false)
                Text("16-bit PNG").tag(true)
            }.pickerStyle(.segmented).labelsHidden().disabled(model.job.started)
            valueRow("尺寸", "原始分辨率")
            HStack {
                Text("保存到")
                Spacer(minLength: 10)
                Text(model.job.outputDirectory?.lastPathComponent ?? "未选择")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.job.outputDirectory?.path ?? "选择输出文件夹")
                Button(action: model.chooseDirectory) { Image(systemName: "folder") }
                    .help("选择输出文件夹").accessibilityLabel("选择输出文件夹").disabled(model.running)
            }
            valueRow("重名文件", "自动添加序号")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.job.started ? "\(model.job.png ? "16-bit PNG" : "JPEG") · 原始分辨率" :
                 "仅用于本次导出，保留各照片原有调整")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if model.running {
                Button(model.stopping ? "正在停止…" : "取消导出", action: model.cancel).disabled(model.stopping)
            } else {
                Button(model.job.started ? "关闭" : "取消") {
                    if model.job.started || model.discardDraft() { dismissWindow(id: "batch-export") }
                }.disabled(model.validating)
                if model.job.succeededCount > 0 {
                    Button { model.reveal() } label: { Label("打开文件夹", systemImage: "folder") }
                }
                if !model.job.started {
                    Button("导出 \(model.job.selectedCount) 张") { model.start() }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                } else if model.job.remainingCount > 0 {
                    Button("继续未完成的 \(model.job.selectedCount - model.job.succeededCount) 张") { model.start() }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                } else if model.job.failedCount > 0 {
                    Button("重试失败的 \(model.job.failedCount) 张") { model.start(.failed) }
                        .buttonStyle(.borderedProminent).tint(.yellow).disabled(!model.canRun)
                }
            }
        }.controlSize(.large).padding(16)
    }

    private var previewSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text(model.previewFile?.lastPathComponent ?? "效果预览").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭") { showPreview = false }
            }
            if model.previewing { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let frame = model.preview {
                Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(model.error ?? "无法生成预览").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("\(model.job.lookName) · 本次导出效果").font(.caption).foregroundStyle(.secondary)
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

private struct BatchThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: url) { image = await PhotoThumbnails.shared.image(for: url) }
    }
}
