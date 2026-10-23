import Foundation

// MARK: - Legal values and tape positions

struct AdjustmentScale: Equatable {
    let range: ClosedRange<Double>
    let step: Double
    let reciprocal: Bool
    let compactDecimals: Int?

    init(range: ClosedRange<Double>, step: Double, reciprocal: Bool = false, compactDecimals: Int? = nil) {
        self.range = range
        self.step = step.isFinite && step > 0 ? step : 1
        self.reciprocal = reciprocal && range.lowerBound > 0
        self.compactDecimals = compactDecimals
    }

    var span: Double { range.upperBound - range.lowerBound }
    var intervalCount: Int { Int((span / step + 1e-8).rounded(.down)) }
    var tapeLength: Double { reciprocal ? 1_200 : min(max(Double(intervalCount) * 8, 400), 1_920) }

    func window(at position: Double, width: Double) -> AdjustmentRulerWindow {
        let span = min(1, max(1e-9, width / tapeLength))
        let current = min(1, max(0, position.isFinite ? position : 0))
        let start = min(max(current - span / 2, 0), 1 - span)
        return AdjustmentRulerWindow(start: start, span: span, indicator: (current - start) / span)
    }

    func completeText(_ value: Double, displayScale: Double = 1, locale: Locale,
                      formatter: (Double) -> String) -> String {
        let ordinary = formatter(value)
        if compactDecimals != nil { return ordinary }
        let parser = NumberFormatter()
        parser.locale = locale
        parser.numberStyle = .decimal
        if let displayed = parser.number(from: ordinary.hasPrefix("+") ? String(ordinary.dropFirst()) : ordinary)?.doubleValue {
            let logical = displayed / displayScale
            // 同一既有网格点保留正常格式，避免二进制长尾；旧非网格值仍须精确相等。
            if logical == value || (contains(logical) && rounded(logical) == value) { return ordinary }
        }
        // Swift 的最短往返表示保留合法历史小数；候选的 Double 本身不经过格式化再解析。
        let exact = String(value * displayScale).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
        return (ordinary.hasPrefix("+") && value > 0 ? "+" : "") + exact
    }

    func contains(_ value: Double) -> Bool {
        value.isFinite && range.contains(value)
    }

    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func rounded(_ value: Double) -> Double {
        if value >= range.upperBound { return range.upperBound }
        if value <= range.lowerBound { return range.lowerBound }
        let index = ((clamped(value) - range.lowerBound) / step).rounded()
        let result = clamped(range.lowerBound + index * step)
        return abs(result) < step * 1e-8 ? 0 : result
    }

    func position(for value: Double) -> Double {
        guard span > 0 else { return 0 }
        let value = clamped(value)
        if reciprocal {
            return (1 / range.lowerBound - 1 / value) / (1 / range.lowerBound - 1 / range.upperBound)
        }
        return (value - range.lowerBound) / span
    }

    func value(at position: Double) -> Double {
        let position = position.isFinite ? min(max(position, 0), 1) : 0
        if reciprocal {
            return clamped(1 / (1 / range.lowerBound - position * (1 / range.lowerBound - 1 / range.upperBound)))
        }
        return clamped(range.lowerBound + position * span)
    }

    func values(including extras: [Double] = []) -> [Double] {
        if let compactDecimals {
            let factor = pow(10, Double(compactDecimals))
            var labels = Set<Double>()
            var values = [Double]()
            // 原值优先，不能让同一显示值的网格点或默认值替换它。
            for value in extras.filter(contains) {
                if labels.insert((value * factor).rounded()).inserted { values.append(value) }
            }
            let first = Int(ceil(range.lowerBound / step - 1e-8))
            let last = Int(floor(range.upperBound / step + 1e-8))
            if first <= last {
                for index in first...last {
                    let value = Double(index) * step
                    if labels.insert((value * factor).rounded()).inserted { values.append(value) }
                }
            }
            return values.sorted()
        }
        var values = (0...intervalCount).map { range.lowerBound + Double($0) * step }
        values.append(range.upperBound)
        values.append(contentsOf: extras.filter(contains))
        let sorted = values.sorted()
        return sorted.reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > step * 1e-8 }) ?? true { result.append(value) }
        }
    }

    func index(of value: Double, in values: [Double]) -> Int {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }

    func increment(_ value: Double, direction: Int) -> Double {
        if compactDecimals != nil {
            let index = direction > 0 ? floor(value / step + 1e-8) + 1 : ceil(value / step - 1e-8) - 1
            let next = index * step
            return range.contains(next) ? next : value
        }
        let relative = (clamped(value) - range.lowerBound) / step
        let index = direction > 0 ? floor(relative + 1e-8) + 1 : ceil(relative - 1e-8) - 1
        return clamped(range.lowerBound + index * step)
    }

    var ticks: [AdjustmentTick] {
        if reciprocal {
            return (0...120).map { index in
                let value = rounded(self.value(at: Double(index) / 120))
                return AdjustmentTick(id: index, value: value, position: position(for: value), major: index.isMultiple(of: 10))
            }
        }
        let stride = max(1, Int(ceil(Double(intervalCount) / 240)))
        var indices = Array(Swift.stride(from: 0, through: intervalCount, by: stride))
        if indices.last != intervalCount { indices.append(intervalCount) }
        return indices.map { index in
            let value = range.lowerBound + Double(index) * step
            return AdjustmentTick(id: index, value: value, position: position(for: value), major: index.isMultiple(of: stride * 10))
        }
    }

    func crossesDefault(from old: Double, to new: Double, defaultValue: Double?) -> Bool {
        guard old != new, let defaultValue, contains(defaultValue) else { return false }
        return (old < defaultValue && new >= defaultValue) || (old > defaultValue && new <= defaultValue)
    }

    func crossesMajor(from old: Double, to new: Double) -> Bool {
        guard old != new else { return false }
        return ticks.contains {
            $0.major && (new > old ? $0.value > old && $0.value <= new : $0.value < old && $0.value >= new)
        }
    }

    static func hasHorizontalIntent(x: Double, y: Double) -> Bool {
        abs(x) >= 6 && abs(x) > abs(y) * 1.4
    }
}

struct AdjustmentTick {
    let id: Int
    let value: Double
    let position: Double
    let major: Bool
}

// MARK: - Per-tick residuals

struct AdjustmentTickMotion {
    private struct Pulse { let amount: Double; let time: Double }
    private var pulses: [Int: Pulse] = [:]
    static let duration = 0.18

    func amount(for id: Int, at time: Double) -> Double {
        guard time.isFinite, let pulse = pulses[id] else { return 0 }
        let remaining = max(0, 1 - max(0, time - pulse.time) / Self.duration)
        return pulse.amount * remaining * remaining
    }

    mutating func excite(id: Int, distance: Double, at time: Double, reduceMotion: Bool = false) {
        guard !reduceMotion, distance.isFinite, time.isFinite else { return }
        let weight = max(0, 1 - pow(distance / 24, 2))
        guard weight > 0 else { return }
        pulses[id] = Pulse(amount: max(amount(for: id, at: time), weight), time: time)
    }

    mutating func prune(at time: Double) {
        pulses = pulses.filter { amount(for: $0.key, at: time) > 0.001 }
    }

    mutating func clear() { pulses.removeAll() }
    var isEmpty: Bool { pulses.isEmpty }

    func height(for tick: AdjustmentTick, at time: Double, reduceMotion: Bool = false) -> Double {
        let base = tick.major ? 22.0 : 13.0
        return base + (28 - base) * (reduceMotion ? 0 : amount(for: tick.id, at: time))
    }
}

struct AdjustmentRulerWindow {
    let start: Double
    let span: Double
    let indicator: Double

    func fraction(for position: Double) -> Double { (position - start) / span }
}
