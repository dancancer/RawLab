import AppKit
import SwiftUI

enum ParameterInvalidInputPolicy {
    case restore, retain
}

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
    var invalidInputPolicy: ParameterInvalidInputPolicy = .restore
    var onValidityChange: (Bool) -> Void = { _ in }

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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NumericTextField, context: Context) -> CGSize? {
        CGSize(width: 72, height: 26)
    }

    func updateNSView(_ field: NumericTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = field
        coordinator.update(self, isEnabled: isEnabled)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ParameterValueField
        weak var field: NumericTextField?
        var editing = false
        var dirty = false
        var lastValue: Double
        var resetRevision: Int
        private(set) var isValid = true
        private var retainedInvalidDraft = false
        private var validityRevision = 0
        private var wheelState = ParameterWheelAccumulator()

        init(_ parent: ParameterValueField) {
            self.parent = parent
            lastValue = parent.value
            resetRevision = parent.resetRevision
        }

        func update(_ parent: ParameterValueField, isEnabled: Bool) {
            guard let field else { return }
            let externalChange = lastValue != parent.value
            let reset = resetRevision != parent.resetRevision
            self.parent = parent
            lastValue = parent.value
            resetRevision = parent.resetRevision
            field.isEnabled = isEnabled
            field.isEditable = isEnabled
            field.setAccessibilityIdentifier(parent.identifier)
            field.setAccessibilityLabel(L10n.format("%@数值", parent.title))
            field.normalHelp = L10n.format("滚轮：%@；Shift：%@；范围：%@ 至 %@ %@",
                                           parent.precision.text(parent.precision.normalStep),
                                           parent.precision.text(parent.precision.fineStep),
                                           parent.precision.text(parent.range.lowerBound),
                                           parent.precision.text(parent.range.upperBound), parent.unit)
            if externalChange || reset || (!editing && !retainedInvalidDraft) {
                write(parent.precision.text(parent.value, signed: parent.signed))
                dirty = false
                if externalChange || reset {
                    retainedInvalidDraft = false
                    field.invalid = false
                    // A representable update must not publish SwiftUI state synchronously.
                    setValidity(true, deferred: true)
                }
            }
            field.needsDisplay = true
        }

        private func setValidity(_ valid: Bool, deferred: Bool = false) {
            guard isValid != valid else { return }
            isValid = valid
            validityRevision += 1
            if deferred {
                let revision = validityRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.validityRevision == revision else { return }
                    self.parent.onValidityChange(valid)
                }
            } else {
                parent.onValidityChange(valid)
            }
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
            if parent.invalidInputPolicy == .retain, let field {
                let valid = parent.precision.parse(field.currentEditor()?.string ?? field.stringValue) != nil
                retainedInvalidDraft = !valid
                field.invalid = !valid
                setValidity(valid)
            } else {
                field?.invalid = false
            }
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
                retainedInvalidDraft = false
                field?.invalid = false
                setValidity(true)
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
                    retainedInvalidDraft = false
                    field.invalid = false
                    setValidity(true)
                } else {
                    field.invalid = true
                    if parent.invalidInputPolicy == .retain {
                        retainedInvalidDraft = true
                        setValidity(false)
                    }
                    if let app = NSApp {
                        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
                            .announcement: L10n.text("请输入有效数字"),
                            .priority: NSAccessibilityPriorityLevel.high.rawValue
                        ])
                    }
                    if parent.invalidInputPolicy == .retain {
                        write(field.currentEditor()?.string ?? field.stringValue)
                        field.needsDisplay = true
                        return
                    }
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
                retainedInvalidDraft = false
                field.invalid = false
                setValidity(true)
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
    var invalid = false {
        didSet { updateHelp(); needsDisplay = true }
    }
    var normalHelp = "" {
        didSet { updateHelp() }
    }
    var acceptedUntil: TimeInterval = 0
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: 72, height: 26) }
    // This border is drawn in bounds; NSTextField's default alignment insets would add four points.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    private func updateHelp() {
        let message = invalid ? L10n.text("请输入有效数字") : normalHelp
        toolTip = message
        setAccessibilityHelp(message)
    }

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
        if invalid, let icon = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: 4, y: (bounds.height - 10) / 2, width: 10, height: 10))
        }
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
