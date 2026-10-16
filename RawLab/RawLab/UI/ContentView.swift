import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.locale) var localizationLocale
    @AppStorage(L10n.preferenceKey) var languagePreference = AppLanguage.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var viewModel = RawEditorViewModel()
    @State var settings = RawSettings.default
    @State private var didAutoLoadSample = false
    @State var showingBefore = false
    @State var selectedAdjustment: AdjustmentKind? = .exposure
    @State var lensSelected = false
    @State var geometrySelected = false
    @State var choosingMasterRecipe = false
    @State var adjustmentsExpanded = true
    @State var histogramExpanded = false
    @State var isImporting = false
    @State var isSaving = false
    @State var isAdjustingSlider = false
    @State var autoExposing = false
    @State var settingsRevision = UUID()
    @State var selectedPhotoItem: PhotosPickerItem?
    @State private var checkedBatchRecovery = false
    @State var showingBatchExport = false
    @State var batchModel: BatchExportModel?
    @State var photoInfoMode = PhotoInfoMode.hidden
    @State var photoInformation: PhotoInformation?
    @State var showingExportSize = false
    @State var showingPrivacy = false
    @State var exportLongEdge: Int?
    @State var singleExportFormat: BatchOutputFormat = .jpeg
    @State var fileExportRequest: FileExportRequest?
    @ScaledMetric(relativeTo: .caption) var toolWidth = 62.0
    @ScaledMetric(relativeTo: .caption) var toolHeight = 82.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 256.0
    @ScaledMetric(relativeTo: .subheadline) var panelHeaderHeight = 44.0

    var body: some View {
        let _ = localizationLocale
        NavigationStack {
            GeometryReader { geometry in
                let landscape = EditorLayoutPolicy.usesSidePanel(width: geometry.size.width, height: geometry.size.height,
                                                                 accessibility: dynamicTypeSize.isAccessibilitySize)
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    previewSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if viewModel.hasImage && adjustmentsExpanded {
                        Divider()
                        ScrollView(.vertical) {
                            adjustmentPanel
                        }
                        .accessibilityIdentifier("editor.panel")
                        .frame(width: landscape ? min(360, geometry.size.width * 0.44) : nil,
                               height: landscape ? nil : min(panelHeight + (geometrySelected ? 360 : lensSelected ? 220 : selectedAdjustment == nil ? 32 : selectedAdjustment == .hsl ? 120 : selectedAdjustment == .noiseReduction ? 80 : 0),
                                                            geometry.size.height * 0.6))
                        .background(Color(.secondarySystemBackground))
                    }
                }
                .background(Color(.systemBackground))
            }
            .safeAreaInset(edge: .top) {
                if let batchModel, !showingBatchExport {
                    Button { showingBatchExport = true } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(L10n.format("查看批量任务 · %@ 张", String(describing: batchModel.job.targets.count)))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(.subheadline).padding(12)
                    }.background(Color(.secondarySystemBackground)).accessibilityIdentifier("batch.resume")
                }
            }
            .navigationTitle("RawLab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .sheet(isPresented: $showingPrivacy) { UsagePrivacyView() }
        .alert("RawLab", isPresented: Binding(
            get: { viewModel.statusMessage != nil },
            set: { if !$0 { viewModel.statusMessage = nil } }
        )) {
            Button(L10n.text("关闭"), role: .cancel) { viewModel.statusMessage = nil }
        } message: {
            Text(viewModel.statusMessage ?? "")
        }
        .onChange(of: settings) { _, newValue in
            settingsRevision = UUID()
            if viewModel.consumeRestoredSettings(newValue) { return }
            showingBefore = false
            viewModel.queueSettingsSave(newValue)
            if isAdjustingSlider {
                viewModel.schedulePreviewUpdate(
                    settings: newValue,
                    delay: 0.08,
                    includeHistogram: false,
                    quality: .interactive
                )
            } else {
                viewModel.updatePreview(settings: newValue, includeHistogram: true, quality: .final)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importFromPhotoItem(newItem)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.saveCurrentSettings(settings)
            }
            if phase == .background { batchModel?.cancel(forBackground: true) }
        }
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy { isImporting = false }
        }
        .onChange(of: viewModel.hasImage) { _, hasImage in
            if hasImage { adjustmentsExpanded = true }
        }
        .onChange(of: adjustmentsExpanded) { _, expanded in
            if !expanded && isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: geometrySelected) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: selectedAdjustment) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            if !checkedBatchRecovery { checkedBatchRecovery = true; recoverBatchExport() }
            guard !didAutoLoadSample else { return }
            if ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] == "1" {
                didAutoLoadSample = true
                viewModel.runBundledSampleSmokeTest(settings: settings)
            }
        }
        .sheet(isPresented: $showingBatchExport) {
            if let batchModel {
                BatchExportView(model: batchModel)
            }
        }
        .sheet(isPresented: $showingExportSize) {
            ExportSizeSheet(longEdge: $exportLongEdge,
                            title: singleExportFormat == .renderedDNG ? "导出渲染型 DNG" : "保存当前照片") {
                showingExportSize = false
                if singleExportFormat == .renderedDNG {
                    exportDNG(longEdge: exportLongEdge)
                } else {
                    exportJPEG(longEdge: exportLongEdge)
                }
            }
        }
        .sheet(item: $fileExportRequest) { request in
            FileExportPicker(urls: request.urls) { exported in
                fileExportRequest = nil
                if exported { UsageAnalytics.shared.record(.exportCompleted) }
                if request.removeAfterExport {
                    for url in request.urls { try? FileManager.default.removeItem(at: url) }
                }
                viewModel.statusMessage = exported ? request.successMessage : request.cancelMessage
            }
        }
    }
}

private struct UsagePrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var usage = UsageAnalytics.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("允许使用统计", isOn: Binding(get: { usage.isEnabled }, set: { usage.setEnabled($0) }))
                        .disabled(!usage.isAvailable && !usage.isEnabled)
                        .accessibilityIdentifier("usage.consent")
                    Text(usage.status).foregroundStyle(.secondary)
                }
                Section("数据与提供方") {
                    Text("开启后，由阿里云处理功能使用次数，数据存储在中国大陆；SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。")
                    Text("不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。")
                    Link("阿里云隐私政策", destination: URL(string: "https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html")!)
                }
            }
            .navigationTitle("隐私设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("usage.done")
                }
            }
        }.preferredColorScheme(.dark).tint(.yellow)
    }
}

#Preview {
    ContentView()
}
