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

struct ToneCurveSettings: Equatable, Hashable, Codable {
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

private struct CurveCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
