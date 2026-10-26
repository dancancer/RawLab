import AppKit
import SwiftUI

// Native press recognition keeps the system movement/press thresholds. Crop overlays
// retain their own input path; this view exists only outside geometry editing.
struct MacCanvasInput: NSViewRepresentable {
    var imageRect: CGRect
    var excludedRects: [CGRect] = []
    var target: HSLTargetCanvasInput? = nil
    var canHold: Bool
    var onHold: (Bool) -> Void
    var onPan: (CGSize) -> Void
    var onPanEnd: () -> Void
    var onDoubleClick: () -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.configure(self)
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.cancelInput() }
    final class InputView: NSView {
        var owner: MacCanvasInput?
        private var observers: [NSObjectProtocol] = []
        private var targetOrigin: CGPoint?
        private var targetFine = false
        func configure(_ next: MacCanvasInput) {
            if owner?.target?.scope != next.target?.scope { cancelInput() }
            owner = next
            for recognizer in gestureRecognizers { recognizer.isEnabled = next.target == nil }
        }
        override func resignFirstResponder() -> Bool { cancelInput(); return super.resignFirstResponder() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.buttonMask = 1
            addGestureRecognizer(press)
            let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.buttonMask = 1
            addGestureRecognizer(pan)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            cancelInput()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.cancelInput() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.cancelInput() })
        }
        func cancelInput() {
            targetOrigin = nil; owner?.target?.cancel()
            owner?.onHold(false); owner?.onPanEnd()
            for recognizer in gestureRecognizers { recognizer.isEnabled = false; recognizer.isEnabled = owner?.target == nil }
        }
        override func cancelOperation(_ sender: Any?) { exitTarget() }
        private func exitTarget() {
            let exit = owner?.target?.exit
            cancelInput(); exit?()
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { exitTarget(); return }
            if let target = owner?.target, [UInt16(123), 124, 125, 126].contains(event.keyCode) {
                if targetOrigin == nil {
                    let direction = event.keyCode == 124 || event.keyCode == 126 ? 1.0 : -1.0
                    target.key(direction * (event.modifierFlags.contains(.shift) ? 0.1 : 1))
                    window?.makeFirstResponder(self)
                }
                return
            }
            super.keyDown(with: event)
        }
        override func viewDidHide() { super.viewDidHide(); cancelInput() }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        @objc private func pressed(_ gesture: NSPressGestureRecognizer) {
            let point = gesture.location(in: self)
            owner?.onHold(gesture.state == .began && owner?.canHold == true && owner?.imageRect.contains(point) == true)
        }
        override func mouseDown(with event: NSEvent) {
            owner?.onHold(false)
            if let owner, let target = owner.target {
                let point = convert(event.locationInWindow, from: nil)
                guard owner.imageRect.contains(point), bounds.contains(point),
                      !owner.excludedRects.contains(where: { $0.contains(point) }),
                      owner.imageRect.width > 0, owner.imageRect.height > 0 else { target.reject(); return }
                target.begin(CGPoint(x: (point.x-owner.imageRect.minX)/owner.imageRect.width,
                                     y: (point.y-owner.imageRect.minY)/owner.imageRect.height))
                // 输入预检可能结束字段焦点，完成后再接管拖动，避免取消刚记录的起点。
                targetOrigin = point; targetFine = event.modifierFlags.contains(.shift)
                window?.makeFirstResponder(self)
            } else {
                window?.makeFirstResponder(self)
                if event.clickCount == 2 { owner?.onDoubleClick() }
            }
        }
        @objc private func panned(_ gesture: NSPanGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                owner?.onHold(false)
                let translation = gesture.translation(in: self)
                owner?.onPan(CGSize(width: translation.x, height: translation.y))
            } else { owner?.onPanEnd() }
        }
        override func mouseDragged(with event: NSEvent) {
            if let origin = targetOrigin {
                let point = convert(event.locationInWindow, from: nil)
                owner?.target?.change(Double(origin.y-point.y) * (targetFine ? 0.125 : 0.5))
            } else { super.mouseDragged(with: event) }
        }
        override func magnify(with event: NSEvent) { cancelInput(); super.magnify(with: event) }
        override func scrollWheel(with event: NSEvent) { cancelInput(); super.scrollWheel(with: event) }
        override func mouseUp(with event: NSEvent) {
            if let origin = targetOrigin {
                let point = convert(event.locationInWindow, from: nil)
                owner?.target?.change(Double(origin.y-point.y) * (targetFine ? 0.125 : 0.5))
                targetOrigin = nil
                owner?.target?.end()
            }
            owner?.onHold(false); owner?.onPanEnd()
        }
    }
}

struct MacViewingKeyboard: NSViewRepresentable {
    var canHold: Bool
    var onHold: (Bool) -> Void
    var onInformation: () -> Void
    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) { view.owner = self }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
    final class KeyboardView: NSView {
        var owner: MacViewingKeyboard?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var menuActive = false
        private var heldKeyCode: UInt16?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let owner = self.owner else { return event }
                if event.type == .keyUp && event.keyCode == self.heldKeyCode { self.heldKeyCode = nil; owner.onHold(false); return event }
                guard event.type == .keyDown else { return event }
                guard event.window === self.window, self.window?.isKeyWindow == true, NSApp.isActive,
                      self.window?.attachedSheet == nil, !self.menuActive,
                      !(self.window?.firstResponder is NSTextView), !(self.window?.firstResponder is NSTextField),
                      event.modifierFlags.intersection([.command, .control]).isEmpty else { return event }
                if event.characters == "\\", owner.canHold { self.heldKeyCode = event.keyCode; owner.onHold(true); return nil }
                if event.modifierFlags.intersection(.option).isEmpty, event.charactersIgnoringModifiers?.lowercased() == "i", !event.isARepeat { owner.onInformation(); return nil }
                return event
            }
            for name in [NSApplication.willResignActiveNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.owner?.onHold(false) })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuActive = true; self?.owner?.onHold(false) })
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuActive = false })
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            menuActive = false; heldKeyCode = nil; owner?.onHold(false)
        }
        deinit { stop() }
    }
}
