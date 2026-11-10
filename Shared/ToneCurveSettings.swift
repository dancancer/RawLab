import Foundation

enum ToneCurveMode: String, Codable { case legacy, custom }

struct ToneCurvePoint: Equatable, Hashable, Codable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self); y = try values.decode(Double.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Curve point requires x and y")
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x); try values.encode(y)
    }
}

struct ToneCurveShape: Equatable, Hashable, Codable {
    static let hdrExposureRange = -8.0...8.0
    var mode: ToneCurveMode = .legacy
    var points: [ToneCurvePoint] = []
    static let identity = Self(mode: .custom, points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])
    var isDefault: Bool { mode == .legacy && points.isEmpty }
    var isIdentity: Bool { mode == .legacy || points.allSatisfy { $0.x == $0.y } }
    var isValid: Bool {
        if mode == .legacy { return points.isEmpty }
        guard (2...33).contains(points.count), points.first == ToneCurvePoint(x: 0, y: 0),
              points.last == ToneCurvePoint(x: 1, y: 1) else { return false }
        for (index, point) in points.enumerated() {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
            if index > 0 && (point.x <= points[index - 1].x || point.y < points[index - 1].y) { return false }
        }
        return true
    }
    var progress: Double { points.map { abs($0.y - $0.x) }.max() ?? 0 }
    func scaled(by strength: Double) -> Self {
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
    func isInterior(_ index: Int) -> Bool { mode == .custom && index > 0 && index + 1 < points.count }
    func inserting(x: Double, y: Double) -> Self {
        guard mode == .custom, isValid, points.count < 33, x.isFinite, y.isFinite, x > 0, x < 1,
              !points.contains(where: { $0.x == x }), let next = points.firstIndex(where: { $0.x > x }) else { return self }
        var result = self
        result.points.insert(.init(x: x, y: min(points[next].y, max(points[next - 1].y, y))), at: next)
        return result
    }
    func moving(index: Int, x: Double, y: Double) -> Self {
        guard isValid, isInterior(index), x.isFinite, y.isFinite else { return self }
        let previous = points[index - 1], next = points[index + 1]
        let low = previous.x.nextUp, high = next.x.nextDown
        guard low <= high else { return self }
        var result = self
        result.points[index] = .init(x: min(high, max(low, x)), y: min(next.y, max(previous.y, y)))
        return result
    }
    func removing(index: Int) -> Self {
        guard isInterior(index) else { return self }
        var result = self; result.points.remove(at: index); return result
    }
    init(mode: ToneCurveMode = .legacy, points: [ToneCurvePoint] = []) { self.mode = mode; self.points = points }
    enum CodingKeys: String, CodingKey { case mode, points }
    init(from decoder: Decoder) throws {
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

enum ToneCurveChannel: String, CaseIterable, Identifiable {
    case rgb, red, green, blue
    var id: String { rawValue }
    var shortLabel: String { self == .rgb ? "RGB" : String(rawValue.prefix(1)).uppercased() }
}

struct ToneCurveChannels: Equatable, Hashable, Codable {
    var red = ToneCurveShape()
    var green = ToneCurveShape()
    var blue = ToneCurveShape()
    var isDefault: Bool { red.isDefault && green.isDefault && blue.isDefault }
    var isIdentity: Bool { red.isIdentity && green.isIdentity && blue.isIdentity }
    var isValid: Bool { red.isValid && green.isValid && blue.isValid }
    var progress: Double { max(red.progress, green.progress, blue.progress) }
    func scaled(by strength: Double) -> Self {
        Self(red: red.scaled(by: strength), green: green.scaled(by: strength), blue: blue.scaled(by: strength))
    }
    init(red: ToneCurveShape = .init(), green: ToneCurveShape = .init(), blue: ToneCurveShape = .init()) {
        self.red = red; self.green = green; self.blue = blue
    }
    enum CodingKeys: String, CodingKey { case red, green, blue }
    init(from decoder: Decoder) throws {
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

struct ToneCurveSettings: Equatable, Hashable, Codable {
    static let hdrExposureRange = ToneCurveShape.hdrExposureRange
    var master: ToneCurveShape
    var channels: ToneCurveChannels
    var mode: ToneCurveMode { get { master.mode } set { master.mode = newValue } }
    var points: [ToneCurvePoint] { get { master.points } set { master.points = newValue } }
    static let identity = Self(mode: .custom, points: ToneCurveShape.identity.points)
    var isDefault: Bool { master.isDefault && channels.isDefault }
    var isIdentity: Bool { master.isIdentity && channels.isIdentity }
    var isValid: Bool { master.isValid && channels.isValid }
    var progress: Double { max(master.progress, channels.progress) }
    var hasChannelCurves: Bool { !channels.isDefault }
    var labeledPoints: [(channel: ToneCurveChannel, point: ToneCurvePoint)] {
        ToneCurveChannel.allCases.flatMap { channel in shape(channel).points.map { (channel, $0) } }
    }
    init(mode: ToneCurveMode = .legacy, points: [ToneCurvePoint] = [], channels: ToneCurveChannels = .init()) {
        master = .init(mode: mode, points: points); self.channels = channels
    }
    func shape(_ channel: ToneCurveChannel) -> ToneCurveShape {
        switch channel { case .rgb: return master; case .red: return channels.red; case .green: return channels.green; case .blue: return channels.blue }
    }
    func replacing(_ channel: ToneCurveChannel, with shape: ToneCurveShape) -> Self {
        var result = self
        switch channel { case .rgb: result.master = shape; case .red: result.channels.red = shape; case .green: result.channels.green = shape; case .blue: result.channels.blue = shape }
        return result
    }
    func scaled(by strength: Double) -> Self {
        var result = self; result.master = master.scaled(by: strength); result.channels = channels.scaled(by: strength); return result
    }
    func isInterior(_ index: Int) -> Bool { master.isInterior(index) }
    func inserting(x: Double, y: Double) -> Self { replacing(.rgb, with: master.inserting(x: x, y: y)) }
    func moving(index: Int, x: Double, y: Double) -> Self { replacing(.rgb, with: master.moving(index: index, x: x, y: y)) }
    func removing(index: Int) -> Self { replacing(.rgb, with: master.removing(index: index)) }
    enum CodingKeys: String, CodingKey { case mode, points, channels }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CurveCodingKey.self)
        let names = Set(keys.allKeys.map(\.stringValue))
        guard names.isSuperset(of: ["mode", "points"]), names.isSubset(of: ["mode", "points", "channels"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid curve fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        master = .init(mode: try values.decode(ToneCurveMode.self, forKey: .mode), points: try values.decode([ToneCurvePoint].self, forKey: .points))
        channels = values.contains(.channels) ? try values.decode(ToneCurveChannels.self, forKey: .channels) : .init()
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .points, in: values, debugDescription: "Invalid curve points") }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode); try values.encode(points, forKey: .points)
        if !channels.isDefault { try values.encode(channels, forKey: .channels) }
    }
}

private struct CurveCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
