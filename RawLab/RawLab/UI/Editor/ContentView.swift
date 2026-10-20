import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.locale) var localizationLocale
    @AppStorage(L10n.preferenceKey) var languagePreference = AppLanguage.system.rawValue
    @AppStorage("rawlab.adjustmentHaptics.enabled") var adjustmentHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
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
    @State var rulerFocusPhase = RulerFocusPhase.idle
    @State var rulerFocusTask: Task<Void, Never>?
    @State var geometryDraft: GeometrySettings?
    @State var geometryAspectPreset: CropAspectPreset = .free
    @State var lensDraft: RawSettings?
    @State var draftExitPresented = false
    @State var pendingToolSelection: EditorToolSelection?
    @State var autoExposing = false
    @State var settingsRevision = UUID()
    @State var selectedPhotoItem: PhotosPickerItem?
    @State var photoImportTask: Task<Void, Never>?
    @State var photoImportRequestID: UUID?
    @State var showingFileImporter = false
    @State var showingLookImporter = false
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
    @ScaledMetric(relativeTo: .caption) var toolHeight = 92.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 256.0
    @ScaledMetric(relativeTo: .subheadline) var panelHeaderHeight = 44.0

    var body: some View {
        let _ = localizationLocale
        let root = editorNavigation
        let presented = applyEditorPresentation(to: root)
        let dataObserved = applyEditorDataObservers(to: presented)
        let draftObserved = applyEditorDraftObservers(to: dataObserved)
        let interactionObserved = applyEditorInteractionObservers(to: draftObserved)
        return applyEditorSheets(to: interactionObserved)
    }

    private var editorNavigation: some View {
        NavigationStack {
            GeometryReader { geometry in
                editorWorkspace(size: geometry.size, accessibility: dynamicTypeSize.isAccessibilitySize)
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
            // 紧凑宽度下两侧按钮已占满导航栏，标题只会被挤成"…"，干脆不显示
            .navigationTitle(horizontalSizeClass == .compact ? "" : "RawLab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func applyEditorPresentation<Content: View>(to content: Content) -> some View {
        content
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .sheet(isPresented: $showingPrivacy) { UsagePrivacyView() }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: PhotoImportFile.supportedContentTypes,
                      allowsMultipleSelection: false) { result in
            importFromFile(result)
        }
        .fileImporter(isPresented: $showingLookImporter,
                      allowedContentTypes: PhotoImportFile.supportedLookContentTypes,
                      allowsMultipleSelection: true) { result in
            importLooks(result)
        }
        .alert("RawLab", isPresented: Binding(
            get: { viewModel.statusMessage != nil },
            set: { if !$0 { viewModel.statusMessage = nil } }
        )) {
            Button(L10n.text("关闭"), role: .cancel) { viewModel.statusMessage = nil }
        } message: {
            ScrollView {
                Text(viewModel.statusMessage ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
    }

    private func applyEditorDataObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: settings) { _, newValue in
            settingsRevision = UUID()
            if viewModel.consumeRestoredSettings(newValue) { return }
            showingBefore = false
            viewModel.queueSettingsSave(newValue)
            if isAdjustingSlider {
                viewModel.schedulePreviewUpdate(
                    settings: draftPreviewSettings,
                    delay: 0.08,
                    includeHistogram: false,
                    quality: .interactive
                )
            } else {
                viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            photoImportTask?.cancel()
            let requestID = UUID()
            photoImportRequestID = requestID
            viewModel.cancelImageImport()
            photoImportTask = Task {
                await importFromPhotoItem(newItem, requestID: requestID)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.saveCurrentSettings(settings)
            }
            if phase == .background { batchModel?.cancel(forBackground: true) }
            if phase != .active { cancelRulerFocus() }
        }
    }

    private func applyEditorDraftObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: geometryDraft) { _, draft in
            if draft != nil { previewEditorDraft() }
        }
        .onChange(of: lensDraft) { _, draft in
            if draft != nil { previewEditorDraft() }
        }
        .onChange(of: viewModel.sourceRevision) { _, _ in
            geometryDraft = nil
            lensDraft = nil
            pendingToolSelection = nil
            draftExitPresented = false
            cancelRulerFocus()
            // Import renders the committed crop; the retained geometry tool needs the full image.
            if geometrySelected && !viewModel.isBusy {
                viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
            }
        }
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy && photoImportTask == nil {
                isImporting = false
                photoImportRequestID = nil
            }
        }
        .onChange(of: viewModel.hasImage) { _, hasImage in
            if hasImage { adjustmentsExpanded = true }
        }
    }

    private func applyEditorInteractionObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: adjustmentsExpanded) { _, expanded in
            if !expanded && isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: geometrySelected) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: selectedAdjustment) { _, _ in
            if isAdjustingSlider { setSliderEditing(false) }
            cancelRulerFocus()
        }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            handleEditorAppear()
        }
    }

    private func applyEditorSheets<Content: View>(to content: Content) -> some View {
        content
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
        .alert(L10n.text("保留这次几何或镜头修改？"), isPresented: $draftExitPresented) {
            Button(L10n.text("应用")) { finishDraftNavigation(apply: true) }
            Button(L10n.text("放弃修改"), role: .destructive) { finishDraftNavigation(apply: false) }
            Button(L10n.text("继续编辑"), role: .cancel) { pendingToolSelection = nil }
        }
        .onDisappear { cancelRulerFocus(); cancelPhotoImport() }
    }

    private func handleEditorAppear() {
        if ProcessInfo.processInfo.arguments.contains("-RawLab.testBusyEditor") {
            isImporting = true
        }
        if !checkedBatchRecovery {
            checkedBatchRecovery = true
            recoverBatchExport()
        }
        guard !didAutoLoadSample else { return }
        guard ProcessInfo.processInfo.environment["RAWLAB_SMOKE_TEST"] == "1" else { return }
        didAutoLoadSample = true
        viewModel.runBundledSampleSmokeTest(settings: settings)
    }
}

private struct UsagePrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var usage = UsageAnalytics.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.text("允许使用统计"), isOn: Binding(get: { usage.isEnabled }, set: { usage.setEnabled($0) }))
                        .disabled(!usage.isAvailable && !usage.isEnabled)
                        .accessibilityIdentifier("usage.consent")
                    Text(L10n.text(usage.statusKey)).foregroundStyle(.secondary)
                }
                Section(L10n.text("数据与提供方")) {
                    Text(L10n.text("开启后，由阿里云处理功能使用次数，数据存储在中国大陆；SDK 可能采集设备标识、设备与系统信息、网络/IP、地区及会话信息。"))
                    Text(L10n.text("为统计活跃设备数，应用会在本机保存一个随机生成的安装标识，不含个人信息；关闭统计时一并删除。"))
                    Text(L10n.text("不采集照片、预览、文件名、路径、EXIF 或 AI 内容。关闭后停止新采集，已发出的请求无法撤回。"))
                    Link(L10n.text("阿里云隐私政策"), destination: URL(string: "https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html")!)
                }
            }
            .navigationTitle(L10n.text("隐私设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { dismiss() }.accessibilityIdentifier("usage.done")
                }
            }
        }.preferredColorScheme(.dark).tint(.yellow)
    }
}

#Preview {
    ContentView()
}
