import Foundation

struct RawSettings: Equatable {
    static let lutStrengthRange: ClosedRange<Double> = 0...2

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
