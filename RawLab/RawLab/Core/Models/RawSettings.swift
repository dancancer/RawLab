import Foundation

enum RawDenoisePreset: String, CaseIterable, Identifiable {
    case detail = "细节优先", clean = "去噪优先", custom = "自定义"
    var id: String { rawValue }
}

struct RawDenoiseSettings: Codable, Equatable {
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

enum RawWhiteBalanceMode: String, Codable, CaseIterable, Equatable {
    case camera
    case custom

    static var asShot: Self { .camera }
}

struct RawSettings: Codable, Equatable {
    static let lutStrengthRange: ClosedRange<Double> = 0...2
    static let temperatureRange: ClosedRange<Double> = 2000...50000
    static let tintRange: ClosedRange<Double> = -150...150

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
    var whiteBalanceMode: RawWhiteBalanceMode

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, tint, highlights, shadows
        case toneCurve, noiseReduction, sharpening, lutID, lutStrength, whiteBalanceMode
        case denoise
    }

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
        lutStrength: 1,
        whiteBalanceMode: .camera
    )

    init(
        exposure: Double,
        contrast: Double,
        saturation: Double,
        temperature: Double,
        tint: Double,
        highlights: Double,
        shadows: Double,
        toneCurve: Double,
        noiseReduction: Double,
        sharpening: Double,
        lutID: String?,
        lutStrength: Double,
        whiteBalanceMode: RawWhiteBalanceMode = .camera
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.toneCurve = toneCurve
        self.noiseReduction = noiseReduction
        self.sharpening = sharpening
        self.lutID = lutID
        self.lutStrength = lutStrength
        self.whiteBalanceMode = whiteBalanceMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        toneCurve = try values.decodeIfPresent(Double.self, forKey: .toneCurve) ?? 0
        noiseReduction = try values.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        sharpening = try values.decodeIfPresent(Double.self, forKey: .sharpening) ?? 0
        lutID = try values.decodeIfPresent(String.self, forKey: .lutID)
        lutStrength = try values.decodeIfPresent(Double.self, forKey: .lutStrength) ?? 1
        whiteBalanceMode = try values.decodeIfPresent(RawWhiteBalanceMode.self, forKey: .whiteBalanceMode) ?? .camera
        denoise = try values.decodeIfPresent(RawDenoiseSettings.self, forKey: .denoise) ?? RawDenoiseSettings()
        guard denoise.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .denoise, in: values, debugDescription: "Invalid denoise strengths")
        }
    }

    var usesCustomWhiteBalance: Bool { whiteBalanceMode == .custom }

    func customWhiteBalance(cameraTemperature: Double, cameraTint: Double) -> RawSettings {
        var result = self
        if whiteBalanceMode == .camera {
            result.temperature = cameraTemperature
            result.tint = cameraTint
        }
        result.whiteBalanceMode = .custom
        return result
    }

    // The visible slider is linear in reciprocal Kelvin while its value field remains Kelvin.
    static func reciprocalSliderValue(for temperature: Double) -> Double {
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = 1 / min(max(temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
        return (reciprocalRange.upperBound - reciprocal) /
            (reciprocalRange.upperBound - reciprocalRange.lowerBound)
    }

    static func temperature(forReciprocalSliderValue value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        let reciprocalRange = (1 / temperatureRange.upperBound)...(1 / temperatureRange.lowerBound)
        let reciprocal = reciprocalRange.upperBound -
            clamped * (reciprocalRange.upperBound - reciprocalRange.lowerBound)
        return min(max((1 / reciprocal).rounded(), temperatureRange.lowerBound), temperatureRange.upperBound)
    }
}
