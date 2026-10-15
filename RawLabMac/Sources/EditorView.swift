import SwiftUI
import AppKit

struct EditorView: View {
    @Environment(\.locale) private var localizationLocale
    @ObservedObject var model: EditorModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = PhotoLibrary()
    @State private var compare = true
    @State private var clipping = false
    @State private var histogramExpanded = true
    @State private var showFiles = true
    @State private var selectedParameter: AdjustmentParameter? = .exposure
    @State private var viewport = PhotoViewport()
    @State private var pan = CGSize.zero
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
        let pan: CGSize
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
                            FloatingHistogram(frame: model.result, clipping: $clipping, expanded: $histogramExpanded).padding(12)
                        }
                    }
                    .overlay(alignment: .topLeading) {
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
                  panelResizeHandle(available: geometry.size.height)
                      .frame(height: adjustmentPanel.collapsed ? 0 : 13).clipped()
                      .allowsHitTesting(!adjustmentPanel.collapsed).accessibilityHidden(adjustmentPanel.collapsed)
                  bottomControls
                      .frame(height: adjustmentPanel.collapsed ? 0 : adjustmentPanel.height(available: geometry.size.height) - 13)
                      .clipped().allowsHitTesting(!adjustmentPanel.collapsed).accessibilityHidden(adjustmentPanel.collapsed)
                  Divider()
                  statusBar
                }
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .preferredColorScheme(.dark)
        .onChange(of: model.file) { _, _ in fit() }
        .onChange(of: model.geometryDraft != nil, initial: true) { _, editing in geometryEditingChanged(editing) }
        .onChange(of: model.geometryDraftTab) { _, tab in
            if geometryViewState != nil { adjustmentPanel.selectHeight(tab == .lens ? 330 : 252) }
        }
        .onChange(of: model.settings.geometrySettings) { _, _ in pan = .zero }
        .task(id: model.file) {
            photoInformation = nil
            guard let file = model.file else { return }
            let info = await Task.detached(priority: .utility) { PhotoInformation.read(file) }.value
            if !Task.isCancelled && model.file == file { photoInformation = info }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveEdits() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.saveEdits() }
        .toolbar { editorToolbar }
        .background(MacGeometryWindowGuard(model: model).frame(width: 0, height: 0))
        .sheet(isPresented: Binding(get: { model.geometryDraftDeparturePending }, set: { _ in })) {
            MacGeometryDeparturePrompt(model: model)
        }
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
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(model.selectedMasterRecipe.map { L10n.format("%@ · 大师配方", String(describing: $0.name)) } ?? model.selectedFilm?.name ?? L10n.text("中性")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                Spacer(minLength: 8)
                Picker(L10n.text("曝光基准"), selection: $model.settings.exposureMode) {
                    ForEach(ExposureMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 210)
                    .id(localizationLocale.identifier)
                    .help(L10n.text("曝光基准")).accessibilityLabel(L10n.text("曝光基准"))
                Text(model.result.map { String(format: "%+.2f EV", $0.baselineEV) } ?? "-- EV")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 66)
                    .help(L10n.text("基础曝光偏移"))
                Menu {
                    Button(L10n.text("重置全部调整")) { reset() }
                    Divider()
                    ForEach(AdjustmentGroup.allCases) { group in
                        Button(L10n.format("重置%@", String(describing: group.title))) { reset(group) }.disabled(model.settings.isDefault(group))
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.text("重置调整")).accessibilityLabel(L10n.text("重置调整"))
                    .disabled(model.settings.isDefault)
            }.padding(.horizontal, 16).font(.system(size: 11))
                .frame(height: model.geometryDraft == nil ? 31 : 0).clipped().controlSize(.small)
                .allowsHitTesting(model.geometryDraft == nil).accessibilityHidden(model.geometryDraft != nil)
            AdjustmentDock(model: model, selected: $selectedParameter, resetVersion: resetVersion,
                           onPreferredHeight: { adjustmentPanel.selectHeight($0) })
        }.background(Color(nsColor: .windowBackgroundColor))
            .disabled(model.file == nil || model.exporting)
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
            HStack(spacing: 1) {
                if compare, model.geometryDraft == nil, let base = model.neutral { imagePane(base, title: L10n.text("中性显影"), showMask: false) }
                imagePane(result, title: model.selectedMasterRecipe?.name ?? model.selectedFilm?.name ?? L10n.text("调整后"), showMask: clipping && model.geometryDraft == nil)
            }
        } else {
            VStack(spacing: 16) {
                if model.busy {
                    ProgressView().controlSize(.regular)
                    Text(model.file?.lastPathComponent ?? L10n.text("RAW 照片")).font(.headline).lineLimit(1)
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.yellow)
                    Text(L10n.text("操作失败")).font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    HStack {
                        Button(L10n.text("重试"), action: model.schedule)
                        Button(L10n.text("打开其他 RAW…"), action: model.openPanel)
                    }
                } else {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
                    Button(action: model.openPanel) { Label(L10n.text("打开 RAW…"), systemImage: "folder") }.controlSize(.large)
                        .accessibilityIdentifier("editor.empty.openRAW")
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .help(L10n.text("打开 RAW")).accessibilityLabel(L10n.text("打开 RAW")).disabled(model.exporting)
        }
        ToolbarItemGroup {
            Button { compare.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                .tint(compare ? .yellow : nil)
                .help(L10n.text("中性显影与调整后对比")).accessibilityLabel(L10n.text("对比"))
                .accessibilityValue(compare ? L10n.text("已开启") : L10n.text("已关闭")).disabled(model.result == nil || model.geometryDraft != nil)
            Button {
                if NSApp.currentEvent?.type == .keyDown, NSApp.keyWindow?.firstResponder is NSTextView { return }
                infoMode = infoMode.next
            } label: { Image(systemName: "info.circle") }
                .tint(infoMode == .hidden ? nil : .yellow)
                .help(L10n.text("照片信息")).accessibilityLabel(L10n.text("照片信息")).accessibilityValue(infoMode.title)
                .keyboardShortcut("i", modifiers: []).disabled(model.file == nil)
            Menu {
                Button(L10n.text("适合窗口"), action: fit).keyboardShortcut("0")
                Button(L10n.text("实际像素 · 100%")) {
                    viewport.actualPixels(); pan = .zero
                    if !model.fullResolution { model.fullResolution = true }
                }.keyboardShortcut("1")
                Divider()
                Button(L10n.text("放大")) { zoom(1.25) }
                Button(L10n.text("缩小")) { zoom(1 / 1.25) }
            } label: { Image(systemName: "magnifyingglass") }
                .help(L10n.text("缩放")).accessibilityLabel(L10n.text("缩放")).disabled(model.result == nil || model.geometryDraft != nil)
            Button {
                if adjustmentPanel.collapsed { adjustmentPanel.collapsed = false }
                else { collapsePanel() }
            } label: { Image(systemName: "slider.horizontal.3") }
                .tint(adjustmentPanel.collapsed ? nil : .yellow)
                .help(adjustmentPanel.collapsed ? L10n.text("展开调整栏") : L10n.text("收起调整栏"))
                .accessibilityLabel(L10n.text("调整栏")).accessibilityValue(adjustmentPanel.collapsed ? L10n.text("已收起") : L10n.text("已展开"))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Menu {
                Button("JPEG…") { model.export(png: false) }
                    .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm || model.missingMasterRecipe || model.geometryDraft != nil)
                Button(L10n.text("PNG · 16-bit…")) { model.export(png: true) }
                    .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm || model.missingMasterRecipe || model.geometryDraft != nil)
                Button(L10n.text("导出渲染型 DNG…")) { model.export(format: .renderedDNG) }
                    .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm || model.missingMasterRecipe || model.geometryDraft != nil)
                Divider()
                Button(L10n.text("使用当前调整批量导出…")) {
                    if model.prepareBatch() { openWindow(id: "batch-export") }
                }.disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm || model.missingMasterRecipe || model.geometryDraft != nil)
                if model.batch != nil {
                    Button(L10n.text("查看批量任务…")) { openWindow(id: "batch-export") }
                }
            } label: { Label(L10n.text("导出"), systemImage: "square.and.arrow.up") }
            .disabled(model.file == nil && model.batch == nil)
            .help(model.geometryDraft != nil ? L10n.text("草稿未应用，无法导出或复制设置。") : L10n.text("导出"))
        }
    }

    private func reset(_ group: AdjustmentGroup? = nil) {
        guard model.geometryDraft == nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let group { model.settings.reset(group) } else { model.settings.resetAll() }
        resetVersion += 1
    }
    private func fit() {
        viewport.fit(); pan = .zero
        if model.fullResolution { model.fullResolution = false }
    }
    private func zoom(_ multiplier: CGFloat) {
        viewport.zoom(by: multiplier)
    }
    private func toggleActualPixels() {
        viewport.toggleActualPixels()
        pan = .zero
        if model.fullResolution != viewport.pixelMode { model.fullResolution = viewport.pixelMode }
    }
    private func imagePane(_ frame: RenderedImage, title: String, showMask: Bool) -> some View {
        PhotoCanvas(frame: frame, viewport: viewport, sourceWidth: model.result?.nativeWidth ?? model.neutral?.image.width ?? frame.image.width,
                    pan: $pan, clipping: showMask, sourceHeight: model.result?.nativeHeight ?? model.neutral?.image.height,
                    onPreviewSizeChange: model.updatePreviewLongEdge,
                    cropSettings: model.geometryDraftPreviewReady ? model.geometryDraft?.geometry : nil,
                    cropAspectRatio: model.cropAspectRatio, cropGrid: model.cropGridEnabled,
                    onCropChange: model.geometryDraftTab == .crop ? { geometry in model.updateGeometryDraft { $0 = geometry } } : nil,
                    onCropEditingChanged: model.geometryDraftTab == .crop ? model.setGeometryCropInteracting : nil)
            .simultaneousGesture(TapGesture(count: 2).onEnded { if model.geometryDraft == nil { toggleActualPixels() } })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .overlay(alignment: .bottomLeading) {
                if compare && model.geometryDraft == nil {
                    Text(title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4)).padding(10)
                        .allowsHitTesting(false)
                }
            }
    }

    private func collapsePanel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.requestLeavingGeometryDraft { adjustmentPanel.collapsed = true }
    }

    private func geometryEditingChanged(_ editing: Bool) {
        if editing {
            geometryViewState = GeometryViewState(file: model.file, viewport: viewport, pan: pan,
                fullResolution: model.fullResolution, panel: adjustmentPanel)
            adjustmentPanel.collapsed = false
            adjustmentPanel.selectHeight(model.geometryDraftTab == .lens ? 330 : 252)
            fit()
        } else if let previous = geometryViewState {
            geometryViewState = nil
            let requestedCollapse = adjustmentPanel.collapsed
            adjustmentPanel = previous.panel
            if requestedCollapse { adjustmentPanel.collapsed = true }
            if previous.file == model.file {
                viewport = previous.viewport; pan = previous.pan
                if model.fullResolution != previous.fullResolution { model.fullResolution = previous.fullResolution }
            } else { fit() }
        }
    }
}

private struct FloatingHistogram: View {
    let frame: RenderedImage?
    @Environment(\.locale) private var localizationLocale
    @Binding var clipping: Bool
    @Binding var expanded: Bool
    var body: some View {
        VStack(spacing: 10) {
        let _ = localizationLocale
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).help(expanded ? L10n.text("收起直方图") : L10n.text("展开直方图"))
                    .accessibilityLabel(L10n.text("直方图"))
                    .accessibilityValue(expanded ? L10n.text("已展开") : L10n.text("已收起"))
                if expanded {
                    Spacer()
                    Toggle(isOn: $clipping) { Image(systemName: "exclamationmark.triangle") }
                        .toggleStyle(.button).buttonStyle(.borderless).tint(.yellow)
                        .help(L10n.text("显示输出高光与黑位裁切")).accessibilityLabel(L10n.text("显示裁切提示")).disabled(frame == nil)
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .accessibilityLabel(expanded ? L10n.text("收起直方图") : L10n.text("展开直方图"))
            }
            if expanded {
                HistogramView(bins: frame?.histogram ?? []).frame(height: 68)
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
