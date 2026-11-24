import RawLabKit
import AppKit
import SwiftUI

// 文本框的 UndoManager 拥有输入草稿；只有离开文本编辑器才路由到照片历史。
final class AdjustmentTextUndoObserver: ObservableObject {
    @Published private(set) var revision = 0
    private var tokens: [NSObjectProtocol] = []
    init() {
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification,
                     NSControl.textDidChangeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.revision &+= 1 }
            })
        }
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    var textEditor: NSTextView? { NSApp?.keyWindow?.firstResponder as? NSTextView }
    var photoWindowActive: Bool { NSApp?.keyWindow != nil && !(NSApp?.keyWindow is NSPanel) && NSApp?.keyWindow?.attachedSheet == nil }
}

struct AdjustmentCommands: Commands {
    @ObservedObject var model: EditorModel
    @StateObject private var textUndo = AdjustmentTextUndoObserver()
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.text("撤销")) { perform(undo: true) }.keyboardShortcut("z")
                .disabled(textUndo.textEditor == nil ? (!textUndo.photoWindowActive || !model.canUndoAdjustment) : textUndo.textEditor?.undoManager?.canUndo != true)
            Button(L10n.text("重做")) { perform(undo: false) }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(textUndo.textEditor == nil ? (!textUndo.photoWindowActive || !model.canRedoAdjustment) : textUndo.textEditor?.undoManager?.canRedo != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L10n.text("复制调整…")) { model.requestAdjustmentSheet(.copy) }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!textUndo.photoWindowActive || model.file == nil || model.exporting)
            Button(L10n.text("粘贴调整…")) { model.requestAdjustmentSheet(.paste) }
                .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!textUndo.photoWindowActive || model.adjustmentClipboard == nil || model.exporting)
            Divider()
            Button(L10n.text("导入调整参数 JSON…")) { model.importAdjustmentTransferPanel() }
                .disabled(!textUndo.photoWindowActive || !model.canImportAdjustmentTransfer)
            Button(L10n.text("导出调整参数 JSON…")) { model.exportAdjustmentTransferPanel() }
                .disabled(!textUndo.photoWindowActive || !model.canExportAdjustmentTransfer)
            Divider()
            Button(L10n.text("本次会话历史…")) { model.requestAdjustmentSheet(.history) }
                .disabled(!textUndo.photoWindowActive || model.exporting)
        }
    }
    private func perform(undo: Bool) {
        if let text = textUndo.textEditor {
            if undo { text.undoManager?.undo() } else { text.undoManager?.redo() }
        } else if textUndo.photoWindowActive {
            if undo { model.undoAdjustment() } else { model.redoAdjustment() }
        }
    }
}

struct FileMenuCommands: Commands {
    @ObservedObject var model: EditorModel
    let openBatchSelection: () -> Void
    let openBatchExport: () -> Void

    static func primaryExportFormat(isHDREditing: Bool) -> ExportFormat {
        isHDREditing ? .hdrJPEG : .jpeg
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("打开照片"), action: model.openPanel).keyboardShortcut("o")
            Button(L10n.text("导入外观…"), action: model.importLUT)
                .disabled(model.lookLibraryBusy || model.exporting || model.geometryDraft != nil)
            Divider()
            if Self.primaryExportFormat(isHDREditing: model.settings.isHDREditing) == .hdrJPEG {
                Button(L10n.text("导出 HDR JPEG…")) { model.export(format: .hdrJPEG) }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
                if HDRImage.heifExportAvailable {
                    Button(L10n.text("导出 HDR HEIF…")) { model.export(format: .hdrHEIF) }
                        .disabled(!model.canExport)
                }
                Button(L10n.text("导出 JPEG…")) { model.export(format: .jpeg) }.disabled(!model.canExport)
            } else {
                Button(L10n.text("导出 JPEG…")) { model.export(format: .jpeg) }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            Button(L10n.text("导出 16 位 PNG…")) { model.export(format: .png) }.disabled(!model.canExport)
            Button(L10n.text("导出渲染型 DNG…")) { model.export(format: .renderedDNG) }.disabled(!model.canExport)
            Divider()
            Button(L10n.text("使用当前调整批量导出…")) {
                if model.prepareBatch() { openBatchExport() }
            }.disabled(!model.canExport)
            Button(L10n.text("批量编辑…"), action: openBatchSelection).disabled(model.exporting)
            Button(L10n.text("查看批量任务…"), action: openBatchExport).disabled(model.batch == nil)
        }
    }
}

@MainActor
final class MacViewCommandState: ObservableObject {
    @Published private(set) var editorWindowActive = false
    @Published var showFiles = true
    @Published var canToggleLibrary = true
    @Published var showInspector = true
    @Published var canToggleInspector = true
    @Published var canOpenHistogram = false
    @Published var canZoom = false
    @Published var margins = true
    @Published var canCompare = false
    @Published var compareEnabled = false
    @Published var compareMode: MacCompareMode = .sideBySide
    @Published var canToggleClipping = false
    @Published var clipping = false
    @Published var canShowInfo = false
    @Published var infoActive = false
    @Published var canInspect = false

    private weak var editorWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []

    var toggleLibrary: () -> Void = {}
    var toggleInspector: () -> Void = {}
    var openHistogram: () -> Void = {}
    var fit: () -> Void = {}
    var actualPixels: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var setMargins: (Bool) -> Void = { _ in }
    var toggleCompare: () -> Void = {}
    var selectCompareMode: (MacCompareMode) -> Void = { _ in }
    var closeCompare: () -> Void = {}
    var setClipping: (Bool) -> Void = { _ in }
    var cycleInfo: () -> Void = {}

    static func isEditorWindowActive(editorWindow: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let editorWindow, let keyWindow else { return false }
        return keyWindow === editorWindow && editorWindow.attachedSheet == nil
    }

    init() {
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshEditorWindowActive()
                }
                DispatchQueue.main.async {
                    Task { @MainActor [weak self] in
                        self?.refreshEditorWindowActive()
                    }
                }
            })
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attachEditorWindow(_ window: NSWindow?) {
        editorWindow = window
        refreshEditorWindowActive()
        DispatchQueue.main.async { [weak self] in
            self?.refreshEditorWindowActive()
        }
    }

    func detachEditorWindow(_ window: NSWindow) {
        guard editorWindow === window else { return }
        editorWindow = nil
        refreshEditorWindowActive()
    }

    func refreshEditorWindowActive(keyWindow: NSWindow?) {
        let active = Self.isEditorWindowActive(editorWindow: editorWindow, keyWindow: keyWindow)
        if editorWindowActive != active {
            editorWindowActive = active
        }
    }

    func refreshEditorWindowActive() {
        refreshEditorWindowActive(keyWindow: NSApp?.keyWindow)
    }

    func performIfActive(_ condition: Bool, keyWindow: NSWindow?, action: () -> Void) {
        refreshEditorWindowActive(keyWindow: keyWindow)
        guard editorWindowActive && condition else { return }
        action()
    }

    func performIfActive(_ condition: Bool, action: () -> Void) {
        performIfActive(condition, keyWindow: NSApp?.keyWindow, action: action)
    }
}

struct ViewCommands: Commands {
    @ObservedObject var model: EditorModel
    @ObservedObject var commands: MacViewCommandState

    var body: some Commands {
        let active = commands.editorWindowActive
        CommandGroup(after: .toolbar) {
            Button(L10n.text("文件树")) {
                commands.performIfActive(commands.canToggleLibrary, action: commands.toggleLibrary)
            }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!active || !commands.canToggleLibrary)
            Button(L10n.text("调整栏")) {
                commands.performIfActive(commands.canToggleInspector, action: commands.toggleInspector)
            }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!active || !commands.canToggleInspector)
            Button(L10n.text("直方图")) {
                commands.performIfActive(commands.canOpenHistogram, action: commands.openHistogram)
            }
                .disabled(!active || !commands.canOpenHistogram)
            Divider()
            Button(L10n.text("适合窗口")) {
                commands.performIfActive(commands.canZoom, action: commands.fit)
            }
                .keyboardShortcut("0")
                .disabled(!active || !commands.canZoom)
            Button(L10n.text("实际像素 · 100%")) {
                commands.performIfActive(commands.canZoom, action: commands.actualPixels)
            }
                .keyboardShortcut("1")
                .disabled(!active || !commands.canZoom)
            Button(L10n.text("放大")) {
                commands.performIfActive(commands.canZoom, action: commands.zoomIn)
            }
                .keyboardShortcut("+")
                .disabled(!active || !commands.canZoom)
            Button(L10n.text("缩小")) {
                commands.performIfActive(commands.canZoom, action: commands.zoomOut)
            }
                .keyboardShortcut("-")
                .disabled(!active || !commands.canZoom)
            Toggle(L10n.text("照片四周留白"), isOn: Binding(
                get: { commands.margins },
                set: { value in
                    commands.performIfActive(commands.canZoom) { commands.setMargins(value) }
                }
            ))
                .disabled(!active || !commands.canZoom)
            Divider()
            Toggle(L10n.text("对比"), isOn: Binding(
                get: { commands.compareEnabled },
                set: { enabled in
                    commands.performIfActive(commands.canCompare) {
                        if enabled != commands.compareEnabled { commands.toggleCompare() }
                    }
                }
            ))
                .disabled(!active || !commands.canCompare)
            Button(L10n.text("并排")) {
                commands.performIfActive(commands.canCompare) { commands.selectCompareMode(.sideBySide) }
            }
                .disabled(!active || !commands.canCompare)
            Button(L10n.text("分割线")) {
                commands.performIfActive(commands.canCompare) { commands.selectCompareMode(.wipe) }
            }
                .disabled(!active || !commands.canCompare)
            Button(L10n.text("关闭对比")) {
                commands.performIfActive(commands.canCompare && commands.compareEnabled, action: commands.closeCompare)
            }
                .disabled(!active || !commands.canCompare || !commands.compareEnabled)
            Toggle(L10n.text("显示裁切提示"), isOn: Binding(
                get: { commands.clipping },
                set: { value in
                    commands.performIfActive(commands.canToggleClipping) { commands.setClipping(value) }
                }
            ))
                .disabled(!active || !commands.canToggleClipping)
            Button(L10n.text("照片信息")) {
                commands.performIfActive(commands.canShowInfo, action: commands.cycleInfo)
            }
                .disabled(!active || !commands.canShowInfo)
            Divider()
            Toggle(L10n.text("取样监视"), isOn: Binding(
                get: { model.inspection.monitorEnabled },
                set: { enabled in
                    commands.performIfActive(commands.canInspect) {
                        model.inspection.monitorEnabled = enabled
                        if !enabled { model.inspection.pinModeEnabled = false }
                    }
                }
            ))
                .disabled(!active || !commands.canInspect)
            Toggle(L10n.text("50% 中性灰"), isOn: Binding(
                get: { model.inspection.overlay == .neutralGray50 },
                set: { enabled in
                    commands.performIfActive(commands.canInspect) {
                        let target: InspectionOverlayMode = enabled ? .neutralGray50 : .none
                        if model.inspection.overlay != target { model.inspection.selectOverlay(target) }
                    }
                }
            ))
                .disabled(!active || !commands.canInspect)
            Menu(L10n.text("观察层")) {
                ForEach(InspectionOverlayMode.allCases) { mode in
                    Button {
                        commands.performIfActive(commands.canInspect) {
                            model.inspection.selectOverlay(mode)
                        }
                    } label: {
                        if model.inspection.overlay == mode {
                            Label(L10n.text(mode.titleKey), systemImage: "checkmark")
                        } else {
                            Text(L10n.text(mode.titleKey))
                        }
                    }
                }
            }
                .disabled(!active || !commands.canInspect)
        }
    }
}
