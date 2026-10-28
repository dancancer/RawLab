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
    @State var photoViewing = PhotoViewingState()
    @State var photoViewport = PhotoViewport()
    @State var photoComparisonControlBounds = CGRect.zero
    @State var pendingPhotoImport = false
    @State var pendingFileImport = false
    var showingBefore: Bool {
        get { photoViewing.holdingBefore }
        nonmutating set {
            if newValue { photoViewing.beginHolding(isDraft: isEditorDraftActive) }
            else { photoViewing.endTemporaryViewing() }
        }
    }
    @State var selectedAdjustment: AdjustmentKind? = nil
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
    @State var geometryLockedRatio: Double?
    @State var geometryAspectSwapped = false
    @State var geometryGrid = true
    @State var geometryPerspective = false
    @State var showingProcessingContext = false
    @State var adjustmentSheet: IOSAdjustmentSheet?
    @State var pendingAdjustmentAction: IOSAdjustmentAction?
    @State var queuedPresetAction: IOSAdjustmentAction?
    @State var applyingPreset: AdjustmentPreset?
    @State var returnToPresetLibrary = false
    @State var adjustmentReloadPresented = false
    @State var lensDraft: RawSettings?
    @State var draftExitPresented = false
    @State var pendingToolSelection: EditorToolSelection?
    @State var selectedGroup = EditorAdjustmentGroup.looks
    @State var hslChannel = 0
    @State var hslTargetEnabled = false
    @State var hslTargetAxis: HSLAxis = .hue
    @State var hslTargetInteraction = HSLTargetInteraction()
    @State var hslTargetPoint: CGPoint?
    @State var hslTargetNotice: HSLTargetAvailability?
    @State var hslTargetHistoryActive = false
    @State var gradingZone: ColorGradingZone = .shadows
    @State var adjustmentFine = false
    @State var pendingAdjustmentExpansion: Bool?
    @State var collapsedEditorTool: EditorToolSelection?
    @State var preparedReset: PreparedEditorReset?
    @State var preparedResetScope: EditorAdjustmentScope?
    @State var resetConfirmationPresented = false
    @State var resetRestoreTool: EditorToolSelection?
    @State var resetIntentSource: EditorEditSource?
    @State var resetDraftSuspended = false
    @State var resetWaitingForReady = false
    @State var suppressNextDraftPreview = false
    @State var autoExposing = false
    @State var settingsRevision = UUID()
    @State var selectedPhotoItem: PhotosPickerItem?
    @State var photoImportTask: Task<Void, Never>?
    @State var photoImportRequestID: UUID?
    @State var showingPhotoImporter = false
    @State var showingFileImporter = false
    @State var showingLookImporter = false
    @State var showingLookCompatibility = false
    @State var pendingLookCompatibility: (source: URL, draft: LUTCompatibility, finish: (LUTCompatibility?) -> Void)?
    @State var confirmedLookCompatibility: LUTCompatibility?
    @State var renamingLUT: LUTOption?
    @State var renamedLUTName = ""
    @State var showingLookRename = false
    @State private var checkedBatchRecovery = false
    @State var showingBatchSelection = false
    @State var queuedCollectionEdit: String?
    @State var queuedCollectionBatch: BatchExportModel?
    @State var queuedCollectionExistingBatch = false
    @State var pendingCollectionNavigation: IOSCollectionNavigation?
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
    @ScaledMetric(relativeTo: .caption) var toolHeight = 44.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 220.0
    @ScaledMetric(relativeTo: .subheadline) var panelHeaderHeight = 44.0

    var body: some View {
        let _ = localizationLocale
        let root = editorNavigation
        let presented = applyEditorPresentation(to: root)
        let dataObserved = applyEditorDataObservers(to: presented)
        let draftObserved = applyEditorDraftObservers(to: dataObserved)
        let interactionObserved = applyEditorInteractionObservers(to: draftObserved)
        return applyEditorSheets(to: interactionObserved)
            .sheet(isPresented: $showingProcessingContext) { processingContextSheet }
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
            .toolbar(photoViewing.previewOnly ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func applyEditorPresentation<Content: View>(to content: Content) -> some View {
        content
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .photosPicker(isPresented: $showingPhotoImporter, selection: $selectedPhotoItem,
                      matching: .images, preferredItemEncoding: .current)
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
        .sheet(isPresented: $showingLookCompatibility, onDismiss: {
            let pending = pendingLookCompatibility
            let confirmed = confirmedLookCompatibility
            pendingLookCompatibility = nil
            confirmedLookCompatibility = nil
            pending?.finish(confirmed)
        }) {
            if let pending = pendingLookCompatibility {
                IOSLUTCompatibilityView(source: pending.source, draft: pending.draft,
                    initialPhoto: viewModel.sourceFile.map { file in
                        LUTPreviewSource(name: file.displayName) { destination in
                            try file.withReadAccess { try FileManager.default.copyItem(at: $0, to: destination) }
                        }
                    }) { result in
                    confirmedLookCompatibility = result
                    showingLookCompatibility = false
                }
            }
        }
        .alert(L10n.text("重命名外观"), isPresented: $showingLookRename) {
            TextField(L10n.text("外观名称"), text: $renamedLUTName)
            Button(L10n.text("取消"), role: .cancel) { renamingLUT = nil }
            Button(L10n.text("保存")) {
                if let look = renamingLUT { viewModel.renameLook(id: look.id, name: renamedLUTName) }
                renamingLUT = nil
            }.disabled(renamedLUTName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                       renamedLUTName.trimmingCharacters(in: .whitespacesAndNewlines).rangeOfCharacter(from: .controlCharacters) != nil)
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
            viewModel.committedPreviewSettings = newValue
            if viewModel.consumeRestoredSettings(newValue) { return }
            if viewModel.consumePersistedEditorSettings(newValue) { return }
            queueEditorSettingsChange(newValue)
        }
        .onChange(of: viewModel.adjustmentRestoredSettings) { _, restored in
            guard let restored else { return }
            settings = restored
            viewModel.adjustmentRestoredSettings = nil
            viewModel.updatePreview(settings: restored, includeHistogram: true, quality: .final)
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
                cancelSliderInteraction()
                viewModel.saveCurrentSettings(settings)
            }
            if phase == .background { batchModel?.cancel(forBackground: true) }
            if phase != .active { cancelRulerFocus(); photoViewing.endTemporaryViewing() }
        }
    }

    private func applyEditorDraftObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: editorDraftSnapshot) { old, draft in
            viewModel.hasAdjustmentDraft = draft.isActive
            if (old.geometry != draft.geometry || old.lens != draft.lens),
               draft.geometry != nil || draft.lens != nil {
                if suppressNextDraftPreview { suppressNextDraftPreview = false }
                else { previewEditorDraft() }
            }
        }
        .onChange(of: viewModel.sourceRevision) { _, _ in
            cancelHSLTarget()
            gradingZone = .shadows
            photoViewing.sourceChanged()
            photoComparisonControlBounds = .zero
            photoViewport = PhotoViewport()
            pendingFileImport = false
            pendingPhotoImport = false
            pendingAdjustmentAction = nil
            queuedPresetAction = nil
            applyingPreset = nil
            returnToPresetLibrary = false
            if adjustmentSheet == .presetSave || adjustmentSheet == .presetApply { adjustmentSheet = nil }
            adjustmentFine = false
            geometryDraft = nil
            lensDraft = nil
            pendingToolSelection = nil
            pendingAdjustmentExpansion = nil
            preparedReset = nil
            preparedResetScope = nil
            resetConfirmationPresented = false
            resetRestoreTool = nil
            resetIntentSource = nil
            resetDraftSuspended = false
            resetWaitingForReady = false
            suppressNextDraftPreview = false
            draftExitPresented = false
            cancelRulerFocus()
            // Import renders the committed crop; the retained geometry tool needs the full image.
            if geometrySelected && !viewModel.isBusy {
                viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
            }
        }
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy, let current = viewModel.batchSelection.selection.current, current != viewModel.sourceIdentity?.key {
                viewModel.batchSelection.selection.returnToCollection()
            }
            if !busy && photoImportTask == nil {
                isImporting = false
                photoImportRequestID = nil
            }
            continuePendingAllReset()
        }
        .onChange(of: viewModel.previewRendering) { _, _ in continuePendingAllReset() }
        .onChange(of: viewModel.previewResizePending) { _, _ in continuePendingAllReset() }
        .onChange(of: viewModel.basePreviewImage) { _, image in
            if image == nil { photoViewing.endTemporaryViewing() }
        }
        .onChange(of: viewModel.hasImage) { _, hasImage in
            if hasImage { adjustmentsExpanded = true }
        }
    }

    private func applyEditorInteractionObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: adjustmentsExpanded) { _, expanded in
            if !expanded && isAdjustingSlider && !hslTargetEnabled { setSliderEditing(false) }
            if expanded, let tool = collapsedEditorTool { activateEditorTool(tool) }
        }
        .onChange(of: geometrySelected) { _, active in
            if active {
                photoViewing.sourceChanged()
                photoComparisonControlBounds = .zero
                // 裁切 controller 使用 fit 画布，进入时显式收敛唯一视口。
                photoViewport = PhotoViewport()
            }
            if isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: lensSelected) { _, active in
            if active { photoViewing.sourceChanged() }
        }
        .onChange(of: selectedAdjustment) { _, _ in
            cancelHSLTarget(); hslTargetEnabled = false
            if isAdjustingSlider { cancelSliderInteraction() }
            cancelRulerFocus()
        }
        .onChange(of: gradingZone) { _, _ in cancelSliderInteraction() }
        .onChange(of: hslChannel) { _, _ in cancelHSLTarget(); cancelSliderInteraction() }
        .onChange(of: hslTargetEnabled) { _, _ in photoViewing.endTemporaryViewing() }
        .onChange(of: adjustmentFine) { _, _ in cancelSliderInteraction() }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            handleEditorAppear()
        }
    }

    private func applyEditorSheets<Content: View>(to content: Content) -> some View {
        content
        .sheet(item: $adjustmentSheet, onDismiss: finishAdjustmentSheet) { kind in
            switch kind {
            case .presets, .presetSave:
                IOSAdjustmentPresetView(model: viewModel, settings: settings, initialSave: kind == .presetSave,
                    requestPhotoAction: queuePresetAction)
            case .presetApply:
                if let applyingPreset {
                    IOSAdjustmentTransferView(model: viewModel, kind: .paste, settings: settings, preset: applyingPreset)
                }
            default:
                IOSAdjustmentTransferView(model: viewModel, kind: kind, settings: settings)
            }
        }
        .sheet(isPresented: $showingBatchSelection, onDismiss: finishBatchSelection) {
            IOSBatchSelectionView(model: viewModel, collection: viewModel.batchSelection, settings: settings,
                hasPendingBatch: batchModel != nil, resolveDraft: resolveCollectionDraft,
                editPhoto: { queuedCollectionEdit = $0; showingBatchSelection = false },
                showExistingBatch: { queuedCollectionExistingBatch = true; showingBatchSelection = false },
                created: { job, journal in
                    queuedCollectionBatch = BatchExportModel(job: job, journalStore: journal)
                    showingBatchSelection = false
                })
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
        .alert(L10n.text("保留这次几何或镜头修改？"), isPresented: $draftExitPresented) {
            Button(L10n.text("应用")) { finishDraftNavigation(apply: true) }
                .disabled(editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || isAdjustingSlider)
            Button(L10n.text("放弃修改"), role: .destructive) { finishDraftNavigation(apply: false) }
            Button(L10n.text("继续编辑"), role: .cancel) { cancelDraftNavigation() }
        }
        .alert(resetConfirmationTitle, isPresented: $resetConfirmationPresented) {
            Button(L10n.text("重置"), role: .destructive) { confirmEditorReset() }
            Button(L10n.text("取消"), role: .cancel) { cancelEditorReset() }
        } message: { Text(resetConfirmationMessage) }
        .alert(L10n.text("重新载入已保存调整"), isPresented: $adjustmentReloadPresented) {
            Button(L10n.text("重新载入已保存调整"), role: .destructive) {
                guard viewModel.reloadSavedAdjustments() else { return }
                if let restored = viewModel.adjustmentRestoredSettings { settings = restored }
                cancelDraftNavigation()
                discardEditorDraft()
                activateEditorTool(.adjustment(.exposure))
            }
            Button(L10n.text("继续编辑"), role: .cancel) {}
        } message: { Text(L10n.text("重新载入会放弃未保存的调整，并读取此照片当前已保存的记录。")) }
        .onDisappear {
            cancelSliderInteraction()
            viewModel.saveCurrentSettings(settings)
            photoViewing.endTemporaryViewing()
            cancelPhotoImport()
        }
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
