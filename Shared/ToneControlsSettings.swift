import Foundation

// UI 与选择性复制保留 [-100,100]；仅在 native/Agent 边界换算。
struct ToneControlsSettings: Codable, Equatable {
    var blackPoint = 0.0
    var whitePoint = 0.0
    var vibrance = 0.0
    var isIdentity: Bool { blackPoint == 0 && whitePoint == 0 && vibrance == 0 }
    var isValid: Bool { [blackPoint, whitePoint, vibrance].allSatisfy { $0.isFinite && (-100...100).contains($0) } }
}
