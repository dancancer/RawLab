import AppKit
import SwiftUI

struct ParameterValueField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let precision: ParameterPrecision
    let title: String
    let unit: String
    let identifier: String
    var resetRevision = 0
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var signed: Bool { range.lowerBound < 0 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NumericTextField {
        let field = NumericTextField()
        field.delegate = context.coordinator
        field.cell = NumericTextFieldCell(textCell: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.textColor = .systemYellow
        field.alignment = .right
        field.cell?.font = field.font
        field.cell?.alignment = .right
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(L10n.format("%@数值", title))
        field.wheelHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.wheel(event) ?? false
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NumericTextField, context: Context) {
        let coordinator = context.coordinator
        let externalChange = coordinator.lastValue != value
        let reset = coordinator.resetRevision != resetRevision
        coordinator.parent = self
        coordinator.lastValue = value
        coordinator.resetRevision = resetRevision
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(L10n.format("%@数值", title))
        field.toolTip = L10n.format("滚轮：%@；Shift：%@；范围：%@ 至 %@ %@",
                                   precision.text(precision.normalStep), precision.text(precision.fineStep),
                                   precision.text(range.lowerBound), precision.text(range.upperBound), unit)
        if !coordinator.editing || externalChange || reset {
            coordinator.write(precision.text(value, signed: signed))
            coordinator.dirty = false
            if externalChange || reset { field.invalid = false }
        }
        field.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ParameterValueField
        weak var field: NumericTextField?
        var editing = false
        var dirty = false
        var lastValue: Double
        var resetRevision: Int
        private var wheelState = ParameterWheelAccumulator()

        init(_ parent: ParameterValueField) {
            self.parent = parent
            lastValue = parent.value
            resetRevision = parent.resetRevision
        }

        func write(_ text: String) {
            field?.stringValue = text
            field?.currentEditor()?.string = text
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            editing = true
            field?.editing = true
            field?.needsDisplay = true
            parent.onEditingChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            dirty = true
            field?.invalid = false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commit()
            editing = false
            field?.editing = false
            field?.needsDisplay = true
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                write(parent.precision.text(parent.value, signed: parent.signed))
                dirty = false
                field?.invalid = false
                field?.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commit()
                field?.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        private func commit() {
            guard let field else { return }
            // Merely focusing an as-shot value must not snap the camera default.
            if dirty {
                if let parsed = parent.precision.parse(field.currentEditor()?.string ?? field.stringValue) {
                    parent.value = parent.precision.snapped(parsed, in: parent.range)
                    lastValue = parent.value
                    field.invalid = false
                } else {
                    field.invalid = true
                }
            }
            write(parent.precision.text(parent.value, signed: parent.signed))
            dirty = false
            field.needsDisplay = true
        }

        func wheel(_ event: NSEvent) -> Bool {
            guard let field else { return false }
            let draft = field.currentEditor()?.string ?? field.stringValue
            let starting = parent.precision.parse(draft)
            let result = wheelState.handle(verticalPixels: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 40),
                                           timestamp: event.timestamp, fine: event.modifierFlags.contains(.shift),
                                           editable: field.isEnabled && field.isEditable,
                                           validValue: parent.value.isFinite && starting != nil,
                                           momentum: event.momentumPhase != [])
            switch result {
            case .pass: return false
            case .consume: return true
            case .step(let direction):
                guard let starting else { return false }
                parent.value = parent.precision.stepped(starting, direction: direction,
                                                       fine: event.modifierFlags.contains(.shift), in: parent.range)
                lastValue = parent.value
                write(parent.precision.text(parent.value, signed: parent.signed))
                dirty = false
                field.invalid = false
                field.acceptedUntil = event.timestamp + 0.18
                field.needsDisplay = true
                // This only clears the transient border; it never schedules a value change.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak field] in field?.needsDisplay = true }
                return true
            }
        }
    }
}

final class NumericTextField: NSTextField {
    var wheelHandler: ((NSEvent) -> Bool)?
    var editing = false
    var invalid = false
    var acceptedUntil: TimeInterval = 0
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        if wheelHandler?(event) != true { super.scrollWheel(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        shape.fill()
        let accepted = ProcessInfo.processInfo.systemUptime < acceptedUntil
        let edge: NSColor = invalid ? .systemRed : (editing || accepted ? .systemYellow : NSColor(calibratedWhite: hovering ? 0.55 : 0.35, alpha: 1))
        edge.setStroke()
        shape.lineWidth = editing ? 2 : 1
        shape.stroke()
        super.draw(dirtyRect)
    }
}

final class NumericTextFieldCell: NSTextFieldCell {
    private let editor = NumericFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.owner = controlView as? NumericTextField
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.drawsBackground = false
        editor.insertionPointColor = .systemYellow
        return editor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect.insetBy(dx: 7, dy: 0))
        let height = cellSize(forBounds: result).height
        result.origin.y += max(0, (result.height - height) / 2)
        result.size.height = min(result.height, height)
        return result
    }
}

/// The field editor is owned by this cell so focused typing has the same local wheel behavior.
final class NumericFieldEditor: NSTextView {
    weak var owner: NumericTextField?

    override func scrollWheel(with event: NSEvent) {
        if owner?.wheelHandler?(event) != true { super.scrollWheel(with: event) }
    }
}
