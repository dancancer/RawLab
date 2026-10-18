import Foundation

struct HistogramChannelMask: OptionSet, Equatable {
    let rawValue: UInt8

    static let red = Self(rawValue: 1 << 0)
    static let green = Self(rawValue: 1 << 1)
    static let blue = Self(rawValue: 1 << 2)
    static let rgb: Self = [.red, .green, .blue]
}

enum HistogramFill: Equatable {
    case red
    case green
    case blue
    case cyan
    case magenta
    case yellow
    case neutralGray

    init(mask: HistogramChannelMask) {
        switch mask {
        case .red: self = .red
        case .green: self = .green
        case .blue: self = .blue
        case [.green, .blue]: self = .cyan
        case [.red, .blue]: self = .magenta
        case [.red, .green]: self = .yellow
        case .rgb: self = .neutralGray
        default: self = .neutralGray
        }
    }
}

struct HistogramSegment: Equatable {
    let lower: Double
    let upper: Double
    let mask: HistogramChannelMask

    var fill: HistogramFill { HistogramFill(mask: mask) }
}

struct HistogramPresentation: Equatable {
    static let channelCount = 3
    static let binCount = 256

    let normalizedBins: [[Double]]
    let peak: Double

    init(bins: [[Double]]) {
        var cleaned = Array(
            repeating: Array(repeating: 0.0, count: Self.binCount),
            count: Self.channelCount
        )
        for channel in 0..<min(bins.count, Self.channelCount) {
            for index in 0..<min(bins[channel].count, Self.binCount) {
                let count = bins[channel][index]
                if count.isFinite && count > 0 {
                    cleaned[channel][index] = count
                }
            }
        }

        let maximum = cleaned.flatMap { $0 }.max() ?? 0
        let sharedPeak = maximum > 0 ? maximum : 1
        peak = sharedPeak
        normalizedBins = cleaned.map { channel in
            channel.map { $0 / sharedPeak }
        }
    }

    func segments(at index: Int) -> [HistogramSegment] {
        guard (0..<Self.binCount).contains(index) else { return [] }
        let heights = normalizedBins.map { $0[index] }
        let thresholds = heights.filter { $0 > 0 }.sorted().reduce(into: [Double]()) { values, value in
            if values.last != value { values.append(value) }
        }

        var lower = 0.0
        return thresholds.compactMap { upper in
            guard upper > lower else { return nil }
            var mask = HistogramChannelMask()
            if heights[0] >= upper { mask.insert(.red) }
            if heights[1] >= upper { mask.insert(.green) }
            if heights[2] >= upper { mask.insert(.blue) }
            defer { lower = upper }
            return HistogramSegment(lower: lower, upper: upper, mask: mask)
        }
    }
}
