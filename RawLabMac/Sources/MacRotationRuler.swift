import AppKit
import SwiftUI

enum MacRotationRulerMath {
    static let range = -45.0...45.0
    static let visibleSpan = 30.0

    static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        let result = (bounded * 10).rounded() / 10
        return result == 0 ? 0 : result
    }

    static func dragged(from value: Double, translation: CGFloat, width: CGFloat) -> Double {
        guard value.isFinite, translation.isFinite, width.isFinite, width > 0 else { return snapped(value) }
        // The scale moves under the stationary center marker.
        return snapped(value - Double(translation / width) * visibleSpan)
    }

    static func stepped(_ value: Double, direction: Int) -> Double {
        snapped((snapped(value) * 10 + Double(direction)) / 10)
    }

    static func position(for angle: Double, current: Double, width: CGFloat) -> CGFloat {
        width / 2 + CGFloat((angle - current) / visibleSpan) * width
    }

    static func visibleTicks(current: Double, width: CGFloat) -> [Double] {
        guard current.isFinite, width.isFinite, width > 0 else { return [] }
        return (-90...90).map { Double($0) / 2 }.filter {
            let x = position(for: $0, current: current, width: width)
            return x >= 0 && x <= width
        }
    }
}

/// A local native ruler; it does not register an event monitor or intercept scrolling.
struct MacRotationRuler: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MacRotationRulerView { MacRotationRulerView() }

    func updateNSView(_ view: MacRotationRulerView, context: Context) {
        view.value = value
        view.isEnabled = isEnabled
        view.onValueChanged = { value = $0 }
        view.onEditingChanged = onEditingChanged
        view.setAccessibilityLabel(L10n.text("拉直"))
        view.setAccessibilityIdentifier("geometry.straighten.ruler")
        view.setAccessibilityHelp(L10n.text("左右拖动刻度尺拉直；方向键每次调整 0.1°"))
        view.toolTip = L10n.text("左右拖动刻度尺拉直；方向键每次调整 0.1°")
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacRotationRulerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 52)
    }
}

final class MacRotationRulerView: NSControl {
    var value = 0.0 { didSet { needsDisplay = true } }
    var onValueChanged: (Double) -> Void = { _ in }
    var onEditingChanged: (Bool) -> Void = { _ in }
    private var dragOrigin: (value: Double, x: CGFloat)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        guard width > 0 else { return }
        let current = MacRotationRulerMath.snapped(value)
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color
        ]
        for angle in MacRotationRulerMath.visibleTicks(current: current, width: width) {
            let x = MacRotationRulerMath.position(for: angle, current: current, width: width)
            let major = angle.truncatingRemainder(dividingBy: 5) == 0
            let integer = angle.rounded() == angle
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: 8))
            tick.line(to: NSPoint(x: x, y: major ? 30 : (integer ? 25 : 20)))
            tick.lineWidth = increasedContrast ? 1.5 : 1
            color.setStroke(); tick.stroke()
            if major {
                let label = angle == 0 ? "0°" : String(format: "%+.0f°", angle)
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: min(width - size.width, max(0, x - size.width / 2)), y: 35),
                           withAttributes: attributes)
            }
        }
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: width / 2, y: 4))
        marker.line(to: NSPoint(x: width / 2, y: 32))
        marker.lineWidth = 2
        (isEnabled ? NSColor.systemYellow : NSColor.disabledControlTextColor).setStroke()
        marker.stroke()
        if window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            focus.lineWidth = 2; NSColor.keyboardFocusIndicatorColor.setStroke(); focus.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    func beginDragging(at x: CGFloat) {
        guard isEnabled, x.isFinite else { return }
        dragOrigin = (value, x)
        onEditingChanged(true)
    }

    func continueDragging(to x: CGFloat) {
        guard isEnabled, let origin = dragOrigin else { return }
        accept(MacRotationRulerMath.dragged(from: origin.value, translation: x - origin.x, width: bounds.width))
    }

    func finishDragging() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        onEditingChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)
        beginDragging(at: convert(event.locationInWindow, from: nil).x)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            continueDragging(to: convert(next.locationInWindow, from: nil).x)
            if next.type == .leftMouseUp { break }
        }
        finishDragging()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 125: step(direction: -1)
        case 124, 126: step(direction: 1)
        default: super.keyDown(with: event)
        }
    }

    private func accept(_ newValue: Double) {
        guard newValue != value else { return }
        value = newValue
        onValueChanged(newValue)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func step(direction: Int) {
        guard isEnabled else { return }
        onEditingChanged(true)
        accept(MacRotationRulerMath.stepped(value, direction: direction))
        onEditingChanged(false)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: MacRotationRulerMath.range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: MacRotationRulerMath.range.upperBound) }
    override func accessibilityValueDescription() -> String? { String(format: "%+.1f°", value == 0 ? 0 : value) }
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEnabled, let number = accessibilityValue as? NSNumber, number.doubleValue.isFinite else { return }
        onEditingChanged(true)
        accept(MacRotationRulerMath.snapped(number.doubleValue))
        onEditingChanged(false)
    }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; step(direction: 1); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; step(direction: -1); return true }
}
