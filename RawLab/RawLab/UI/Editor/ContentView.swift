import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LookCompatibilityPresentation: Identifiable {
    let id = UUID()
    let source: URL
    let draft: LUTCompatibility
}

struct DCPImportOptionsPresentation: Identifiable {
    let id = UUID()
    let source: URL
    let reason: DCPCompilerError
}

enum EditorDocumentImportKind {
    case photo
    case looks

    var contentTypes: [UTType] {
        switch self {
        case .photo: PhotoImportFile.photoPickerContentTypes
        case .looks: PhotoImportFile.supportedLookContentTypes
        }
    }

    var allowsMultipleSelection: Bool { self == .looks }
}

struct ContentView: View {
    @Environment(\.locale) var localizationLocale
    @AppStorage(L10n.preferenceKey) var languagePreference = AppLanguage.system.rawValue
    @AppStorage("rawlab.adjustmentHaptics.enabled") var adjustmentHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase
    @StateObject var viewModel = RawEditorViewModel()
    @StateObject var hdrDisplay=HDRDisplayState()
    @StateObject var photoPreviews = IOSPhotoPreviewLibrary()
    @State var showingRecentPhotos = false
    @State var recentPhotoFilter = PhotoEditFilter.all
    @State var recentPhotoScrollID: String?
    @State var recentPhotoToOpen: RecentPhoto?
    @State var recentImportRequested = false
    @State var recentOpenError: String?
    @State var recentFailedPhoto: RecentPhoto?
    @State var recentReselection: RecentPhoto?
    @State var showingLegacyAssetEdit = false
    @State var legacyAssetEditDecision: CheckedContinuation<Bool?, Never>?
    @State var settings = RawSettings.default
    @State var workspaceDraft: EditorToolDraft?
    @State var toolWorkspaceOpen = false
    @State var workspaceDraftID = UUID()
    @State var lookSearchExpanded = false
    @State private var didAutoLoadSample = false
    @State var photoViewing = PhotoViewingState()
    @State var photoViewport = PhotoViewport()
    @State var photoComparisonControlBounds = CGRect.zero
    @State var showingCameraWorkspace = false
    @State var cameraOriginalToOpen: URL?
    @State var pendingPhotoImport = false
    @State var pendingFileImport = false
    @State var pendingSystemPhotoURLs: [[URL]] = []
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
    @State var geometryRotation = false
    @State var showingProcessingContext = false
    @State var confirmingProcessingRollback = false
    @State var adjustmentSheet: IOSAdjustmentSheet?
    @State var pendingAdjustmentAction: IOSAdjustmentAction?
    @State var queuedPresetAction: IOSAdjustmentAction?
    @State var applyingPreset: AdjustmentPreset?
    @State var returnToPresetLibrary = false
    @State var presetLibraryRevision = UUID()
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
    @State var documentImportKind = EditorDocumentImportKind.photo
    @State var showingDocumentImporter = false
    @State var pendingLookCompatibility: LookCompatibilityPresentation?
    @State var lookCompatibilityCompletion: ((LUTCompatibility?) -> Void)?
    @State var confirmedLookCompatibility: LUTCompatibility?
    @State var pendingDCPImportOptions: DCPImportOptionsPresentation?
    @State var dcpImportOptionsCompletion: ((DCPImportOptions?) -> Void)?
    @State var confirmedDCPImportOptions: DCPImportOptions?
    @State var renamingLUT: LUTOption?
    @State var renamedLUTName = ""
    @State var showingLookRename = false
    @State private var checkedBatchRecovery = false
    @State var showingBatchSelection = false
    @State var queuedCollectionEdit: String?
    @State var collectionBatchHandoff = IOSCollectionBatchHandoff()
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
    @State var parameterContentHeight: CGFloat = 0
    @State var parameterActionsHeight: CGFloat = 0

    var body: some View {
        let _ = localizationLocale
        let root = editorNavigation
        let presented = applyEditorPresentation(to: root)
        let dataObserved = applyEditorDataObservers(to: presented)
        let draftObserved = applyEditorDraftObservers(to: dataObserved)
        let interactionObserved = applyEditorInteractionObservers(to: draftObserved)
        return applyEditorSheets(to: interactionObserved)
            .fullScreenCover(isPresented: $showingCameraWorkspace, onDismiss: {
                guard let url = cameraOriginalToOpen else { return }
                cameraOriginalToOpen = nil
                requestSystemPhotoImport([url])
            }) {
                IOSCameraWorkspace(onOpenOriginal: { url in
                    cameraOriginalToOpen = url; showingCameraWorkspace = false
                }, onClose: { showingCameraWorkspace = false })
            }
            .sheet(isPresented: $showingProcessingContext) { processingContextSheet }
            .sheet(isPresented: $showingRecentPhotos, onDismiss: finishRecentPhotos) {
                RecentPhotosView(library: photoPreviews, model: viewModel, filter: $recentPhotoFilter, scrollID: $recentPhotoScrollID,
                    open: { recentPhotoToOpen = $0; showingRecentPhotos = false },
                    importPhoto: { recentImportRequested = true; showingRecentPhotos = false })
            }
            .alert(L10n.text("无法重新打开照片"), isPresented: Binding(get: { recentOpenError != nil }, set: { if !$0 { recentOpenError = nil } })) {
                Button(L10n.text("从照片图库导入")) {
                    recentOpenError = nil; requestEditorImport(file: false, recent: recentFailedPhoto); recentFailedPhoto = nil
                }
                Button(L10n.text("从文件导入")) {
                    recentOpenError = nil; requestEditorImport(file: true, recent: recentFailedPhoto); recentFailedPhoto = nil
                }
                Button(L10n.text("取消"), role: .cancel) { recentOpenError = nil; recentFailedPhoto = nil }
            } message: { Text(recentOpenError ?? "") }
            .onChange(of: viewModel.importedPhotoRevision) { _, _ in recordRecentPhoto(); restoreEditorDraft() }
            .onChange(of: viewModel.hslFrameRevision) { _, _ in cacheCurrentPhotoPreview() }
            .onChange(of: viewModel.adjustmentHistoryRevision) { _, _ in
                cacheCurrentPhotoPreview()
                Task { await photoPreviews.reload(editDirectory: viewModel.editPersistence?.directory) }
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
            .navigationTitle(viewModel.sourceDisplayName ?? "RawLab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbar(photoViewing.previewOnly || toolWorkspaceOpen ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func applyEditorPresentation<Content: View>(to content: Content) -> some View {
        // 同一宿主只注册一个文件窗口，避免 iPadOS 26 的照片入口被后一个导入器遮蔽。
        let importKind = documentImportKind
        return content
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .photosPicker(isPresented: $showingPhotoImporter, selection: $selectedPhotoItem,
                      matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
        .sheet(isPresented: $showingPrivacy) { UsagePrivacyView() }
        .fileImporter(isPresented: $showingDocumentImporter,
                      allowedContentTypes: importKind.contentTypes,
                      allowsMultipleSelection: importKind.allowsMultipleSelection) { result in
            switch importKind {
            case .photo: importFromFile(result)
            case .looks: importLooks(result)
            }
        }
        .sheet(item: $pendingLookCompatibility, onDismiss: {
            let completion = lookCompatibilityCompletion
            let confirmed = confirmedLookCompatibility
            lookCompatibilityCompletion = nil
            confirmedLookCompatibility = nil
            completion?(confirmed)
        }) { pending in
            IOSLUTCompatibilityView(source: pending.source, draft: pending.draft,
                initialPhoto: viewModel.sourceFile.map { file in
                    LUTPreviewSource(name: file.displayName) { destination in
                        try file.withReadAccess { try FileManager.default.copyItem(at: $0, to: destination) }
                    }
                }) { result in
                confirmedLookCompatibility = result
                pendingLookCompatibility = nil
            }
        }
        .sheet(item: $pendingDCPImportOptions, onDismiss: {
            let completion = dcpImportOptionsCompletion
            let options = confirmedDCPImportOptions
            dcpImportOptionsCompletion = nil
            confirmedDCPImportOptions = nil
            completion?(options)
        }) { pending in
            IOSDCPImportOptionsView(source: pending.source, reason: pending.reason) { options in
                confirmedDCPImportOptions = options
                pendingDCPImportOptions = nil
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
            set: { if !$0, viewModel.statusMessage != nil { viewModel.statusMessage = nil } }
        )) {
            if let recover = viewModel.resetUnusableImportRecord {
                Button(L10n.text("重置全部调整"), role: .destructive) {
                    viewModel.statusMessage = nil
                    recover { restored in
                        settings = restored
                        if restored.isHDREditing { selectedGroup = .light; selectedAdjustment = .exposure }
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
            if restored.isHDREditing && !viewModel.quickPresetsVisible { selectedGroup = .light; selectedAdjustment = .exposure }
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
                preserveEditorDraft()
                cancelSliderInteraction()
                viewModel.saveCurrentSettings(settings)
            }
            if phase == .background {
                batchModel?.cancel(forBackground: true)
                viewModel.cancelHDRExport()
            }
            if phase != .active {
                collectionBatchHandoff.cancelAutomaticStart()
                viewModel.cancelCollectionExportPreparation()
                viewModel.cancelQuickPreset(); cancelRulerFocus(); photoViewing.endTemporaryViewing()
            }
        }
    }

    private func applyEditorDraftObservers<Content: View>(to content: Content) -> some View {
        content
        .onChange(of: editorDraftSnapshot) { old, draft in
            viewModel.hasAdjustmentDraft = draft.isActive
            if old.projecting(on: settings) != draft.projecting(on: settings), draft.isActive {
                if suppressNextDraftPreview { suppressNextDraftPreview = false }
                else { previewEditorDraft() }
            }
        }
        .onChange(of: geometryDraftState) { _, _ in syncGeometryDraft() }
        .onChange(of: geometryDraft) { _, _ in syncGeometryDraft() }
        .onChange(of: lensDraft) { _, _ in syncGeometryDraft() }
        .onChange(of: viewModel.sourceRevision) { _, _ in
            workspaceDraft = nil; toolWorkspaceOpen = false; workspaceDraftID = UUID()
            geometrySelected = false; lensSelected = false
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
            if !expanded { closeQuickPresets() }
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
            IOSBatchSelectionView(model: viewModel, collection: viewModel.batchSelection, previews: photoPreviews, settings: settings,
                hasPendingBatch: batchModel != nil || collectionBatchHandoff.hasPending, resolveDraft: resolveCollectionDraft,
                editPhoto: { queuedCollectionEdit = $0; showingBatchSelection = false },
                showExistingBatch: { queuedCollectionExistingBatch = true; showingBatchSelection = false },
                created: { job, journal, automaticallyStart in
                    collectionBatchHandoff.enqueue(BatchExportModel(job: job, journalStore: journal, editor: viewModel),
                        automaticallyStart: automaticallyStart && scenePhase == .active)
                    if showingBatchSelection { showingBatchSelection = false }
                    else { finishBatchSelection() }
                })
        }
        .sheet(isPresented: $showingBatchExport) {
            if let batchModel {
                BatchExportView(model: batchModel)
            }
        }
        .sheet(isPresented: $showingExportSize) {
            ExportSizeSheet(longEdge: $exportLongEdge,
                            title: singleExportFormat == .renderedDNG ? "导出渲染型 DNG" :
                                singleExportFormat == .hdrHEIF ? singleExportFormat.title : "保存当前照片") {
                showingExportSize = false
                if singleExportFormat == .renderedDNG {
                    exportDNG(longEdge: exportLongEdge)
                } else {
                    exportPhoto(longEdge: exportLongEdge, format: singleExportFormat)
                }
            }
        }
        .sheet(item: $fileExportRequest) { request in
            FileExportPicker(urls: request.urls) { exported in
                fileExportRequest = nil
                if exported && request.recordsPhotoExport { UsageAnalytics.shared.record(.exportCompleted) }
                if request.removeAfterExport {
                    for url in request.urls { try? FileManager.default.removeItem(at: url) }
                }
                viewModel.statusMessage = exported ? request.successMessage : request.cancelMessage
            }
            .interactiveDismissDisabled(!request.recordsPhotoExport)
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
        .alert(L10n.text("恢复这张照片的旧调整？"), isPresented: $showingLegacyAssetEdit) {
            Button(L10n.text("恢复旧调整")) { finishLegacyAssetEditDecision(true) }
            Button(L10n.text("从原片开始"), role: .cancel) { finishLegacyAssetEditDecision(false) }
        } message: { Text(L10n.text("旧版记录只有相册标识。确认当前照片与原来的照片一致后，可恢复旧调整。")) }
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
