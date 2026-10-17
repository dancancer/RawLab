import ImageIO
import PhotosUI
import SwiftUI

struct BatchExportView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: BatchExportModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var selectedTarget: BatchTarget?
    @State private var confirmTarget: BatchTarget?
    @State private var showDiscard = false
    @State private var exportSizeValid = true

    var body: some View {
        let _ = localizationLocale
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
                            Button(L10n.text("打开系统设置")) {
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
                    Button(L10n.text("返回")) { close() }.disabled(model.isRunning || model.isPreparing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(L10n.text("放弃任务"), role: .destructive) { showDiscard = true }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel(L10n.text("任务操作")).disabled(model.isRunning || model.isPreparing)
                }
            }
            .sheet(item: $selectedTarget) { target in
                TargetEffectInspectionView(model: model, target: target)
            }
            .sheet(isPresented: Binding(get: { model.shouldPresentFileExport },
                                        set: { model.shouldPresentFileExport = $0 }) ) {
                if let urls = model.fileExportURLs {
                    FileExportPicker(urls: urls) { model.finishFileExport($0) }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task { await model.addPickerItems(items) }
            }
            .fileImporter(isPresented: $showingFileImporter,
                          allowedContentTypes: PhotoImportFile.supportedContentTypes,
                          allowsMultipleSelection: true) { result in
                guard let urls = try? result.get() else { return }
                Task { await model.addFiles(urls) }
            }
            .confirmationDialog(L10n.text("放弃此任务？已保存的照片会保留。"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L10n.text("放弃任务"), role: .destructive) { if model.discard() { dismiss() } }
            }
            .confirmationDialog(confirmTarget?.displayName ?? L10n.text("核对保存结果"),
                isPresented: Binding(get: { model.job.outputFormat == .jpeg && confirmTarget != nil },
                                     set: { if !$0 { confirmTarget = nil } }),
                titleVisibility: .visible) {
                if let target = confirmTarget {
                    Button(L10n.text("已在照片图库中确认保存")) { model.confirmPublication(id: target.id, saved: true) }
                    Button(L10n.text("尚未保存，允许重新导出")) { model.confirmPublication(id: target.id, saved: false) }
                }
            } message: { Text(L10n.text("中断发生在写入照片图库时，请核对后选择，避免重复生成。")) }
        }
        .preferredColorScheme(.dark).tint(.yellow)
        .interactiveDismissDisabled(model.isRunning || model.isPreparing)
        .onDisappear { if model.isRunning { model.cancel() } }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("调整来源")).font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                BatchPhotoThumbnail(url: model.job.source.sourceURL).frame(width: 92, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.job.source.displayName).font(.body.weight(.medium)).lineLimit(2)
                    Text(L10n.format("%@ · %@%%", model.job.source.settings.hasLook ? L10n.text(model.job.source.lookName ?? "中性") : L10n.text("中性"), String(Int(model.job.source.settings.lutStrength * 100))))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }.padding(20)
    }

    private var settingsSection: some View {
        VStack(spacing: 0) {
            settingRow(L10n.text("曝光补偿"), value: String(format: "%+.2f EV", model.job.source.settings.exposure))
            settingRow(L10n.text("曝光基准"), value: model.job.source.settings.exposureMode.title)
            settingRow("HSL", value: model.job.source.settings.hsl.isIdentity ? L10n.text("未调整") : L10n.text("已调整"))
            settingRow(L10n.text("白平衡"), value: model.job.source.settings.whiteBalanceMode == .camera ? L10n.text("拍摄时设置") : L10n.text("自定义"))
            DisclosureGroup(L10n.text("全部调整")) {
                VStack(spacing: 0) {
                    ForEach(AdjustmentKind.allCases) { adjustment in
                        settingRow(adjustment.title, value: adjustment == .temperature || adjustment == .tint
                            ? model.job.source.settings.whiteBalanceMode == .camera ? L10n.text("按每张照片") : adjustment.valueLabel(for: adjustment.value(from: model.job.source.settings))
                            : adjustment.valueLabel(for: adjustment.value(from: model.job.source.settings)))
                    }
                    let denoise = model.job.source.settings.denoise
                    settingRow(L10n.text("小波降噪"), value: denoise.enabled ? L10n.text("开启") : L10n.text("关闭"))
                    settingRow(L10n.text("亮度降噪"), value: String(format: "%.0f", denoise.luma))
                    settingRow(L10n.text("色彩降噪"), value: String(format: "%.0f", denoise.chroma))
                    settingRow(L10n.text("粗颗粒降噪"), value: String(format: "%.0f", denoise.coarse))
                    let effects = model.job.source.settings.photoEffects
                    settingRow(L10n.text("暗角强度"), value: String(format: "%+.0f", effects.vignetteAmount))
                    settingRow(L10n.text("暗角中点"), value: String(format: "%.0f", effects.vignetteMidpoint))
                    settingRow(L10n.text("暗角圆度"), value: String(format: "%+.0f", effects.vignetteRoundness))
                    settingRow(L10n.text("暗角羽化"), value: String(format: "%.0f", effects.vignetteFeather))
                    settingRow(L10n.text("暗角高光保护"), value: String(format: "%.0f", effects.vignetteHighlights))
                    settingRow(L10n.text("颗粒强度"), value: String(format: "%.0f", effects.grainAmount))
                    settingRow(L10n.text("颗粒大小"), value: String(format: "%.0f", effects.grainSize))
                    settingRow(L10n.text("颗粒粗糙度"), value: String(format: "%.0f", effects.grainRoughness))
                    let lens = model.job.source.settings.lensSettings
                    settingRow(L10n.text("镜头匹配"), value: lens.mode == .automatic ? "\(L10n.text("自动")) · \(L10n.text("按每张照片"))" : L10n.text("手动"))
                    settingRow(L10n.text("畸变矫正"), value: lens.distortion ? L10n.text("开启") : L10n.text("关闭"))
                    settingRow(L10n.text("横向色差"), value: lens.tca ? L10n.text("开启") : L10n.text("关闭"))
                    settingRow(L10n.text("自动裁边"), value: lens.autoCrop ? L10n.text("开启") : L10n.text("关闭"))
                }
            }.padding(.vertical, 16).accessibilityIdentifier("batch.settings")
        }.padding(.horizontal, 20)
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                Text(L10n.text("目标照片")).font(.title3.weight(.semibold))
                Spacer()
                if model.job.status == .draft {
                    PhotosPicker(selection: $pickerItems, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) {
                        Label(model.job.targets.isEmpty ? L10n.text("选择") : L10n.text("添加"), systemImage: "plus")
                    }.disabled(!model.canChangeTargets).accessibilityIdentifier("batch.pick")
                    Button { showingFileImporter = true } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel(L10n.text("从文件导入"))
                    .disabled(!model.canChangeTargets)
                    .accessibilityIdentifier("batch.filePick")
                }
            }.padding(.horizontal, 20).padding(.top, 12)
            if model.job.targets.isEmpty {
                Text(L10n.text("尚未选择照片")).foregroundStyle(.secondary).padding(.horizontal, 20)
            } else if model.job.status == .draft {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.job.targets) { target in
                            VStack(spacing: 4) {
                                Button { selectedTarget = target } label: {
                                    BatchPhotoThumbnail(url: target.sourceURL).frame(width: 88, height: 88)
                                }.buttonStyle(.plain).disabled(model.isPreparing)
                                    .accessibilityLabel(L10n.format("检查 %@ 的效果", String(describing: target.displayName)))
                                Text(target.displayName).font(.caption).lineLimit(2).frame(width: 88, height: 34)
                                Button { model.removeTarget(id: target.id) } label: {
                                    Image(systemName: "minus.circle").frame(width: 44, height: 44)
                                }.accessibilityLabel(L10n.format("移除 %@", String(describing: target.displayName))).disabled(!model.canChangeTargets)
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
                                .accessibilityLabel(L10n.format("检查 %@ 的效果", String(describing: target.displayName)))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(target.displayName).lineLimit(2)
                                Text(target.status.title).font(.footnote)
                                    .foregroundStyle(target.status == .failed || target.status == .needsConfirmation ? Color.orange : .secondary)
                                if let error = target.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                                if target.status == .needsConfirmation {
                                    if model.job.outputFormat == .renderedDNG {
                                        Button(L10n.text("核对 DNG 文件")) { Task { await model.reconcilePublication() } }
                                            .font(.footnote)
                                    } else {
                                        Button(L10n.text("核对保存结果")) { confirmTarget = target }.font(.footnote)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            if target.status == .succeeded { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                            .overlay(alignment: .bottom) { Divider() }
                    }
                }.padding(.horizontal, 20)
            }
            Text(L10n.format("已选 %@ 张照片", String(describing: model.job.targets.count))).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text(L10n.text("输出")).font(.title3.weight(.semibold)).padding(.top, 18).padding(.bottom, 10)
            Picker(L10n.text("格式"), selection: Binding(get: { model.job.outputFormat }, set: model.setFormat)) {
                Text(BatchOutputFormat.jpeg.title).tag(BatchOutputFormat.jpeg)
                Text(BatchOutputFormat.renderedDNG.title).tag(BatchOutputFormat.renderedDNG)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .id(localizationLocale.identifier)
            .accessibilityIdentifier("batch.format")
            .disabled(!model.canChangeTargets)
            ExportSizePicker(longEdge: Binding(get: { model.job.longEdge }, set: model.setLongEdge),
                             onValidityChanged: { exportSizeValid = $0 })
                .disabled(!model.canChangeTargets)
            settingRow(L10n.text("保存到"), value: model.job.outputFormat == .renderedDNG ? L10n.text("RawLab 文件") : L10n.text("照片图库"))
        }.padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if model.isPreparing {
                ProgressView(L10n.text("正在准备照片…")).frame(maxWidth: .infinity)
            } else if model.isRunning {
                ProgressView(value: Double(model.completedCount + model.failedCount), total: Double(max(1, model.selectedCount)))
                Text(L10n.format("已处理 %@ / %@", String(describing: model.completedCount + model.failedCount), String(describing: model.selectedCount)))
                    .font(.footnote).monospacedDigit()
                if let current = model.job.targets.first(where: { [.processing, .publishing].contains($0.status) }) {
                    Text(current.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Button(model.isStopping ? L10n.text("正在停止…") : L10n.text("取消导出")) { model.cancel() }
                    .buttonStyle(.bordered).disabled(model.isStopping)
            } else if model.job.status == .completed {
                if model.job.outputFormat == .renderedDNG {
                    switch model.fileExportStatus {
                    case .exported:
                        Text(L10n.format("已导出 %@ 个渲染型 DNG", String(model.completedCount))).font(.footnote).foregroundStyle(.secondary)
                    case .cancelled:
                        Text(L10n.format("已生成 %@ 个渲染型 DNG，未另存到所选位置", String(model.completedCount)))
                            .font(.footnote).foregroundStyle(.secondary)
                    default:
                        Text(L10n.format("已生成 %@ 个渲染型 DNG", String(model.completedCount))).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.fileExportURLs?.isEmpty == false {
                        Button(L10n.text("导出到文件…")) { model.presentFileExport() }.font(.footnote)
                    }
                } else {
                    Text(L10n.format("已保存 %@ 张到照片图库", String(model.completedCount))).font(.footnote).foregroundStyle(.secondary)
                }
                primary(L10n.text("完成")) { if model.discard() { dismiss() } }
            } else {
                if model.job.status == .draft {
                    Text(L10n.text("仅用于本次导出，保留各照片原有调整")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(L10n.format("成功 %@ 张 · 失败 %@ 张 · 未处理 %@ 张", String(describing: model.completedCount), String(describing: model.failedCount), String(describing: model.pendingCount)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.job.outputFormat == .renderedDNG && model.fileExportURLs?.isEmpty == false {
                    Button(L10n.text("导出已完成的 DNG 到文件…")) { model.presentFileExport() }
                        .font(.footnote)
                }
                if model.uncertainCount > 0 {
                    Button(model.job.outputFormat == .renderedDNG ? L10n.text("核对 DNG 文件保存结果") : L10n.text("授权核对相册中的保存结果")) {
                        Task { await model.reconcilePublication() }
                    }
                        .font(.footnote)
                }
                if model.pendingCount > 0 {
                    primary(model.job.status == .draft ? L10n.format("导出 %@ 张", String(describing: model.selectedCount)) : L10n.text("继续未完成项")) { model.start() }
                        .disabled(!model.canStart || !exportSizeValid).accessibilityIdentifier("batch.export")
                } else if model.failedCount > 0 {
                    primary(L10n.format("重试失败的 %@ 张", String(describing: model.failedCount))) { model.retryFailed() }.disabled(!model.canStart)
                } else if model.job.status == .draft {
                    primary(L10n.text("导出 0 张")) { }.disabled(true).accessibilityIdentifier("batch.export")
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
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: BatchExportModel
    let target: BatchTarget
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            ZStack {
                Color(white: 0.12).ignoresSafeArea()
                if let image { ZoomablePhoto(image: image, referenceImage: image, label: L10n.text("本次批量导出效果")) }
                else if let error { Text(error).foregroundStyle(.secondary).padding(24) }
                else { ProgressView(L10n.text("正在生成效果预览…")) }
            }
            .navigationTitle(target.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { dismiss() } } }
        }
        .task(id: target.id) {
            do { image = try await model.preview(target: target) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct BatchPhotoThumbnail: View {
    @Environment(\.locale) private var localizationLocale
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        let _ = localizationLocale
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
