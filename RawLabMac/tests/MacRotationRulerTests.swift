import AppKit
import Foundation

@main struct MacRotationRulerTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }

    static func main() {
        _ = NSApplication.shared
        check(MacRotationRulerMath.snapped(1.24) == 1.2 && MacRotationRulerMath.snapped(-1.26) == -1.3,
              "Ruler snaps both signs to one tenth of a degree")
        check(MacRotationRulerMath.snapped(1e100) == 45 && MacRotationRulerMath.snapped(-1e100) == -45,
              "Ruler clamps before grid arithmetic")
        check(MacRotationRulerMath.snapped(.nan) == 0 && MacRotationRulerMath.snapped(.infinity) == 0,
              "Nonfinite state cannot enter ruler calculations")
        let zero = MacRotationRulerMath.snapped(-0.001)
        check(zero == 0 && zero.sign == .plus, "Straightening does not show negative zero")
        check(MacRotationRulerMath.dragged(from: 1.2, translation: 16, width: 480) == 0.2,
              "At design width one degree uses sixteen points of ruler travel")
        check(MacRotationRulerMath.dragged(from: 1.2, translation: -8, width: 240) == 2.2,
              "Narrow ruler retains its thirty degree visible span")
        check(MacRotationRulerMath.dragged(from: 0, translation: -1.6, width: 480) == 0.1,
              "Dragging resolves tenths rather than whole degrees")
        check(MacRotationRulerMath.dragged(from: 44.9, translation: -5000, width: 300) == 45 &&
              MacRotationRulerMath.dragged(from: -44.9, translation: 5000, width: 300) == -45,
              "Dragging clamps to the renderer's supported forty five degree bounds")
        check(MacRotationRulerMath.dragged(from: 1.23, translation: .nan, width: 300) == 1.2 &&
              MacRotationRulerMath.dragged(from: 1.23, translation: 10, width: 0) == 1.2,
              "Invalid drag geometry preserves the finite snapped angle")
        var angle = -45.0
        for _ in 0..<900 { angle = MacRotationRulerMath.stepped(angle, direction: 1) }
        check(angle == 45, "Repeated keyboard steps reach the exact positive bound without drift")
        for _ in 0..<900 { angle = MacRotationRulerMath.stepped(angle, direction: -1) }
        check(angle == -45, "Repeated keyboard steps reach the exact negative bound without drift")
        check(MacRotationRulerMath.stepped(45, direction: 1) == 45 &&
              MacRotationRulerMath.stepped(-45, direction: -1) == -45,
              "Keyboard steps remain at supported limits")
        check(MacRotationRulerMath.position(for: 1.2, current: 1.2, width: 480) == 240,
              "Current angle stays under the center marker")
        let ticks = MacRotationRulerMath.visibleTicks(current: 0, width: 480)
        check(ticks.count == 61 && ticks.first == -15 && ticks.last == 15,
              "Default ruler shows the approved minus fifteen to plus fifteen degree span")
        let nearEnd = MacRotationRulerMath.visibleTicks(current: 45, width: 300)
        check(nearEnd.first == 30 && nearEnd.last == 45 && nearEnd.allSatisfy { (-45...45).contains($0) },
              "Endpoint ruler never draws unavailable angles")
        check(MacRotationRulerMath.visibleTicks(current: .nan, width: 300).isEmpty &&
              MacRotationRulerMath.visibleTicks(current: 0, width: 0).isEmpty,
              "Unusable layout cannot produce tick positions")

        let ruler = MacRotationRulerView(frame: NSRect(x: 0, y: 0, width: 480, height: 52))
        ruler.isEnabled = true
        var written: [Double] = []
        var interactions: [Bool] = []
        ruler.onValueChanged = { written.append($0) }
        ruler.onEditingChanged = { interactions.append($0) }
        ruler.value = 1.2
        ruler.beginDragging(at: 200)
        ruler.continueDragging(to: 208)
        ruler.continueDragging(to: 216)
        ruler.finishDragging()
        check(written == [0.7, 0.2] && interactions == [true, false],
              "Native drag uses a stable entry baseline and ends the interaction once")
        ruler.beginDragging(at: 200)
        ruler.continueDragging(to: 216)
        ruler.finishDragging()
        check(ruler.value == -0.8, "A second native drag starts at the last accepted angle")
        check(ruler.accessibilityRole() == .slider && ruler.isAccessibilityElement(),
              "The native ruler exposes an adjustable slider accessibility role")
        check((ruler.accessibilityMinValue() as? NSNumber)?.doubleValue == -45 &&
              (ruler.accessibilityMaxValue() as? NSNumber)?.doubleValue == 45,
              "Accessibility exposes the complete supported angle range")
        ruler.setAccessibilityValue(NSNumber(value: 2.26))
        check(ruler.value == 2.3 && (ruler.accessibilityValue() as? NSNumber)?.doubleValue == 2.3 &&
              ruler.accessibilityValueDescription() == "+2.3°",
              "Accessible edits snap and expose a signed angle with its unit")
        check(ruler.accessibilityPerformIncrement() && ruler.value == 2.4 &&
              ruler.accessibilityPerformDecrement() && ruler.value == 2.3,
              "Accessibility increment and decrement use exact tenths")
        ruler.setAccessibilityValue(NSNumber(value: Double.nan))
        check(ruler.value == 2.3, "Accessibility rejects nonfinite values")
        ruler.setAccessibilityValue(NSNumber(value: 200))
        check(ruler.value == 45, "Accessible input clamps to the rendering limit")
        ruler.isEnabled = false
        let disabledWrittenCount = written.count
        let disabledInteractionCount = interactions.count
        ruler.beginDragging(at: 200)
        ruler.continueDragging(to: 216)
        ruler.finishDragging()
        ruler.setAccessibilityValue(NSNumber(value: 0))
        check(!ruler.acceptsFirstResponder && !ruler.accessibilityPerformIncrement() &&
              !ruler.accessibilityPerformDecrement() && ruler.value == 45 &&
              written.count == disabledWrittenCount && interactions.count == disabledInteractionCount,
              "Disabled ruler prevents mouse and accessible editing without callbacks")
        check(ruler.intrinsicContentSize.height == 52, "Native ruler preserves its compact fifty two point lane")
    }
}
