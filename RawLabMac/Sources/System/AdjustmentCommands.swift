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
