import AppKit
import SwiftUI

@main
struct ParameterValueTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }
    final class ValueBox { var value: Double; init(_ value: Double) { self.value = value } }

    static func wheel(_ pixels: Int32, time: Double, fine: Bool = false, horizontal: Int32 = 0) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: pixels, wheel2: horizontal, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.timestamp = UInt64(time * 1_000_000_000)
        if fine { event.flags = .maskShift }
        return NSEvent(cgEvent: event)!
    }

    static func fixture(_ value: Double, precision: ParameterPrecision = .exposure,
                        range: ClosedRange<Double> = -4...4) -> (ValueBox, NumericTextField, ParameterValueField.Coordinator) {
        let box = ValueBox(value)
        let parent = ParameterValueField(value: Binding(get: { box.value }, set: { box.value = $0 }),
                                         range: range, precision: precision, title: "Exposure", unit: "EV", identifier: "value.exposure")
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

    static func main() {
        _ = NSApplication.shared
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

        let (box, field, coordinator) = fixture(0.3)
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
        print("PASS: parameter value precision and native field regressions")
    }
}
