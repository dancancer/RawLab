import Foundation

private func v014CheckedDouble(
    _ values: KeyedDecodingContainer<V014DynamicKey>,
    key: String,
    default fallback: Double,
    range: ClosedRange<Double>,
    exclusiveMax: Bool = false
) throws -> Double {
    let codingKey = V014DynamicKey(stringValue: key)!
    guard let raw = try values.decodeIfPresent(Double.self, forKey: codingKey) else { return fallback }
    let inBounds = exclusiveMax ? (raw >= range.lowerBound && raw < range.upperBound) : range.contains(raw)
    guard raw.isFinite, inBounds else {
        throw DecodingError.dataCorruptedError(forKey: codingKey, in: values, debugDescription: "Out of range \(key)")
    }
    return raw == 0 ? 0 : raw
}

private struct V014DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public enum GrainToneCurve: String, CaseIterable, Identifiable, Codable, Sendable {
    case legacy = "legacy"
    case negativeAsymmetric = "negative_asymmetric"
    public var id: String { rawValue }
}

public enum GrainFormatPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case custom = "custom"
    case film135 = "135"
    case film120 = "120"
    public var id: String { rawValue }
}

public struct CameraCalibrationSettings: Codable, Equatable, Hashable, Sendable {
    public static let axisRange: ClosedRange<Double> =
        AdjustmentFieldSpec.Fields.colorCalibrationShadowTint.macosModel.closedRange!

    public var shadowTint: Double = 0.0
    public var redHue: Double = 0.0
    public var redSaturation: Double = 0.0
    public var greenHue: Double = 0.0
    public var greenSaturation: Double = 0.0
    public var blueHue: Double = 0.0
    public var blueSaturation: Double = 0.0

    public init(
        shadowTint: Double = 0.0,
        redHue: Double = 0.0,
        redSaturation: Double = 0.0,
        greenHue: Double = 0.0,
        greenSaturation: Double = 0.0,
        blueHue: Double = 0.0,
        blueSaturation: Double = 0.0
    ) {
        self.shadowTint = shadowTint == 0 ? 0 : shadowTint
        self.redHue = redHue == 0 ? 0 : redHue
        self.redSaturation = redSaturation == 0 ? 0 : redSaturation
        self.greenHue = greenHue == 0 ? 0 : greenHue
        self.greenSaturation = greenSaturation == 0 ? 0 : greenSaturation
        self.blueHue = blueHue == 0 ? 0 : blueHue
        self.blueSaturation = blueSaturation == 0 ? 0 : blueSaturation
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        [shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation]
            .allSatisfy { $0.isFinite && Self.axisRange.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        self.init(
            shadowTint: try v014CheckedDouble(c, key: "shadowTint", default: 0, range: Self.axisRange),
            redHue: try v014CheckedDouble(c, key: "redHue", default: 0, range: Self.axisRange),
            redSaturation: try v014CheckedDouble(c, key: "redSaturation", default: 0, range: Self.axisRange),
            greenHue: try v014CheckedDouble(c, key: "greenHue", default: 0, range: Self.axisRange),
            greenSaturation: try v014CheckedDouble(c, key: "greenSaturation", default: 0, range: Self.axisRange),
            blueHue: try v014CheckedDouble(c, key: "blueHue", default: 0, range: Self.axisRange),
            blueSaturation: try v014CheckedDouble(c, key: "blueSaturation", default: 0, range: Self.axisRange)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shadowTint, forKey: .shadowTint)
        try c.encode(redHue, forKey: .redHue)
        try c.encode(redSaturation, forKey: .redSaturation)
        try c.encode(greenHue, forKey: .greenHue)
        try c.encode(greenSaturation, forKey: .greenSaturation)
        try c.encode(blueHue, forKey: .blueHue)
        try c.encode(blueSaturation, forKey: .blueSaturation)
    }

    private enum CodingKeys: String, CodingKey {
        case shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation
    }
}

public struct PointColorSwatch: Codable, Equatable, Hashable, Sendable {
    public static let shiftRange: ClosedRange<Double> =
        AdjustmentFieldSpec.SubFields.PointColor.shiftRange
    public static let controlRange: ClosedRange<Double> =
        AdjustmentFieldSpec.SubFields.PointColor.rangeControlRange

    public var srcHue: Double
    public var srcSaturation: Double
    public var srcLuminance: Double
    public var hueShift: Double
    public var saturationShift: Double
    public var luminanceShift: Double
    public var range: Double
    public var hueRange: Double
    public var satRange: Double
    public var lumRange: Double
    public var variance: Double
    public var enabled: Bool

    public init(
        srcHue: Double = 0.0,
        srcSaturation: Double = 0.5,
        srcLuminance: Double = 0.5,
        hueShift: Double = 0.0,
        saturationShift: Double = 0.0,
        luminanceShift: Double = 0.0,
        range: Double = 50.0,
        hueRange: Double = 50.0,
        satRange: Double = 50.0,
        lumRange: Double = 50.0,
        variance: Double = 0.0,
        enabled: Bool = true
    ) {
        self.srcHue = srcHue == 0 ? 0 : srcHue
        self.srcSaturation = srcSaturation == 0 ? 0 : srcSaturation
        self.srcLuminance = srcLuminance == 0 ? 0 : srcLuminance
        self.hueShift = hueShift == 0 ? 0 : hueShift
        self.saturationShift = saturationShift == 0 ? 0 : saturationShift
        self.luminanceShift = luminanceShift == 0 ? 0 : luminanceShift
        self.range = range == 0 ? 0 : range
        self.hueRange = hueRange == 0 ? 0 : hueRange
        self.satRange = satRange == 0 ? 0 : satRange
        self.lumRange = lumRange == 0 ? 0 : lumRange
        self.variance = variance == 0 ? 0 : variance
        self.enabled = enabled
    }

    public var isValid: Bool {
        let sf = AdjustmentFieldSpec.SubFields.PointColor.self
        return srcHue.isFinite && srcHue >= sf.srcHueMin && srcHue < sf.srcHueMax
            && srcSaturation.isFinite && sf.srcSaturationRange.contains(srcSaturation)
            && srcLuminance.isFinite && sf.srcLuminanceRange.contains(srcLuminance)
            && [hueShift, saturationShift, luminanceShift, variance].allSatisfy { $0.isFinite && Self.shiftRange.contains($0) }
            && [range, hueRange, satRange, lumRange].allSatisfy { $0.isFinite && Self.controlRange.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let sf = AdjustmentFieldSpec.SubFields.PointColor.self
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        let enabledKey = V014DynamicKey(stringValue: "enabled")!
        let enabledVal = try c.decodeIfPresent(Bool.self, forKey: enabledKey) ?? sf.enabledDefault
        self.init(
            srcHue: try v014CheckedDouble(c, key: "srcHue", default: 0, range: sf.srcHueMin...sf.srcHueMax, exclusiveMax: sf.srcHueExclusiveMax),
            srcSaturation: try v014CheckedDouble(c, key: "srcSaturation", default: 0.5, range: sf.srcSaturationRange),
            srcLuminance: try v014CheckedDouble(c, key: "srcLuminance", default: 0.5, range: sf.srcLuminanceRange),
            hueShift: try v014CheckedDouble(c, key: "hueShift", default: sf.shiftDefault, range: Self.shiftRange),
            saturationShift: try v014CheckedDouble(c, key: "saturationShift", default: sf.shiftDefault, range: Self.shiftRange),
            luminanceShift: try v014CheckedDouble(c, key: "luminanceShift", default: sf.shiftDefault, range: Self.shiftRange),
            range: try v014CheckedDouble(c, key: "range", default: sf.rangeControlDefault, range: Self.controlRange),
            hueRange: try v014CheckedDouble(c, key: "hueRange", default: sf.rangeControlDefault, range: Self.controlRange),
            satRange: try v014CheckedDouble(c, key: "satRange", default: sf.rangeControlDefault, range: Self.controlRange),
            lumRange: try v014CheckedDouble(c, key: "lumRange", default: sf.rangeControlDefault, range: Self.controlRange),
            variance: try v014CheckedDouble(c, key: "variance", default: sf.shiftDefault, range: Self.shiftRange),
            enabled: enabledVal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(srcHue, forKey: .srcHue)
        try c.encode(srcSaturation, forKey: .srcSaturation)
        try c.encode(srcLuminance, forKey: .srcLuminance)
        try c.encode(hueShift, forKey: .hueShift)
        try c.encode(saturationShift, forKey: .saturationShift)
        try c.encode(luminanceShift, forKey: .luminanceShift)
        try c.encode(range, forKey: .range)
        try c.encode(hueRange, forKey: .hueRange)
        try c.encode(satRange, forKey: .satRange)
        try c.encode(lumRange, forKey: .lumRange)
        try c.encode(variance, forKey: .variance)
        try c.encode(enabled, forKey: .enabled)
    }

    private enum CodingKeys: String, CodingKey {
        case srcHue, srcSaturation, srcLuminance
        case hueShift, saturationShift, luminanceShift
        case range, hueRange, satRange, lumRange, variance, enabled
    }
}

public struct PointColorSettings: Codable, Equatable, Hashable, Sendable {
    public var swatches: [PointColorSwatch] = []
    public init(swatches: [PointColorSwatch] = []) { self.swatches = swatches }
    public var isDefault: Bool { swatches.isEmpty }
    public var isValid: Bool {
        swatches.count <= AdjustmentFieldSpec.SubFields.PointColor.maxSwatches && swatches.allSatisfy(\.isValid)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decodeIfPresent([PointColorSwatch].self, forKey: .swatches) ?? []
        guard list.count <= AdjustmentFieldSpec.SubFields.PointColor.maxSwatches, list.allSatisfy(\.isValid) else {
            throw DecodingError.dataCorruptedError(forKey: .swatches, in: c, debugDescription: "Invalid point color swatches")
        }
        self.swatches = list
    }

    private enum CodingKeys: String, CodingKey { case swatches }
}

public enum SelectiveColorMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case relative = "relative"
    case absolute = "absolute"
    public var id: String { rawValue }
}

public struct SelectiveColorBand: Codable, Equatable, Hashable, Sendable {
    public static let componentRange: ClosedRange<Double> =
        AdjustmentFieldSpec.SubFields.SelectiveColor.componentRange

    public var cyan: Double = 0.0
    public var magenta: Double = 0.0
    public var yellow: Double = 0.0
    public var black: Double = 0.0

    public init(cyan: Double = 0.0, magenta: Double = 0.0, yellow: Double = 0.0, black: Double = 0.0) {
        self.cyan = cyan == 0 ? 0 : cyan
        self.magenta = magenta == 0 ? 0 : magenta
        self.yellow = yellow == 0 ? 0 : yellow
        self.black = black == 0 ? 0 : black
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        [cyan, magenta, yellow, black].allSatisfy { $0.isFinite && Self.componentRange.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        self.init(
            cyan: try v014CheckedDouble(c, key: "cyan", default: 0, range: Self.componentRange),
            magenta: try v014CheckedDouble(c, key: "magenta", default: 0, range: Self.componentRange),
            yellow: try v014CheckedDouble(c, key: "yellow", default: 0, range: Self.componentRange),
            black: try v014CheckedDouble(c, key: "black", default: 0, range: Self.componentRange)
        )
    }

    private enum CodingKeys: String, CodingKey { case cyan, magenta, yellow, black }
}

public struct SelectiveColorBands: Codable, Equatable, Hashable, Sendable {
    public var reds: SelectiveColorBand
    public var yellows: SelectiveColorBand
    public var greens: SelectiveColorBand
    public var cyans: SelectiveColorBand
    public var blues: SelectiveColorBand
    public var magentas: SelectiveColorBand
    public var whites: SelectiveColorBand
    public var neutrals: SelectiveColorBand
    public var blacks: SelectiveColorBand

    public init(
        reds: SelectiveColorBand = .init(),
        yellows: SelectiveColorBand = .init(),
        greens: SelectiveColorBand = .init(),
        cyans: SelectiveColorBand = .init(),
        blues: SelectiveColorBand = .init(),
        magentas: SelectiveColorBand = .init(),
        whites: SelectiveColorBand = .init(),
        neutrals: SelectiveColorBand = .init(),
        blacks: SelectiveColorBand = .init()
    ) {
        self.reds = reds; self.yellows = yellows; self.greens = greens
        self.cyans = cyans; self.blues = blues; self.magentas = magentas
        self.whites = whites; self.neutrals = neutrals; self.blacks = blacks
    }

    public var allBands: [(String, SelectiveColorBand)] {
        [("reds", reds), ("yellows", yellows), ("greens", greens), ("cyans", cyans),
         ("blues", blues), ("magentas", magentas), ("whites", whites), ("neutrals", neutrals), ("blacks", blacks)]
    }
    public var isDefault: Bool { self == Self() }
    public var isValid: Bool { allBands.allSatisfy { $0.1.isValid } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            reds: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .reds) ?? .init(),
            yellows: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .yellows) ?? .init(),
            greens: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .greens) ?? .init(),
            cyans: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .cyans) ?? .init(),
            blues: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .blues) ?? .init(),
            magentas: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .magentas) ?? .init(),
            whites: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .whites) ?? .init(),
            neutrals: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .neutrals) ?? .init(),
            blacks: try c.decodeIfPresent(SelectiveColorBand.self, forKey: .blacks) ?? .init()
        )
    }

    private enum CodingKeys: String, CodingKey {
        case reds, yellows, greens, cyans, blues, magentas, whites, neutrals, blacks
    }
}

public struct SelectiveColorSettings: Codable, Equatable, Hashable, Sendable {
    public var method: SelectiveColorMethod = .relative
    public var bands: SelectiveColorBands = .init()

    public init(method: SelectiveColorMethod = .relative, bands: SelectiveColorBands = .init()) {
        self.method = method
        self.bands = bands
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool { bands.isValid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(SelectiveColorMethod.self, forKey: .method) ?? .relative
        bands = try c.decodeIfPresent(SelectiveColorBands.self, forKey: .bands) ?? .init()
    }

    private enum CodingKeys: String, CodingKey { case method, bands }
}

public struct BwMixerChannelWeights: Codable, Equatable, Hashable, Sendable {
    public static let weightRange: ClosedRange<Double> =
        AdjustmentFieldSpec.SubFields.BwMixer.channelRange

    public var red: Double = 0.0
    public var orange: Double = 0.0
    public var yellow: Double = 0.0
    public var green: Double = 0.0
    public var aqua: Double = 0.0
    public var blue: Double = 0.0
    public var purple: Double = 0.0
    public var magenta: Double = 0.0

    public init(
        red: Double = 0.0,
        orange: Double = 0.0,
        yellow: Double = 0.0,
        green: Double = 0.0,
        aqua: Double = 0.0,
        blue: Double = 0.0,
        purple: Double = 0.0,
        magenta: Double = 0.0
    ) {
        self.red = red == 0 ? 0 : red
        self.orange = orange == 0 ? 0 : orange
        self.yellow = yellow == 0 ? 0 : yellow
        self.green = green == 0 ? 0 : green
        self.aqua = aqua == 0 ? 0 : aqua
        self.blue = blue == 0 ? 0 : blue
        self.purple = purple == 0 ? 0 : purple
        self.magenta = magenta == 0 ? 0 : magenta
    }

    public var allChannels: [(String, Double)] {
        [("red", red), ("orange", orange), ("yellow", yellow), ("green", green),
         ("aqua", aqua), ("blue", blue), ("purple", purple), ("magenta", magenta)]
    }
    public var isDefault: Bool { self == Self() }
    public var isValid: Bool { allChannels.allSatisfy { $0.1.isFinite && Self.weightRange.contains($0.1) } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        self.init(
            red: try v014CheckedDouble(c, key: "red", default: 0, range: Self.weightRange),
            orange: try v014CheckedDouble(c, key: "orange", default: 0, range: Self.weightRange),
            yellow: try v014CheckedDouble(c, key: "yellow", default: 0, range: Self.weightRange),
            green: try v014CheckedDouble(c, key: "green", default: 0, range: Self.weightRange),
            aqua: try v014CheckedDouble(c, key: "aqua", default: 0, range: Self.weightRange),
            blue: try v014CheckedDouble(c, key: "blue", default: 0, range: Self.weightRange),
            purple: try v014CheckedDouble(c, key: "purple", default: 0, range: Self.weightRange),
            magenta: try v014CheckedDouble(c, key: "magenta", default: 0, range: Self.weightRange)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }
}

public struct BwMixerSettings: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool = false
    public var mixer: BwMixerChannelWeights = .init()

    public init(enabled: Bool = false, mixer: BwMixerChannelWeights = .init()) {
        self.enabled = enabled
        self.mixer = mixer
    }

    public var isDefault: Bool { !enabled && mixer.isDefault }
    public var isValid: Bool { mixer.isValid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mixer = try c.decodeIfPresent(BwMixerChannelWeights.self, forKey: .mixer) ?? .init()
    }

    private enum CodingKeys: String, CodingKey { case enabled, mixer }
}

public struct SharpenV2Settings: Codable, Equatable, Hashable, Sendable {
    public static let radiusRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.detailSharpeningRadius.macosModel.closedRange!
    public static let detailRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.detailSharpeningDetail.macosModel.closedRange!
    public static let maskingRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.detailSharpeningMasking.macosModel.closedRange!

    public var luminanceV2: Bool = false
    public var radius: Double = 1.0
    public var detail: Double = 25.0
    public var masking: Double = 0.0

    public init(luminanceV2: Bool = false, radius: Double = 1.0, detail: Double = 25.0, masking: Double = 0.0) {
        self.luminanceV2 = luminanceV2
        self.radius = radius
        self.detail = detail == 0 ? 0 : detail
        self.masking = masking == 0 ? 0 : masking
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        radius.isFinite && Self.radiusRange.contains(radius)
            && detail.isFinite && Self.detailRange.contains(detail)
            && masking.isFinite && Self.maskingRange.contains(masking)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        let lumKey = V014DynamicKey(stringValue: "luminanceV2")!
        let luminance = try c.decodeIfPresent(Bool.self, forKey: lumKey) ?? false
        self.init(
            luminanceV2: luminance,
            radius: try v014CheckedDouble(c, key: "radius", default: 1.0, range: Self.radiusRange),
            detail: try v014CheckedDouble(c, key: "detail", default: 25.0, range: Self.detailRange),
            masking: try v014CheckedDouble(c, key: "masking", default: 0.0, range: Self.maskingRange)
        )
    }

    private enum CodingKeys: String, CodingKey { case luminanceV2, radius, detail, masking }
}

public struct FilmOpticsSettings: Codable, Equatable, Hashable, Sendable {
    public static let halationAmountRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsHalationAmount.macosModel.closedRange!
    public static let halationThresholdRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsHalationThreshold.macosModel.closedRange!
    public static let halationRadiusRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsHalationRadius.macosModel.closedRange!
    public static let halationHueRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsHalationHue.macosModel.closedRange!
    public static let bloomAmountRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsBloomAmount.macosModel.closedRange!
    public static let bloomThresholdRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsBloomThreshold.macosModel.closedRange!
    public static let bloomRadiusRange: ClosedRange<Double> = AdjustmentFieldSpec.Fields.effectsBloomRadius.macosModel.closedRange!

    public var halationAmount: Double = 0.0
    public var halationThreshold: Double = 75.0
    public var halationRadius: Double = 35.0
    public var halationHue: Double = 0.0
    public var bloomAmount: Double = 0.0
    public var bloomThreshold: Double = 70.0
    public var bloomRadius: Double = 40.0

    public init(
        halationAmount: Double = 0.0,
        halationThreshold: Double = 75.0,
        halationRadius: Double = 35.0,
        halationHue: Double = 0.0,
        bloomAmount: Double = 0.0,
        bloomThreshold: Double = 70.0,
        bloomRadius: Double = 40.0
    ) {
        self.halationAmount = halationAmount == 0 ? 0 : halationAmount
        self.halationThreshold = halationThreshold == 0 ? 0 : halationThreshold
        self.halationRadius = halationRadius == 0 ? 0 : halationRadius
        self.halationHue = halationHue == 0 ? 0 : halationHue
        self.bloomAmount = bloomAmount == 0 ? 0 : bloomAmount
        self.bloomThreshold = bloomThreshold == 0 ? 0 : bloomThreshold
        self.bloomRadius = bloomRadius == 0 ? 0 : bloomRadius
    }

    public var isDefault: Bool { self == Self() }
    public var isValid: Bool {
        halationAmount.isFinite && Self.halationAmountRange.contains(halationAmount)
            && halationThreshold.isFinite && Self.halationThresholdRange.contains(halationThreshold)
            && halationRadius.isFinite && Self.halationRadiusRange.contains(halationRadius)
            && halationHue.isFinite && Self.halationHueRange.contains(halationHue)
            && bloomAmount.isFinite && Self.bloomAmountRange.contains(bloomAmount)
            && bloomThreshold.isFinite && Self.bloomThresholdRange.contains(bloomThreshold)
            && bloomRadius.isFinite && Self.bloomRadiusRange.contains(bloomRadius)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: V014DynamicKey.self)
        self.init(
            halationAmount: try v014CheckedDouble(c, key: "halationAmount", default: 0.0, range: Self.halationAmountRange),
            halationThreshold: try v014CheckedDouble(c, key: "halationThreshold", default: 75.0, range: Self.halationThresholdRange),
            halationRadius: try v014CheckedDouble(c, key: "halationRadius", default: 35.0, range: Self.halationRadiusRange),
            halationHue: try v014CheckedDouble(c, key: "halationHue", default: 0.0, range: Self.halationHueRange),
            bloomAmount: try v014CheckedDouble(c, key: "bloomAmount", default: 0.0, range: Self.bloomAmountRange),
            bloomThreshold: try v014CheckedDouble(c, key: "bloomThreshold", default: 70.0, range: Self.bloomThresholdRange),
            bloomRadius: try v014CheckedDouble(c, key: "bloomRadius", default: 40.0, range: Self.bloomRadiusRange)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case halationAmount, halationThreshold, halationRadius, halationHue
        case bloomAmount, bloomThreshold, bloomRadius
    }
}
