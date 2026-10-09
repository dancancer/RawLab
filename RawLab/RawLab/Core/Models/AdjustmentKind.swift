import Foundation

enum AdjustmentKind: String, CaseIterable, Identifiable {
    case strength
    case exposure
    case highlights
    case shadows
    case contrast
    case toneCurve
    case saturation
    case temperature
    case tint
    case noiseReduction
    case sharpening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength:
            return "强度"
        case .exposure:
            return "曝光"
        case .contrast:
            return "对比度"
        case .highlights:
            return "高光"
        case .shadows:
            return "阴影"
        case .toneCurve:
            return "S 曲线"
        case .saturation:
            return "饱和度"
        case .temperature:
            return "色温"
        case .tint:
            return "色调"
        case .noiseReduction:
            return "降噪"
        case .sharpening:
            return "锐化"
        }
    }

    var iconName: String {
        switch self {
        case .strength:
            return "camera.aperture"
        case .exposure:
            return "plusminus.circle"
        case .contrast:
            return "circle.lefthalf.filled"
        case .highlights:
            return "sun.max.fill"
        case .shadows:
            return "moon"
        case .toneCurve:
            return "waveform.path.ecg"
        case .saturation:
            return "drop"
        case .temperature:
            return "thermometer"
        case .tint:
            return "circle.hexagongrid"
        case .noiseReduction:
            return "sparkles"
        case .sharpening:
            return "triangle"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .strength:
            return RawSettings.lutStrengthRange
        case .exposure:
            return -2...2
        case .contrast:
            return 0.5...1.5
        case .highlights:
            return -1...1
        case .shadows:
            return -1...1
        case .toneCurve:
            return -1...1
        case .saturation:
            return 0...2
        case .temperature:
            return 2000...10000
        case .tint:
            return -100...100
        case .noiseReduction:
            return 0...1
        case .sharpening:
            return 0...1.5
        }
    }

    var step: Double {
        switch self {
        case .strength:
            return 0.01
        case .exposure:
            return 0.1
        case .contrast:
            return 0.05
        case .highlights, .shadows:
            return 0.05
        case .toneCurve:
            return 0.02
        case .saturation:
            return 0.05
        case .temperature:
            return 100
        case .tint:
            return 1
        case .noiseReduction:
            return 0.05
        case .sharpening:
            return 0.05
        }
    }

    func value(from settings: RawSettings) -> Double {
        switch self {
        case .strength:
            return settings.lutStrength
        case .exposure:
            return settings.exposure
        case .contrast:
            return settings.contrast
        case .highlights:
            return settings.highlights
        case .shadows:
            return settings.shadows
        case .toneCurve:
            return settings.toneCurve
        case .saturation:
            return settings.saturation
        case .temperature:
            return settings.temperature
        case .tint:
            return settings.tint
        case .noiseReduction:
            return settings.denoise.enabled ? 1 : 0
        case .sharpening:
            return settings.sharpening
        }
    }

    func setValue(_ value: Double, in settings: inout RawSettings) {
        switch self {
        case .strength:
            settings.lutStrength = value
        case .exposure:
            settings.exposure = value
        case .contrast:
            settings.contrast = value
        case .highlights:
            settings.highlights = value
        case .shadows:
            settings.shadows = value
        case .toneCurve:
            settings.toneCurve = value
        case .saturation:
            settings.saturation = value
        case .temperature:
            settings.temperature = value
        case .tint:
            settings.tint = value
        case .noiseReduction:
            settings.noiseReduction = 0
            settings.denoise = RawDenoiseSettings(enabled: value > 0)
        case .sharpening:
            settings.sharpening = value
        }
    }

    func valueLabel(for value: Double) -> String {
        switch self {
        case .strength:
            return String(format: "%.0f%%", value * 100)
        case .exposure:
            return String(format: "%+.1f EV", value)
        case .contrast, .saturation, .noiseReduction, .sharpening:
            return String(format: "%.2f", value)
        case .highlights, .shadows, .toneCurve:
            return String(format: "%+.2f", value)
        case .temperature:
            return String(format: "%.0fK", value)
        case .tint:
            return String(format: "%.0f", value)
        }
    }

    func progress(in settings: RawSettings) -> Double {
        let baseline = value(from: .default)
        let delta = value(from: settings) - baseline
        let span = delta >= 0 ? range.upperBound - baseline : baseline - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(delta / span, -1), 1)
    }

    func reset(in settings: inout RawSettings) {
        setValue(value(from: .default), in: &settings)
    }
}
