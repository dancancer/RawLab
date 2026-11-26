import Foundation

public enum X3fMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case legacy = "legacy"
    case normal = "normal-v1"

    public var id: String { rawValue }
    public var nativeValue: UInt32 { self == .normal ? 1 : 0 }
    public var title: String { L10n.text(self == .normal ? "正常显影" : "伪红外（旧版）") }
}

public struct ProcessingIdentity: Equatable, Hashable, Codable, Sendable {
    public let family: String
    public let version: Int
    public let quality: String

    public static let legacy = ProcessingIdentity(version: 1)
    public static let c5 = ProcessingIdentity(version: 2)
    public static let current = ProcessingIdentity(version: 3)

    private init(version: Int) {
        family = "rawlab"
        self.version = version
        quality = "standard"
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self).allKeys
        guard fields.allSatisfy({ CodingKeys(stringValue: $0.stringValue) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported processing identity field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        family = try values.decode(String.self, forKey: .family)
        version = try values.decode(Int.self, forKey: .version)
        quality = try values.decode(String.self, forKey: .quality)
        guard family == "rawlab", (1...3).contains(version), quality == "standard" else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported processing identity"))
        }
    }
}

public struct PhotoEffectsSettings: Codable, Equatable, Sendable {
    public static let vignetteAmountRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsVignetteAmount.macosModel.closedRange!
    public static let vignetteMidpointRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsVignetteMidpoint.macosModel.closedRange!
    public static let vignetteRoundnessRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsVignetteRoundness.macosModel.closedRange!
    public static let vignetteFeatherRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsVignetteFeather.macosModel.closedRange!
    public static let vignetteHighlightsRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsVignetteHighlights.macosModel.closedRange!
    public static let grainAmountRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsGrainAmount.macosModel.closedRange!
    public static let grainSizeRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsGrainSize.macosModel.closedRange!
    public static let grainRoughnessRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsGrainRoughness.macosModel.closedRange!

    public var vignetteAmount: Double {
        didSet { vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange) }
    }
    public var vignetteMidpoint: Double {
        didSet { vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange) }
    }
    public var vignetteRoundness: Double {
        didSet { vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange) }
    }
    public var vignetteFeather: Double {
        didSet { vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange) }
    }
    public var vignetteHighlights: Double {
        didSet { vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange) }
    }
    public var grainAmount: Double {
        didSet { grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange) }
    }
    public var grainSize: Double {
        didSet { grainSize = Self.clamped(grainSize, to: Self.grainSizeRange) }
    }
    public var grainRoughness: Double {
        didSet { grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange) }
    }
    public var grainToneCurve: GrainToneCurve = .legacy
    public var grainFormatPreset: GrainFormatPreset = .custom

    public init(vignetteAmount: Double = AdjustmentFieldSpec.Fields.effectsVignetteAmount.macosModel.defaultValue.numberValue!,
                vignetteMidpoint: Double = AdjustmentFieldSpec.Fields.effectsVignetteMidpoint.macosModel.defaultValue.numberValue!,
                vignetteRoundness: Double = AdjustmentFieldSpec.Fields.effectsVignetteRoundness.macosModel.defaultValue.numberValue!,
                vignetteFeather: Double = AdjustmentFieldSpec.Fields.effectsVignetteFeather.macosModel.defaultValue.numberValue!,
                vignetteHighlights: Double = AdjustmentFieldSpec.Fields.effectsVignetteHighlights.macosModel.defaultValue.numberValue!,
                grainAmount: Double = AdjustmentFieldSpec.Fields.effectsGrainAmount.macosModel.defaultValue.numberValue!,
                grainSize: Double = AdjustmentFieldSpec.Fields.effectsGrainSize.macosModel.defaultValue.numberValue!,
                grainRoughness: Double = AdjustmentFieldSpec.Fields.effectsGrainRoughness.macosModel.defaultValue.numberValue!,
                grainToneCurve: GrainToneCurve = .legacy,
                grainFormatPreset: GrainFormatPreset = .custom) {
        self.vignetteAmount = Self.clamped(vignetteAmount, to: Self.vignetteAmountRange)
        self.vignetteMidpoint = Self.clamped(vignetteMidpoint, to: Self.vignetteMidpointRange)
        self.vignetteRoundness = Self.clamped(vignetteRoundness, to: Self.vignetteRoundnessRange)
        self.vignetteFeather = Self.clamped(vignetteFeather, to: Self.vignetteFeatherRange)
        self.vignetteHighlights = Self.clamped(vignetteHighlights, to: Self.vignetteHighlightsRange)
        self.grainAmount = Self.clamped(grainAmount, to: Self.grainAmountRange)
        self.grainSize = Self.clamped(grainSize, to: Self.grainSizeRange)
        self.grainRoughness = Self.clamped(grainRoughness, to: Self.grainRoughnessRange)
        self.grainToneCurve = grainToneCurve
        self.grainFormatPreset = grainFormatPreset
    }

    public var isValid: Bool {
        [vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather,
         vignetteHighlights, grainAmount, grainSize, grainRoughness].allSatisfy { $0.isFinite }
    }

    public var isDefault: Bool { self == Self() }

    public mutating func resetVignette() {
        self = Self(vignetteAmount: 0, vignetteMidpoint: 50, vignetteRoundness: 0,
                    vignetteFeather: 50, vignetteHighlights: 0,
                    grainAmount: grainAmount, grainSize: grainSize, grainRoughness: grainRoughness,
                    grainToneCurve: grainToneCurve, grainFormatPreset: grainFormatPreset)
    }

    public mutating func resetGrain() {
        self = Self(vignetteAmount: vignetteAmount, vignetteMidpoint: vignetteMidpoint,
                    vignetteRoundness: vignetteRoundness, vignetteFeather: vignetteFeather,
                    vignetteHighlights: vignetteHighlights, grainAmount: 0, grainSize: 25,
                    grainRoughness: 50, grainToneCurve: .legacy, grainFormatPreset: .custom)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return value }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
        case grainAmount, grainSize, grainRoughness, grainToneCurve, grainFormatPreset
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func decodeChecked(_ key: CodingKeys, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let raw = try values.decodeIfPresent(Double.self, forKey: key) else { return fallback }
            guard raw.isFinite, range.contains(raw) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Out of range photo effect parameter")
            }
            return raw
        }
        self.init(
            vignetteAmount: try decodeChecked(.vignetteAmount, default: 0, range: Self.vignetteAmountRange),
            vignetteMidpoint: try decodeChecked(.vignetteMidpoint, default: 50, range: Self.vignetteMidpointRange),
            vignetteRoundness: try decodeChecked(.vignetteRoundness, default: 0, range: Self.vignetteRoundnessRange),
            vignetteFeather: try decodeChecked(.vignetteFeather, default: 50, range: Self.vignetteFeatherRange),
            vignetteHighlights: try decodeChecked(.vignetteHighlights, default: 0, range: Self.vignetteHighlightsRange),
            grainAmount: try decodeChecked(.grainAmount, default: 0, range: Self.grainAmountRange),
            grainSize: try decodeChecked(.grainSize, default: 25, range: Self.grainSizeRange),
            grainRoughness: try decodeChecked(.grainRoughness, default: 50, range: Self.grainRoughnessRange),
            grainToneCurve: try values.decodeIfPresent(GrainToneCurve.self, forKey: .grainToneCurve) ?? .legacy,
            grainFormatPreset: try values.decodeIfPresent(GrainFormatPreset.self, forKey: .grainFormatPreset) ?? .custom
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(vignetteAmount, forKey: .vignetteAmount)
        try values.encode(vignetteMidpoint, forKey: .vignetteMidpoint)
        try values.encode(vignetteRoundness, forKey: .vignetteRoundness)
        try values.encode(vignetteFeather, forKey: .vignetteFeather)
        try values.encode(vignetteHighlights, forKey: .vignetteHighlights)
        try values.encode(grainAmount, forKey: .grainAmount)
        try values.encode(grainSize, forKey: .grainSize)
        try values.encode(grainRoughness, forKey: .grainRoughness)
        if grainToneCurve != .legacy { try values.encode(grainToneCurve, forKey: .grainToneCurve) }
        if grainFormatPreset != .custom { try values.encode(grainFormatPreset, forKey: .grainFormatPreset) }
    }
}

public enum PhotoEffectParameter: String, CaseIterable, Identifiable, Sendable {
    case vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
    case grainAmount, grainSize, grainRoughness

    public var id: String { rawValue }
    public var isVignette: Bool {
        switch self {
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights:
            return true
        case .grainAmount, .grainSize, .grainRoughness:
            return false
        }
    }
    public var title: String {
        switch self {
        case .vignetteAmount, .grainAmount: return L10n.text("强度")
        case .vignetteMidpoint: return L10n.text("中点")
        case .vignetteRoundness: return L10n.text("圆度")
        case .vignetteFeather: return L10n.text("羽化")
        case .vignetteHighlights: return L10n.text("高光保护")
        case .grainSize: return L10n.text("大小")
        case .grainRoughness: return L10n.text("粗糙度")
        }
    }
    public var keyPath: WritableKeyPath<PhotoEffectsSettings, Double> {
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
    public var range: ClosedRange<Double> {
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
    public var hdrKeyPath: WritableKeyPath<HDRPhotoEffectsSettings, Double> {
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
    public var defaultValue: Double { PhotoEffectsSettings()[keyPath: keyPath] }
}
