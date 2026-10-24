import SwiftUI

struct ToneCurveCanvas: View {
    @Binding var value: ToneCurveSettings
    @Binding var selected: Int
    let scope: String
    var fine = false
    var isCurrent: () -> Bool = { true }
    var canChange: () -> Bool = { true }
    var prepareEditing: () -> Bool = { true }
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let samples = value.sampledPoints()
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
                func point(_ p: ToneCurvePoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height) }
                var grid = Path()
                for i in 0...4 {
                    let offset = Double(i) / 4
                    grid.move(to: point(.init(x: offset, y: 0))); grid.addLine(to: point(.init(x: offset, y: 1)))
                    grid.move(to: point(.init(x: 0, y: offset))); grid.addLine(to: point(.init(x: 1, y: offset)))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                var identity = Path(); identity.move(to: point(.init(x: 0, y: 0))); identity.addLine(to: point(.init(x: 1, y: 1)))
                context.stroke(identity, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if let first = samples.first {
                    var curve = Path(); curve.move(to: point(first))
                    for sample in samples.dropFirst() { curve.addLine(to: point(sample)) }
                    context.stroke(curve, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                for (index, p) in value.points.enumerated() {
                    let center = point(p), radius: CGFloat = selected == index ? 6 : 4
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(index == selected ? .yellow : .primary))
                    context.stroke(circle, with: .color(.black.opacity(0.8)), lineWidth: 1)
                }
            }.accessibilityHidden(true)
            ToneCurveInput(configuration: configuration)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("曲线"))
        .accessibilityValue(L10n.format("多点曲线（%d 个控制点）", value.points.count))
        .accessibilityHint(L10n.text("点击曲线区域添加控制点，拖动中间点调整。"))
        .accessibilityIdentifier("curve.canvas")
    }
    private var configuration: ToneCurveInputConfiguration {
        .init(read: { value }, selected: selected, scope: scope, fine: fine, enabled: enabled,
            isCurrent: isCurrent, prepare: { isCurrent() && canChange() && prepareEditing() },
            begin: { onEditingChanged(true); return isCurrent() && canChange() }, select: { selected = $0 },
            change: { if isCurrent(), canChange() { value = $0 } },
            end: { if isCurrent() { onEditingChanged(false) } }, cancel: onCancelled)
    }
}

#if canImport(UIKit)
import UIKit

private struct ToneCurveInput: UIViewRepresentable {
    let configuration: ToneCurveInputConfiguration
    func makeUIView(context: Context) -> ToneCurveInputView { ToneCurveInputView() }
    func updateUIView(_ view: ToneCurveInputView, context: Context) { view.session.configure(configuration) }
    static func dismantleUIView(_ view: ToneCurveInputView, coordinator: ()) { view.session.cancel(deferred: true) }
}

private final class ToneCurvePanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var initialLocation: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if initialLocation == nil, let touch = touches.first { initialLocation = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
    }
    override func reset() { super.reset(); initialLocation = nil }
}

private final class ToneCurveInputView: UIView {
    let session = ToneCurveInputSession()
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
        super.init(frame: frame); backgroundColor = .clear
        let pan = ToneCurvePanGestureRecognizer(target: self, action: #selector(dragged(_:))); pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan); addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(cancelled), name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func point(_ location: CGPoint) -> (Double, Double) {
        (Double((location.x - 12) / max(1, bounds.width - 24)), Double(1 - (location.y - 12) / max(1, bounds.height - 24)))
    }
    private func begin(_ p: (Double, Double)) -> Bool {
        session.begin(x: p.0, y: p.1, toleranceX: Double(20 / max(1, bounds.width - 24)), toleranceY: Double(20 / max(1, bounds.height - 24)))
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if begin(point(recognizer.location(in: self))) { becomeFirstResponder(); session.end() }
    }
    @objc private func dragged(_ recognizer: ToneCurvePanGestureRecognizer) {
        let p = point(recognizer.location(in: self))
        switch recognizer.state {
        case .began:
            // UIKit 识别拖动时可能重置 translation，需保留落指至识别之间的位移。
            guard let origin = recognizer.initialLocation else { return }
            if begin(point(origin)) {
                becomeFirstResponder(); session.move(x: p.0, y: p.1)
            }
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

private struct ToneCurveInput: NSViewRepresentable {
    let configuration: ToneCurveInputConfiguration
    func makeNSView(context: Context) -> ToneCurveInputView { ToneCurveInputView() }
    func updateNSView(_ view: ToneCurveInputView, context: Context) { view.session.configure(configuration) }
    static func dismantleNSView(_ view: ToneCurveInputView, coordinator: ()) { view.session.cancel(deferred: true) }
}

final class ToneCurveInputView: NSView {
    let session = ToneCurveInputSession()
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
        return (Double((location.x - 12) / max(1, bounds.width - 24)), Double(1 - (location.y - 12) / max(1, bounds.height - 24)))
    }
    override func mouseDown(with event: NSEvent) {
        fineAtStart = event.modifierFlags.contains(.shift); let p = point(event)
        if session.begin(x: p.0, y: p.1, toleranceX: Double(12 / max(1, bounds.width - 24)),
            toleranceY: Double(12 / max(1, bounds.height - 24)), fine: fineAtStart) { window?.makeFirstResponder(self) }
    }
    override func mouseDragged(with event: NSEvent) { let p = point(event); session.move(x: p.0, y: p.1) }
    override func mouseUp(with event: NSEvent) { let p = point(event); session.move(x: p.0, y: p.1); session.end() }
    override func flagsChanged(with event: NSEvent) {
        if session.isActive && event.modifierFlags.contains(.shift) != fineAtStart { session.cancel() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session.cancel(); return }
        if event.keyCode == 51 || event.keyCode == 117 {
            session.key(remove: true); window?.makeFirstResponder(self); return
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            session.key(horizontal: event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0,
                vertical: event.keyCode == 125 ? -1 : event.keyCode == 126 ? 1 : 0, fine: event.modifierFlags.contains(.shift))
            window?.makeFirstResponder(self)
        } else { super.keyDown(with: event) }
    }
    @objc private func deactivated(_ notification: Notification) {
        if let source = notification.object as? NSWindow, source === window { session.cancel() }
    }
}
#endif
