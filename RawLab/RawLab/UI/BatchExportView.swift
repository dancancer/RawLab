import ImageIO
import PhotosUI
import SwiftUI

struct BatchExportView: View {
    @ObservedObject var model: BatchExportModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedTarget: BatchTarget?
    @State private var confirmTarget: BatchTarget?
    @State private var showDiscard = false
    @State private var exportSizeValid = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sourceSection
                    settingsSection
                    targetsSection
                    outputSection
                    if let message = model.validationMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.footnote)
                            Button("打开系统设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.font(.footnote)
                        }.padding(20).accessibilityIdentifier("batch.validation")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle(model.stateTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") { close() }.disabled(model.isRunning || model.isPreparing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("放弃任务", role: .destructive) { showDiscard = true }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("任务操作").disabled(model.isRunning || model.isPreparing)
                }
            }
            .sheet(item: $selectedTarget) { target in
                TargetEffectInspectionView(model: model, target: target)
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task { await model.addPickerItems(items) }
            }
            .confirmationDialog("放弃此任务？已保存的照片会保留。", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("放弃任务", role: .destructive) { if model.discard() { dismiss() } }
            }
            .confirmationDialog(confirmTarget?.displayName ?? "核对保存结果",
                isPresented: Binding(get: { confirmTarget != nil }, set: { if !$0 { confirmTarget = nil } }),
                titleVisibility: .visible) {
                if let target = confirmTarget {
                    Button("已在照片图库中确认保存") { model.confirmPublication(id: target.id, saved: true) }
                    Button("尚未保存，允许重新导出") { model.confirmPublication(id: target.id, saved: false) }
                }
            } message: { Text("中断发生在写入照片图库时，请核对后选择，避免重复生成。") }
        }
        .preferredColorScheme(.dark).tint(.yellow)
        .interactiveDismissDisabled(model.isRunning || model.isPreparing)
        .onDisappear { if model.isRunning { model.cancel() } }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("调整来源").font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                BatchPhotoThumbnail(url: model.job.source.sourceURL).frame(width: 92, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.job.source.displayName).font(.body.weight(.medium)).lineLimit(2)
                    Text("\(model.job.source.lookName ?? "中性") · \(Int(model.job.source.settings.lutStrength * 100))%")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }.padding(20)
    }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            settingRow("曝光补偿", value: String(format: "%+.2f EV", model.job.source.settings.exposure))
            settingRow("白平衡", value: model.job.source.settings.whiteBalanceMode == .camera ? "拍摄时设置" : "自定义")
            DisclosureGroup("全部调整") {
                VStack(spacing: 0) {
                    ForEach(AdjustmentKind.allCases) { adjustment in
                        settingRow(adjustment.title, value: adjustment == .temperature || adjustment == .tint
                            ? model.job.source.settings.whiteBalanceMode == .camera ? "按每张照片" : adjustment.valueLabel(for: adjustment.value(from: model.job.source.settings))
                            : adjustment.valueLabel(for: adjustment.value(from: model.job.source.settings)))
                    }
                    let denoise = model.job.source.settings.denoise
                    settingRow("小波降噪", value: denoise.enabled ? "开启" : "关闭")
                    settingRow("亮度降噪", value: String(format: "%.0f", denoise.luma))
                    settingRow("色彩降噪", value: String(format: "%.0f", denoise.chroma))
                    settingRow("粗颗粒降噪", value: String(format: "%.0f", denoise.coarse))
                }
            }.padding(.vertical, 16).accessibilityIdentifier("batch.settings")
        }.padding(.horizontal, 20)
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                Text("目标照片").font(.title3.weight(.semibold))
                Spacer()
                if model.job.status == .draft {
                    PhotosPicker(selection: $pickerItems, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                        Label(model.job.targets.isEmpty ? "选择" : "添加", systemImage: "plus")
                    }.disabled(!model.canChangeTargets).accessibilityIdentifier("batch.pick")
                }
            }.padding(.horizontal, 20).padding(.top, 12)
            if model.job.targets.isEmpty {
                Text("尚未选择 RAW").foregroundStyle(.secondary).padding(.horizontal, 20)
            } else if model.job.status == .draft {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.job.targets) { target in
                            VStack(spacing: 4) {
                                Button { selectedTarget = target } label: {
                                    BatchPhotoThumbnail(url: target.sourceURL).frame(width: 88, height: 88)
                                }.buttonStyle(.plain).disabled(model.isPreparing)
                                    .accessibilityLabel("检查 \(target.displayName) 的效果")
                                Text(target.displayName).font(.caption).lineLimit(2).frame(width: 88, height: 34)
                                Button { model.removeTarget(id: target.id) } label: {
                                    Image(systemName: "minus.circle").frame(width: 44, height: 44)
                                }.accessibilityLabel("移除 \(target.displayName)").disabled(!model.canChangeTargets)
                            }
                        }
                    }.padding(.horizontal, 20)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.job.targets) { target in
                        HStack(alignment: .top, spacing: 12) {
                            Button { selectedTarget = target } label: {
                                BatchPhotoThumbnail(url: target.sourceURL).frame(width: 64, height: 64)
                            }.buttonStyle(.plain).disabled(model.isRunning)
                                .accessibilityLabel("检查 \(target.displayName) 的效果")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(target.displayName).lineLimit(2)
                                Text(target.status.title).font(.footnote)
                                    .foregroundStyle(target.status == .failed || target.status == .needsConfirmation ? Color.orange : .secondary)
                                if let error = target.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                                if target.status == .needsConfirmation {
                                    Button("核对保存结果") { confirmTarget = target }.font(.footnote)
                                }
                            }
                            Spacer(minLength: 0)
                            if target.status == .succeeded { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                            .overlay(alignment: .bottom) { Divider() }
                    }
                }.padding(.horizontal, 20)
            }
            Text("已选 \(model.job.targets.count) 张 RAW").foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("输出").font(.title3.weight(.semibold)).padding(.top, 18).padding(.bottom, 10)
            settingRow("格式", value: "JPEG")
            ExportSizePicker(longEdge: Binding(get: { model.job.longEdge }, set: model.setLongEdge),
                             onValidityChanged: { exportSizeValid = $0 })
                .disabled(!model.canChangeTargets)
            settingRow("保存到", value: "照片图库")
        }.padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if model.isPreparing {
                ProgressView("正在准备 RAW…").frame(maxWidth: .infinity)
            } else if model.isRunning {
                ProgressView(value: Double(model.completedCount + model.failedCount), total: Double(max(1, model.selectedCount)))
                Text("已处理 \(model.completedCount + model.failedCount) / \(model.selectedCount)")
                    .font(.footnote).monospacedDigit()
                if let current = model.job.targets.first(where: { [.processing, .publishing].contains($0.status) }) {
                    Text(current.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Button(model.isStopping ? "正在停止…" : "取消导出") { model.cancel() }
                    .buttonStyle(.bordered).disabled(model.isStopping)
            } else if model.job.status == .completed {
                Text("已保存 \(model.completedCount) 张到照片图库").font(.footnote).foregroundStyle(.secondary)
                primary("完成") { if model.discard() { dismiss() } }
            } else {
                if model.job.status == .draft {
                    Text("仅用于本次导出，保留各照片原有调整").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("成功 \(model.completedCount) 张 · 失败 \(model.failedCount) 张 · 未处理 \(model.pendingCount) 张")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.uncertainCount > 0 {
                    Button("授权核对相册中的保存结果") { Task { await model.reconcilePhotos() } }
                        .font(.footnote)
                }
                if model.pendingCount > 0 {
                    primary(model.job.status == .draft ? "导出 \(model.selectedCount) 张" : "继续未完成项") { model.start() }
                        .disabled(!model.canStart || !exportSizeValid).accessibilityIdentifier("batch.export")
                } else if model.failedCount > 0 {
                    primary("重试失败的 \(model.failedCount) 张") { model.retryFailed() }.disabled(!model.canStart)
                } else if model.job.status == .draft {
                    primary("导出 0 张") { }.disabled(true).accessibilityIdentifier("batch.export")
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
    }

    private func close() {
        if model.job.status == .completed { _ = model.discard() }
        dismiss()
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 34) }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
    }
    private func settingRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title); Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.padding(.vertical, 11).overlay(alignment: .bottom) { Divider() }
    }
}

private struct TargetEffectInspectionView: View {
    @ObservedObject var model: BatchExportModel
    let target: BatchTarget
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.12).ignoresSafeArea()
                if let image { ZoomablePhoto(image: image, referenceImage: image, label: "本次批量导出效果") }
                else if let error { Text(error).foregroundStyle(.secondary).padding(24) }
                else { ProgressView("正在生成效果预览…") }
            }
            .navigationTitle(target.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .task(id: target.id) {
            do { image = try await model.preview(target: target) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct BatchPhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: url) {
                image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 240
                          ] as CFDictionary) else { return nil as UIImage? }
                    return UIImage(cgImage: thumbnail)
                }.value
            }
    }
}
