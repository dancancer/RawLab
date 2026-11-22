import Foundation

public enum ToneCurveMode: String, Codable { case legacy, custom }

public struct ToneCurvePoint: Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self); y = try values.decode(Double.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Curve point requires x and y")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x); try values.encode(y)
    }
}

public struct ToneCurveShape: Equatable, Hashable, Codable {
    public static let hdrExposureRange = -8.0...8.0
    public var mode: ToneCurveMode = .legacy
    public var points: [ToneCurvePoint] = []
    public static let identity = Self(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])
    public var isDefault: Bool { mode == .legacy && points.isEmpty }
    public var isIdentity: Bool { mode == .legacy || points.allSatisfy { $0.x == $0.y } }
    public var hasUnpinnedEndpoints: Bool {
        mode == .custom && ((points.first?.y ?? 0) != 0 || (points.last?.y ?? 1) != 1)
    }
    public var isValid: Bool {
        let sub = AdjustmentFieldSpec.SubFields.LightCurve.self
        if mode == .legacy { return points.count == sub.legacyPointsCount }
        guard (sub.customMinPoints...sub.customMaxPoints).contains(points.count),
              let first = points.first, let last = points.last,
              first.x == sub.coordRange.lowerBound,
              last.x == sub.coordRange.upperBound,
              sub.endpointsYUnpinned || (first.y == sub.coordRange.lowerBound && last.y == sub.coordRange.upperBound) else { return false }
        for (index, point) in points.enumerated() {
            guard point.x.isFinite, point.y.isFinite,
                  sub.coordRange.contains(point.x), sub.coordRange.contains(point.y) else { return false }
            if index > 0 && (point.x <= points[index - 1].x || point.y < points[index - 1].y) { return false }
        }
        return true
    }
    public var progress: Double { points.map { abs($0.y - $0.x) }.max() ?? 0 }
    public func scaled(by strength: Double) -> Self {
        guard mode == .custom, strength != 1 else { return self }
        guard strength != 0 else { return .identity }
        var result = self
        var previous = 0.0
        for index in result.points.indices {
            let point = points[index]
            // 放大相对恒等线的偏移；极端手动曲线仍保持端点和明暗单调性。
            let y = min(1, max(previous, point.x + (point.y - point.x) * strength))
            result.points[index].y = y
            previous = y
        }
        return result
    }
    public func isInterior(_ index: Int) -> Bool { mode == .custom && index > 0 && index + 1 < points.count }
    public func inserting(x: Double, y: Double) -> Self {
        guard mode == .custom, isValid, points.count < 33, x.isFinite, y.isFinite, x > 0, x < 1,
              !points.contains(where: { $0.x == x }), let next = points.firstIndex(where: { $0.x > x }) else { return self }
        var result = self
        result.points.insert(.init(x: x, y: min(points[next].y, max(points[next - 1].y, y))), at: next)
        return result
    }
    public func moving(index: Int, x: Double, y: Double) -> Self {
        guard isValid, isInterior(index), x.isFinite, y.isFinite else { return self }
        let previous = points[index - 1], next = points[index + 1]
        let low = previous.x.nextUp, high = next.x.nextDown
        guard low <= high else { return self }
        var result = self
        result.points[index] = .init(x: min(high, max(low, x)), y: min(next.y, max(previous.y, y)))
        return result
    }
    public func removing(index: Int) -> Self {
        guard isInterior(index) else { return self }
        var result = self; result.points.remove(at: index); return result
    }
    public init(mode: ToneCurveMode = .legacy, points: [ToneCurvePoint] = []) { self.mode = mode; self.points = points }
    public enum CodingKeys: String, CodingKey { case mode, points }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CurveCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["mode", "points"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid curve fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(ToneCurveMode.self, forKey: .mode)
        points = try values.decode([ToneCurvePoint].self, forKey: .points)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: values, debugDescription: "Invalid curve points")
        }
    }
}

public enum ToneCurveChannel: String, CaseIterable, Identifiable {
    case rgb, red, green, blue
    public var id: String { rawValue }
    public var shortLabel: String { self == .rgb ? "RGB" : String(rawValue.prefix(1)).uppercased() }
}

public struct ToneCurveChannels: Equatable, Hashable, Codable {
    public var red = ToneCurveShape()
    public var green = ToneCurveShape()
    public var blue = ToneCurveShape()
    public var isDefault: Bool { red.isDefault && green.isDefault && blue.isDefault }
    public var isIdentity: Bool { red.isIdentity && green.isIdentity && blue.isIdentity }
    public var isValid: Bool { red.isValid && green.isValid && blue.isValid }
    public var hasUnpinnedEndpoints: Bool {
        red.hasUnpinnedEndpoints || green.hasUnpinnedEndpoints || blue.hasUnpinnedEndpoints
    }
    public var progress: Double { max(red.progress, green.progress, blue.progress) }
    public func scaled(by strength: Double) -> Self {
        Self(red: red.scaled(by: strength), green: green.scaled(by: strength), blue: blue.scaled(by: strength))
    }
    public init(red: ToneCurveShape = .init(), green: ToneCurveShape = .init(), blue: ToneCurveShape = .init()) {
        self.red = red; self.green = green; self.blue = blue
    }
    public enum CodingKeys: String, CodingKey { case red, green, blue }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CurveCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["red", "green", "blue"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid curve channels"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        red = values.contains(.red) ? try values.decode(ToneCurveShape.self, forKey: .red) : .init()
        green = values.contains(.green) ? try values.decode(ToneCurveShape.self, forKey: .green) : .init()
        blue = values.contains(.blue) ? try values.decode(ToneCurveShape.self, forKey: .blue) : .init()
    }
}

public struct ToneCurveParametric: Equatable, Hashable, Codable {
    public var highlights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault
    public var lights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault
    public var darks: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault
    public var shadows: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault
    public var splitShadow: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitShadowDefault
    public var splitMidtone: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitMidtoneDefault
    public var splitHighlight: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitHighlightDefault

    public var isDefault: Bool {
        let sub = AdjustmentFieldSpec.SubFields.LightCurveParametric.self
        return highlights == sub.bandDefault && lights == sub.bandDefault &&
            darks == sub.bandDefault && shadows == sub.bandDefault &&
            splitShadow == sub.splitShadowDefault && splitMidtone == sub.splitMidtoneDefault &&
            splitHighlight == sub.splitHighlightDefault
    }
    public var isIdentity: Bool {
        let sub = AdjustmentFieldSpec.SubFields.LightCurveParametric.self
        return highlights == sub.bandDefault && lights == sub.bandDefault &&
            darks == sub.bandDefault && shadows == sub.bandDefault
    }
    public var isValid: Bool {
        let sub = AdjustmentFieldSpec.SubFields.LightCurveParametric.self
        return [highlights, lights, darks, shadows, splitShadow, splitMidtone, splitHighlight].allSatisfy(\.isFinite) &&
            sub.bandRange.contains(highlights) && sub.bandRange.contains(lights) &&
            sub.bandRange.contains(darks) && sub.bandRange.contains(shadows) &&
            sub.splitShadowRange.contains(splitShadow) &&
            sub.splitMidtoneRange.contains(splitMidtone) &&
            sub.splitHighlightRange.contains(splitHighlight) &&
            splitShadow + sub.splitMinGap <= splitMidtone &&
            splitMidtone + sub.splitMinGap <= splitHighlight
    }
    public var progress: Double {
        max(abs(highlights), abs(lights), abs(darks), abs(shadows)) / 100
    }
    public func scaled(by strength: Double) -> Self {
        var result = self
        result.highlights = min(100, max(-100, highlights * strength))
        result.lights = min(100, max(-100, lights * strength))
        result.darks = min(100, max(-100, darks * strength))
        result.shadows = min(100, max(-100, shadows * strength))
        return result
    }
    public init(
        highlights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
        lights: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
        darks: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
        shadows: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.bandDefault,
        splitShadow: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitShadowDefault,
        splitMidtone: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitMidtoneDefault,
        splitHighlight: Double = AdjustmentFieldSpec.SubFields.LightCurveParametric.splitHighlightDefault
    ) {
        self.highlights = highlights
        self.lights = lights
        self.darks = darks
        self.shadows = shadows
        self.splitShadow = splitShadow
        self.splitMidtone = splitMidtone
        self.splitHighlight = splitHighlight
    }
    public enum CodingKeys: String, CodingKey {
        case highlights, lights, darks, shadows
        case splitShadow = "split_shadow"
        case splitMidtone = "split_midtone"
        case splitHighlight = "split_highlight"
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CurveCodingKey.self)
        let expected: Set<String> = ["highlights", "lights", "darks", "shadows", "split_shadow", "split_midtone", "split_highlight"]
        guard Set(keys.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid parametric curve fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try values.decode(Double.self, forKey: .highlights)
        lights = try values.decode(Double.self, forKey: .lights)
        darks = try values.decode(Double.self, forKey: .darks)
        shadows = try values.decode(Double.self, forKey: .shadows)
        splitShadow = try values.decode(Double.self, forKey: .splitShadow)
        splitMidtone = try values.decode(Double.self, forKey: .splitMidtone)
        splitHighlight = try values.decode(Double.self, forKey: .splitHighlight)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid parametric curve values"))
        }
    }
}

public struct ToneCurveSettings: Equatable, Hashable, Codable {
    public static let hdrExposureRange = ToneCurveShape.hdrExposureRange
    public var master: ToneCurveShape
    public var channels: ToneCurveChannels
    public var applyToLuminosity: Bool
    public var parametric: ToneCurveParametric
    public var mode: ToneCurveMode { get { master.mode } set { master.mode = newValue } }
    public var points: [ToneCurvePoint] { get { master.points } set { master.points = newValue } }
    public static let identity = Self(mode: .custom, points: ToneCurveShape.identity.points)
    public var isDefault: Bool { master.isDefault && channels.isDefault && !applyToLuminosity && parametric.isDefault }
    public var isIdentity: Bool { master.isIdentity && channels.isIdentity && parametric.isIdentity }
    public var isValid: Bool { master.isValid && channels.isValid && parametric.isValid }
    public var progress: Double { max(master.progress, channels.progress, parametric.progress) }
    public var hasChannelCurves: Bool { !channels.isDefault }
    public var hasV2Extensions: Bool {
        applyToLuminosity || !parametric.isDefault || master.hasUnpinnedEndpoints || channels.hasUnpinnedEndpoints
    }
    public var labeledPoints: [(channel: ToneCurveChannel, point: ToneCurvePoint)] {
        ToneCurveChannel.allCases.flatMap { channel in shape(channel).points.map { (channel, $0) } }
    }
    public init(mode: ToneCurveMode = .legacy,
                points: [ToneCurvePoint] = [],
                channels: ToneCurveChannels = .init(),
                applyToLuminosity: Bool = false,
                parametric: ToneCurveParametric = .init()) {
        master = .init(mode: mode, points: points)
        self.channels = channels
        self.applyToLuminosity = applyToLuminosity
        self.parametric = parametric
    }
    public func shape(_ channel: ToneCurveChannel) -> ToneCurveShape {
        switch channel { case .rgb: return master; case .red: return channels.red; case .green: return channels.green; case .blue: return channels.blue }
    }
    public func replacing(_ channel: ToneCurveChannel, with shape: ToneCurveShape) -> Self {
        var result = self
        switch channel { case .rgb: result.master = shape; case .red: result.channels.red = shape; case .green: result.channels.green = shape; case .blue: result.channels.blue = shape }
        return result
    }
    public func scaled(by strength: Double) -> Self {
        var result = self
        result.master = master.scaled(by: strength)
        result.channels = channels.scaled(by: strength)
        result.parametric = parametric.scaled(by: strength)
        return result
    }
    public func isInterior(_ index: Int) -> Bool { master.isInterior(index) }
    public func inserting(x: Double, y: Double) -> Self { replacing(.rgb, with: master.inserting(x: x, y: y)) }
    public func moving(index: Int, x: Double, y: Double) -> Self { replacing(.rgb, with: master.moving(index: index, x: x, y: y)) }
    public func removing(index: Int) -> Self { replacing(.rgb, with: master.removing(index: index)) }
    public enum CodingKeys: String, CodingKey {
        case mode, points, channels
        case applyToLuminosity = "apply_to_luminosity"
        case parametric
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CurveCodingKey.self)
        let names = Set(keys.allKeys.map(\.stringValue))
        guard names.isSuperset(of: ["mode", "points"]),
              names.isSubset(of: ["mode", "points", "channels", "apply_to_luminosity", "parametric"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid curve fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        master = .init(mode: try values.decode(ToneCurveMode.self, forKey: .mode), points: try values.decode([ToneCurvePoint].self, forKey: .points))
        channels = values.contains(.channels) ? try values.decode(ToneCurveChannels.self, forKey: .channels) : .init()
        applyToLuminosity = values.contains(.applyToLuminosity) ? try values.decode(Bool.self, forKey: .applyToLuminosity) : false
        parametric = values.contains(.parametric) ? try values.decode(ToneCurveParametric.self, forKey: .parametric) : .init()
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .points, in: values, debugDescription: "Invalid curve points") }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode); try values.encode(points, forKey: .points)
        if !channels.isDefault { try values.encode(channels, forKey: .channels) }
        if applyToLuminosity { try values.encode(applyToLuminosity, forKey: .applyToLuminosity) }
        if !parametric.isDefault { try values.encode(parametric, forKey: .parametric) }
    }
}

private struct CurveCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
