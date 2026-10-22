import Foundation

/// Precision is expressed in the units shown in the editor, not engine units.
enum ParameterPrecision {
    case standard, exposure, temperature

    var scale: Double {
        switch self {
        case .standard: return 10
        case .exposure: return 100
        case .temperature: return 0.1
        }
    }
    var normalStep: Double {
        switch self {
        case .standard: return 1
        case .exposure: return 0.1
        case .temperature: return 100
        }
    }
    var fineStep: Double { 1 / scale }

    func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    func snapped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let bounded = clamped(value, in: range)
        return clamped((bounded * scale).rounded() / scale, in: range)
    }

    func stepped(_ value: Double, direction: Int, fine: Bool, in range: ClosedRange<Double>) -> Double {
        // Add integer grid ticks to avoid accumulating binary floating-point error.
        let ticks = (clamped(value, in: range) * scale).rounded()
        let increment = ((fine ? fineStep : normalStep) * scale).rounded()
        return clamped((ticks + Double(direction) * increment) / scale, in: range)
    }

    func text(_ value: Double, signed: Bool = false) -> String {
        let clean = value == 0 ? 0 : value
        let decimals: Int
        switch self {
        case .exposure: decimals = 2
        case .temperature: decimals = 0
        case .standard: decimals = abs(clean - clean.rounded()) < 0.0000001 ? 0 : 1
        }
        let roundedText = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, clean)
        // Existing values may predate the editing grid, including camera white balance.
        let result = Double(roundedText) == clean ? roundedText : String(clean)
        return signed && clean > 0 ? "+" + result : result
    }

    func accepts(_ value: Double, original: Double, in range: ClosedRange<Double>) -> Bool {
        guard value.isFinite, range.contains(value) else { return false }
        if value == original { return true }
        let ticks = value * scale
        return value == ticks.rounded() / scale
    }

    func parse(_ draft: String) -> Double? {
        guard let value = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return value
    }
}

enum ParameterSliderMapping {
    case linear, reciprocalKelvin

    func position(for value: Double, in range: ClosedRange<Double>) -> Double {
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        let position: Double
        switch self {
        case .linear: position = (bounded - range.lowerBound) / (range.upperBound - range.lowerBound)
        case .reciprocalKelvin:
            position = (1 / range.lowerBound - 1 / bounded) / (1 / range.lowerBound - 1 / range.upperBound)
        }
        return position.isFinite ? min(1, max(0, position)) : 0
    }

    func fill(from defaultValue: Double, to value: Double, in range: ClosedRange<Double>) -> ClosedRange<Double> {
        let origin = position(for: defaultValue, in: range)
        let current = position(for: value, in: range)
        return min(origin, current)...max(origin, current)
    }

    func value(at position: Double, in range: ClosedRange<Double>) -> Double {
        let position = min(1, max(0, position))
        switch self {
        case .linear: return range.lowerBound + position * (range.upperBound - range.lowerBound)
        case .reciprocalKelvin:
            return 1 / (1 / range.lowerBound - position * (1 / range.lowerBound - 1 / range.upperBound))
        }
    }
}

/// Per-field wheel state. No delayed work or residual steps are scheduled.
struct ParameterWheelAccumulator {
    enum Result: Equatable { case pass, consume, step(Int) }
    private var remainder = 0.0
    private var lastEvent: TimeInterval?
    private var lastAccepted: TimeInterval?
    private var direction = 0
    private var fine = false

    mutating func reset() { self = Self() }

    mutating func handle(verticalPixels: Double, timestamp: TimeInterval, fine: Bool,
                         editable: Bool, validValue: Bool, momentum: Bool = false, discrete: Bool = false) -> Result {
        guard editable, validValue, verticalPixels.isFinite, timestamp.isFinite else {
            reset()
            return .pass
        }
        guard verticalPixels != 0 else { return .pass }
        let newDirection = verticalPixels > 0 ? 1 : -1
        if let lastEvent, timestamp - lastEvent >= 0.2 || timestamp < lastEvent {
            remainder = 0
        }
        if newDirection != direction || fine != self.fine { remainder = 0 }
        lastEvent = timestamp
        direction = newDirection
        self.fine = fine
        if momentum { remainder = 0; return .consume }
        if discrete {
            remainder = 0
            lastAccepted = nil
            return .step(newDirection)
        }
        // Cap spikes so a large mouse event cannot leave queued steps behind.
        remainder += min(80, abs(verticalPixels)) * Double(newDirection)
        guard abs(remainder) >= 80 else { return .consume }
        remainder = 0
        guard lastAccepted == nil || timestamp - lastAccepted! >= 0.125 else { return .consume }
        lastAccepted = timestamp
        return .step(newDirection)
    }
}
