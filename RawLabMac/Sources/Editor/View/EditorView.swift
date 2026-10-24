import SwiftUI
import AppKit

struct EditorView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = PhotoLibrary()
    @State private var viewing = MacViewingState()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clipping = false
    @State private var histogramExpanded = true
    @State private var showFiles = true
    @State private var showsProcessingSettings = false
    @State private var selectedParameter: AdjustmentParameter? = .exposure
    @State private var viewport = PhotoViewport()
    @State private var dropTarget = false
    @State private var resetVersion = 0
    @State private var adjustmentPanel = AdjustmentPanelLayout()
    @State private var resizeStart: CGFloat?
    @State private var infoMode = PhotoInfoMode.hidden
    @State private var photoInformation: PhotoInformation?
    @State private var geometryViewState: GeometryViewState?
    private struct GeometryViewState {
        let file: URL?
        let viewport: PhotoViewport
        let fullResolution: Bool
        let panel: AdjustmentPanelLayout
    }

    var body: some View {
        let _ = localizationLocale
        GeometryReader { geometry in
            HSplitView {
                if showFiles {
                    FileBrowser(library: library, selected: model.file, open: model.open,
                                canApplySettings: model.canApplySettings, applySettings: model.confirmApplySettings)
                        .frame(minWidth: 200, idealWidth: 236, maxWidth: 300)
                        .disabled(model.exporting)
                }
                VStack(spacing: 0) {
                  workspace.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
                    .overlay(alignment: .topTrailing) {
                        if model.geometryDraft == nil {
                            FloatingHistogram(frame: viewing.holdingBefore ? model.neutral : model.result,
                                before: viewing.holdingBefore, clipping: $clipping, expanded: $histogramExpanded).padding(12)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                        Button { infoMode = infoMode.next } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).frame(width: 28, height: 28)
                            .background(.black.opacity(0.6), in: Circle())
                            .accessibilityLabel(L10n.text("照片信息")).accessibilityValue(infoMode.title)
                            .accessibilityIdentifier("photo.information")
                        if infoMode != .hidden, let photoInformation {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(photoInformation.lines(for: infoMode).enumerated()), id: \.offset) { index, line in
                                    Text(line).font(.system(size: index == 0 ? 14 : 12, weight: index == 0 ? .semibold : .regular))
                                        .lineLimit(2).truncationMode(.middle)
                                }
                            }.foregroundStyle(.white).shadow(color: .black, radius: 2, y: 1)
                                .padding(10).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                                .frame(maxWidth: min(380, max(130, geometry.size.width - (showFiles ? 300 : 0) - 300)), alignment: .leading)
                                .padding(12).allowsHitTesting(false)
                                .accessibilityElement(children: .combine)
                        }
                        }.padding(8)
                    }
                    .overlay(alignment: .top) {
                        if model.busy {
                            if reduceMotion { Rectangle().fill(.yellow).frame(height: 2) }
                            else { ProgressView().progressViewStyle(.linear).frame(height: 2).clipped() }
                        }
                    }
                    .accessibilityValue(model.busy ? L10n.text("正在显影…") : model.previewOutdated ? L10n.text("预览未更新") : L10n.text("预览已更新"))
                    .overlay(alignment: .bottom) {
                        if model.previewOutdated {
                            HStack(spacing: 8) {
                                Label(L10n.text("预览未更新"), systemImage: "exclamationmark.triangle")
                                Button(L10n.text("重试"), action: model.schedule)
                            }.font(.callout).padding(8).background(.black.opacity(0.7)).padding(8)
                        }
                    }
                    .overlay { if dropTarget { Rectangle().stroke(Color.accentColor, lineWidth: 3) } }
                    .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                        guard !model.exporting, let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            DispatchQueue.main.async { model.open(url) }
                        }
                        return true
                    }
                  if model.file != nil {
                  panelResizeHandle(available: geometry.size.height)
                      .frame(height: adjustmentPanel.collapsed ? 0 : 13).clipped()
                      .allowsHitTesting(!adjustmentPanel.collapsed).accessibilityHidden(adjustmentPanel.collapsed)
                  bottomControls
                      .frame(height: adjustmentPanel.collapsed ? 0 : (model.adjustmentNavigation.expandedGroup == nil ? 86 : adjustmentPanel.height(available: geometry.size.height)) - 13)
                      .clipped().allowsHitTesting(!adjustmentPanel.collapsed).accessibilityHidden(adjustmentPanel.collapsed)
                  }
                  Divider()
                  statusBar
                }
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .preferredColorScheme(.dark)
        .onChange(of: model.sourceRevision) { _, _ in
            viewing.sourceChanged()
            fit()
        }
        .onChange(of: model.hslTargetEnabled) { _, _ in viewing.hold(false, allowed: false) }
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
            model.cancelHSLTarget()
            if model.adjustmentNavigation.tool == .colorGrading { model.cancelAdjustmentInteraction() }
            model.saveEdits()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            model.cancelHSLTarget()
            if model.adjustmentNavigation.tool == .colorGrading { model.cancelAdjustmentInteraction() }
            model.saveEdits()
        }
        .toolbar { editorToolbar }
        .sheet(item: Binding(get: { model.adjustmentSheetInCollection ? nil : model.adjustmentSheet }, set: { model.adjustmentSheet = $0 })) { kind in
            if kind == .presets { AdjustmentPresetView(model: model) }
            else { AdjustmentTransferView(model: model, kind: kind) }
        }
        .onExitCommand { model.cancelHSLTarget(); model.cancelAdjustmentInteraction() }
        .background(MacViewingKeyboard(canHold: canHoldBefore, onHold: { viewing.hold($0, allowed: canHoldBefore) },
            onInformation: { infoMode = infoMode.next }).frame(width: 0, height: 0))
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
        .onAppear {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--sample"), args.indices.contains(index + 1) {
                model.open(URL(fileURLWithPath: args[index + 1]))
            }
        }
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

    private var bottomControls: some View {
        AdjustmentDock(model: model, selected: $selectedParameter, resetVersion: resetVersion,
            headerAccessory: AnyView(HStack(spacing: 8) {
                Button { showsProcessingSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
                }.buttonStyle(.plain).help(L10n.text("照片处理设置"))
                    .accessibilityLabel(L10n.text("照片处理设置"))
                    .accessibilityIdentifier("processing.settings")
                    .popover(isPresented: $showsProcessingSettings) { processingSettings }
                resetMenu
            }.controlSize(.small)))
            .background(Color(nsColor: .windowBackgroundColor))
            .disabled(model.file == nil || model.exporting)
    }

    private var processingSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("照片处理设置")).font(.headline)
            Text(model.selectedMasterRecipe.map { L10n.format("%@ · 大师配方", String(describing: $0.title)) } ?? model.selectedFilm?.name ?? L10n.text("中性"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("处理版本"), selection: $model.settings.processing) {
                Text(L10n.text("处理 v1（旧版）")).tag(ProcessingIdentity.legacy)
                Text(L10n.text("处理 v2")).tag(ProcessingIdentity.current)
            }.id(localizationLocale.identifier).accessibilityIdentifier("processing.version")
                .disabled(model.geometryDraft != nil)
            Picker(L10n.text("曝光基准"), selection: $model.settings.exposureMode) {
                ForEach(ExposureMode.allCases) { Text($0.title).tag($0) }
            }.id(localizationLocale.identifier)
                .disabled(RenderEngine.isRasterInput(model.file) || model.geometryDraft != nil)
            Text(RenderEngine.isRasterInput(model.file) ? "-- EV" : model.result.map { String(format: "%+.2f EV", $0.baselineEV) } ?? "-- EV")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).help(L10n.text("基础曝光偏移"))
        }.padding(18).frame(width: 320)
    }

    private func panelResizeHandle(available: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 32, height: 3)
            HStack {
                Spacer()
                Button { collapsePanel() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.buttonStyle(.plain).frame(width: 28, height: 13)
                    .help(L10n.text("收起调整栏")).accessibilityLabel(L10n.text("收起调整栏"))
            }.padding(.trailing, 12)
        }.frame(height: 13).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = adjustmentPanel.height(available: available) }
                    adjustmentPanel.resize(to: (resizeStart ?? 252) - value.translation.height, available: available)
                }.onEnded { _ in resizeStart = nil })
            .onHover { inside in (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("调整栏高度"))
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 20 : -20
                adjustmentPanel.resize(to: adjustmentPanel.height(available: available) + delta, available: available)
            }
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
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(L10n.text("显示或收起文件树")).accessibilityLabel(L10n.text("文件树"))
                .accessibilityValue(showFiles ? L10n.text("已展开") : L10n.text("已收起"))
            Button(action: model.openPanel) { Image(systemName: "folder") }
                .help(L10n.text("打开照片")).accessibilityLabel(L10n.text("打开照片")).disabled(model.exporting)
        }
        ToolbarItemGroup {
            Menu {
                Button(L10n.text("复制调整…")) { model.requestAdjustmentSheet(.copy) }.disabled(model.file == nil)
                Button(L10n.text("粘贴调整…")) { model.requestAdjustmentSheet(.paste) }.disabled(model.adjustmentClipboard == nil)
                Divider()
                Button(L10n.text("撤销"), action: model.undoAdjustment).disabled(!model.canUndoAdjustment)
                Button(L10n.text("重做"), action: model.redoAdjustment).disabled(!model.canRedoAdjustment)
                Button(L10n.text("本次会话历史…")) { model.requestAdjustmentSheet(.history) }
            } label: { Image(systemName: "ellipsis.circle") }
                .help(L10n.text("更多编辑操作")).accessibilityLabel(L10n.text("更多编辑操作"))
                .accessibilityIdentifier("adjustment.more").disabled(model.exporting)
            Button { viewing.toggle() } label: { Image(systemName: "rectangle.split.2x1").activeTint(viewing.enabled) }
                .help(L10n.text("中性显影与调整后对比")).accessibilityLabel(L10n.text("对比"))
                .accessibilityValue(viewing.enabled ? L10n.text("已开启") : L10n.text("已关闭"))
                .accessibilityIdentifier("compare.toggle").disabled(model.result == nil || !model.canComparePreview)
            Menu {
                Button(L10n.text("并排")) { viewing.select(.sideBySide) }
                Button(L10n.text("分割线")) { viewing.select(.wipe) }
                Button(L10n.text("关闭对比")) { viewing.close() }
            } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(L10n.text("对比方式")).accessibilityIdentifier("compare.mode")
                .disabled(model.result == nil || !model.canComparePreview)
            Button { infoMode = infoMode.next } label: { Image(systemName: "info.circle").activeTint(infoMode != .hidden) }
                .help(L10n.text("照片信息")).accessibilityLabel(L10n.text("照片信息")).accessibilityValue(infoMode.title)
                .disabled(model.file == nil)
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
                .help(L10n.text("缩放与显示")).accessibilityLabel(L10n.text("缩放与显示")).disabled(model.result == nil || model.geometryDraft != nil)
            Button {
                if adjustmentPanel.collapsed { adjustmentPanel.collapsed = false }
                else { collapsePanel() }
            } label: { Image(systemName: "slider.horizontal.3").activeTint(!adjustmentPanel.collapsed) }
                .help(adjustmentPanel.collapsed ? L10n.text("展开调整栏") : L10n.text("收起调整栏"))
                .accessibilityLabel(L10n.text("调整栏")).accessibilityValue(adjustmentPanel.collapsed ? L10n.text("已收起") : L10n.text("已展开"))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(L10n.text(model.batchSelection.current == nil ? "批量编辑…" : "返回选片集合")) {
                if model.batchSelection.current != nil { model.returnToBatchSelection { openWindow(id: "batch-selection") } }
                else { openWindow(id: "batch-selection") }
            }.accessibilityIdentifier("collection.open").disabled(model.exporting)
            Menu {
                // 与批量导出的格式选择同名：JPEG、16 位 PNG、DNG · 渲染型
                ForEach(ExportFormat.allCases) { format in
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
            .disabled(model.file == nil && model.batch == nil)
            .help(model.geometryDraft != nil ? L10n.text("草稿未应用，无法导出或复制设置。") : L10n.text("导出"))
        }
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
    private var canHoldBefore: Bool { !model.hslTargetActive && model.result != nil && model.neutral != nil && model.canComparePreview && !viewing.enabled }

    private var hslTargetInput: HSLTargetCanvasInput {
        let source = model.sourceRevision, axis = model.hslTargetAxis
        func current() -> Bool { model.sourceRevision == source && model.hslTargetAxis == axis }
        return HSLTargetCanvasInput(scope: "\(source)-\(axis.rawValue)",
            begin: { if current() { model.beginHSLTarget($0) } },
            change: { if current() { model.moveHSLTarget($0) } },
            end: { if current() { model.endHSLTarget() } }, cancel: { if current() { model.cancelHSLTarget() } },
            key: { if current() { model.keyHSLTarget($0) } }, reject: { if current() { model.rejectHSLTarget() } })
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
                    })
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            .accessibilityActions {
                if canHoldBefore {
                    Button(L10n.text(viewing.holdingBefore ? "返回调整后" : "查看调整前")) {
                        viewing.hold(!viewing.holdingBefore, allowed: canHoldBefore)
                    }
                }
            }
    }

    private func collapsePanel() {
        ParameterValueField.cancelPendingInputs()
        model.requestLeavingGeometryDraft { adjustmentPanel.collapsed = true }
    }

    private func geometryEditingChanged(_ editing: Bool) {
        if editing {
            viewing.holdingBefore = false
            geometryViewState = GeometryViewState(file: model.file, viewport: viewport,
                fullResolution: model.fullResolution, panel: adjustmentPanel)
            adjustmentPanel.collapsed = false
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

struct FloatingHistogram: View {
    let frame: RenderedImage?
    var before = false
    @Environment(\.locale) private var localizationLocale
    @Binding var clipping: Bool
    @Binding var expanded: Bool
    private var source: String { L10n.text(before ? "调整前" : "调整后") }
    var body: some View {
        VStack(spacing: 10) {
        let _ = localizationLocale
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).help(expanded ? L10n.text("收起直方图") : L10n.text("展开直方图"))
                    .accessibilityLabel(L10n.text("RGB 直方图") + " · " + source)
                    .accessibilityValue(source + " · " + (expanded ? L10n.text("已展开") : L10n.text("已收起")))
                    .accessibilityIdentifier("histogram.toggle")
                if expanded {
                    Spacer()
                    Toggle(isOn: $clipping) { Image(systemName: "exclamationmark.triangle") }
                        .toggleStyle(.button).buttonStyle(.borderless).tint(.yellow)
                        .help(L10n.text("显示输出高光与黑位裁切")).accessibilityLabel(L10n.text("显示裁切提示")).disabled(frame?.clipping == nil)
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .accessibilityLabel(expanded ? L10n.text("收起直方图") : L10n.text("展开直方图"))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("RGB 直方图")).font(.system(size: 12, weight: .semibold))
                    Text(source).font(.system(size: 11))
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.text("RGB 直方图") + " · " + source)
                    .accessibilityIdentifier("histogram.source")
                HistogramView(bins: frame?.histogram ?? []).frame(height: 68)
                    .accessibilityLabel(L10n.text("RGB 直方图") + " · " + source)
                    .accessibilityIdentifier("histogram.plot")
                if frame?.histogram.isEmpty != false {
                    Text(L10n.text("统计不可用")).font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("histogram.unavailable")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("高光 %@", String(describing: percent(frame?.highlights))))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.format("黑位 %@", String(describing: percent(frame?.shadows))))
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.white.opacity(0.9))
            }
        }.padding(12).frame(width: expanded ? 242 : 66)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1) }
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "--" }
}
