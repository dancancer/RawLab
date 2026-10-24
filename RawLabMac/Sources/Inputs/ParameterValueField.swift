import AppKit
import SwiftUI

enum ParameterInvalidInputPolicy {
    case restore, retain
}

private struct ParameterInputScopeKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var parameterInputScope: String {
        get { self[ParameterInputScopeKey.self] }
        set { self[ParameterInputScopeKey.self] = newValue }
    }
}

struct ParameterValueField: NSViewRepresentable {
    @Environment(\.parameterInputScope) private var sourceScope
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    let precision: ParameterPrecision
    let title: String
    let unit: String
    let identifier: String
    var defaultValue: Double = 0
    var fontSize: CGFloat = 13
    var inputScope = ""
    var onValidationMessage: (String?) -> Void = { _ in }
    var resetRevision = 0
    var onEditingChanged: (Bool) -> Void = { _ in }
    var invalidInputPolicy: ParameterInvalidInputPolicy = .restore
    var onValidityChange: (Bool) -> Void = { _ in }

    static var hasPendingInputs: Bool { Coordinator.instances.allObjects.contains { $0.dirty } }

    static func cancelPendingInputs() {
        for coordinator in Coordinator.instances.allObjects { coordinator.cancel() }
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    static func resolvePendingInputs() -> Bool {
        let pending = Coordinator.instances.allObjects.filter { $0.dirty }
        guard !pending.isEmpty else { return true }
        pending.forEach { $0.preflightPending = true }
        defer { pending.forEach { $0.preflightPending = false } }
        let alert = NSAlert()
        alert.messageText = L10n.text("数值输入尚未提交")
        alert.informativeText = L10n.text("应用有效输入、放弃输入，或返回继续编辑。")
        alert.addButton(withTitle: L10n.text("应用输入"))
        alert.addButton(withTitle: L10n.text("放弃输入"))
        alert.addButton(withTitle: L10n.text("继续编辑"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard pending.allSatisfy({ $0.commit() }) else {
                if let field = pending.first(where: { $0.dirty })?.field { field.window?.makeFirstResponder(field) }
                return false
            }
            NSApp?.keyWindow?.makeFirstResponder(nil)
            return true
        case .alertSecondButtonReturn: cancelPendingInputs(); return true
        default:
            if let field = pending.first?.field { field.window?.makeFirstResponder(field) }
            return false
        }
    }

    @discardableResult static func commitPendingInputs() -> Bool {
        let valid = Coordinator.instances.allObjects.map { $0.commit() }.allSatisfy { $0 }
        if valid { NSApp?.keyWindow?.makeFirstResponder(nil) }
        return valid
    }

    static func dismantleNSView(_ field: NumericTextField, coordinator: Coordinator) {
        coordinator.cancel(deferred: true)
    }

    private var signed: Bool { range.lowerBound < 0 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NumericTextField {
        let field = NumericTextField()
        field.delegate = context.coordinator
        field.cell = NumericTextFieldCell(textCell: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        field.textColor = value == defaultValue ? .labelColor : .systemYellow
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
        CGSize(width: max(72, (precision.text(value, signed: signed) as NSString).size(withAttributes: [.font: nsView.font!]).width + 24), height: max(26, fontSize + 13))
    }

    func updateNSView(_ field: NumericTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = field
        coordinator.update(self, isEnabled: isEnabled)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        static let instances = NSHashTable<Coordinator>.weakObjects()
        var parent: ParameterValueField
        weak var field: NumericTextField?
        var editing = false
        var dirty = false
        var preflightPending = false
        var lastValue: Double
        var resetRevision: Int
        private(set) var isValid = true
        private var retainedInvalidDraft = false
        private var validityRevision = 0
        private var validationRevision = 0
        private var wheelState = ParameterWheelAccumulator()
        private var wheelInteracting = false
        private var wheelRevision = 0

        init(_ parent: ParameterValueField) {
            self.parent = parent
            lastValue = parent.value
            resetRevision = parent.resetRevision
            super.init()
            Self.instances.add(self)
            NotificationCenter.default.addObserver(self, selector: #selector(applicationWillHide), name: NSApplication.willHideNotification, object: nil)
        }

        @objc private func applicationWillHide() { cancel() }
        deinit { NotificationCenter.default.removeObserver(self) }

        func update(_ parent: ParameterValueField, isEnabled: Bool) {
            guard let field else { return }
            let externalChange = lastValue != parent.value
            let reset = resetRevision != parent.resetRevision || self.parent.inputScope != parent.inputScope || self.parent.sourceScope != parent.sourceScope
            self.parent = parent
            lastValue = parent.value
            resetRevision = parent.resetRevision
            field.font = .monospacedDigitSystemFont(ofSize: parent.fontSize, weight: .regular)
            field.cell?.font = field.font
            field.textColor = parent.value == parent.defaultValue ? .labelColor : .systemYellow
            field.setAccessibilityValueDescription(parent.value == parent.defaultValue ? L10n.text("未调整") : L10n.text("已调整"))
            field.isEnabled = isEnabled
            field.isEditable = isEnabled
            field.setAccessibilityIdentifier(parent.identifier)
            field.setAccessibilityLabel(L10n.format("%@数值", parent.title))
            let metadata = L10n.format("默认值：%@；范围：%@ 至 %@；步进：%@。",
                parent.precision.text(parent.defaultValue) + parent.unit,
                parent.precision.text(parent.range.lowerBound) + parent.unit,
                parent.precision.text(parent.range.upperBound) + parent.unit,
                parent.precision.fineStepText + parent.unit)
            field.normalHelp = metadata + " " + L10n.format("滚轮：%@；Shift：%@；范围：%@ 至 %@ %@",
                                           parent.precision.text(parent.precision.normalStep),
                                           parent.precision.fineStepText,
                                           parent.precision.text(parent.range.lowerBound),
                                           parent.precision.text(parent.range.upperBound), parent.unit)
            if externalChange || reset || (!editing && !retainedInvalidDraft) {
                write(parent.precision.text(parent.value, signed: parent.signed))
                dirty = false
                if externalChange || reset {
                    retainedInvalidDraft = false
                    field.invalid = false
                    field.validationMessage = nil
                    reportValidation(nil, deferred: true)
                    // A representable update must not publish SwiftUI state synchronously.
                    setValidity(true, deferred: true)
                }
            }
            field.needsDisplay = true
        }

        private func reportValidation(_ message: String?, deferred: Bool = false) {
            validationRevision += 1
            guard deferred else { parent.onValidationMessage(message); return }
            let revision = validationRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.validationRevision == revision else { return }
                self.parent.onValidationMessage(message)
            }
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
        }

        private func validationMessage(_ text: String) -> String? {
            if parent.precision.isUnchangedDisplay(text, original: parent.value) { return nil }
            guard let value = parent.precision.parse(text) else { return L10n.text("请输入有效数字") }
            guard parent.range.contains(value) else { return L10n.text("请输入范围内的有效数字") }
            guard parent.precision.accepts(value, original: parent.value, in: parent.range) else {
                return L10n.format("请使用 %@ 的步进。", parent.precision.fineStepText)
            }
            return nil
        }

        func controlTextDidChange(_ notification: Notification) {
            dirty = true
            guard let field else { return }
            let message = validationMessage(field.currentEditor()?.string ?? field.stringValue)
            retainedInvalidDraft = message != nil
            field.validationMessage = message
            field.invalid = message != nil
            reportValidation(message)
            if parent.invalidInputPolicy == .retain { setValidity(message == nil) }
        }

        func cancel(deferred: Bool = false) {
            write(parent.precision.text(parent.value, signed: parent.signed))
            dirty = false
            retainedInvalidDraft = false
            field?.invalid = false
            field?.validationMessage = nil
            reportValidation(nil, deferred: deferred)
            setValidity(true, deferred: deferred)
            wheelState.reset()
            editing = false
            field?.editing = false
            finishWheelInteraction(deferred: deferred)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if !preflightPending { commit() }
            editing = false
            field?.editing = false
            field?.needsDisplay = true
            finishWheelInteraction()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent.precision == .cropPercent {
                if commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) {
                    _ = step(commandSelector == #selector(NSResponder.moveUp(_:)) ? 1 : -1,
                             fine: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancel()
                field?.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if commit() { field?.window?.makeFirstResponder(nil) }
                return true
            }
            return false
        }

        @discardableResult func commit() -> Bool {
            guard let field else { return true }
            if dirty {
                let draft = field.currentEditor()?.string ?? field.stringValue
                if let message = validationMessage(draft) {
                    retainedInvalidDraft = true
                    field.validationMessage = message
                    field.invalid = true
                    reportValidation(message)
                    if parent.invalidInputPolicy == .retain { setValidity(false) }
                    write(draft)
                    if let app = NSApp {
                        NSAccessibility.post(element: app, notification: .announcementRequested,
                            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                    }
                    return false
                }
                if !parent.precision.isUnchangedDisplay(draft, original: parent.value),
                   let parsed = parent.precision.parse(draft), parsed != parent.value {
                    parent.value = parsed
                    lastValue = parent.value
                }
                retainedInvalidDraft = false
                field.invalid = false
                field.validationMessage = nil
                reportValidation(nil)
                setValidity(true)
            }
            write(parent.precision.text(parent.value, signed: parent.signed))
            dirty = false
            field.needsDisplay = true
            return true
        }

        @discardableResult func step(_ direction: Int, fine: Bool) -> Bool {
            guard let field, field.isEnabled, field.isEditable, commit() else { return false }
            let next = parent.precision.stepped(parent.value, direction: direction, fine: fine, in: parent.range)
            if next != parent.value { parent.value = next }
            lastValue = parent.value
            write(parent.precision.text(parent.value, signed: parent.signed))
            return true
        }

        private func finishWheelInteraction(deferred: Bool = false) {
            wheelRevision += 1
            guard wheelInteracting else { return }
            wheelInteracting = false
            if deferred { DispatchQueue.main.async { [parent] in parent.onEditingChanged(false) } }
            else { parent.onEditingChanged(false) }
        }

        private func beginWheelInteraction() {
            if !wheelInteracting { wheelInteracting = true; parent.onEditingChanged(true) }
            wheelRevision += 1
            let revision = wheelRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.wheelRevision == revision else { return }
                self.finishWheelInteraction()
            }
        }

        func wheel(_ event: NSEvent) -> Bool {
            guard let field else { return false }
            let draft = field.currentEditor()?.string ?? field.stringValue
            let starting = parent.precision.isUnchangedDisplay(draft, original: parent.value)
                ? parent.value : parent.precision.parse(draft)
            let fine = event.modifierFlags.contains(.shift)
            // Shift 滚轮可能由 AppKit 转为横轴；普通横向滚动仍交给父视图。
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : (fine ? event.scrollingDeltaX : 0)
            let result = wheelState.handle(verticalPixels: delta,
                                           timestamp: event.timestamp, fine: fine,
                                           editable: field.isEnabled && field.isEditable,
                                           validValue: parent.value.isFinite && starting != nil &&
                                               (parent.precision != .cropPercent || validationMessage(draft) == nil),
                                           momentum: event.momentumPhase != [], discrete: !event.hasPreciseScrollingDeltas)
            switch result {
            case .pass: return false
            case .consume: return true
            case .step(let direction):
                guard let starting else { return false }
                let next = parent.precision.stepped(starting, direction: direction, fine: fine, in: parent.range)
                if next != parent.value {
                    beginWheelInteraction()
                    parent.value = next
                }
                lastValue = parent.value
                write(parent.precision.text(parent.value, signed: parent.signed))
                dirty = false
                retainedInvalidDraft = false
                field.invalid = false
                field.validationMessage = nil
                reportValidation(nil)
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
    var validationMessage: String? { didSet { updateHelp() } }
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
        let message = invalid ? (validationMessage ?? L10n.text("请输入有效数字")) : normalHelp
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
        editor.allowsUndo = true
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

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: start, length: length)
    }
}

/// The field editor is owned by this cell so focused typing has the same local wheel behavior.
final class NumericFieldEditor: NSTextView {
    weak var owner: NumericTextField?

    override func scrollWheel(with event: NSEvent) {
        if owner?.wheelHandler?(event) != true { super.scrollWheel(with: event) }
    }
}
