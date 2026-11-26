import Foundation

// 界面和保存使用 [-100,100]，仅在原生渲染和 Agent 边界换算。
public struct AtmosphereSettings: Codable, Equatable, Hashable {
    public var clarity = 0.0
    public var dehaze = 0.0
    public var texture = 0.0
    public init(clarity: Double = 0.0, dehaze: Double = 0.0, texture: Double = 0.0) {
        self.clarity = clarity == 0 ? 0 : clarity
        self.dehaze = dehaze == 0 ? 0 : dehaze
        self.texture = texture == 0 ? 0 : texture
    }
    public var isIdentity: Bool { clarity == 0 && dehaze == 0 && texture == 0 }
    public var isValid: Bool {
        zip([clarity, dehaze, texture], [
            AdjustmentFieldSpec.Fields.effectsClarity.macosModel.closedRange!,
            AdjustmentFieldSpec.Fields.effectsDehaze.macosModel.closedRange!,
            AdjustmentFieldSpec.Fields.effectsTexture.macosModel.closedRange!,
        ]).allSatisfy { $0.0.isFinite && $0.1.contains($0.0) }
    }
    public func scaled(by strength: Double) -> Self {
        Self(clarity: min(100, max(-100, clarity * strength)),
             dehaze: min(100, max(-100, dehaze * strength)),
             texture: texture)
    }

    private enum CodingKeys: String, CodingKey { case clarity, dehaze, texture }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0.0
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0.0
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0.0
        if clarity == 0 { clarity = 0 }
        if dehaze == 0 { dehaze = 0 }
        if texture == 0 { texture = 0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clarity, forKey: .clarity)
        try c.encode(dehaze, forKey: .dehaze)
        if texture != 0 { try c.encode(texture, forKey: .texture) }
    }
}
