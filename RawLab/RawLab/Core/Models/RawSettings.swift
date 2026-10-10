import Foundation

enum RawDenoisePreset: String, CaseIterable, Identifiable {
    case detail = "细节优先", clean = "去噪优先", custom = "自定义"
    var id: String { rawValue }
}

struct PhotoEffectsSettings: Codable, Equatable {
    static let vignetteAmountRange: ClosedRange<Double> = -100...100
    static let vignetteMidpointRange: ClosedRange<Double> = 0...100
    static let vignetteRoundnessRange: ClosedRange<Double> = -100...100
    static let vignetteFeatherRange: ClosedRange<Double> = 0...100
    static let vignetteHighlightsRange: ClosedRange<Double> = 0...100
    static let grainAmountRange: ClosedRange<Double> = 0...100
    static let grainSizeRange: ClosedRange<Double> = 0...100
    static let grainRoughnessRange: ClosedRange<Double> = 0...100

    var vignetteAmount: Double {
        didSet { vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange) }
    }
    var vignetteMidpoint: Double {
        didSet { vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange) }
    }
    var vignetteRoundness: Double {
        didSet { vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange) }
    }
    var vignetteFeather: Double {
        didSet { vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange) }
    }
    var vignetteHighlights: Double {
        didSet { vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange) }
    }
    var grainAmount: Double {
        didSet { grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange) }
    }
    var grainSize: Double {
        didSet { grainSize = Self.clamped(grainSize, to: Self.grainSizeRange) }
    }
    var grainRoughness: Double {
        didSet { grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange) }
    }

    init(vignetteAmount: Double = 0,
         vignetteMidpoint: Double = 50,
         vignetteRoundness: Double = 0,
         vignetteFeather: Double = 50,
         vignetteHighlights: Double = 0,
         grainAmount: Double = 0,
         grainSize: Double = 25,
         grainRoughness: Double = 50) {
        self.vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange)
        self.vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange)
        self.vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange)
        self.vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange)
        self.vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange)
        self.grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange)
        self.grainSize = Self.clamped(grainSize, to: Self.grainSizeRange)
        self.grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange)
    }

    var isValid: Bool {
        [vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather,
         vignetteHighlights, grainAmount, grainSize, grainRoughness].allSatisfy { $0.isFinite }
    }

    var isDefault: Bool { self == Self() }

    mutating func resetVignette() {
        self = Self(vignetteAmount: 0, vignetteMidpoint: 50, vignetteRoundness: 0,
                    vignetteFeather: 50, vignetteHighlights: 0,
                    grainAmount: grainAmount, grainSize: grainSize, grainRoughness: grainRoughness)
    }

    mutating func resetGrain() {
        self = Self(vignetteAmount: vignetteAmount, vignetteMidpoint: vignetteMidpoint,
                    vignetteRoundness: vignetteRoundness, vignetteFeather: vignetteFeather,
                    vignetteHighlights: vignetteHighlights, grainAmount: 0, grainSize: 25,
                    grainRoughness: 50)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound <= 0 && range.upperBound >= 0 ? 0 : range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value.rounded()))
    }

    private enum CodingKeys: String, CodingKey {
        case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
        case grainAmount, grainSize, grainRoughness
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            vignetteAmount: try values.decodeIfPresent(Double.self, forKey: .vignetteAmount) ?? 0,
            vignetteMidpoint: try values.decodeIfPresent(Double.self, forKey: .vignetteMidpoint) ?? 50,
            vignetteRoundness: try values.decodeIfPresent(Double.self, forKey: .vignetteRoundness) ?? 0,
            vignetteFeather: try values.decodeIfPresent(Double.self, forKey: .vignetteFeather) ?? 50,
            vignetteHighlights: try values.decodeIfPresent(Double.self, forKey: .vignetteHighlights) ?? 0,
            grainAmount: try values.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0,
            grainSize: try values.decodeIfPresent(Double.self, forKey: .grainSize) ?? 25,
            grainRoughness: try values.decodeIfPresent(Double.self, forKey: .grainRoughness) ?? 50
        )
    }
}

enum PhotoEffectParameter: String, CaseIterable, Identifiable {
    case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
    case grainAmount, grainSize, grainRoughness

    var id: String { rawValue }
    var isVignette: Bool {
        switch self {
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights:
            return true
        case .grainAmount, .grainSize, .grainRoughness:
            return false
        }
    }
    var title: String {
        switch self {
        case .vignetteAmount, .grainAmount: return "强度"
        case .vignetteMidpoint: return "中点"
        case .vignetteRoundness: return "圆度"
        case .vignetteFeather: return "羽化"
        case .vignetteHighlights: return "高光保护"
        case .grainSize: return "大小"
        case .grainRoughness: return "粗糙度"
        }
    }
    var keyPath: WritableKeyPath<PhotoEffectsSettings, Double> {
        switch self {
        case .vignetteAmount: return \.vignetteAmount
        case .vignetteMidpoint: return \.vignetteMidpoint
        case .vignetteRoundness: return \.vignetteRoundness
        case .vignetteFeather: return \.vignetteFeather
        case .vignetteHighlights: return \.vignetteHighlights
        case .grainAmount: return \.grainAmount
        case .grainSize: return \.grainSize
        case .grainRoughness: return \.grainRoughness
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .vignetteAmount: return PhotoEffectsSettings.vignetteAmountRange
        case .vignetteMidpoint: return PhotoEffectsSettings.vignetteMidpointRange
        case .vignetteRoundness: return PhotoEffectsSettings.vignetteRoundnessRange
        case .vignetteFeather: return PhotoEffectsSettings.vignetteFeatherRange
        case .vignetteHighlights: return PhotoEffectsSettings.vignetteHighlightsRange
        case .grainAmount: return PhotoEffectsSettings.grainAmountRange
        case .grainSize: return PhotoEffectsSettings.grainSizeRange
        case .grainRoughness: return PhotoEffectsSettings.grainRoughnessRange
        }
    }
    var defaultValue: Double { PhotoEffectsSettings()[keyPath: keyPath] }
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
    var photoEffects = PhotoEffectsSettings()
    var displayChromaDenoise = 0 {
        didSet { displayChromaDenoise = Self.clampedDisplayChromaDenoise(displayChromaDenoise) }
    }
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
        case denoise, photoEffects, displayChromaDenoise
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
        whiteBalanceMode: .camera,
        photoEffects: PhotoEffectsSettings(),
        displayChromaDenoise: 0
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
        whiteBalanceMode: RawWhiteBalanceMode = .camera,
        photoEffects: PhotoEffectsSettings = PhotoEffectsSettings(),
        displayChromaDenoise: Int = 0
    ) {
        self.photoEffects = photoEffects
        self.displayChromaDenoise = Self.clampedDisplayChromaDenoise(displayChromaDenoise)
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
        photoEffects = try values.decodeIfPresent(PhotoEffectsSettings.self, forKey: .photoEffects) ?? PhotoEffectsSettings()
        displayChromaDenoise = Self.clampedDisplayChromaDenoise(
            try values.decodeIfPresent(Int.self, forKey: .displayChromaDenoise) ?? 0
        )
        guard denoise.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .denoise, in: values, debugDescription: "Invalid denoise strengths")
        }
    }

    private static func clampedDisplayChromaDenoise(_ mode: Int) -> Int {
        min(2, max(0, mode))
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
