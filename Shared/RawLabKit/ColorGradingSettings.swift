import Foundation

public enum ColorGradingZone: String, CaseIterable, Identifiable, Codable {
    case shadows, midtones, highlights
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shadows: return L10n.text("阴影")
        case .midtones: return L10n.text("中间调")
        case .highlights: return L10n.text("高光")
        }
    }
}

public struct ColorGradingWheel: Codable, Equatable, Hashable {
    public var hue = 0.0
    public var saturation = 0.0
    public var luminance = 0.0
    public var isDefault: Bool { hue == 0 && saturation == 0 && luminance == 0 }
    public var isIdentity: Bool { saturation == 0 && luminance == 0 }
    public var isValid: Bool {
        let sub = AdjustmentFieldSpec.SubFields.ColorGradingWheel.self
        return hue.isFinite && hue >= sub.hueMin && hue < sub.hueMax &&
            saturation.isFinite && sub.saturationRange.contains(saturation) &&
            luminance.isFinite && sub.luminanceRange.contains(luminance)
    }
    // 用户输入允许端点 360；模型、复制与 native 均使用 [0,360)。
    public static func inputHue(_ value: Double) -> Double? {
        guard value.isFinite, (0...360).contains(value) else { return nil }
        return value == 360 ? 0 : value
    }
    public var point: (x: Double, y: Double) {
        let angle = hue * .pi / 180, radius = saturation / 100
        return (cos(angle) * radius, sin(angle) * radius)
    }
    public func moving(toX x: Double, y: Double) -> Self {
        guard x.isFinite, y.isFinite else { return self }
        let radius = hypot(x, y)
        guard radius > 0 else { return Self(hue: hue, saturation: 0, luminance: luminance) }
        let angle = atan2(y, x) * 180 / .pi
        return Self(hue: angle < 0 ? (angle + 360).truncatingRemainder(dividingBy: 360) : angle, saturation: min(1, radius) * 100, luminance: luminance)
    }
    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
    public enum CodingKeys: String, CodingKey { case hue, saturation, luminance }
    public init(from decoder: Decoder) throws {
        try GradingCodingKey.require(decoder, required: ["hue", "saturation"], allowed: ["hue", "saturation", "luminance"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hue = try values.decode(Double.self, forKey: .hue)
        saturation = try values.decode(Double.self, forKey: .saturation)
        luminance = values.contains(.luminance) ? try values.decode(Double.self, forKey: .luminance) : 0.0
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid grading wheel")) }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hue, forKey: .hue)
        try values.encode(saturation, forKey: .saturation)
        if luminance != 0.0 {
            try values.encode(luminance, forKey: .luminance)
        }
    }
}

public struct ColorGradingSettings: Codable, Equatable, Hashable {
    public var shadows = ColorGradingWheel()
    public var midtones = ColorGradingWheel()
    public var highlights = ColorGradingWheel()
    public var global = ColorGradingWheel()
    public var blending = 50.0
    public var balance = 0.0
    // 待用 hue 仍属于编辑记录，不能按渲染 identity 丢弃。
    public var isDefault: Bool {
        ColorGradingZone.allCases.allSatisfy { self[$0].isDefault } &&
            global.isDefault && blending == 50.0 && balance == 0.0
    }
    public var isIdentity: Bool {
        ColorGradingZone.allCases.allSatisfy { self[$0].isIdentity } && global.isIdentity
    }
    public var isValid: Bool {
        ColorGradingZone.allCases.allSatisfy { self[$0].isValid } &&
            global.isValid &&
            blending.isFinite && (0.0...100.0).contains(blending) &&
            balance.isFinite && (-100.0...100.0).contains(balance)
    }
    public var hasV2Extensions: Bool {
        !global.isDefault || blending != 50.0 || balance != 0.0 ||
            ColorGradingZone.allCases.contains(where: { self[$0].luminance != 0.0 })
    }
    public func scaled(by strength: Double) -> Self {
        var result = self
        for zone in ColorGradingZone.allCases {
            result[zone].saturation = min(100, max(0, self[zone].saturation * strength))
            result[zone].luminance = min(100, max(-100, self[zone].luminance * strength))
        }
        result.global.saturation = min(100, max(0, global.saturation * strength))
        result.global.luminance = min(100, max(-100, global.luminance * strength))
        return result
    }
    public var progress: Double {
        let zoneMax = ColorGradingZone.allCases.map { max(self[$0].saturation / 100, abs(self[$0].luminance) / 100) }.max() ?? 0
        return max(zoneMax, global.saturation / 100, abs(global.luminance) / 100)
    }
    public subscript(_ zone: ColorGradingZone) -> ColorGradingWheel {
        get { switch zone { case .shadows: return shadows; case .midtones: return midtones; case .highlights: return highlights } }
        set { switch zone { case .shadows: shadows = newValue; case .midtones: midtones = newValue; case .highlights: highlights = newValue } }
    }
    public init(shadows: ColorGradingWheel = ColorGradingWheel(),
                midtones: ColorGradingWheel = ColorGradingWheel(),
                highlights: ColorGradingWheel = ColorGradingWheel(),
                global: ColorGradingWheel = ColorGradingWheel(),
                blending: Double = 50.0,
                balance: Double = 0.0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.global = global
        self.blending = blending
        self.balance = balance
    }
    public enum CodingKeys: String, CodingKey { case shadows, midtones, highlights, global, blending, balance }
    public init(from decoder: Decoder) throws {
        try GradingCodingKey.require(
            decoder,
            required: ["shadows", "midtones", "highlights"],
            allowed: ["shadows", "midtones", "highlights", "global", "blending", "balance"]
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try values.decode(ColorGradingWheel.self, forKey: .shadows)
        midtones = try values.decode(ColorGradingWheel.self, forKey: .midtones)
        highlights = try values.decode(ColorGradingWheel.self, forKey: .highlights)
        global = values.contains(.global) ? try values.decode(ColorGradingWheel.self, forKey: .global) : ColorGradingWheel()
        blending = values.contains(.blending) ? try values.decode(Double.self, forKey: .blending) : 50.0
        balance = values.contains(.balance) ? try values.decode(Double.self, forKey: .balance) : 0.0
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid grading settings")) }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(shadows, forKey: .shadows)
        try values.encode(midtones, forKey: .midtones)
        try values.encode(highlights, forKey: .highlights)
        if !global.isDefault { try values.encode(global, forKey: .global) }
        if blending != 50.0 { try values.encode(blending, forKey: .blending) }
        if balance != 0.0 { try values.encode(balance, forKey: .balance) }
    }
}

public struct ColorGradingDrag {
    public let initial: ColorGradingWheel
    public let originX: Double
    public let originY: Double
    public let fine: Bool
    public init(initial: ColorGradingWheel, originX: Double, originY: Double, fine: Bool) {
        self.initial = initial; self.originX = originX; self.originY = originY; self.fine = fine
    }
    public func value(x: Double, y: Double) -> ColorGradingWheel {
        if fine {
            if x == originX && y == originY { return initial }
            return initial.moving(toX: initial.point.x + (x - originX) * 0.25,
                                  y: initial.point.y + (y - originY) * 0.25)
        }
        return initial.moving(toX: x, y: y)
    }
}

private struct GradingCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func require(_ decoder: Decoder, required: Set<String>, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        guard keys.isSuperset(of: required), keys.isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid grading fields"))
        }
    }
}
