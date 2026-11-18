import Foundation

// UI 与选择性复制保留 [-100,100]；仅在 native/Agent 边界换算。
public struct ToneControlsSettings: Codable, Equatable, Hashable {
    public var blackPoint = 0.0
    public var whitePoint = 0.0
    public var vibrance = 0.0
    public init(blackPoint: Double = 0.0, whitePoint: Double = 0.0, vibrance: Double = 0.0) {
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.vibrance = vibrance
    }
    public var isIdentity: Bool { blackPoint == 0 && whitePoint == 0 && vibrance == 0 }
    public var isValid: Bool { [blackPoint, whitePoint, vibrance].allSatisfy { $0.isFinite && (-100...100).contains($0) } }
    public func scaled(by strength: Double) -> Self {
        Self(blackPoint: min(100, max(-100, blackPoint * strength)),
             whitePoint: min(100, max(-100, whitePoint * strength)),
             vibrance: min(100, max(-100, vibrance * strength)))
    }
}
