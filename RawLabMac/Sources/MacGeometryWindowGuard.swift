import AppKit
import SwiftUI

/// Keep the editor's native close action inside the same draft transaction.
struct MacGeometryWindowGuard: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> GuardView { GuardView(model: model) }
    func updateNSView(_ view: GuardView, context: Context) { view.proxy.model = model }
    static func dismantleNSView(_ view: GuardView, coordinator: ()) { view.restoreDelegate() }

    final class GuardView: NSView {
        let proxy: CloseDelegate
        private weak var guardedWindow: NSWindow?

        init(model: EditorModel) {
            proxy = CloseDelegate(model: model)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restoreDelegate()
            guard let window else { return }
            guardedWindow = window
            proxy.previous = window.delegate
            window.delegate = proxy
        }

        func restoreDelegate() {
            if let window = guardedWindow, window.delegate === proxy { window.delegate = proxy.previous }
            guardedWindow = nil
        }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var model: EditorModel?
        weak var previous: NSWindowDelegate?
        init(model: EditorModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let model else { return previous?.windowShouldClose?(sender) ?? true }
            NSApp.keyWindow?.makeFirstResponder(nil)
            if model.geometryDraftHasChanges {
                model.requestLeavingGeometryDraft { [weak sender] in sender?.performClose(nil) }
                return false
            }
            guard model.saveEdits() else { return false }
            model.cancelGeometryDraft()
            return previous?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
        }
    }
}

final class RawLabMacDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        sender.keyWindow?.makeFirstResponder(nil)
        guard model.geometryDraftHasChanges else {
            return model.saveEdits() ? .terminateNow : .terminateCancel
        }
        guard !model.geometryDraftDeparturePending else { return .terminateCancel }
        model.requestLeavingGeometryDraft({ sender.reply(toApplicationShouldTerminate: true) },
                                         onStay: { sender.reply(toApplicationShouldTerminate: false) })
        return .terminateLater
    }
}
