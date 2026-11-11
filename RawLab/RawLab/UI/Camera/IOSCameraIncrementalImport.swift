import SwiftUI

struct IOSCameraIncrementalImport: View {
    @ObservedObject var model: IOSCameraController
    let history: () -> Void
    let reconnect: () -> Void
    let resume: (CameraTransferJob) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var customCutoff: Date?
    @State private var cutoffDraft: Date?
    @State private var showCutoff = false
    @State private var showJPEG = false
    @State private var includeUndated = false

    var body: some View {
        let job = model.displayedIncrementalJob
        let pending = job.flatMap { !$0.complete ? $0 : nil }
        let scan = model.phase == .browsing && !model.scanning && pending == nil
            ? model.incrementalScan(customCutoff: customCutoff, includeUndated: includeUndated) : nil
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.orange) }
                    if model.phase == .receiving || pending != nil {
                        taskStatus(job)
                    } else if model.scanning {
                        HStack { ProgressView(); Text(L10n.text("正在扫描相机…")) }
                            .accessibilityIdentifier("camera.incremental.scanning")
                    } else if let scan {
                        if let job, job.complete {
                            completion(job)
                        }
                        overview(scan)
                    } else {
                        Text(L10n.text("相机连接已断开。已保存的照片仍可查看。")).foregroundStyle(.secondary)
                    }
                }
                .padding(16).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("camera.incremental")
            VStack(spacing: 0) {
                if model.phase == .receiving {
                    action(L10n.text("停止导入"), id: "camera.incremental.stop", perform: { model.stop() })
                } else if let pending {
                    action(L10n.text(model.connected ? "继续未完成" : "重新连接并继续"),
                           id: "camera.incremental.resume", perform: { resume(pending) })
                } else if !model.connected {
                    action(L10n.text("重新连接"), id: "camera.incremental.reconnect", perform: reconnect)
                } else if let scan, !scan.assets.isEmpty {
                    action(L10n.format("导入 %@ 个文件", String(scan.assets.count)), id: "camera.incremental.start",
                           disabled: !scan.assets.allSatisfy { $0.snapshot.transferable }, perform: { model.startIncremental(scan) })
                }
            }.padding(.horizontal, 14).background(Color(white: 0.16))
        }
        .onChange(of: job?.complete == true ? job?.id : nil) { _, completed in
            if completed != nil {
                customCutoff = nil
                includeUndated = false
            }
        }
        .sheet(isPresented: $showJPEG) {
            IOSCameraJPEGSettings(draft: model.importPreferences.jpeg, apply: model.setJPEGOptions)
        }
        .sheet(isPresented: $showCutoff) { cutoffSheet }
    }

    private func overview(_ scan: CameraIncrementalScan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                cutoffDraft = scan.start; showCutoff = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("增量起点")).foregroundStyle(.primary)
                        Text(L10n.format("从 %@ 开始（相机时间）", formatted(scan.start)))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("camera.incremental.cutoff")
            if scan.needsCutoffConfirmation {
                Text(L10n.text("无法确认上次的存储卡或拍摄时间，请选择新的起点。")).font(.callout).foregroundStyle(.orange)
            } else {
                let count = scan.assets.count
                Text(count == 0 ? L10n.text("没有新的照片") : L10n.format("待导入 %@ 个文件", String(count)))
                    .font(.headline).accessibilityIdentifier("camera.incremental.count")
                if count > 0 {
                    let raw = scan.assets.filter { $0.snapshot.kind == "RAW" }.count
                    let formats = [raw > 0 ? "\(raw) RAW" : nil, count > raw ? "\(count - raw) JPEG" : nil]
                    Text(formats.compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    if !scan.assets.allSatisfy({ $0.snapshot.transferable }) {
                        Text(L10n.text("有文件超出相机导入上限，请调整起点或格式。")).font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            Divider()
            Group {
                if dynamicTypeSize.isAccessibilitySize { formatPicker.pickerStyle(.menu) }
                else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("传输格式")).font(.subheadline)
                        formatPicker.pickerStyle(.segmented).frame(minHeight: 44)
                    }
                }
            }.accessibilityIdentifier("camera.incremental.format")
            if model.importPreferences.format != .raw {
                Button {
                    showJPEG = true
                } label: {
                    HStack {
                        ViewThatFits(in: .horizontal) {
                            HStack { Text(L10n.text("JPEG 保存")); Spacer(minLength: 12); jpegSummary }
                            VStack(alignment: .leading, spacing: 4) { Text(L10n.text("JPEG 保存")); jpegSummary }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("camera.jpeg.settings")
            }
            if scan.undatedCount > 0 {
                Toggle(L10n.format("一并导入 %@ 个日期未知的文件", String(scan.undatedCount)), isOn: $includeUndated)
                    .frame(minHeight: 44).accessibilityIdentifier("camera.incremental.undated")
            }
            HStack {
                Button(L10n.text("重新扫描"), action: model.refreshImport)
                    .frame(minHeight: 44).accessibilityIdentifier("camera.incremental.refresh")
                if customCutoff != nil {
                    Spacer(minLength: 12)
                    Button(L10n.text("使用默认起点")) { customCutoff = nil }.frame(minHeight: 44)
                }
            }.font(.callout)
        }
    }

    private var formatPicker: some View {
        Picker(L10n.text("传输格式"), selection: Binding(get: { model.importPreferences.format }, set: model.setImportFormat)) {
            ForEach(CameraImportFormat.allCases) { Text($0.title).tag($0) }
        }
    }
    private var jpegSummary: some View {
        let options = model.importPreferences.jpeg
        let size = options.longEdge.map { L10n.format("长边 %@ px", String($0)) } ?? L10n.text("原始尺寸")
        let summary = options.adjust
            ? L10n.format("%@ · 质量 %@", size, (Double(options.quality) / 100).formatted(.percent.locale(L10n.locale)))
            : L10n.text("原样保存")
        return Text(summary).font(.subheadline).foregroundStyle(.secondary)
    }
    private func taskStatus(_ job: CameraTransferJob?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(model.phase == .receiving ? "正在导入照片…" : "上次导入未完成"))
                .font(.headline).accessibilityIdentifier("camera.incremental.status")
            if let job {
                Text(L10n.format("已保存 %@ / %@ 个文件", String(job.items.count - job.pendingItems.count), String(job.items.count)))
                    .monospacedDigit().accessibilityIdentifier("camera.incremental.saved")
            }
            if let progress = model.progress, progress.total > 0 {
                ProgressView(value: Double(progress.bytes), total: Double(progress.total))
                if progress.bytes == progress.total { Text(L10n.text("正在保存照片…")).font(.subheadline).foregroundStyle(.secondary) }
            } else if model.phase == .receiving { ProgressView() }
            if let job, model.phase != .receiving {
                Button(L10n.text("导入记录"), action: history).frame(minHeight: 44)
                if model.connected && requiresNewImport(job) {
                    Button(L10n.text("开始新的增量导入")) { model.dismissIncrementalJob(job) }
                        .frame(minHeight: 44).disabled(model.busy)
                }
            }
        }
    }
    private func requiresNewImport(_ job: CameraTransferJob) -> Bool {
        let bound = job.bindToListing(model.assets)
        return job.pendingItems.contains {
            bound[$0.id] == nil || $0.failure == CameraProtocolError.jpegProcessing.errorDescription
        }
    }
    private func completion(_ job: CameraTransferJob) -> some View {
        let reused = job.items.filter { $0.reused == true }.count
        let summary = reused > 0
            ? L10n.format("新保存 %@ 个文件，%@ 个已在本机", String(job.items.count - reused), String(reused))
            : L10n.format("已保存 %@ / %@ 个文件", String(job.items.count), String(job.items.count))
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("增量导入完成")).font(.headline).accessibilityIdentifier("camera.incremental.complete")
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("camera.incremental.saved")
            Button(L10n.text("导入记录"), action: history).frame(minHeight: 44)
            Divider()
        }
    }
    private func action(_ title: String, id: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            .disabled(disabled).accessibilityIdentifier(id).padding(.vertical, 8).frame(maxWidth: 560)
    }
    private var cutoffSheet: some View {
        NavigationStack {
            Form {
                DatePicker(L10n.text("增量起点"), selection: Binding(
                    get: { cutoffDraft ?? Date() }, set: { cutoffDraft = $0 }
                )).environment(\.timeZone, model.cameraTimeZone)
                Text(L10n.text("相机时间")).font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle(L10n.text("增量起点")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { showCutoff = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("应用")) { customCutoff = cutoffDraft; showCutoff = false }
                    }
                }
        }
    }
    private func formatted(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)
        style.timeZone = model.cameraTimeZone
        return date.formatted(style)
    }
}

private struct IOSCameraJPEGSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: CameraJPEGOptions
    let apply: (CameraJPEGOptions) -> Void
    @State private var validSize = true

    var body: some View {
        NavigationStack {
            Form {
                Picker(L10n.text("JPEG 保存"), selection: $draft.adjust) {
                    Text(L10n.text("原样保存")).tag(false)
                    Text(L10n.text("调整后保存")).tag(true)
                }.accessibilityIdentifier("camera.jpeg.mode")
                if draft.adjust {
                    Section {
                        ExportSizePicker(longEdge: $draft.longEdge, title: L10n.text("尺寸")) { validSize = $0 }
                        HStack {
                            Text(L10n.text("JPEG 质量"))
                            Spacer()
                            Text(quality).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { Double(draft.quality) }, set: { draft.quality = Int($0.rounded()) }),
                               in: 1...100, step: 1)
                            .accessibilityLabel(L10n.text("JPEG 质量")).accessibilityValue(quality)
                            .accessibilityIdentifier("camera.jpeg.quality")
                    } footer: {
                        Text(L10n.text("JPEG 传入手机后再处理。"))
                    }
                }
            }.navigationTitle(L10n.text("JPEG 保存")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("应用")) { apply(draft); dismiss() }
                            .disabled(draft.adjust && !validSize).accessibilityIdentifier("camera.jpeg.apply")
                    }
                }
        }
    }
    private var quality: String { (Double(draft.quality) / 100).formatted(.percent.locale(L10n.locale)) }
}
