import Foundation

// 界面和保存使用 [-100,100]，仅在原生渲染和 Agent 边界换算。
struct AtmosphereSettings: Codable, Equatable, Hashable {
    var clarity = 0.0
    var dehaze = 0.0
    var isIdentity: Bool { clarity == 0 && dehaze == 0 }
    var isValid: Bool { [clarity, dehaze].allSatisfy { $0.isFinite && (-100...100).contains($0) } }
    func scaled(by strength: Double) -> Self {
        Self(clarity: min(100, max(-100, clarity * strength)),
             dehaze: min(100, max(-100, dehaze * strength)))
    }
}
