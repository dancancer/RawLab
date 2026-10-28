import Foundation

// UI 与选择性复制保留 [-100,100]；仅在 native/Agent 边界换算。
struct ToneControlsSettings: Codable, Equatable, Hashable {
    var blackPoint = 0.0
    var whitePoint = 0.0
    var vibrance = 0.0
    var isIdentity: Bool { blackPoint == 0 && whitePoint == 0 && vibrance == 0 }
    var isValid: Bool { [blackPoint, whitePoint, vibrance].allSatisfy { $0.isFinite && (-100...100).contains($0) } }
    func scaled(by strength: Double) -> Self {
        Self(blackPoint: min(100, max(-100, blackPoint * strength)),
             whitePoint: min(100, max(-100, whitePoint * strength)),
             vibrance: min(100, max(-100, vibrance * strength)))
    }
}
