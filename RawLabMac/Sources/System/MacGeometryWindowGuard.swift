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
        private weak var closeAfterSheet: NSWindow?
        init(model: EditorModel) { self.model = model }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let model else { return previous?.windowShouldClose?(sender) ?? true }
            ParameterValueField.cancelPendingInputs()
            if model.geometryDraftHasChanges {
                model.requestLeavingGeometryDraft { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    // SwiftUI 尚未移除确认表单时，AppKit 会忽略关闭操作。
                    if sender.attachedSheet != nil { self.closeAfterSheet = sender }
                    else { sender.performClose(nil) }
                }
                return false
            }
            guard model.saveEdits() else { return false }
            model.cancelGeometryDraft()
            return previous?.windowShouldClose?(sender) ?? true
        }

        func windowDidEndSheet(_ notification: Notification) {
            previous?.windowDidEndSheet?(notification)
            guard let window = notification.object as? NSWindow, closeAfterSheet === window else { return }
            closeAfterSheet = nil
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.delegate === self, window.attachedSheet == nil,
                      self.model?.geometryDraftDeparturePending != true else { return }
                window.performClose(nil)
            }
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
    // 退出时最多等统计 SDK 收尾这么久（秒）
    static let usageShutdownLimit: TimeInterval = 3
    weak var model: EditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ParameterValueField.cancelPendingInputs()
        guard let model else {
            return finishTermination(sender)
        }
        guard !model.geometryDraftHasChanges else {
            guard !model.geometryDraftDeparturePending else { return .terminateCancel }
            model.requestLeavingGeometryDraft({ [weak self, weak sender] in
                guard let self, let sender else { return }
                let reply = self.finishTermination(sender)
                if reply != .terminateLater {
                    sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
                }
            }, onStay: { [weak sender] in
                sender?.reply(toApplicationShouldTerminate: false)
            })
            return .terminateLater
        }
        guard model.saveEdits() else { return .terminateCancel }
        return finishTermination(sender)
    }

    private func finishTermination(_ sender: NSApplication, allow: Bool = true) -> NSApplication.TerminateReply {
        guard allow else {
            sender.reply(toApplicationShouldTerminate: false)
            return .terminateLater
        }
#if RAWLAB_RUM
        var replied = false
        let reply: () -> Void = { [weak sender] in
            guard !replied else { return }
            replied = true
            sender?.reply(toApplicationShouldTerminate: true)
        }
        UsageRUM.shutdown { DispatchQueue.main.async(execute: reply) }
        // 网络失联不允许统计服务阻塞退出；超时视为异常终止，未发出的统计丢弃。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.usageShutdownLimit, execute: reply)
        return .terminateLater
#else
        return .terminateNow
#endif
    }
}
