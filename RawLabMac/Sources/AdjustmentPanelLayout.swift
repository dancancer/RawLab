import Foundation

struct AdjustmentPanelLayout {
    // ------------------------------------------------------------------------
    //  各工具面板共用的外框：拖动条 13 + 标题行 31 + 工具行 72
    // ------------------------------------------------------------------------
    static let chrome: CGFloat = 116

    // ------------------------------------------------------------------------
    //  效果面板按可见行数要高度：组标题 28 + 每行 32 + 底部提示 22
    //  提示随强度出现或消失，始终留出它的位置，拖动滑杆时面板不跳动
    // ------------------------------------------------------------------------
    static func effectsHeight(rows: Int) -> CGFloat {
        max(252, chrome + 28 + 32 * CGFloat(rows) + 22)
    }

    var collapsed = false
    private var preferredHeight: CGFloat = 252

    func height(available: CGFloat) -> CGFloat {
        collapsed ? 0 : min(preferredHeight, Self.maximum(available))
    }

    mutating func selectHeight(_ height: CGFloat) {
        preferredHeight = min(380, max(220, height))
    }

    mutating func resize(to height: CGFloat, available: CGFloat) {
        preferredHeight = min(max(height, 220), Self.maximum(available))
    }

    private static func maximum(_ available: CGFloat) -> CGFloat {
        max(220, min(380, available * 0.5))
    }
}
