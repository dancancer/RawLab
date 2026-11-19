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
    public var isDefault: Bool { hue == 0 && saturation == 0 }
    public var isIdentity: Bool { saturation == 0 }
    public var isValid: Bool {
        let sub = AdjustmentFieldSpec.SubFields.ColorGradingWheel.self
        return hue.isFinite && hue >= sub.hueMin && hue < sub.hueMax &&
            saturation.isFinite && sub.saturationRange.contains(saturation)
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
        guard radius > 0 else { return Self(hue: hue, saturation: 0) }
        let angle = atan2(y, x) * 180 / .pi
        return Self(hue: angle < 0 ? (angle + 360).truncatingRemainder(dividingBy: 360) : angle, saturation: min(1, radius) * 100)
    }
    public init(hue: Double = 0, saturation: Double = 0) {
        self.hue = hue; self.saturation = saturation
    }
    public enum CodingKeys: String, CodingKey { case hue, saturation }
    public init(from decoder: Decoder) throws {
        try GradingCodingKey.require(decoder, keys: ["hue", "saturation"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hue = try values.decode(Double.self, forKey: .hue)
        saturation = try values.decode(Double.self, forKey: .saturation)
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid grading wheel")) }
    }
}

public struct ColorGradingSettings: Codable, Equatable, Hashable {
    public var shadows = ColorGradingWheel()
    public var midtones = ColorGradingWheel()
    public var highlights = ColorGradingWheel()
    // 待用 hue 仍属于编辑记录，不能按渲染 identity 丢弃。
    public var isDefault: Bool { ColorGradingZone.allCases.allSatisfy { self[$0].isDefault } }
    public var isIdentity: Bool { ColorGradingZone.allCases.allSatisfy { self[$0].isIdentity } }
    public var isValid: Bool { ColorGradingZone.allCases.allSatisfy { self[$0].isValid } }
    public func scaled(by strength: Double) -> Self {
        var result = self
        for zone in ColorGradingZone.allCases {
            result[zone].saturation = min(100, max(0, self[zone].saturation * strength))
        }
        return result
    }
    public var progress: Double { ColorGradingZone.allCases.map { self[$0].saturation / 100 }.max() ?? 0 }
    public subscript(_ zone: ColorGradingZone) -> ColorGradingWheel {
        get { switch zone { case .shadows: return shadows; case .midtones: return midtones; case .highlights: return highlights } }
        set { switch zone { case .shadows: shadows = newValue; case .midtones: midtones = newValue; case .highlights: highlights = newValue } }
    }
    public init(shadows: ColorGradingWheel = ColorGradingWheel(),
                midtones: ColorGradingWheel = ColorGradingWheel(),
                highlights: ColorGradingWheel = ColorGradingWheel()) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
    }
    public enum CodingKeys: String, CodingKey { case shadows, midtones, highlights }
    public init(from decoder: Decoder) throws {
        try GradingCodingKey.require(decoder, keys: ["shadows", "midtones", "highlights"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try values.decode(ColorGradingWheel.self, forKey: .shadows)
        midtones = try values.decode(ColorGradingWheel.self, forKey: .midtones)
        highlights = try values.decode(ColorGradingWheel.self, forKey: .highlights)
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
    static func require(_ decoder: Decoder, keys: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard Set(values.allKeys.map(\.stringValue)) == keys else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid grading fields"))
        }
    }
}
