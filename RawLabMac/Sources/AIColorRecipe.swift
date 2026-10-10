import Foundation

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct AIToneRegions: Codable, Equatable {
    var shadowStart: Double
    var shadowEnd: Double
    var highlightStart: Double
    var highlightEnd: Double
    static let standard = Self(shadowStart: 0.2, shadowEnd: 0.6, highlightStart: 0.4, highlightEnd: 0.8)
    var parameters: [Float] { [shadowStart, shadowEnd, highlightStart, highlightEnd].map(Float.init) }

    func validated() throws -> Self {
        let values = [shadowStart, shadowEnd, highlightStart, highlightEnd]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              shadowEnd-shadowStart >= 0.05-1e-7, highlightEnd-highlightStart >= 0.05-1e-7,
              shadowStart <= highlightStart, shadowEnd <= highlightEnd else {
            throw AIError.message("明暗分区边界无效：过渡宽度至少 0.05，暗部边界不能越过亮部边界。")
        }
        return self
    }
}

struct AIColorRecipe: Codable, Equatable {
    struct HueBand: Codable, Equatable {
        var hue: Float
        var chroma: Float
        var lightness: Float
    }
    struct Tint: Codable, Equatable { var a: Float; var b: Float }
    var version: Int
    var name: String
    var summary: String
    var tone: [Float]
    var chroma: Float
    var hueBands: [HueBand]
    var toning: [Tint]

    static func identity(name: String, summary: String) -> Self {
        Self(version: 1, name: name, summary: summary, tone: (0...8).map { Float($0)/8 }, chroma: 1,
             hueBands: Array(repeating: HueBand(hue: 0, chroma: 1, lightness: 0), count: 8),
             toning: Array(repeating: Tint(a: 0, b: 0), count: 3))
    }

    var parameters: [Float] {
        tone + [chroma] + hueBands.flatMap { [$0.hue, $0.chroma, $0.lightness] } + toning.flatMap { [$0.a, $0.b] }
    }

    func validated() throws -> Self {
        guard version == 1, tone.count == 9, hueBands.count == 8, toning.count == 3 else {
            throw AIError.message("AI 返回的配方版本或参数数量不兼容，请重新生成。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              name.utf8.count <= 512, name.rangeOfCharacter(from: .controlCharacters) == nil,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 600 else {
            throw AIError.message("AI 返回的外观名称或说明无效，请重新生成。")
        }
        guard parameters.allSatisfy(\.isFinite), tone.allSatisfy({ (0...1).contains($0) }),
              tone[0] <= 0.1, tone[8] >= 0.9, (0...2).contains(chroma),
              zip(tone, tone.dropFirst()).allSatisfy({ (0.05...4).contains(($0.1-$0.0)*8) }),
              hueBands.allSatisfy({ (-30...30).contains($0.hue) && (0...2).contains($0.chroma) && (-0.08...0.08).contains($0.lightness) }),
              toning.allSatisfy({ (-0.03...0.03).contains($0.a) && (-0.03...0.03).contains($0.b) }) else {
            throw AIError.message("AI 返回的颜色配方超出允许范围，请重新生成。")
        }
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw AIError.message("AI 配方过大，已拒绝读取。") }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
                guard let object = value as? [String: Any], Set(object.keys) == keys else {
                    throw AIError.message("AI 配方包含缺失或未知字段，请重新生成。")
                }
                return object
            }
            let root = try object(value, keys: ["version", "name", "summary", "tone", "chroma", "hueBands", "toning"])
            guard let bands = root["hueBands"] as? [Any], let tints = root["toning"] as? [Any] else {
                throw AIError.message("AI 配方结构无效，请重新生成。")
            }
            for band in bands { _ = try object(band, keys: ["hue", "chroma", "lightness"]) }
            for tint in tints { _ = try object(tint, keys: ["a", "b"]) }
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as AIError { throw error }
        catch { throw AIError.message("AI 未返回有效的 JSON 配方，请重新生成。") }
    }
}
