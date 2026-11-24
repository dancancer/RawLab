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

@MainActor
final class MacViewCommandState: ObservableObject {
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
}

struct ViewCommands: Commands {
    @ObservedObject var model: EditorModel
    @ObservedObject var commands: MacViewCommandState

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(L10n.text("文件树")) { commands.toggleLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!commands.canToggleLibrary)
            Button(L10n.text("调整栏")) { commands.toggleInspector() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!commands.canToggleInspector)
            Button(L10n.text("直方图")) { commands.openHistogram() }
                .disabled(!commands.canOpenHistogram)
            Divider()
            Button(L10n.text("适合窗口")) { commands.fit() }
                .keyboardShortcut("0")
                .disabled(!commands.canZoom)
            Button(L10n.text("实际像素 · 100%")) { commands.actualPixels() }
                .keyboardShortcut("1")
                .disabled(!commands.canZoom)
            Button(L10n.text("放大")) { commands.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!commands.canZoom)
            Button(L10n.text("缩小")) { commands.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!commands.canZoom)
            Toggle(L10n.text("照片四周留白"), isOn: Binding(
                get: { commands.margins },
                set: { commands.setMargins($0) }
            ))
                .disabled(!commands.canZoom)
            Divider()
            Toggle(L10n.text("对比"), isOn: Binding(
                get: { commands.compareEnabled },
                set: { enabled in
                    if enabled != commands.compareEnabled { commands.toggleCompare() }
                }
            ))
                .disabled(!commands.canCompare)
            Button(L10n.text("并排")) { commands.selectCompareMode(.sideBySide) }
                .disabled(!commands.canCompare)
            Button(L10n.text("分割线")) { commands.selectCompareMode(.wipe) }
                .disabled(!commands.canCompare)
            Button(L10n.text("关闭对比")) { commands.closeCompare() }
                .disabled(!commands.canCompare || !commands.compareEnabled)
            Toggle(L10n.text("显示裁切提示"), isOn: Binding(
                get: { commands.clipping },
                set: { commands.setClipping($0) }
            ))
                .disabled(!commands.canToggleClipping)
            Button(L10n.text("照片信息")) { commands.cycleInfo() }
                .disabled(!commands.canShowInfo)
            Divider()
            Toggle(L10n.text("取样监视"), isOn: Binding(
                get: { model.inspection.monitorEnabled },
                set: { enabled in
                    model.inspection.monitorEnabled = enabled
                    if !enabled { model.inspection.pinModeEnabled = false }
                }
            ))
                .disabled(!commands.canInspect)
            Toggle(L10n.text("50% 中性灰"), isOn: Binding(
                get: { model.inspection.overlay == .neutralGray50 },
                set: { enabled in
                    let target: InspectionOverlayMode = enabled ? .neutralGray50 : .none
                    if model.inspection.overlay != target { model.inspection.selectOverlay(target) }
                }
            ))
                .disabled(!commands.canInspect)
            Menu(L10n.text("观察层")) {
                ForEach(InspectionOverlayMode.allCases) { mode in
                    Button {
                        model.inspection.selectOverlay(mode)
                    } label: {
                        if model.inspection.overlay == mode {
                            Label(L10n.text(mode.titleKey), systemImage: "checkmark")
                        } else {
                            Text(L10n.text(mode.titleKey))
                        }
                    }
                }
            }
                .disabled(!commands.canInspect)
        }
    }
}
