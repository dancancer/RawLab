import Foundation

// 界面和保存使用 [-100,100]，仅在原生渲染和 Agent 边界换算。
public struct AtmosphereSettings: Codable, Equatable, Hashable {
    public var clarity = 0.0
    public var dehaze = 0.0
    public init(clarity: Double = 0.0, dehaze: Double = 0.0) {
        self.clarity = clarity
        self.dehaze = dehaze
    }
    public var isIdentity: Bool { clarity == 0 && dehaze == 0 }
    public var isValid: Bool {
        zip([clarity, dehaze], [
            AdjustmentFieldSpec.Fields.effectsClarity.macosModel.closedRange!,
            AdjustmentFieldSpec.Fields.effectsDehaze.macosModel.closedRange!,
        ]).allSatisfy { $0.0.isFinite && $0.1.contains($0.0) }
    }
    public func scaled(by strength: Double) -> Self {
        Self(clarity: min(100, max(-100, clarity * strength)),
             dehaze: min(100, max(-100, dehaze * strength)))
    }
}
