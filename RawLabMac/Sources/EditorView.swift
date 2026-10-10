import SwiftUI
import AppKit

struct EditorView: View {
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

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                if showFiles {
                    FileBrowser(library: library, selected: model.file, open: model.open)
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                        .disabled(model.exporting)
                }
                VStack(spacing: 0) {
                  workspace.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
                    .overlay(alignment: .topTrailing) {
                        FloatingHistogram(frame: model.result, clipping: $clipping, expanded: $histogramExpanded).padding(12)
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
                  if !adjustmentPanel.collapsed {
                      panelResizeHandle(available: geometry.size.height)
                      bottomControls
                          .frame(height: adjustmentPanel.height(available: geometry.size.height) - 12)
                  }
                  Divider()
                  statusBar
                }
            }
        }
        .frame(minWidth: 950, minHeight: 620)
        .preferredColorScheme(.dark)
        .onChange(of: model.file) { _, _ in fit() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveEdits() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.saveEdits() }
        .toolbar { editorToolbar }
        .onAppear {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--sample"), args.indices.contains(index + 1) {
                model.open(URL(fileURLWithPath: args[index + 1]))
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.result != nil && model.error != nil && model.lookImportReport == nil },
            set: { if !$0 { model.error = nil } }
        )) { Button("关闭", role: .cancel) { model.error = nil } }
        message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(
            get: { model.lookImportReport != nil },
            set: { if !$0 { model.lookImportReport = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text("导入结果").font(.headline)
                ScrollView {
                    Text(model.lookImportReport ?? "").font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("关闭") { model.lookImportReport = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 520, height: 380)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(model.selectedFilm?.name ?? "中性").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .leading)
                Spacer(minLength: 8)
                Picker("曝光基准", selection: $model.settings.exposureMode) {
                    ForEach(ExposureMode.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 220)
                Text(model.result.map { String(format: "%+.2f EV", $0.baselineEV) } ?? "-- EV")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 66)
                    .help("基础曝光偏移")
                Menu {
                    Button("重置全部调整") { reset() }
                    Divider()
                    ForEach(AdjustmentGroup.allCases) { group in
                        Button("重置\(group.rawValue)") { reset(group) }.disabled(model.settings.isDefault(group))
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                .menuStyle(.borderlessButton).fixedSize().help("重置调整").accessibilityLabel("重置调整")
                    .disabled(model.settings.isDefault)
            }.padding(.horizontal, 20).frame(height: 42)
            AdjustmentDock(model: model, selected: $selectedParameter, resetVersion: resetVersion)
        }.background(Color(nsColor: .windowBackgroundColor))
            .disabled(model.file == nil || model.exporting)
    }

    private func panelResizeHandle(available: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 32, height: 3)
            HStack {
                Spacer()
                Button { adjustmentPanel.collapsed = true } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.buttonStyle(.plain).frame(width: 28, height: 12)
                    .help("收起调整栏").accessibilityLabel("收起调整栏")
            }.padding(.trailing, 12)
        }.frame(height: 12).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = adjustmentPanel.height(available: available) }
                    adjustmentPanel.resize(to: (resizeStart ?? 260) - value.translation.height, available: available)
                }.onEnded { _ in resizeStart = nil })
            .onHover { inside in (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("调整栏高度")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 20 : -20
                adjustmentPanel.resize(to: adjustmentPanel.height(available: available) + delta, available: available)
            }
    }

    @ViewBuilder private var workspace: some View {
        if let result = model.result {
            HStack(spacing: 1) {
                if compare, let base = model.neutral { imagePane(base, title: "原图", showMask: false) }
                imagePane(result, title: model.selectedFilm?.name ?? "调整后", showMask: clipping)
            }
        } else {
            VStack(spacing: 16) {
                if model.busy {
                    ProgressView().controlSize(.regular)
                    Text(model.file?.lastPathComponent ?? "RAW 照片").font(.headline).lineLimit(1)
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.yellow)
                    Text("操作失败").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    HStack {
                        Button("重试", action: model.schedule)
                        Button("打开其他 RAW…", action: model.openPanel)
                    }
                } else {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("RAW 照片").font(.title3)
                    Button(action: model.openPanel) { Label("打开 RAW…", systemImage: "folder") }.controlSize(.large)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(model.file?.lastPathComponent ?? "未打开照片").lineLimit(1).truncationMode(.middle)
                .help(model.file?.path ?? "未打开照片")
            Spacer(minLength: 8)
            if let failure = model.saveError {
                Button { model.saveEdits() } label: { Label("调整未保存 · 重试", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.plain).foregroundStyle(.yellow).help(failure)
            } else if !model.saveStatus.isEmpty {
                Label(model.saveStatus, systemImage: "checkmark").foregroundStyle(.secondary)
            }
            if model.batch?.job.interrupted == true {
                Button("继续上次批量任务") { openWindow(id: "batch-export") }
            }
            if model.busy || model.exporting {
                ProgressView().controlSize(.mini)
                Text(model.exporting ? "正在导出…" : "正在显影…")
            } else {
                Text(model.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 30).background(.bar)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("显示或收起文件树").accessibilityLabel("文件树")
                .accessibilityValue(showFiles ? "已展开" : "已收起")
            Button(action: model.openPanel) { Image(systemName: "folder") }
                .help("打开 RAW").accessibilityLabel("打开 RAW").disabled(model.exporting)
        }
        ToolbarItemGroup {
            Button { compare.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                .tint(compare ? .yellow : nil)
                .help("原图与调整后对比").accessibilityLabel("对比")
                .accessibilityValue(compare ? "已开启" : "已关闭").disabled(model.result == nil)
            Menu {
                Button("适合窗口", action: fit).keyboardShortcut("0")
                Button("实际像素 · 100%") {
                    viewport.actualPixels(); pan = .zero
                    if !model.fullResolution { model.fullResolution = true }
                }.keyboardShortcut("1")
                Divider()
                Button("放大") { zoom(1.25) }
                Button("缩小") { zoom(1 / 1.25) }
            } label: { Image(systemName: "magnifyingglass") }
                .help("缩放").accessibilityLabel("缩放").disabled(model.result == nil)
            Button { adjustmentPanel.collapsed.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .tint(adjustmentPanel.collapsed ? nil : .yellow)
                .help(adjustmentPanel.collapsed ? "展开调整栏" : "收起调整栏")
                .accessibilityLabel("调整栏").accessibilityValue(adjustmentPanel.collapsed ? "已收起" : "已展开")
                .keyboardShortcut("a", modifiers: [.command, .option])
            Menu {
                Button("JPEG…") { model.export(png: false) }
                    .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm)
                Button("PNG · 16-bit…") { model.export(png: true) }
                    .disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm)
                Divider()
                Button("使用当前调整批量导出…") {
                    if model.prepareBatch() { openWindow(id: "batch-export") }
                }.disabled(model.result == nil || model.busy || model.exporting || model.lookLibraryBusy || model.missingFilm)
                if model.batch != nil {
                    Button("查看批量任务…") { openWindow(id: "batch-export") }
                }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
            .disabled(model.file == nil && model.batch == nil)
        }
    }

    private func reset(_ group: AdjustmentGroup? = nil) {
        if let group { model.settings.reset(group) } else { model.settings.resetAll() }
        resetVersion += 1
    }
    private func fit() {
        viewport.fit(); pan = .zero
        if model.fullResolution { model.fullResolution = false }
    }
    private func zoom(_ multiplier: CGFloat) {
        viewport.zoom(by: multiplier)
        if viewport.magnification > 1 && !model.fullResolution { model.fullResolution = true }
    }
    private func toggleActualPixels() {
        viewport.toggleActualPixels()
        pan = .zero
        if model.fullResolution != viewport.pixelMode { model.fullResolution = viewport.pixelMode }
    }
    private func imagePane(_ frame: RenderedImage, title: String, showMask: Bool) -> some View {
        PhotoCanvas(frame: frame, viewport: viewport, sourceWidth: model.neutral?.image.width ?? frame.image.width, pan: $pan, clipping: showMask)
            .simultaneousGesture(TapGesture(count: 2).onEnded { toggleActualPixels() })
            .accessibilityLabel(title)
            .overlay(alignment: .bottomLeading) {
                if compare {
                    Text(title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4)).padding(10)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FloatingHistogram: View {
    let frame: RenderedImage?
    @Binding var clipping: Bool
    @Binding var expanded: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).help(expanded ? "收起直方图" : "展开直方图")
                    .accessibilityLabel("直方图")
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                if expanded {
                    Spacer()
                    Toggle(isOn: $clipping) { Image(systemName: "exclamationmark.triangle") }
                        .toggleStyle(.button).buttonStyle(.borderless).tint(.yellow)
                        .help("显示输出高光与黑位裁切").accessibilityLabel("显示裁切提示").disabled(frame == nil)
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起直方图" : "展开直方图")
            }
            if expanded {
                HistogramView(bins: frame?.histogram ?? []).frame(height: 68)
                HStack {
                    Text("高光 \(percent(frame?.highlights))")
                    Spacer()
                    Text("黑位 \(percent(frame?.shadows))")
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.white.opacity(0.9))
            }
        }.padding(12).frame(width: expanded ? 242 : 66)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 1) }
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "--" }
}
