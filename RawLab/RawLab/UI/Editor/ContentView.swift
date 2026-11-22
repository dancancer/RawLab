import RawLabKit
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LookCompatibilityPresentation: Identifiable {
    let id: UUID
    let source: URL
    let draft: LUTCompatibility

    init(id: UUID = UUID(), source: URL, draft: LUTCompatibility) {
        self.id = id
        self.source = source
        self.draft = draft
    }
}

struct DCPImportOptionsPresentation: Identifiable {
    let id: UUID
    let source: URL
    let reason: DCPCompilerError

    init(id: UUID = UUID(), source: URL, reason: DCPCompilerError) {
        self.id = id
        self.source = source
        self.reason = reason
    }
}

struct ContentView: View {
    @Environment(\.locale) var localizationLocale
    @AppStorage(L10n.preferenceKey) var languagePreference = AppLanguage.system.rawValue
    @AppStorage("rawlab.adjustmentHaptics.enabled") var adjustmentHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.displayScale) var displayScale
    @Environment(\.scenePhase) var scenePhase
    @StateObject var viewModel: RawEditorViewModel
    @StateObject var hdrDisplay = HDRDisplayState()
    @StateObject var photoPreviews = IOSPhotoPreviewLibrary()
    @StateObject var coordinator: EditorCoordinator
    let testHooks: EditorTestHooks
    @State var photoComparisonControlBounds = CGRect.zero
    @ScaledMetric(relativeTo: .caption) var toolWidth = 62.0
    @ScaledMetric(relativeTo: .caption) var toolHeight = 44.0
    @ScaledMetric(relativeTo: .caption) var filmSize = 72.0
    @ScaledMetric(relativeTo: .body) var panelHeight = 220.0
    @ScaledMetric(relativeTo: .subheadline) var panelHeaderHeight = 44.0
    @State var parameterContentHeight: CGFloat = 0

    @MainActor
    init(
        viewModel: @autoclosure @escaping () -> RawEditorViewModel = RawEditorViewModel(),
        coordinator: @MainActor @autoclosure @escaping () -> EditorCoordinator? = nil,
        testHooks: EditorTestHooks = EditorTestHooks()
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        _coordinator = StateObject(wrappedValue: coordinator() ?? EditorCoordinator())
        self.testHooks = testHooks
    }

    var body: some View {
        let _ = localizationLocale
        let _ = coordinator.attachIfNeeded(backend: viewModel)
        let root = editorNavigation
        let presented = applyEditorPresentation(to: root)
        let dataObserved = applyEditorDataObservers(to: presented)
        let draftObserved = applyEditorDraftObservers(to: dataObserved)
        let interactionObserved = applyEditorInteractionObservers(to: draftObserved)
        return applyEditorSheets(to: interactionObserved)
            .fullScreenCover(isPresented: $coordinator.showingCameraWorkspace, onDismiss: {
                guard let url = coordinator.cameraOriginalToOpen else { return }
                coordinator.cameraOriginalToOpen = nil
                requestSystemPhotoImport([url])
            }) {
                IOSCameraWorkspace(onOpenOriginal: { url in
                    coordinator.cameraOriginalToOpen = url
                    coordinator.showingCameraWorkspace = false
                }, onClose: { coordinator.showingCameraWorkspace = false })
            }
            .sheet(isPresented: $coordinator.showingProcessingContext) { processingContextSheet }
            .sheet(isPresented: $coordinator.showingRecentPhotos, onDismiss: finishRecentPhotos) {
                RecentPhotosView(library: photoPreviews, model: viewModel,
                    filter: $coordinator.recentPhotoFilter, scrollID: $coordinator.recentPhotoScrollID,
                    open: { coordinator.recentPhotoToOpen = $0; coordinator.showingRecentPhotos = false },
                    importPhoto: { coordinator.recentImportRequested = true; coordinator.showingRecentPhotos = false })
            }
            .alert(L10n.text("无法重新打开照片"), isPresented: Binding(get: { coordinator.recentOpenError != nil }, set: { if !$0 { coordinator.recentOpenError = nil } })) {
                Button(L10n.text("从照片图库导入")) {
                    coordinator.recentOpenError = nil
                    requestEditorImport(file: false, recent: coordinator.recentFailedPhoto)
                    coordinator.recentFailedPhoto = nil
                }
                Button(L10n.text("从文件导入")) {
                    coordinator.recentOpenError = nil
                    requestEditorImport(file: true, recent: coordinator.recentFailedPhoto)
                    coordinator.recentFailedPhoto = nil
                }
                Button(L10n.text("取消"), role: .cancel) {
                    coordinator.recentOpenError = nil
                    coordinator.recentFailedPhoto = nil
                }
            } message: { Text(coordinator.recentOpenError ?? "") }
            .onChange(of: viewModel.importedPhotoRevision) { _, _ in recordRecentPhoto(); restoreEditorDraft() }
            .onChange(of: viewModel.hslFrameRevision) { _, _ in cacheCurrentPhotoPreview() }
            .onChange(of: viewModel.adjustmentHistoryRevision) { _, _ in
                cacheCurrentPhotoPreview()
                if coordinator.showingRecentPhotos {
                    Task { await photoPreviews.reload(editDirectory: viewModel.editPersistence?.directory) }
                }
            }
            .onChange(of: editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.matchingProcessing, initial: true) { _, busy in photoPreviews.isEditorBusy = busy }
            .onOpenURL { requestSystemPhotoImport([$0]) }
            .onChange(of: editorBusy) { _, busy in
                if !busy { continueSystemPhotoImport() }
            }
    }

    private var editorNavigation: some View {
        NavigationStack {
            GeometryReader { geometry in
                editorWorkspace(size: geometry.size, accessibility: dynamicTypeSize.isAccessibilitySize)
                    .dropDestination(for: PhotoImportFile.self) { files, _ in
                        let urls = stageSystemPhotoImport(files)
                        guard !urls.isEmpty else { return false }
                        requestSystemPhotoImport(urls)
                        return true
                    }
            }
            .background(EditorToolBackGesture(
                enabled: toolWorkspaceOpen && !editorBusy && !draftExitPresented && adjustmentSheet == nil && !photoViewing.previewOnly,
                onBack: requestToolWorkspaceExit))
            .safeAreaInset(edge: .top) {
                if let batchModel, !showingBatchExport {
                    Button { coordinator.showingBatchExport = true } label: {
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                            Text(L10n.format("查看批量任务 · %@ 张", String(describing: batchModel.job.targets.count)))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(.subheadline).padding(12)
                    }.background(Color(.secondarySystemBackground)).accessibilityIdentifier("batch.resume")
                }
            }
            .navigationTitle(toolWorkspaceOpen ? currentEditorTool.title : viewModel.sourceDisplayName ?? "RawLab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbar(photoViewing.previewOnly ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func applyEditorPresentation<Content: View>(to content: Content) -> some View {
        // 同一宿主只注册一个文件窗口，避免 iPadOS 26 的照片入口被后一个导入器遮蔽。
        let importKind = coordinator.documentImportKind
        return content
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .photosPicker(isPresented: $coordinator.showingPhotoImporter, selection: $coordinator.selectedPhotoItem,
                      matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
        .sheet(isPresented: $coordinator.showingPrivacy) { UsagePrivacyView() }
        .fileImporter(isPresented: $coordinator.showingDocumentImporter,
                      allowedContentTypes: importKind.contentTypes,
                      allowsMultipleSelection: importKind.allowsMultipleSelection) { result in
            switch importKind {
            case .photo: importFromFile(result)
            case .looks: importLooks(result)
            }
        }
        .sheet(item: Binding<LookCompatibilityPresentation?>(
            get: { coordinator.pendingLookCompatibility.flatMap { $0.value as? LookCompatibilityPresentation } },
            set: { coordinator.pendingLookCompatibility = $0.map { EditorOpaquePresentation(value: $0) } }
        ), onDismiss: {
            let completion = coordinator.lookCompatibilityCompletion as? (LUTCompatibility?) -> Void
            let confirmed = coordinator.confirmedLookCompatibility as? LUTCompatibility
            coordinator.lookCompatibilityCompletion = nil
            coordinator.confirmedLookCompatibility = nil
            completion?(confirmed)
        }) { pending in
            IOSLUTCompatibilityView(source: pending.source, draft: pending.draft,
                initialPhoto: viewModel.sourceFile.map { file in
                    LUTPreviewSource(name: file.displayName, localURL: file.persistentLocalURL) { destination in
                        try file.withReadAccess { try FileManager.default.copyItem(at: $0, to: destination) }
                    }
                }) { result in
                coordinator.confirmedLookCompatibility = result
                coordinator.pendingLookCompatibility = nil
            }
        }
        .sheet(item: Binding<DCPImportOptionsPresentation?>(
            get: { coordinator.pendingDCPImportOptions.flatMap { $0.value as? DCPImportOptionsPresentation } },
            set: { coordinator.pendingDCPImportOptions = $0.map { EditorOpaquePresentation(value: $0) } }
        ), onDismiss: {
            let completion = coordinator.dcpImportOptionsCompletion as? (DCPImportOptions?) -> Void
            let options = coordinator.confirmedDCPImportOptions as? DCPImportOptions
            coordinator.dcpImportOptionsCompletion = nil
            coordinator.confirmedDCPImportOptions = nil
            completion?(options)
        }) { pending in
            IOSDCPImportOptionsView(source: pending.source, reason: pending.reason) { options in
                coordinator.confirmedDCPImportOptions = options
                coordinator.pendingDCPImportOptions = nil
            }
        }
        .alert(L10n.text("重命名外观"), isPresented: $coordinator.showingLookRename) {
            TextField(L10n.text("外观名称"), text: $coordinator.renamedLUTName)
            Button(L10n.text("取消"), role: .cancel) { coordinator.cancelLookRename() }
            Button(L10n.text("保存")) { coordinator.completeLookRename() }
                .disabled(coordinator.renamedLUTName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          coordinator.renamedLUTName.trimmingCharacters(in: .whitespacesAndNewlines).rangeOfCharacter(from: .controlCharacters) != nil)
        }
        .alert("RawLab", isPresented: Binding(
            get: { viewModel.statusMessage != nil },
            set: { if !$0, viewModel.statusMessage != nil { viewModel.statusMessage = nil } }
        )) {
            if let recover = viewModel.resetUnusableImportRecord {
                Button(L10n.text("重置全部调整"), role: .destructive) {
                    viewModel.statusMessage = nil
                    recover { restored in
                        settings = restored
                        if restored.isHDREditing {
                            coordinator.selectedGroup = .light
                            coordinator.selectedAdjustment = .exposure
                            coordinator.selectedHDRRenditionTool = nil
                        }
                    }
                }
                .accessibilityIdentifier("edits.resetUnusable")
            }
            if let retry = viewModel.retryLegacyX3fImport {
                Button(L10n.text("使用旧版显影重试")) { retry { settings = $0 } }
                    .accessibilityIdentifier("x3f.retryLegacy")
            }
            if viewModel.statusHasDiagnostics {
                Button(L10n.text("导出错误日志"), action: exportErrorDiagnostics)
                    .disabled(!canStartFileExport)
                    .accessibilityIdentifier("diagnostics.export.alert")
            }
            Button(L10n.text(viewModel.resetUnusableImportRecord == nil ? "关闭" : "取消"), role: .cancel) {
                viewModel.statusMessage = nil
            }
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
        .onChange(of: coordinator.settings) { _, newValue in
            coordinator.handleSettingsChange(newValue)
        }
        .onChange(of: viewModel.adjustmentRestoredSettings) { _, restored in
            guard let restored else { return }
            settings = restored
            if restored.isHDREditing && !viewModel.quickPresetsVisible {
                coordinator.selectedGroup = .light
                coordinator.selectedAdjustment = .exposure
                coordinator.selectedHDRRenditionTool = nil
            } else {
                coordinator.normalizeHDRNavigation(isHDREditing: restored.isHDREditing)
            }
            viewModel.adjustmentRestoredSettings = nil
            viewModel.updatePreview(settings: restored, includeHistogram: true, quality: .final)
        }
        .onChange(of: coordinator.selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            coordinator.photoImportTask?.cancel()
            let requestID = UUID()
            coordinator.photoImportRequestID = requestID
            viewModel.cancelImageImport()
            coordinator.photoImportTask = Task {
                await importFromPhotoItem(newItem, requestID: requestID)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.handleScenePhaseChange(phase)
        }
    }

    private func applyEditorDraftObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: coordinator.editorDraftSnapshot) { old, draft in
            coordinator.handleDraftSnapshotChange(old: old, draft: draft)
        }
        .onChange(of: coordinator.geometryDraftState) { _, _ in coordinator.syncGeometryDraft() }
        .onChange(of: coordinator.geometryDraft) { _, _ in coordinator.syncGeometryDraft() }
        .onChange(of: coordinator.lensDraft) { _, _ in coordinator.syncGeometryDraft() }
        .onChange(of: viewModel.sourceRevision) { _, _ in
            coordinator.resetForNewSource()
            photoComparisonControlBounds = .zero
        }
        .onChange(of: viewModel.isBusy) { _, busy in
            if !busy, let current = viewModel.batchSelection.selection.current, current != viewModel.sourceIdentity?.key {
                viewModel.batchSelection.selection.returnToCollection()
            }
            if !busy && coordinator.photoImportTask == nil {
                coordinator.isImporting = false
                coordinator.photoImportRequestID = nil
            }
        }
        .onChange(of: viewModel.basePreviewImage) { _, image in
            if image == nil { coordinator.photoViewing.endTemporaryViewing() }
        }
        .onChange(of: viewModel.hasImage) { _, hasImage in
            if hasImage { coordinator.adjustmentsExpanded = true }
        }
        .onChange(of: coordinator.photoViewing.holdingBefore) { _, _ in
            testHooks.onHoldingBeforeChange?(self)
        }
        .onChange(of: coordinator.photoViewing.enabled || coordinator.photoViewing.holdingBefore || coordinator.inspection.monitorEnabled || !coordinator.inspection.anchors.isEmpty, initial: true) { _, needed in
            viewModel.setDetailNeedsBefore(needed)
        }
    }

    private func applyEditorInteractionObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: coordinator.adjustmentsExpanded) { _, expanded in
            if !expanded { closeQuickPresets() }
            if !expanded && coordinator.isAdjustingSlider && !coordinator.hslTargetEnabled { setSliderEditing(false) }
            if expanded, let tool = coordinator.collapsedEditorTool { activateEditorTool(tool) }
        }
        .onChange(of: coordinator.geometrySelected) { _, active in
            if active {
                coordinator.photoViewing.sourceChanged()
                photoComparisonControlBounds = .zero
                // 裁切 controller 使用 fit 画布，进入时显式收敛唯一视口。
                coordinator.photoViewport = PhotoViewport()
            }
            if coordinator.isAdjustingSlider { setSliderEditing(false) }
        }
        .onChange(of: coordinator.lensSelected) { _, active in
            if active { coordinator.photoViewing.sourceChanged() }
        }
        .onChange(of: coordinator.selectedAdjustment) { _, _ in
            coordinator.cancelHSLTarget()
            coordinator.hslTargetEnabled = false
            if coordinator.isAdjustingSlider { cancelSliderInteraction() }
            coordinator.cancelRulerFocus()
        }
        .onChange(of: coordinator.selectedHDRRenditionTool) { _, _ in
            coordinator.cancelHSLTarget()
            coordinator.hslTargetEnabled = false
            if coordinator.isAdjustingSlider { cancelSliderInteraction() }
            coordinator.cancelRulerFocus()
        }
        .onChange(of: coordinator.gradingZone) { _, _ in cancelSliderInteraction() }
        .onChange(of: coordinator.hslChannel) { _, _ in
            coordinator.cancelHSLTarget()
            cancelSliderInteraction()
        }
        .onChange(of: coordinator.hslTargetEnabled) { _, _ in coordinator.photoViewing.endTemporaryViewing() }
        .onChange(of: coordinator.adjustmentFine) { _, _ in cancelSliderInteraction() }
        .onAppear {
            viewModel.loadLUTsIfNeeded()
            handleEditorAppear()
            testHooks.onAppear?(self)
        }
    }

    private func applyEditorSheets<Content: View>(to content: Content) -> some View {
        content
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Q3/Q4：快捷预设（无粘贴 Sheet）用非阻塞横幅展示提示，数秒后自动消失；
            // Sheet 打开时不显示横幅，提示保留在属性里，由 Sheet 内嵌提示行呈现。
            if viewModel.transferResultNotices.isEmpty || adjustmentSheet != nil {
                Color.clear.frame(height: 0)
            } else {
                Text(viewModel.transferResultNotices.joined(separator: "；"))
                    .font(.footnote)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(.bar)
                    .accessibilityIdentifier("adjustment.notices.banner")
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        viewModel.transferResultNotices = []
                    }
            }
        }
        .sheet(item: $coordinator.adjustmentSheet, onDismiss: finishAdjustmentSheet) { kind in
            switch kind {
            case .presets, .presetSave:
                IOSAdjustmentPresetView(model: viewModel, settings: settings, initialSave: kind == .presetSave,
                    requestPhotoAction: queuePresetAction)
            case .presetApply:
                if let applyingPreset = coordinator.applyingPreset {
                    IOSAdjustmentTransferView(model: viewModel, kind: .paste, settings: settings, preset: applyingPreset)
                }
            default:
                IOSAdjustmentTransferView(model: viewModel, kind: kind, settings: settings)
            }
        }
        .sheet(isPresented: $coordinator.showingBatchSelection, onDismiss: finishBatchSelection) {
            IOSBatchSelectionView(model: viewModel, collection: viewModel.batchSelection, previews: photoPreviews, settings: settings,
                hasPendingBatch: batchModel != nil || coordinator.collectionBatchHandoff.hasPending, resolveDraft: resolveCollectionDraft,
                editPhoto: { coordinator.queuedCollectionEdit = $0; coordinator.showingBatchSelection = false },
                showExistingBatch: { coordinator.queuedCollectionExistingBatch = true; coordinator.showingBatchSelection = false },
                created: { job, journal, automaticallyStart in
                    let batch = BatchExportModel(job: job, journalStore: journal, editor: viewModel)
                    testHooks.onBatchModelCreated?(batch)
                    testHooks.onBatchHandoff?(automaticallyStart, scenePhase)
                    coordinator.collectionBatchHandoff.enqueue(batch,
                        automaticallyStart: automaticallyStart && scenePhase == .active)
                    if coordinator.showingBatchSelection { coordinator.showingBatchSelection = false }
                    else { finishBatchSelection() }
                })
        }
        .sheet(isPresented: $coordinator.showingBatchExport) {
            if let batchModel {
                BatchExportView(model: batchModel)
            }
        }
        .sheet(isPresented: $coordinator.showingExportSize) {
            ExportSizeSheet(longEdge: $coordinator.exportLongEdge,
                            outputSharpening: $coordinator.exportOutputSharpening,
                            showOutputSharpening: coordinator.singleExportFormat != .renderedDNG,
                            title: coordinator.singleExportFormat == .renderedDNG ? "导出渲染型 DNG" :
                                coordinator.singleExportFormat == .hdrHEIF ? coordinator.singleExportFormat.title :
                                coordinator.singleExportFormat == .png ? BatchOutputFormat.png.title : "保存当前照片") {
                coordinator.showingExportSize = false
                if coordinator.singleExportFormat == .renderedDNG {
                    exportDNG(longEdge: coordinator.exportLongEdge)
                } else {
                    exportPhoto(longEdge: coordinator.exportLongEdge,
                                format: coordinator.singleExportFormat,
                                outputSharpening: coordinator.exportOutputSharpening)
                }
            }
        }
        .sheet(item: $coordinator.fileExportRequest) { request in
            FileExportPicker(urls: request.urls) { exported in
                coordinator.fileExportRequest = nil
                if exported && request.recordsPhotoExport {
                    UsageAnalytics.shared.record(.exportCompleted)
                    // Q6（B1）：Files 另存成功 = 真实外部出口，登记源照片内容标识。
                    ExportEvidenceStore.shared.record(contentIdentifiers: request.evidenceIdentifiers)
                }
                if request.removeAfterExport {
                    for url in request.urls { try? FileManager.default.removeItem(at: url) }
                }
                viewModel.statusMessage = exported ? request.successMessage : request.cancelMessage
            }
            .interactiveDismissDisabled(!request.recordsPhotoExport)
        }
        .alert(L10n.text("保留这次几何或镜头修改？"), isPresented: $coordinator.draftExitPresented) {
            Button(L10n.text("应用")) { finishDraftNavigation(apply: true) }
                .disabled(editorBusy || viewModel.previewRendering || viewModel.previewResizePending || viewModel.previewFailed || coordinator.isAdjustingSlider)
            Button(L10n.text("放弃修改"), role: .destructive) { finishDraftNavigation(apply: false) }
            Button(L10n.text("继续编辑"), role: .cancel) { cancelDraftNavigation() }
        }
        .alert(resetConfirmationTitle, isPresented: $coordinator.resetConfirmationPresented) {
            Button(L10n.text("重置"), role: .destructive) { confirmEditorReset() }
            Button(L10n.text("取消"), role: .cancel) { cancelEditorReset() }
        } message: { Text(resetConfirmationMessage) }
        .alert(L10n.text("恢复这张照片的旧调整？"), isPresented: $coordinator.showingLegacyAssetEdit) {
            Button(L10n.text("恢复旧调整")) { coordinator.finishLegacyAssetEditDecision(true) }
            Button(L10n.text("从原片开始"), role: .cancel) { coordinator.finishLegacyAssetEditDecision(false) }
        } message: { Text(L10n.text("旧版记录只有相册标识。确认当前照片与原来的照片一致后，可恢复旧调整。")) }
        .onDisappear {
            cancelSliderInteraction()
            _ = viewModel.saveCurrentSettings(settings)
            coordinator.photoViewing.endTemporaryViewing()
            cancelPhotoImport()
            testHooks.onDisappear?()
        }
    }

    private func handleEditorAppear() {
        if !coordinator.checkedBatchRecovery {
            coordinator.checkedBatchRecovery = true
            recoverBatchExport()
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
