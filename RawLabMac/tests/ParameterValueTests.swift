import AppKit
import CoreGraphics
import SwiftUI

@main
struct ParameterValueTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }
    final class ValueBox { var value: Double; init(_ value: Double) { self.value = value } }

    static func wheel(_ pixels: Int32, time: Double, fine: Bool = false, horizontal: Int32 = 0,
                       line: Bool = false, precise: Bool = true) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: line ? .line : .pixel, wheelCount: 2,
                            wheel1: pixels, wheel2: horizontal, wheel3: 0)!
        if precise { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        event.timestamp = UInt64(time * 1_000_000_000)
        if fine { event.flags = .maskShift }
        return NSEvent(cgEvent: event)!
    }

    static func fixture(_ value: Double, precision: ParameterPrecision = .exposure,
                        range: ClosedRange<Double> = -4...4,
                        invalidInputPolicy: ParameterInvalidInputPolicy = .restore,
                        onValidityChange: @escaping (Bool) -> Void = { _ in }) -> (ValueBox, NumericTextField, ParameterValueField.Coordinator) {
        let box = ValueBox(value)
        let parent = ParameterValueField(value: Binding(get: { box.value }, set: { box.value = $0 }),
                                         range: range, precision: precision, title: "Exposure", unit: "EV", identifier: "value.exposure",
                                         invalidInputPolicy: invalidInputPolicy, onValidityChange: onValidityChange)
        let coordinator = ParameterValueField.Coordinator(parent)
        let field = NumericTextField()
        field.cell = NumericTextFieldCell(textCell: "")
        field.wheelHandler = { [weak coordinator] in coordinator?.wheel($0) ?? false }
        field.stringValue = precision.text(value)
        field.isEnabled = true
        field.isEditable = true
        coordinator.field = field
        return (box, field, coordinator)
    }

    static func change(_ text: String, field: NumericTextField, coordinator: ParameterValueField.Coordinator) {
        field.stringValue = text
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    static func blur(_ field: NumericTextField, coordinator: ParameterValueField.Coordinator) {
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    static func drainDeferredValidity() {
        let deadline = Date().addingTimeInterval(0.02)
        while RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}
    }

    static func shiftHorizontalChecks() {
        let (ordinaryBox, ordinaryField, ordinaryCoordinator) = fixture(0.3)
        let ordinary = ordinaryCoordinator.wheel(wheel(0, time: 40, horizontal: 80))
        check(!ordinary && ordinaryBox.value == 0.3 && ordinaryField.stringValue == "0.30",
              "Ordinary horizontal scrolling passes through without changing a numeric field")

        let (fineBox, fineField, fineCoordinator) = fixture(0.3)
        let event = wheel(0, time: 40, fine: true, horizontal: 80)
        let fine = fineCoordinator.wheel(event)
        check(fine && fineBox.value == 0.31 && fineField.stringValue == "+0.31",
              "Shift horizontal scrolling applies one fine numeric step (accepted=\(fine), value=\(fineBox.value), dx=\(event.scrollingDeltaX), dy=\(event.scrollingDeltaY))")
    }

    static func discreteLineWheelChecks() {
        let (box, field, coordinator) = fixture(0.3)
        let event = wheel(1, time: 40, line: true, precise: false)
        check(!event.hasPreciseScrollingDeltas && event.scrollingDeltaY == 1,
              "The regression fixture is one non-precise native line notch")
        let accepted = coordinator.wheel(event)
        check(accepted && box.value == 0.4 && field.stringValue == "+0.40",
              "One discrete line notch applies one ordinary numeric step immediately (accepted=\(accepted), value=\(box.value), text=\(field.stringValue), dy=\(event.scrollingDeltaY), precise=\(event.hasPreciseScrollingDeltas))")
        check(coordinator.wheel(wheel(1, time: 40.02, line: true, precise: false)) && box.value == 0.5,
              "A second discrete notch is not dropped by the trackpad throttle")
    }

    static func valueFieldLayoutChecks() {
        let bounds = NSRect(x: 0, y: 0, width: 72, height: 26)
        let field = NumericTextField(frame: bounds)
        let cell = NumericTextFieldCell(textCell: "")
        field.cell = cell
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .right
        cell.font = field.font
        cell.alignment = .right
        cell.wraps = false
        cell.isScrollable = true
        field.stringValue = "+0.30"
        check(field.bounds.size == bounds.size && field.font?.pointSize == 13 && cell.font?.pointSize == 13,
              "The native value field uses a 72 by 26 frame and 13 point font")

        let drawing = cell.drawingRect(forBounds: bounds)
        let editor = cell.fieldEditor(for: field)!
        cell.edit(withFrame: bounds, in: field, editor: editor, delegate: nil, event: nil)
        cell.select(withFrame: bounds, in: field, editor: editor, delegate: nil, start: 0, length: field.stringValue.count)
        editor.string = field.stringValue
        guard let container = editor.textContainer, let layout = editor.layoutManager else {
            check(false, "The native cell edit/select path exposes a text layout")
            return
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let usedCenterY = editor.frame.minY + editor.textContainerOrigin.y + used.midY
        check(abs(usedCenterY - drawing.midY) < 0.5,
              "The field editor's used text is vertically centered with the drawing rect (used=\(used), origin=\(editor.textContainerOrigin), editor=\(editor.frame), usedCenterY=\(usedCenterY), drawing=\(drawing))")
    }

    static func main() {
        _ = NSApplication.shared
        if let focus = ProcessInfo.processInfo.environment["RAWLAB_PARAMETER_FOCUS"] {
            switch focus {
            case "shift-horizontal": shiftHorizontalChecks()
            case "line-wheel": discreteLineWheelChecks()
            case "cell-layout": valueFieldLayoutChecks()
            default: check(false, "Unknown parameter-value focus: \(focus)")
            }
            return
        }
        var exposure = 0.0
        for _ in 0..<40 { exposure = ParameterPrecision.exposure.stepped(exposure, direction: 1, fine: false, in: -4...4) }
        check(exposure == 4, "Forty ordinary EV steps reach the exact upper bound")
        for _ in 0..<800 { exposure = ParameterPrecision.exposure.stepped(exposure, direction: -1, fine: true, in: -4...4) }
        check(exposure == -4, "Repeated fine EV steps do not accumulate drift")
        check(ParameterPrecision.exposure.text(0.3, signed: true) == "+0.30", "Exposure always displays two decimals and its sign")
        check(ParameterPrecision.standard.text(25) == "25" && ParameterPrecision.standard.text(-25.1) == "-25.1", "Other values omit redundant decimal zero")
        check(ParameterPrecision.exposure.stepped(0.455, direction: 1, fine: false, in: -4...4) == 0.56,
              "A valid draft starts at its nearest fine grid tick")
        check(ParameterPrecision.standard.snapped(21.36, in: 0...100) == 21.4, "Percentage edits use a tenth grid")
        check(ParameterPrecision.exposure.parse(" nan ") == nil && ParameterPrecision.exposure.parse("-") == nil,
              "Nonfinite and incomplete drafts are rejected")
        check(ParameterPrecision.exposure.snapped(1e308, in: -4...4) == 4, "Large finite drafts clamp before grid arithmetic")
        let temperatureRange = 2000.0...50000.0
        let mapping = ParameterSliderMapping.reciprocalKelvin
        let middle = mapping.value(at: 0.5, in: temperatureRange)
        check(abs(middle - 3846.153846153846) < 0.00001, "Temperature slider retains reciprocal Kelvin mapping")
        check(abs(mapping.position(for: middle, in: temperatureRange) - 0.5) < 0.00001, "Reciprocal Kelvin position round trips")
        check(ParameterPrecision.temperature.stepped(5600, direction: 1, fine: false, in: temperatureRange) == 5700,
              "Temperature wheel uses a 100 K ordinary step")
        check(ParameterPrecision.temperature.stepped(5600, direction: -1, fine: true, in: temperatureRange) == 5590,
              "Shift uses a 10 K temperature step without reversing direction")

        var wheelState = ParameterWheelAccumulator()
        check(wheelState.handle(verticalPixels: 40, timestamp: 1, fine: false, editable: true, validValue: true) == .consume,
              "A field consumes below-threshold movement without accepting a step")
        check(wheelState.handle(verticalPixels: 40, timestamp: 1.05, fine: false, editable: true, validValue: true) == .step(1),
              "Per-field pixels accumulate to the 80 pixel threshold")
        check(wheelState.handle(verticalPixels: 2400, timestamp: 1.06, fine: false, editable: true, validValue: true) == .consume,
              "A burst is throttled within 125 ms")
        check(wheelState.handle(verticalPixels: 1, timestamp: 1.2, fine: false, editable: true, validValue: true) == .consume,
              "A throttled spike leaves no queued step")
        check(wheelState.handle(verticalPixels: 80, timestamp: 1.4, fine: false, editable: true, validValue: true) == .step(1),
              "A new event after the throttle can accept at most one step")
        wheelState.reset()
        _ = wheelState.handle(verticalPixels: 60, timestamp: 2, fine: false, editable: true, validValue: true)
        check(wheelState.handle(verticalPixels: 40, timestamp: 2.21, fine: false, editable: true, validValue: true) == .consume,
              "A 200 ms pause clears the partial threshold")
        check(wheelState.handle(verticalPixels: -50, timestamp: 2.22, fine: false, editable: true, validValue: true) == .consume,
              "A direction change discards the old remainder")
        check(wheelState.handle(verticalPixels: -30, timestamp: 2.23, fine: true, editable: true, validValue: true) == .consume,
              "A Shift change discards the old remainder")
        check(wheelState.handle(verticalPixels: -50, timestamp: 2.24, fine: true, editable: true, validValue: true) == .step(-1),
              "Only the new direction and Shift state accumulate")
        check(wheelState.handle(verticalPixels: 80, timestamp: 3, fine: false, editable: false, validValue: true) == .pass &&
              wheelState.handle(verticalPixels: 80, timestamp: 3, fine: false, editable: true, validValue: false) == .pass &&
              wheelState.handle(verticalPixels: .nan, timestamp: 3, fine: false, editable: true, validValue: true) == .pass &&
              wheelState.handle(verticalPixels: 0, timestamp: 3, fine: false, editable: true, validValue: true) == .pass,
              "Disabled, invalid, nonfinite and horizontal input passes through")
        check(wheelState.handle(verticalPixels: 800, timestamp: 3, fine: false, editable: true, validValue: true, momentum: true) == .consume,
              "Momentum cannot replay an adjustment")

        var restoreValidityEvents: [Bool] = []
        let (box, field, coordinator) = fixture(0.3, onValidityChange: { restoreValidityEvents.append($0) })
        field.stringValue = ".455"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        check(coordinator.wheel(wheel(40, time: 10)) && box.value == 0.3 && field.stringValue == ".455",
              "A valid draft stays uncommitted below the wheel threshold")
        check(coordinator.wheel(wheel(40, time: 10.05)) && box.value == 0.56 && field.stringValue == "+0.56",
              "Accepting a wheel step commits the draft and updates the field")
        field.stringValue = "-"
        check(!coordinator.wheel(wheel(80, time: 11)) && box.value == 0.56, "An invalid native field draft passes scrolling through")
        field.stringValue = "+4.00"
        check(coordinator.wheel(wheel(80, time: 12)) && box.value == 4, "An accepted step clamps at the upper bound")
        check(coordinator.wheel(wheel(80, time: 12.2)) && box.value == 4, "Valid wheel events remain consumed at the bound")
        field.stringValue = "1.234"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        check(box.value == 1.23 && field.stringValue == "+1.23", "Blur commits and snaps the numeric draft")
        field.stringValue = "abc"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        check(box.value == 1.23 && field.invalid && field.stringValue == "+1.23", "Invalid blur restores the current value with an error border")
        check(restoreValidityEvents.isEmpty, "Ordinary fields keep their existing restored-value error behavior without draft validity changes")
        check(field.toolTip == L10n.text("请输入有效数字") && field.accessibilityHelp() == field.toolTip,
              "Rejected input exposes a localized tooltip and accessible error explanation")
        field.invalid = false
        check(field.accessibilityHelp() != L10n.text("请输入有效数字"),
              "A corrected input clears the accessible error explanation")
        check(field.intrinsicContentSize == NSSize(width: 72, height: 26),
              "Native value field requests the designed 72 by 26 point bounds")
        check(field.alignmentRectInsets.left == 0 && field.alignmentRectInsets.right == 0,
              "Native alignment adds no width outside the value field border")
        field.stringValue = "2.5"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        check(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Escape is handled by the native field delegate")
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        check(box.value == 1.23 && field.stringValue == "+1.23" && !field.invalid, "Escape discards only the draft")
        let (cameraBox, cameraField, cameraCoordinator) = fixture(5274, precision: .temperature, range: temperatureRange)
        cameraCoordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: cameraField))
        cameraCoordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cameraField))
        check(cameraBox.value == 5274, "Focus and blur preserve an exact off-grid camera default")

        var validityEvents: [Bool] = []
        let (draftBox, draftField, draftCoordinator) = fixture(0.3, invalidInputPolicy: .retain,
                                                               onValidityChange: { validityEvents.append($0) })
        draftCoordinator.update(draftCoordinator.parent, isEnabled: true)
        check(validityEvents.isEmpty, "Creating and updating a valid draft field does not publish validity")
        draftCoordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: draftField))
        change("-", field: draftField, coordinator: draftCoordinator)
        check(validityEvents == [false] && draftField.invalid && !draftCoordinator.isValid && draftBox.value == 0.3,
              "Retained invalid typing reports invalidity immediately without changing the setting")
        change("abc", field: draftField, coordinator: draftCoordinator)
        check(validityEvents == [false], "Repeated invalid typing does not repeat the validity callback")
        check(draftCoordinator.control(draftField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))),
              "The retained draft field handles Enter")
        check(draftField.stringValue == "abc" && draftField.invalid && draftCoordinator.dirty && draftBox.value == 0.3,
              "Invalid Enter preserves the marked draft and the last valid setting")
        blur(draftField, coordinator: draftCoordinator)
        check(!draftCoordinator.editing && draftField.stringValue == "abc" && draftField.invalid && draftCoordinator.dirty,
              "Invalid blur preserves the draft after native editing ends")
        draftCoordinator.update(draftCoordinator.parent, isEnabled: true)
        check(draftField.stringValue == "abc" && draftField.invalid && validityEvents == [false],
              "A representable refresh keeps a blurred invalid draft for correction")
        check(draftField.toolTip == L10n.text("请输入有效数字") && draftField.accessibilityHelp() == draftField.toolTip,
              "Retained errors expose the existing tooltip and accessibility explanation")
        check(!draftCoordinator.wheel(wheel(80, time: 30)) && draftBox.value == 0.3 && draftField.stringValue == "abc",
              "An invalid retained draft passes wheel input without consuming or restoring it")
        draftCoordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: draftField))
        change("1.234", field: draftField, coordinator: draftCoordinator)
        check(validityEvents == [false, true] && !draftField.invalid && draftBox.value == 0.3,
              "Correcting the draft clears its invalidity before committing a value")
        blur(draftField, coordinator: draftCoordinator)
        check(draftBox.value == 1.23 && draftField.stringValue == "+1.23" && !draftCoordinator.dirty && draftCoordinator.isValid,
              "A corrected retained draft commits and snaps normally on blur")
        change("nan", field: draftField, coordinator: draftCoordinator)
        blur(draftField, coordinator: draftCoordinator)
        check(draftCoordinator.control(draftField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))),
              "Escape is handled for a retained invalid draft")
        blur(draftField, coordinator: draftCoordinator)
        check(draftField.stringValue == "+1.23" && !draftField.invalid && !draftCoordinator.dirty &&
              draftCoordinator.isValid && validityEvents == [false, true, false, true] && draftBox.value == 1.23,
              "Escape restores only the field draft and reports recovery without changing the setting")

        change("incomplete", field: draftField, coordinator: draftCoordinator)
        blur(draftField, coordinator: draftCoordinator)
        var resetParent = draftCoordinator.parent
        resetParent.resetRevision += 1
        let beforeReset = validityEvents.count
        draftCoordinator.update(resetParent, isEnabled: true)
        check(draftField.stringValue == "+1.23" && !draftField.invalid && !draftCoordinator.dirty &&
              draftCoordinator.isValid && validityEvents.count == beforeReset,
              "A same-value reset clears the retained draft without publishing during the representable update")
        drainDeferredValidity()
        check(validityEvents.last == true && validityEvents.count == beforeReset + 1,
              "A same-value reset reports recovered validity after the native update")
        change("bad", field: draftField, coordinator: draftCoordinator)
        blur(draftField, coordinator: draftCoordinator)
        draftBox.value = -2.4
        let beforeExternal = validityEvents.count
        draftCoordinator.update(draftCoordinator.parent, isEnabled: true)
        check(draftField.stringValue == "-2.40" && !draftField.invalid && !draftCoordinator.dirty &&
              draftCoordinator.isValid && validityEvents.count == beforeExternal,
              "An external setting change replaces an invalid draft and defers its recovery notification")
        drainDeferredValidity()
        check(validityEvents.last == true && validityEvents.count == beforeExternal + 1,
              "External changes report recovered validity after the representable update")

        change("bad", field: draftField, coordinator: draftCoordinator)
        draftField.stringValue = "-1.1"
        check(draftCoordinator.wheel(wheel(80, time: 31)) && draftBox.value == -1 && !draftField.invalid &&
              !draftCoordinator.dirty && draftCoordinator.isValid && validityEvents.last == true,
              "An accepted wheel step commits a corrected draft and clears retained invalidity")
        change("bad", field: draftField, coordinator: draftCoordinator)
        resetParent = draftCoordinator.parent
        resetParent.resetRevision += 1
        draftCoordinator.update(resetParent, isEnabled: true)
        change("still bad", field: draftField, coordinator: draftCoordinator)
        let afterNewDraft = validityEvents.count
        drainDeferredValidity()
        check(!draftCoordinator.isValid && draftField.invalid && validityEvents.last == false && validityEvents.count == afterNewDraft,
              "A deferred reset recovery cannot re-enable Apply after a newer invalid edit")

        let (focusedBox, focusedField, _) = fixture(0.3)
        let focusedCoordinator = ParameterValueField.Coordinator(ParameterValueField(
            value: Binding(get: { focusedBox.value }, set: { focusedBox.value = $0 }),
            range: -4...4, precision: .exposure, title: "Exposure", unit: "EV", identifier: "value.exposure"))
        focusedCoordinator.field = focusedField
        focusedField.wheelHandler = { [weak focusedCoordinator] in focusedCoordinator?.wheel($0) ?? false }
        let editor = focusedField.cell!.fieldEditor(for: focusedField)!
        check(editor.isFieldEditor && editor is NumericFieldEditor, "Every numeric cell owns its native field editor")
        editor.scrollWheel(with: wheel(80, time: 20))
        check(focusedBox.value == 0.4, "Focused text editor routes wheel adjustment to its own numeric field")

        var settings = Adjustments()
        settings.resolveWhiteBalance(WhiteBalance(temperature: 5274, tint: 3.27))
        settings.set(.temperature, to: 7000)
        settings.set(.tint, to: 12.1)
        let temperatureDefault = AdjustmentParameter.temperature.spec(for: settings).defaultValue
        let tintDefault = AdjustmentParameter.tint.spec(for: settings).defaultValue
        settings.set(.temperature, to: temperatureDefault)
        settings.set(.tint, to: tintDefault)
        check(settings.temperature == 5274 && settings.tint == 3.27 && settings.whiteBalanceMode == .asShot,
              "Per-parameter reset preserves exact camera temperature and tint")
        settings.setEffect(.grainAmount, to: 10.14)
        settings.setDenoiseParameter(.luma, to: 20.16)
        check(settings.effectSettings.grainAmount == 10.1 && settings.waveletSettings.luma == 20.2,
              "Effects and denoise preserve the fine tenth grid in saved settings")
        check(AdjustmentParameter.strength.spec.multiplier == 100 && AdjustmentParameter.strength.spec.step == 0.001 &&
              AdjustmentParameter.sharpening.spec.multiplier == 1 && AdjustmentParameter.sharpening.spec.step == 0.1,
              "Strength and sharpening retain their engine-to-display mappings")
        shiftHorizontalChecks()
        discreteLineWheelChecks()
        valueFieldLayoutChecks()
        rowAlignmentChecks()
        print("PASS: parameter value precision and native field regressions")
    }

    // ------------------------------------------------------------------------
    //  隐藏重置按钮时保留它的位置：收起的暗角只显示强度一行，数值框不能比其他面板的偏右
    // ------------------------------------------------------------------------
    static func rowAlignmentChecks() {
        func width(_ showsReset: Bool) -> CGFloat {
            NSHostingView(rootView: ParameterRow(title: "Amount", value: .constant(0), range: -100...100, defaultValue: 0,
                                                 identifier: "value.alignment", showsReset: showsReset)).fittingSize.width
        }
        check(width(false) == width(true), "A row without its reset button keeps the reset column")
    }
}
