import SwiftUI

struct ColorGradingWheelControl: View {
    @Binding var value: ColorGradingWheel
    let scope: String
    let title: String
    var fine = false
    var isCurrent: () -> Bool = { true }
    var canChange: () -> Bool = { true }
    var prepareEditing: () -> Bool = { true }
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = max(1, (side - 20) / 2)
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 0.9) }, center: .center))
                Circle().fill(RadialGradient(colors: [.gray, .gray.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                Circle().strokeBorder(.black.opacity(0.8), lineWidth: 4)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .frame(width: 16, height: 16)
                    .offset(x: value.point.x * radius, y: value.point.y * radius)
            }.frame(width: radius * 2, height: radius * 2)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .opacity(enabled ? 1 : 0.4).accessibilityHidden(true)
            GradingWheelInput(configuration: configuration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(L10n.text("色相") + " " + String(format: "%.1f°", locale: L10n.locale, value.hue)
            + ", " + L10n.text("饱和度") + " " + String(format: "%.1f%%", locale: L10n.locale, value.saturation))
        .accessibilityIdentifier("grading.wheel")
        .accessibilityAdjustableAction { direction in
            guard enabled, isCurrent(), canChange() else { return }
            let next = min(100, max(0, value.saturation + (direction == .increment ? 1 : -1)))
            guard next != value.saturation else { return }
            onEditingChanged(true)
            guard canChange() else { onCancelled(); return }
            value.saturation = next
            onEditingChanged(false)
        }
    }

    private var configuration: GradingWheelConfiguration {
        GradingWheelConfiguration(value: value, scope: scope, fine: fine, enabled: enabled,
            isCurrent: isCurrent, begin: {
                guard isCurrent(), canChange(), prepareEditing() else { return false }
                onEditingChanged(true)
                return canChange()
            }, change: { if isCurrent(), canChange() { value = $0 } },
            end: { if isCurrent() { onEditingChanged(false) } }, cancel: onCancelled)
    }
}

struct GradingWheelConfiguration {
    let value: ColorGradingWheel
    let scope: String
    let fine: Bool
    let enabled: Bool
    let isCurrent: () -> Bool
    let begin: () -> Bool
    let change: (ColorGradingWheel) -> Void
    let end: () -> Void
    let cancel: () -> Void
}

final class GradingWheelSession {
    var configuration: GradingWheelConfiguration?
    private var active: (GradingWheelConfiguration, ColorGradingDrag)?
    var isActive: Bool { active != nil }
    func configure(_ next: GradingWheelConfiguration) {
        if let old = configuration, old.scope != next.scope || old.fine != next.fine || !next.enabled {
            cancel(deferred: true)
        }
        configuration = next
    }
    @discardableResult func begin(x: Double, y: Double, fine: Bool = false) -> Bool {
        guard active == nil, let config = configuration, config.enabled, config.isCurrent() else { return false }
        guard config.begin() else { config.cancel(); return false }
        active = (config, ColorGradingDrag(initial: config.value, originX: x, originY: y, fine: fine || config.fine))
        move(x: x, y: y)
        return true
    }
    func move(x: Double, y: Double) {
        guard let (config, drag) = active else { return }
        guard config.isCurrent() else { cancel(); return }
        config.change(drag.value(x: x, y: y))
    }
    func end() {
        guard let (config, _) = active else { return }
        active = nil
        if config.isCurrent() { config.end() }
    }
    func cancel(deferred: Bool = false) {
        guard let (config, _) = active else { return }
        active = nil
        if deferred { DispatchQueue.main.async { if config.isCurrent() { config.cancel() } } }
        else if config.isCurrent() { config.cancel() }
    }
    func key(horizontal: Double, vertical: Double, fine: Bool) {
        guard active == nil, let config = configuration, config.enabled, config.isCurrent() else { return }
        let step = fine ? 0.1 : 1.0
        var next = config.value
        next.hue = (next.hue + horizontal * step + 360).truncatingRemainder(dividingBy: 360)
        next.saturation = min(100, max(0, next.saturation + vertical * step))
        guard next != config.value else { return }
        guard config.begin() else { config.cancel(); return }
        config.change(next); config.end()
    }
}

#if canImport(UIKit)
import UIKit

private struct GradingWheelInput: UIViewRepresentable {
    let configuration: GradingWheelConfiguration
    func makeUIView(context: Context) -> GradingWheelNativeView { GradingWheelNativeView() }
    func updateUIView(_ view: GradingWheelNativeView, context: Context) { view.session.configure(configuration) }
    static func dismantleUIView(_ view: GradingWheelNativeView, coordinator: ()) { view.session.cancel(deferred: true) }
}

private final class GradingWheelNativeView: UIView {
    let session = GradingWheelSession()
    private let keyboardlessInput = UIView(frame: .zero)
    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { keyboardlessInput }
    override var isHidden: Bool { didSet { if isHidden { session.cancel() } } }
    override func resignFirstResponder() -> Bool { session.cancel(); return super.resignFirstResponder() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { session.cancel() } }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelled))]
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(cancelled), name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func point(_ location: CGPoint) -> (Double, Double) {
        let radius = max(1, (min(bounds.width, bounds.height) - 20) / 2)
        return (Double((location.x - bounds.midX) / radius), Double((location.y - bounds.midY) / radius))
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let p = point(recognizer.location(in: self))
        if session.begin(x: p.0, y: p.1) { becomeFirstResponder(); session.end() }
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let p = point(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            let location = recognizer.location(in: self), translation = recognizer.translation(in: self)
            let start = point(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
            if session.begin(x: start.0, y: start.1) { becomeFirstResponder(); session.move(x: p.0, y: p.1) }
        case .changed: session.move(x: p.0, y: p.1)
        case .ended: session.move(x: p.0, y: p.1); session.end()
        case .cancelled, .failed: session.cancel()
        default: break
        }
    }
    @objc private func cancelled() { session.cancel() }
}
#else
import AppKit

private struct GradingWheelInput: NSViewRepresentable {
    let configuration: GradingWheelConfiguration
    func makeNSView(context: Context) -> GradingWheelNativeView { GradingWheelNativeView() }
    func updateNSView(_ view: GradingWheelNativeView, context: Context) { view.session.configure(configuration) }
    static func dismantleNSView(_ view: GradingWheelNativeView, coordinator: ()) { view.session.cancel(deferred: true) }
}

private final class GradingWheelNativeView: NSView {
    let session = GradingWheelSession()
    private var fineAtStart = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resignFirstResponder() -> Bool { session.cancel(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { session.cancel() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func point(_ event: NSEvent) -> (Double, Double) {
        let location = convert(event.locationInWindow, from: nil)
        let radius = max(1, (min(bounds.width, bounds.height) - 20) / 2)
        return (Double((location.x - bounds.midX) / radius), Double((location.y - bounds.midY) / radius))
    }
    override func mouseDown(with event: NSEvent) {
        fineAtStart = event.modifierFlags.contains(.shift)
        let p = point(event)
        if session.begin(x: p.0, y: p.1, fine: fineAtStart) { window?.makeFirstResponder(self) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event); session.move(x: p.0, y: p.1)
    }
    override func mouseUp(with event: NSEvent) {
        let p = point(event); session.move(x: p.0, y: p.1); session.end()
    }
    override func flagsChanged(with event: NSEvent) {
        if session.isActive && event.modifierFlags.contains(.shift) != fineAtStart { session.cancel() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session.cancel(); return }
        if [123, 124, 125, 126].contains(event.keyCode) {
            session.key(horizontal: event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0,
                vertical: event.keyCode == 125 ? -1 : event.keyCode == 126 ? 1 : 0, fine: event.modifierFlags.contains(.shift))
        } else { super.keyDown(with: event) }
    }
    @objc private func deactivated(_ notification: Notification) {
        if let source = notification.object as? NSWindow, source === window { session.cancel() }
    }
}
#endif
