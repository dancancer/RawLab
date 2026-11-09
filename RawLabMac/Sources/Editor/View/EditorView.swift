import SwiftUI
import AppKit

struct EditorView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = PhotoLibrary()
    @StateObject private var photoPreviews: MacEditedPhotoPreviews

    init(model: EditorModel) {
        self.model = model
        _photoPreviews = StateObject(wrappedValue: MacEditedPhotoPreviews(editDirectory: model.editDirectory))
    }
    @StateObject private var browser = MacWorkspaceBrowserState()
    @AppStorage("workspace.files.width") private var savedLibraryWidth = Double(MacWorkspaceLayout.defaultLibraryWidth)
    @AppStorage("workspace.adjustments.width") private var savedInspectorWidth = Double(MacWorkspaceLayout.defaultInspectorWidth)
    @State private var libraryResizeWidth: CGFloat?
    @State private var inspectorResizeWidth: CGFloat?
    @State private var viewing = MacViewingState()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clipping = false
    @State private var histogramExpanded = true
    @State private var workspaceLayout = MacWorkspaceLayout()
    @State private var windowWidth: CGFloat = 1320
    @State private var showsProcessingSettings = false
    @State private var showsHistogram = false
    @State private var viewport = PhotoViewport()
    @State private var dropTarget = false
    @State private var resetVersion = 0
    @State private var infoMode = PhotoInfoMode.hidden
    @State private var photoInformation: PhotoInformation?
    @State private var geometryViewState: GeometryViewState?
    @State private var queuedQuickPreset: (preset: AdjustmentPreset, source: UUID)?
    @StateObject private var hdrDisplay=HDRDisplayState()
    private struct GeometryViewState {
        let file: URL?
        let viewport: PhotoViewport
        let fullResolution: Bool
    }
    private var showFiles: Bool { workspaceLayout.libraryPresentation(width: windowWidth) != .hidden }
    private var showInspector: Bool { workspaceLayout.showsInspector(hasPhoto: model.file != nil) }
    private var showsPhotoWorkspace: Bool { workspaceLayout.mode != .selection }

    private var editorContent: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let filePane = workspaceLayout.libraryPresentation(width: width)
            let filesWidth = MacWorkspaceLayout.libraryWidth(libraryResizeWidth ?? CGFloat(savedLibraryWidth))
            let toolsWidth = MacWorkspaceLayout.inspectorWidth(inspectorResizeWidth ?? CGFloat(savedInspectorWidth), windowWidth: width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if filePane == .pinned {
                        fileBrowser.frame(width: filesWidth)
                        MacWorkspaceDivider(width: filesWidth, limits: MacWorkspaceLayout.libraryRange, leading: true) { value, finished in
                            libraryResizeWidth = finished ? nil : value
                            if finished { savedLibraryWidth = Double(value) }
                        }
                    }
                    centerPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        if MacWorkspaceLayout.isCompact(width) { Divider() }
                        else {
                            MacWorkspaceDivider(width: toolsWidth, limits: MacWorkspaceLayout.inspectorRange, leading: false) { value, finished in
                                inspectorResizeWidth = finished ? nil : value
                                if finished { savedInspectorWidth = Double(value) }
                            }
                        }
                    }
                    if model.file != nil {
                        adjustmentInspector.frame(width: toolsWidth)
                            .frame(width: showInspector ? toolsWidth : 0, alignment: .leading)
                            .clipped().opacity(showInspector ? 1 : 0)
                            .allowsHitTesting(showInspector).accessibilityHidden(!showInspector)
                    }
                }
                .overlay(alignment: .leading) {
                    if filePane == .drawer {
                        fileBrowser.frame(width: MacWorkspaceLayout.drawerWidth)
                            .overlay(alignment: .trailing) { Divider() }
                            .shadow(color: .black.opacity(0.35), radius: 12, x: 4)
                            .accessibilityIdentifier("workspace.library.drawer")
                    }
                }
                Divider()
                statusBar
            }
            .onChange(of: width, initial: true) { old, new in
                workspaceLayout.windowResized(from: old, to: new)
                windowWidth = new
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    private var fileBrowser: some View {
        MacWorkspaceLibrary(library: library, navigation: browser, selected: model.file,
            foldersOnly: workspaceLayout.mode == .selection, open: openWorkspacePhoto,
            canApplySettings: model.canApplySettings, applySettings: model.confirmApplySettings)
            .disabled(model.exporting)
    }

    @ViewBuilder private var centerPane: some View {
        if workspaceLayout.mode == .selection {
            MacWorkspaceSelection(library: library, navigation: browser, selected: model.file,
                open: openWorkspacePhoto, canAdd: !model.exporting && !model.importing, onAdd: addToCollection,
                showTree: { if !showFiles { workspaceLayout.toggleLibrary(width: windowWidth) } })
                .disabled(model.exporting)
        } else {
            photoPane
        }
    }

    private var photoPane: some View {
        workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
            .overlay(alignment: .topLeading) {
                if infoMode != .hidden, let photoInformation {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(photoInformation.lines(for: infoMode).enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(size: index == 0 ? 14 : 12, weight: index == 0 ? .semibold : .regular))
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }.foregroundStyle(.white).shadow(color: .black, radius: 2, y: 1)
                        .padding(10).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: 360, alignment: .leading).padding(10)
                        .allowsHitTesting(false).accessibilityElement(children: .combine)
                }
            }
            .overlay(alignment: .top) {
                if model.busy || model.importing {
                    if reduceMotion { Rectangle().fill(.yellow).frame(height: 2) }
                    else { ProgressView().progressViewStyle(.linear).frame(height: 2).clipped() }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if !showInspector && model.hslTargetActive {
                        HSLTargetCanvasControls(axis: model.hslTargetAxis, onExit: exitHSLTarget).padding(8)
                    }
                    if model.previewOutdated {
                        HStack(spacing: 8) {
                            Label(L10n.text("预览未更新"), systemImage: "exclamationmark.triangle")
                            Button(L10n.text("重试"), action: model.schedule)
                        }.font(.callout).padding(8).background(.black.opacity(0.7)).padding(8)
                    }
                }
            }
            .overlay { if dropTarget { Rectangle().stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.exporting else { return false }
                let directoriesAdded = library.addDirectories(urls)
                if urls.count == 1, let url = urls.first?.standardizedFileURL.resolvingSymlinksInPath(),
                   url.isFileURL, !directoriesAdded,
                   (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    // 单文件沿用显影入口，让不支持或损坏的文件显示原有错误。
                    openWorkspacePhoto(url)
                    return true
                }
                let photos = DirectoryContents.photoURLs(from: urls)
                guard let first = photos.first else { return directoriesAdded }
                if photos.count == 1 { openWorkspacePhoto(first) }
                else { addToCollection(photos) }
                return true
            } isTargeted: { dropTarget = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("照片"))
            .accessibilityIdentifier("workspace.canvas")
            .accessibilityValue(model.busy ? L10n.text("正在显影…") : model.previewOutdated ? L10n.text("预览未更新") : L10n.text("预览已更新"))
    }

    private var observedEditor: some View {
        editorContent
        .environmentObject(photoPreviews)
        .onChange(of: model.films, initial: true) { _, films in
            photoPreviews.films = films
            photoPreviews.refresh()
        }
        .onChange(of: model.busy || model.importing || model.exporting || model.aiState.isRunning, initial: true) { _, busy in photoPreviews.isEditorBusy = busy }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in photoPreviews.refresh() }
        .onChange(of: model.adjustmentHistoryRevision) { _, _ in photoPreviews.refresh() }
        .onReceive(model.$completedEditPreview) { preview in
            guard let preview else { return }
            photoPreviews.accept(record: preview.record, image: preview.image)
        }
        .onChange(of: model.sourceRevision) { _, _ in
            photoPreviews.refresh()
            queuedQuickPreset = nil
            viewing.sourceChanged()
            fit()
            workspaceLayout.photoOpened()
        }
        .onChange(of: library.roots.map(\.id), initial: true) { _, _ in
            browser.reconcile(with: library)
        }
        .onChange(of: model.batchSelection.current) { _, current in
            if current != nil { workspaceLayout.photoOpened() }
        }
        .onChange(of: model.hslTargetEnabled) { _, _ in viewing.hold(false, allowed: false) }
        .onChange(of: model.quickPresetsVisible) { _, visible in
            if visible { workspaceLayout.setMode(.editing); workspaceLayout.showInspector() }
        }
        .onChange(of: model.geometryDraft != nil, initial: true) { _, editing in geometryEditingChanged(editing) }
        .onChange(of: model.busy) { _, _ in model.resumeResetToolIfReady() }
        .onChange(of: model.pendingGeometryPresentation) { _, _ in model.resumeResetToolIfReady() }
        .onChange(of: model.settings.geometrySettings) { _, _ in viewport.focus = CGPoint(x: 0.5, y: 0.5) }
        .task(id: model.sourceRevision) {
            photoInformation = nil
            guard let file = model.file else { return }
            let info = await Task.detached(priority: .utility) { PhotoInformation.read(file) }.value
            if !Task.isCancelled && model.file == file { photoInformation = info }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if model.quickPresetState.isPreparing { model.cancelQuickPreset() }
            model.cancelHSLTarget()
            if [.colorGrading, .toneCurve].contains(model.adjustmentNavigation.tool) { model.cancelAdjustmentInteraction() }
            model.saveEdits()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            if model.quickPresetState.isPreparing { model.cancelQuickPreset() }
            model.cancelHSLTarget()
            if [.colorGrading, .toneCurve].contains(model.adjustmentNavigation.tool) { model.cancelAdjustmentInteraction() }
            model.saveEdits()
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                editorToolbar.sharedBackgroundVisibility(.hidden)
            } else {
                editorToolbar
            }
        }
    }

    private var presentedEditor: some View {
        observedEditor
        .sheet(item: adjustmentSheetBinding, onDismiss: applyQueuedQuickPreset) { kind in
            if kind == .presets { AdjustmentPresetView(model: model, startSaving: model.adjustmentSheetStartsPresetSave) { preset in
                queuedQuickPreset = (preset, model.sourceRevision); model.adjustmentSheet = nil
            } }
            else { AdjustmentTransferView(model: model, kind: kind, preset: model.adjustmentSheetPreset) }
        }
        .onExitCommand {
            exitHSLTarget(); model.cancelAdjustmentInteraction()
        }
        .background(MacViewingKeyboard(canHold: canHoldBefore, onHold: { viewing.hold($0, allowed: canHoldBefore) },
            onInformation: { infoMode = infoMode.next }, onEscape: { workspaceLayout.dismissTransient() }).frame(width: 0, height: 0))
        .background(MacGeometryWindowGuard(model: model).frame(width: 0, height: 0))
        .sheet(isPresented: Binding(get: { model.geometryDraftDeparturePending && model.adjustmentSheet != .presets }, set: { _ in })) {
            MacGeometryDeparturePrompt(model: model)
        }
        .alert(resetConfirmationTitle, isPresented: Binding(get: { model.resetConfirmation != nil }, set: { if !$0 && model.resetConfirmation != nil { model.finishAdjustmentReset(confirm: false) } })) {
            Button(L10n.text("取消"), role: .cancel) { model.finishAdjustmentReset(confirm: false) }
            Button(L10n.text("重置"), role: .destructive) { model.finishAdjustmentReset(confirm: true); resetVersion += 1 }
        } message: { Text(resetConfirmationMessage) }
        .alert(L10n.text("无法重置调整"), isPresented: Binding(get: { model.resetBlockedMessage != nil }, set: { if !$0 { model.resetBlockedMessage = nil } })) {
            Button(L10n.text("关闭"), role: .cancel) { model.resetBlockedMessage = nil }
        } message: { Text(model.resetBlockedMessage ?? "") }
    }

    var body: some View {
        let _ = localizationLocale
        presentedEditor
        .onAppear(perform: openCommandLineSample)
        .alert(L10n.text("操作失败"), isPresented: Binding(
            get: { model.result != nil && model.error != nil && model.lookImportReport == nil },
            set: { if !$0 { model.error = nil } }
        )) { Button(L10n.text("关闭"), role: .cancel) { model.error = nil } }
        message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(
            get: { model.lookImportReport != nil },
            set: { if !$0 { model.lookImportReport = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("导入结果")).font(.headline)
                ScrollView {
                    Text(model.lookImportReport ?? "").font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("关闭")) { model.lookImportReport = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 520, height: 380)
        }
    }

    private var adjustmentSheetBinding: Binding<AdjustmentSheetKind?> {
        Binding(get: { model.adjustmentSheetInCollection ? nil : model.adjustmentSheet },
                set: { model.adjustmentSheet = $0 })
    }

    private func applyQueuedQuickPreset() {
        guard let queued = queuedQuickPreset else { return }
        queuedQuickPreset = nil
        guard queued.source == model.sourceRevision else { return }
        model.showQuickPresets(); model.applyPresetToCurrentPhoto(queued.preset)
    }

    private func openCommandLineSample() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--sample"), args.indices.contains(index + 1) {
            model.open(URL(fileURLWithPath: args[index + 1]))
        }
    }

    private var activeLookName: String {
        model.selectedMasterRecipe.map { L10n.format("%@ · 大师配方", String(describing: $0.title)) }
            ?? model.selectedFilm?.name ?? L10n.text("中性")
    }

    private var adjustmentInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(L10n.text("调整栏")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                resetMenu
                Button(action: toggleInspector) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).help(L10n.text("收起调整栏"))
                    .accessibilityLabel(L10n.text("收起调整栏"))
            }.padding(.horizontal, 12).frame(minHeight: 34)
            Divider()
            histogram
            Divider()
            AdjustmentDock(model: model, resetVersion: resetVersion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(model.exporting || model.importing)
            if model.geometryDraft == nil {
                Divider()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("当前外观")).foregroundStyle(.secondary)
                        Text(activeLookName).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        .help(activeLookName)
                    Button { showsProcessingSettings.toggle() } label: {
                        Label(L10n.text("照片处理设置"), systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }.help(L10n.text("照片处理设置")).accessibilityLabel(L10n.text("照片处理设置"))
                        .accessibilityIdentifier("processing.settings")
                        .popover(isPresented: $showsProcessingSettings) { processingSettings }
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 7)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("调整栏")).accessibilityIdentifier("workspace.inspector")
    }

    private var histogram: some View {
        WorkspaceHistogram(frame: viewing.holdingBefore ? model.neutral : model.result,
            before: viewing.holdingBefore, clipping: $clipping, expanded: $histogramExpanded,
            hdrDisplay: hdrDisplay, clippingEnabled: model.geometryDraft == nil)
    }

    private var processingSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("照片处理设置")).font(.headline)
            if model.sourceIsHDR || model.sourceSupportsCameraHDR {
                Toggle(L10n.text("HDR 编辑"),isOn:Binding(get:{ model.settings.isHDREditing },set:model.setHDREditing))
                    .disabled(!model.canExport).accessibilityIdentifier("hdr.editMode")
            }
            if model.settings.isHDREditing {
                HDRMonitoringControls(state:hdrDisplay)
                HDRRenditionControls(settings: Binding(
                    get: { model.settings.hdr?.renditionSettings ?? HDRRenditionSettings() },
                    set: { if model.settings.isHDREditing { model.settings.hdr?.renditionSettings = $0 } }
                ), onEditingChanged: model.setInteracting, onCancelled: model.cancelAdjustmentInteraction)
                    .id(model.sourceRevision)
                    .disabled(model.geometryDraft != nil || model.exporting)
                if model.sourceIsBayerHDR, let hdr = model.settings.hdr {
                    HDRCameraDevelopmentControls(settings: hdr.cameraDevelopmentSettings,
                        supportsBayerDevelopment: model.rawHDRSource?.supportsBayerDevelopment == true,
                        apply: model.applyHDRCameraDevelopment,
                        onResourceRestored: { model.schedule(forceExact: true) })
                        .id(model.sourceRevision).disabled(!model.canApplyHDRCameraDevelopment)
                }
            } else {
            Text(activeLookName)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("处理版本"), selection: $model.settings.processing) {
                Text(L10n.text("处理 v1（旧版）")).tag(ProcessingIdentity.legacy)
                Text(L10n.text("处理 v2")).tag(ProcessingIdentity.c5)
                Text(L10n.text("处理 v3")).tag(ProcessingIdentity.current)
            }.id(localizationLocale.identifier).accessibilityIdentifier("processing.version")
                .disabled(model.geometryDraft != nil)
            if let status = model.processingMigrationStatus {
                Text(L10n.text(status)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("processing.migration.status")
            }
            if model.processingMigrationReceipt?.status == .migrated {
                Button(L10n.text("回到迁移前"), action: model.rollbackProcessingMigration)
                    .disabled(!model.canRollbackProcessingMigration)
                    .accessibilityIdentifier("processing.migration.rollback")
            }
            if RenderEngine.isX3fInput(model.file) {
                Picker(L10n.text("X3F 显影"), selection: Binding(get: { model.settings.x3fMode }, set: model.selectX3fMode)) {
                    ForEach(X3fMode.allCases) { mode in
                        Text(mode.title).tag(mode).disabled(mode == .normal && !RenderEngine.x3fAvailable)
                    }
                }.accessibilityIdentifier("x3f.mode").disabled(model.geometryDraft != nil)
                Text(L10n.text(model.settings.x3fMode == .normal ?
                    "以文件保存的显影为基准，白平衡作相对调整。" : "保留旧版的特殊色彩。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker(L10n.text("曝光基准"), selection: $model.settings.exposureMode) {
                ForEach(ExposureMode.allCases) { Text($0.title).tag($0) }
            }.id(localizationLocale.identifier)
                .disabled(RenderEngine.isRasterInput(model.file) || model.geometryDraft != nil ||
                    (RenderEngine.isX3fInput(model.file) && model.settings.x3fMode == .normal))
            Text(RenderEngine.isRasterInput(model.file) ? "-- EV" : model.result.map { String(format: "%+.2f EV", $0.baselineEV) } ?? "-- EV")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).help(L10n.text("基础曝光偏移"))
            }
        }.padding(18).frame(width: 320)
    }

    @ViewBuilder private var workspace: some View {
        if let result = model.result {
            GeometryReader { area in
                let comparing = viewing.enabled && model.canComparePreview && model.neutral != nil
                let horizontal = MacViewingState.horizontalPanes(in: area.size)
                let paired = comparing && viewing.preferredMode == .sideBySide
                let pane = paired ? CGSize(width: horizontal ? (area.size.width - 1) / 2 : area.size.width,
                                           height: horizontal ? area.size.height : (area.size.height - 1) / 2) : area.size
                let demand = viewport.previewLongEdge(canvas: pane, displayScale: displayScale,
                    source: CGSize(width: result.nativeWidth ?? result.image.width, height: result.nativeHeight ?? result.image.height),
                    margin: viewing.margins ? 12 : 0)
                Group {
                    if paired, let before = model.neutral {
                        if horizontal {
                            HStack(spacing: 1) { imagePane(before, title: L10n.text("调整前"), showMask: false); imagePane(result, title: L10n.text("调整后"), showMask: clipping) }
                        } else {
                            VStack(spacing: 1) { imagePane(before, title: L10n.text("调整前"), showMask: false); imagePane(result, title: L10n.text("调整后"), showMask: clipping) }
                        }
                    } else if comparing, viewing.preferredMode == .wipe {
                        imagePane(result, title: L10n.text("调整前"), showMask: false, wipe: true)
                    } else {
                        imagePane(viewing.holdingBefore ? model.neutral ?? result : result,
                            title: viewing.holdingBefore ? L10n.text("调整前") : L10n.text("调整后"),
                            showMask: clipping && !viewing.holdingBefore && model.geometryDraft == nil)
                    }
                }.onChange(of: demand, initial: true) { _, value in model.updatePreviewLongEdge(value) }
            }
        } else {
            VStack(spacing: 16) {
                if model.busy {
                    ProgressView().controlSize(.regular)
                    Text(model.file?.lastPathComponent ?? L10n.text("照片")).font(.headline).lineLimit(1)
                } else if model.aiState.isRunning {
                    ProgressView().controlSize(.regular)
                    Text(model.aiState.progressTitle).font(.headline)
                    Button(L10n.text("取消"), action: model.cancelAIDenoise)
                        .accessibilityIdentifier("editor.ai.cancel")
                } else if model.file != nil && aiNeedsRetry {
                    Image(systemName: model.aiState == .cancelled ? "xmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(L10n.text(model.aiState == .cancelled ? "AI 降噪已取消。" : "AI 降噪失败")).font(.headline)
                    if case .failed(let message) = model.aiState {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 420)
                    }
                    HStack {
                        Button(L10n.text("重试"), action: model.requestAIDenoise)
                            .disabled(!model.canStartAI)
                            .accessibilityIdentifier("editor.ai.retry")
                        Button(L10n.text("关闭 AI 降噪")) { model.setAIEnabled(false) }
                            .accessibilityIdentifier("editor.ai.disable")
                    }
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.yellow)
                    Text(L10n.text("操作失败")).font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    HStack {
                        Button(L10n.text("重试"), action: model.schedule)
                        Button(L10n.text("打开照片"), action: model.openPanel)
                    }
                } else {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
                    Button(action: model.openPanel) { Label(L10n.text("打开照片"), systemImage: "folder") }.controlSize(.large)
                        .accessibilityIdentifier("editor.empty.openRAW")
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var aiNeedsRetry: Bool {
        switch model.aiState {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(model.file?.lastPathComponent ?? L10n.text("未打开照片")).lineLimit(1).truncationMode(.middle)
                .help(model.file?.path ?? L10n.text("未打开照片"))
            Spacer(minLength: 8)
            if let failure = model.saveError {
                Button {
                    if model.geometryDraft != nil { _ = model.applyGeometryDraft() }
                    else { _ = model.saveEdits() }
                } label: { Label(L10n.text("调整未保存 · 重试"), systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.plain).foregroundStyle(.yellow).help(failure)
            } else if !model.saveStatus.isEmpty {
                Label(model.saveStatus, systemImage: "checkmark").foregroundStyle(.secondary)
            }
            if model.batch?.job.interrupted == true {
                Button(L10n.text("继续上次批量任务")) { openWindow(id: "batch-export") }
            }
            if model.busy || model.exporting {
                ProgressView().controlSize(.mini)
                Text(model.exporting ? L10n.text("正在导出…") : L10n.text("正在显影…"))
            } else {
                Text(model.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 30).background(.bar)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspaceLayout.toggleLibrary(width: windowWidth) } label: { Image(systemName: "sidebar.left").activeTint(showFiles) }
                .help(L10n.text("显示或收起文件树")).accessibilityLabel(L10n.text("文件树"))
                .accessibilityValue(showFiles ? L10n.text("已展开") : L10n.text("已收起"))
                .accessibilityIdentifier("workspace.library.toggle").disabled(workspaceLayout.mode == .preview)
            Button(action: model.openPanel) { Image(systemName: "folder") }
                .help(L10n.text("打开照片")).accessibilityLabel(L10n.text("打开照片")).disabled(model.exporting)
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {
                ForEach(MacWorkspaceMode.allCases, id: \.self) { mode in workspaceModeButton(mode) }
            }
                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("工作区"))
        }
        ToolbarItemGroup {
            Menu {
                Button(L10n.text("复制调整…")) { model.requestAdjustmentSheet(.copy) }.disabled(model.file == nil)
                Button(L10n.text("粘贴调整…")) { model.requestAdjustmentSheet(.paste) }.disabled(model.adjustmentClipboard == nil)
                Divider()
                Button(L10n.text("撤销"), action: model.undoAdjustment).disabled(!model.canUndoAdjustment)
                Button(L10n.text("重做"), action: model.redoAdjustment).disabled(!model.canRedoAdjustment)
                Button(L10n.text("本次会话历史…")) { model.requestAdjustmentSheet(.history) }
                Divider()
                Button(L10n.text("直方图")) {
                    if showInspector { histogramExpanded = true }
                    else { showsHistogram = true }
                }.disabled(model.result == nil || !showsPhotoWorkspace)
                Button(L10n.text(model.batchSelection.current == nil ? "批量编辑…" : "返回选片集合"), action: openCollection)
                    .accessibilityIdentifier("collection.open")
            } label: { Image(systemName: "ellipsis.circle") }
                .help(L10n.text("更多编辑操作")).accessibilityLabel(L10n.text("更多编辑操作"))
                .accessibilityIdentifier("adjustment.more").disabled(model.exporting)
                .popover(isPresented: $showsHistogram) {
                    WorkspaceHistogram(frame: viewing.holdingBefore ? model.neutral : model.result,
                        before: viewing.holdingBefore, clipping: $clipping, expanded: .constant(true),
                        hdrDisplay: hdrDisplay, collapsible: false, clippingEnabled: model.geometryDraft == nil)
                        .frame(width: 286)
                }
            Button { viewing.toggle() } label: { Image(systemName: "rectangle.split.2x1").activeTint(viewing.enabled) }
                .help(L10n.text("中性显影与调整后对比")).accessibilityLabel(L10n.text("对比"))
                .accessibilityValue(viewing.enabled ? L10n.text("已开启") : L10n.text("已关闭"))
                .accessibilityIdentifier("compare.toggle").disabled(model.result == nil || !model.canComparePreview || !showsPhotoWorkspace)
            Menu {
                Button(L10n.text("并排")) { viewing.select(.sideBySide) }
                Button(L10n.text("分割线")) { viewing.select(.wipe) }
                Button(L10n.text("关闭对比")) { viewing.close() }
            } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(L10n.text("对比方式")).accessibilityIdentifier("compare.mode")
                .disabled(model.result == nil || !model.canComparePreview || !showsPhotoWorkspace)
            Button { infoMode = infoMode.next } label: { Image(systemName: "info.circle").activeTint(infoMode != .hidden) }
                .help(L10n.text("照片信息")).accessibilityLabel(L10n.text("照片信息")).accessibilityValue(infoMode.title)
                .accessibilityIdentifier("photo.information")
                .disabled(model.file == nil || !showsPhotoWorkspace)
            Menu {
                Button(L10n.text("适合窗口"), action: fit).keyboardShortcut("0")
                Button(L10n.text("实际像素 · 100%")) {
                    viewport.actualPixels(); viewport.focus = CGPoint(x: 0.5, y: 0.5)
                    if !model.fullResolution { model.fullResolution = true }
                }.keyboardShortcut("1")
                Divider()
                Button(L10n.text("放大")) { zoom(1.25) }
                Button(L10n.text("缩小")) { zoom(1 / 1.25) }
                Divider()
                Toggle(L10n.text("照片四周留白"), isOn: $viewing.margins)
            } label: { Image(systemName: "magnifyingglass") }
                .help(L10n.text("缩放与显示")).accessibilityLabel(L10n.text("缩放与显示"))
                .disabled(model.result == nil || model.geometryDraft != nil || !showsPhotoWorkspace)
            Button(action: toggleInspector) { Image(systemName: "sidebar.right").activeTint(showInspector) }
                .help(showInspector ? L10n.text("收起调整栏") : L10n.text("展开调整栏"))
                .accessibilityLabel(L10n.text("调整栏")).accessibilityValue(showInspector ? L10n.text("已展开") : L10n.text("已收起"))
                .accessibilityIdentifier("workspace.inspector.toggle")
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.file == nil || workspaceLayout.mode != .editing)
            Menu {
                // 与批量导出的格式选择同名：JPEG、16 位 PNG、DNG · 渲染型
                ForEach(ExportFormat.available(isHDR:model.settings.isHDREditing)) { format in
                    Button(format.title + "…") { model.export(format: format) }
                        .disabled(!model.canExport)
                }
                Divider()
                Button(L10n.text("使用当前调整批量导出…")) {
                    if model.prepareBatch() { openWindow(id: "batch-export") }
                }.disabled(!model.canExport)
                if model.batch != nil {
                    Button(L10n.text("查看批量任务…")) { openWindow(id: "batch-export") }
                }
            } label: { Label(L10n.text("导出"), systemImage: "square.and.arrow.up") }
            .disabled((model.file == nil && model.batch == nil) || !showsPhotoWorkspace)
            .help(model.geometryDraft != nil ? L10n.text("草稿未应用，无法导出或复制设置。") : L10n.text("导出"))
        }
    }

    private func workspaceModeButton(_ mode: MacWorkspaceMode) -> some View {
        let title: String
        let symbol: String
        switch mode {
        case .editing: title = L10n.text("编辑"); symbol = "slider.horizontal.3"
        case .selection: title = L10n.text("选片"); symbol = "square.grid.2x2"
        case .preview: title = L10n.text("纯预览"); symbol = "arrow.up.left.and.arrow.down.right"
        }
        let active = workspaceLayout.mode == mode
        return Button { switchWorkspace(to: mode) } label: {
            HStack(spacing: 4) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 12, weight: active ? .semibold : .regular)).fixedSize()
                .padding(.horizontal, 8).frame(minHeight: 25)
                .background(active ? Color.primary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
            .accessibilityLabel(title).accessibilityIdentifier("workspace.mode.\(mode.rawValue)")
            .accessibilityAddTraits(active ? .isSelected : [])
            .disabled(model.exporting || model.importing || (mode == .preview && model.result == nil))
    }

    private func switchWorkspace(to mode: MacWorkspaceMode) {
        guard workspaceLayout.mode != mode else { return }
        let switchMode = {
            if [.colorGrading, .toneCurve].contains(model.adjustmentNavigation.tool) {
                model.cancelAdjustmentInteraction()
            }
            exitHSLTarget()
            viewing.hold(false, allowed: false)
            workspaceLayout.setMode(mode)
        }
        if model.geometryDraft != nil { model.requestLeavingGeometryDraft(switchMode) }
        else if ParameterValueField.resolvePendingInputs() { switchMode() }
    }

    private func openWorkspacePhoto(_ url: URL) {
        model.open(url)
        if model.file?.standardizedFileURL == url.standardizedFileURL, !model.geometryDraftDeparturePending {
            workspaceLayout.photoOpened()
        }
    }

    private func addToCollection(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.prepareCollectionSource {
            let accepted = model.addCollectionPhotos(urls, selectExisting: true)
            browser.removeSelection(accepted)
            openWindow(id: "batch-selection")
        }
    }

    private func openCollection() {
        if model.batchSelection.current != nil { model.returnToBatchSelection { openWindow(id: "batch-selection") } }
        else { openWindow(id: "batch-selection") }
    }

    private var resetMenu: some View {
        Menu {
            let tool = model.adjustmentNavigation.tool
            if tool == .colorGrading {
                resetButton(.gradingZone(model.adjustmentNavigation.selectedGradingZone), title: L10n.text("重置当前分区"))
                resetButton(.allGrading, title: L10n.text("重置颜色分级"))
            } else if tool == .hsl {
                resetButton(.hslColor(model.adjustmentNavigation.selectedHSLChannel),
                    title: L10n.format("重置当前颜色（%@）", L10n.text(HSLSettings.channelNames[model.adjustmentNavigation.selectedHSLChannel])))
                resetButton(.hslAll, title: L10n.text("重置全部 HSL…"))
            } else {
                resetButton(.tool(tool), title: L10n.format("重置%@", tool.title))
            }
            resetButton(.group(tool.group), title: L10n.format("重置%@组…", tool.group.title))
            resetButton(.all, title: L10n.text("重置全部调整…"))
        } label: { Image(systemName: "arrow.counterclockwise") }
            .menuStyle(.borderlessButton).fixedSize().help(L10n.text("重置调整"))
            .accessibilityLabel(L10n.text("重置调整")).accessibilityIdentifier("editor.reset.menu")
            .disabled(model.busy || model.exporting || model.geometryDraftDeparturePending || model.resetReturnTool != nil)
    }

    private func resetButton(_ scope: EditorResetScope, title: String) -> some View {
        Button(title) { model.requestAdjustmentReset(scope) }
            .disabled(!model.isAdjustmentModified(scope))
    }

    private var resetConfirmationTitle: String {
        switch model.resetConfirmationScope {
        case .all: return L10n.text("重置全部调整？")
        case .group(let group): return L10n.format("重置%@组？", group.title)
        case .allGrading, .tool(.colorGrading): return L10n.text("重置颜色分级")
        case .hslAll, .tool(.hsl): return L10n.text("重置全部 HSL？")
        default: return L10n.text("重置调整")
        }
    }

    private var resetConfirmationMessage: String {
        var message: String
        switch model.resetConfirmationScope {
        case .all: message = L10n.text("恢复当前照片的全部调整，不改写原始照片。")
        case .allGrading, .tool(.colorGrading): message = L10n.text("恢复阴影、中间调和高光的颜色分级默认值？")
        case .hslAll, .tool(.hsl): message = L10n.text("八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。")
        case .group(let group): message = L10n.format("此操作只恢复%@组内的调整，其他分组保持不变。", group.title)
        default: message = ""
        }
        if model.resetConfirmationScope != .all, let prepared = model.resetConfirmation {
            let conversions = model.resetConversions(prepared)
            if !conversions.isEmpty { message += "\n" + L10n.format("将以下项目转为独立调整，以保留其他分组的当前效果：%@", conversions.joined(separator: "、")) }
        }
        return message
    }

    private func fit() {
        viewing.holdingBefore = false; viewport.fit()
        if model.fullResolution { model.fullResolution = false }
    }
    private func zoom(_ multiplier: CGFloat) {
        viewing.holdingBefore = false; viewport.zoom(by: multiplier)
    }
    private func toggleActualPixels() {
        viewing.holdingBefore = false
        viewport.toggleActualPixels()
        viewport.focus = CGPoint(x: 0.5, y: 0.5)
        if model.fullResolution != viewport.pixelMode { model.fullResolution = viewport.pixelMode }
    }
    private var canHoldBefore: Bool { showsPhotoWorkspace && !model.hslTargetActive && model.result != nil && model.neutral != nil && model.canComparePreview && !viewing.enabled }

    private var hslTargetInput: HSLTargetCanvasInput {
        let source = model.sourceRevision, axis = model.hslTargetAxis, hdr = model.settings.isHDREditing
        func current() -> Bool { model.sourceRevision == source && model.hslTargetAxis == axis && model.settings.isHDREditing == hdr }
        return HSLTargetCanvasInput(scope: "\(source)-\(axis.rawValue)-\(hdr)",
            begin: { if current() { model.beginHSLTarget($0) } },
            change: { if current() { model.moveHSLTarget($0) } },
            end: { if current() { model.endHSLTarget() } }, cancel: { if current() { model.cancelHSLTarget() } },
            key: { if current() { model.keyHSLTarget($0) } }, reject: { if current() { model.rejectHSLTarget() } },
            exit: exitHSLTarget)
    }

    private func imagePane(_ frame: RenderedImage, title: String, showMask: Bool, wipe: Bool = false) -> some View {
        PhotoCanvas(frame: frame, viewport: $viewport, sourceWidth: model.result?.nativeWidth ?? frame.image.width,
                    clipping: showMask && !model.hslTargetActive, margins: viewing.margins, beforeFrame: wipe ? model.neutral : nil,
                    split: wipe ? $viewing.split : nil,
                    comparisonLabel: (viewing.enabled && model.canComparePreview) || viewing.holdingBefore ? title : nil,
                    hslTarget: model.hslTargetActive && model.result?.image === frame.image ? hslTargetInput : nil,
                    hslTargetPoint: model.hslTargetPoint,
                    canHold: canHoldBefore, onHold: { viewing.hold($0, allowed: canHoldBefore) }, onDoubleClick: {
                        if model.geometryDraft == nil { toggleActualPixels() }
                    }, sourceHeight: model.result?.nativeHeight,
                    cropSettings: model.geometryDraftPreviewReady ? model.geometryDraft?.geometry : nil,
                    pendingGeometry: model.geometryDraft == nil ? model.pendingGeometryPresentation : nil,
                    cropAspectRatio: model.cropAspectRatio, cropGrid: model.cropGridEnabled,
                    onCropChange: model.geometryCropInputEnabled ? { geometry in model.updateGeometryDraft { $0 = geometry } } : nil,
                    onCropEditingChanged: model.geometryCropInputEnabled ? model.setGeometryCropInteracting : nil,
                    prepareCropInteraction: { before in
                        ParameterValueField.commitPendingInputs() && model.geometryDraftSettings == before
                    },hdrDisplay:hdrDisplay)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            .accessibilityActions {
                if canHoldBefore {
                    Button(L10n.text(viewing.holdingBefore ? "返回调整后" : "查看调整前")) {
                        viewing.hold(!viewing.holdingBefore, allowed: canHoldBefore)
                    }
                }
            }
    }

    private func exitHSLTarget() {
        model.cancelHSLTarget(); model.hslTargetEnabled = false
    }

    private func toggleInspector() {
        if showInspector {
            ParameterValueField.cancelPendingInputs()
            model.requestLeavingGeometryDraft {
                model.closeQuickPresets()
                workspaceLayout.toggleInspector()
            }
        } else {
            workspaceLayout.showInspector()
        }
    }

    private func geometryEditingChanged(_ editing: Bool) {
        if editing {
            viewing.holdingBefore = false
            geometryViewState = GeometryViewState(file: model.file, viewport: viewport,
                fullResolution: model.fullResolution)
            workspaceLayout.setMode(.editing)
            workspaceLayout.showInspector()
            fit()
        } else if let previous = geometryViewState {
            geometryViewState = nil
            if previous.file == model.file {
                viewport = previous.viewport
                if model.fullResolution != previous.fullResolution { model.fullResolution = previous.fullResolution }
            } else { fit() }
        }
    }
}

// ----------------------------------------------------------------------------
//  工具栏开关的开启状态：macOS 26 的工具栏不理会 .tint，开启时直接把图标染成黄色
// ----------------------------------------------------------------------------
private extension View {
    @ViewBuilder func activeTint(_ active: Bool) -> some View {
        if active { foregroundStyle(Color.yellow) } else { self }
    }
}
