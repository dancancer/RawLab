import Foundation

@main
struct AdjustmentScaleTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func close(_ a: Double, _ b: Double, tolerance: Double = 1e-8) -> Bool { abs(a - b) < tolerance }

    static func main() {
        legalValues()
        reciprocalValues()
        movementAndEvents()
        tickResiduals()
        visibleWindows()
        completeLegacyValues()
        compactCropValues()
        print("PASS: \(checks) adjustment scale, wheel, intent, event and motion checks")
    }

    static func compactCropValues() {
        let original = 33.33333333333333
        let crop = AdjustmentScale(range: 0...100, step: 0.01, compactDecimals: 2)
        let format: (Double) -> String = { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) }
        check(crop.completeText(original, locale: Locale(identifier: "en"), formatter: format) == "33.33",
              "Crop presents two decimals without exposing the drag's binary tail")
        let values = crop.values(including: [original, 100])
        check(values.contains(original) && values.filter { format($0) == "33.33" }.count == 1,
              "The complete-value wheel retains its exact original without duplicate rounded rows")
        check(close(crop.increment(original, direction: 1), 33.34) && close(crop.increment(original, direction: -1), 33.33),
              "Crop accessibility moves to neighboring hundredth-percent grid points")
        let boundary = 99.99999999
        let boundaryValues = crop.values(including: [boundary, 100])
        check(boundaryValues.contains(boundary) && boundaryValues.filter { format($0) == "100.00" }.count == 1,
              "The exact original wins over a default with the same rounded label")
        let bounded = AdjustmentScale(range: 0...original, step: 0.01, compactDecimals: 2)
        check(bounded.increment(original, direction: 1) == original && bounded.values(including: [original]).contains(original),
              "An off-grid crop boundary remains unchanged when incremented at its limit")
    }

    static func visibleWindows() {
        let fixtures: [(ClosedRange<Double>, Double, Bool)] = [(0...2, 0.01, false), (0...100, 1, false),
            (-100...100, 1, false), (-4...4, 0.05, false), (2000...50000, 10, true)]
        for (range, step, reciprocal) in fixtures {
            let scale = AdjustmentScale(range: range, step: step, reciprocal: reciprocal)
            for width in [120.0, 320, 768, 2400] {
                let lower = scale.window(at: 0, width: width)
                let upper = scale.window(at: 1, width: width)
                let middle = scale.window(at: 0.5, width: width)
                check(lower.start == 0 && lower.indicator == 0, "Minimum fills the ruler from its left edge")
                check(close(upper.start + upper.span, 1) && close(upper.indicator, 1), "Maximum fills through the right edge")
                check(close(middle.indicator, 0.5), "Middle remains centered at every width")
                check(lower.span > 0 && lower.span <= 1, "A wide viewport never leaves the legal tape domain")
            }
        }
        let exposure = AdjustmentScale(range: -4...4, step: 0.05)
        let window = exposure.window(at: 0.5, width: 320)
        check(close(window.span, 0.25) && close(window.start, 0.375), "320pt of the original1280pt tape uses a quarter-domain window")
        let singleton = AdjustmentScale(range: 3...3, step: 1).window(at: 0, width: 0)
        check(singleton.indicator.isFinite && singleton.span > 0, "Collapsed layout and singleton ranges remain finite")
    }

    static func completeLegacyValues() {
        let locale = Locale(identifier: "en_US")
        let hsl = AdjustmentScale(range: -100...100, step: 1)
        check(hsl.values(including: [0.5]).contains(0.5) && hsl.values(including: [0.5]).count == 202, "The complete wheel includes the stored half without rounding")
        check(hsl.completeText(0.5, locale: locale, formatter: { String(format: "%+.0f", $0) }) == "+0.5", "Half-step row and wheel do not claim integer0 or1")
        check(hsl.completeText(-0.05, locale: locale, formatter: { String(format: "%+.0f", $0) }) == "-0.05", "All legal old fractions retain their precision")
        check(hsl.completeText(0.5, locale: Locale(identifier: "de_DE"), formatter: { _ in "+0" }) == "+0,5", "Legacy digits follow the current locale")
        let strength = AdjustmentScale(range: 0...2, step: 0.01)
        check(strength.completeText(0.005, displayScale: 100, locale: locale, formatter: { String(format: "%.0f", $0 * 100) }) == "0.5", "Percent display preserves the old logical value without changing storage")
        let ev = AdjustmentScale(range: -4...4, step: 0.05)
        let gridEV = ev.rounded(0.35)
        let percentText = strength.completeText(0.29, displayScale: 100, locale: locale, formatter: { String(format: "%.0f", $0 * 100) })
        let evText = ev.completeText(gridEV, locale: locale, formatter: { String(format: "%+.2f", $0) })
        check(percentText == "29" && evText == "+0.35", "Canonical grid keeps compact digits: percent=\(percentText), EV=\(evText), gridEV=\(gridEV)")
        check(strength.values().allSatisfy { value in
            strength.completeText(value, displayScale: 100, locale: locale, formatter: { String(format: "%.0f", $0 * 100) }) == String(format: "%.0f", value * 100)
        }, "Every strength grid value keeps its integer percent formatter")
        check(ev.values().allSatisfy { value in
            ev.completeText(value, locale: locale, formatter: { String(format: "%+.2f", $0) }) == String(format: "%+.2f", value)
        }, "Every EV grid value keeps its two-decimal formatter")
        check(ev.completeText(gridEV.nextUp, locale: locale, formatter: { String(format: "%+.2f", $0) }) == "+0.35", "A distinct legal old value displays two decimals without changing its candidate")
        let original = 0.25123456789
        let curve = AdjustmentScale(range: 0...1, step: 0.001)
        check(curve.completeText(original, locale: locale, formatter: { String(format: "%.2f", $0) }) == "0.25",
              "Curve coordinates never reveal the full floating point tail")
        check(curve.values(including: [original]).contains(original), "Rounded curve labels preserve the exact selectable candidate")
        check(hsl.completeText(12.345678, locale: Locale(identifier: "de_DE"), formatter: { _ in "+12" }) == "+12,35",
              "Off-grid values display at most two localized decimals")
        check(hsl.completeText(25, locale: locale, formatter: { String(format: "%+.0f", $0) }) == "+25", "Grid values keep existing formatting")
    }

    static func legalValues() {
        let exposure = AdjustmentScale(range: -4...4, step: 0.05)
        let values = exposure.values()
        check(values.count == 161, "Exposure wheel has 161 complete values")
        check(values.first == -4 && values.last == 4, "Exposure endpoints remain legal")
        check(values.allSatisfy(exposure.contains), "Every exposure candidate is bounded")
        check(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "Exposure candidates are sorted and unique")
        check(close(exposure.rounded(0.674), 0.65), "Exposure commit uses .05 grid")
        check(close(exposure.rounded(-0.674), -0.65), "Negative exposure uses same grid")
        check(exposure.rounded(-999) == -4 && exposure.rounded(999) == 4, "Clamp before rounding")
        check(exposure.rounded(.nan).isFinite && exposure.value(at: .nan).isFinite, "Nonfinite input never produces a nonfinite value")
        let hsl = AdjustmentScale(range: -100...100, step: 1)
        check(hsl.values().count == 201, "Each HSL wheel has 201 integers")
        check(hsl.values().allSatisfy { $0 == $0.rounded() }, "HSL candidates stay integers")
        let crop = AdjustmentScale(range: 0...89.3, step: 0.1)
        check(crop.values().last == 89.3 && crop.values().allSatisfy(crop.contains), "Effective crop limit remains bounded")
        check(!crop.values(including: [100, .nan]).contains(100), "Unavailable default is not inserted")
        check(AdjustmentScale(range: 0...1, step: 0).step == 1, "Invalid step falls back to a legal step")
        check(AdjustmentScale(range: 3...3, step: 1).values() == [3], "Single-valued range remains valid")
        check(AdjustmentScale(range: 0...1.03, step: 0.1).rounded(1.03) == 1.03, "Declared legal endpoint remains reachable off-grid")
    }

    static func reciprocalValues() {
        let temperature = AdjustmentScale(range: 2000...50000, step: 10, reciprocal: true)
        let values = temperature.values(including: [5267, 5243, 5267, 0, .nan, 55000])
        check(values.count == 4803, "WB inserts current and camera baseline off-grid values once")
        check(values.contains(5267) && values.contains(5243), "WB keeps exact current and default")
        check(values[temperature.index(of: 5267, in: values)] == 5267, "Opening wheel finds original without rounding it")
        check(values.allSatisfy(temperature.contains), "WB excludes invalid and out-of-range extras")
        check(temperature.position(for: 2000) == 0 && temperature.position(for: 50000) == 1, "Reciprocal endpoints map exactly")
        for value in [2000.0, 5243, 6500, 18000, 50000] {
            check(close(temperature.value(at: temperature.position(for: value)), value, tolerance: 1e-6), "Reciprocal round trip")
        }
        check(temperature.position(for: 6500) > 0.5, "WB tape uses reciprocal rather than linear Kelvin")
        check(temperature.position(for: .infinity).isFinite, "Nonfinite WB input has a finite position")
        check(temperature.value(at: -1) == 2000 && temperature.value(at: 2) == 50000, "Reciprocal movement remains bounded")
        check(temperature.values(including: [5200, 5200]).count == 4801, "Grid-aligned baseline is deduplicated")
    }

    static func movementAndEvents() {
        let scale = AdjustmentScale(range: -4...4, step: 0.05)
        check(!AdjustmentScale.hasHorizontalIntent(x: 5.9, y: 0), "Touch without 6pt movement is not an adjustment")
        check(!AdjustmentScale.hasHorizontalIntent(x: 10, y: 10), "Vertical/diagonal scroll does not become a ruler drag")
        check(AdjustmentScale.hasHorizontalIntent(x: -8, y: 2), "Both horizontal directions satisfy intent")
        check(close(scale.increment(0.65, direction: 1), 0.7), "Accessibility increment reaches the next legal grid value")
        check(close(scale.increment(0.65, direction: -1), 0.6), "Accessibility decrement reaches the previous legal grid value")
        check(scale.increment(4, direction: 1) == 4 && scale.increment(-4, direction: -1) == -4, "Increment cannot leave an endpoint")
        check(scale.crossesDefault(from: -0.1, to: 0.05, defaultValue: 0), "Default crossing uses actual values")
        check(!scale.crossesDefault(from: 0, to: 0, defaultValue: 0), "Unchanged value generates no event")
        check(!scale.crossesDefault(from: -0.1, to: 0.1, defaultValue: .nan), "Invalid default generates no event")
        check(scale.crossesMajor(from: 0.45, to: 0.5) && scale.crossesMajor(from: 0.55, to: 0.5), "Major arrival works in both directions")
        check(!scale.crossesMajor(from: 0.5, to: 0.55), "Leaving a major does not repeat its arrival")
        let position = scale.position(for: 0)
        let ordinary = scale.value(at: position + 40 / scale.tapeLength)
        let fine = scale.value(at: position + 40 / scale.tapeLength * 0.25)
        check(close(fine, ordinary * 0.25), "Fine mode reduces travel by exactly four without changing legal grid")
    }

    static func tickResiduals() {
        var motion = AdjustmentTickMotion()
        let minor = AdjustmentTick(id: 1, value: 0, position: 0, major: false)
        let major = AdjustmentTick(id: 2, value: 0, position: 0, major: true)
        motion.excite(id: 1, distance: 0, at: 1)
        motion.excite(id: 2, distance: 12, at: 1)
        check(motion.height(for: minor, at: 1) == 28, "Local minor tick reaches peak 28pt")
        check(close(motion.height(for: major, at: 1), 26.5), "Major height uses quadratic 24pt spatial weight")
        check(close(motion.amount(for: 1, at: 1.09), 0.25), "Pause decay reaches one-quarter after 90ms")
        check(motion.height(for: minor, at: 1.18) == 13, "Holding still relaxes after 180ms before release")
        motion.excite(id: 1, distance: 23, at: 1.09)
        check(close(motion.amount(for: 1, at: 1.09), 0.25), "Fresh movement continues the current decayed residual")
        check(close(motion.amount(for: 1, at: 1.18), 0.0625), "Rebased pulse decays from retained height")
        motion.excite(id: 1, distance: 30, at: 1.18)
        check(close(motion.amount(for: 1, at: 1.2), 0.25 * pow(1 - 0.11 / 0.18, 2)), "Far ticks do not restart old pulse time")
        var direction = AdjustmentTickMotion()
        direction.excite(id: 1, distance: 0, at: 2)
        direction.excite(id: 2, distance: 0, at: 2.06)
        check(direction.amount(for: 1, at: 2.06) < direction.amount(for: 2, at: 2.06), "Moving creates asymmetric short history")
        check(direction.height(for: minor, at: 2.06, reduceMotion: true) == 13, "Reduce Motion keeps minor height static")
        check(direction.height(for: major, at: 2.06, reduceMotion: true) == 22, "Reduce Motion keeps major height static")
        motion.clear()
        motion.excite(id: 1, distance: 0, at: 3, reduceMotion: true)
        motion.excite(id: 1, distance: .nan, at: 3)
        motion.excite(id: 1, distance: 0, at: .nan)
        check(motion.isEmpty, "Reduce Motion and invalid movement create no pulses")
        direction.prune(at: 3)
        check(direction.isEmpty, "Decay releases every animation task")
        check(direction.amount(for: 1, at: .nan) == 0, "Invalid animation time remains finite")
    }
}
