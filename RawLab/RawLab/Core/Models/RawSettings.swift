import Foundation

enum RawDenoisePreset: String, CaseIterable, Identifiable {
    case detail = "细节优先", clean = "去噪优先", custom = "自定义"
    var id: String { rawValue }
}

struct RawDenoiseSettings: Equatable {
    var enabled = false
    var luma = 0.0
    var chroma = 46.0
    var coarse = 50.0
    var isValid: Bool { [luma, chroma, coarse].allSatisfy { $0.isFinite && (0...100).contains($0) } }
    var preset: RawDenoisePreset {
        if luma == 0 && chroma == 46 && coarse == 50 { return .detail }
        if luma == 10 && chroma == 72 && coarse == 100 { return .clean }
        return .custom
    }
    mutating func apply(_ preset: RawDenoisePreset) {
        switch preset {
        case .detail: self = Self(enabled: true)
        case .clean: self = Self(enabled: true, luma: 10, chroma: 72, coarse: 100)
        case .custom: break
        }
    }
}

struct RawSettings: Equatable {
    static let lutStrengthRange: ClosedRange<Double> = 0...2

    var denoise = RawDenoiseSettings()
    var exposure: Double
    var contrast: Double
    var saturation: Double
    var temperature: Double
    var tint: Double
    var highlights: Double
    var shadows: Double
    var toneCurve: Double
    var noiseReduction: Double
    var sharpening: Double
    var lutID: String?
    var lutStrength: Double

    var clampedLUTStrength: Float {
        Float(min(max(lutStrength, Self.lutStrengthRange.lowerBound), Self.lutStrengthRange.upperBound))
    }

    static let `default` = RawSettings(
        exposure: 0,
        contrast: 1,
        saturation: 1,
        temperature: 6500,
        tint: 0,
        highlights: 0,
        shadows: 0,
        toneCurve: 0,
        noiseReduction: 0,
        sharpening: 0,
        lutID: nil,
        lutStrength: 1
    )
}
