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
    private var preferredHeight: CGFloat = 320

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

// ----------------------------------------------------------------------------
//  大师配方卡片：名称最多两行，说明最多三行（德、法、西文的说明在 112 pt 宽时要三行）
//  卡片铺满默认高度面板的内容区，图下留出完整的文字高度，文字不再被截成省略号
// ----------------------------------------------------------------------------
extension AdjustmentPanelLayout {
    enum RecipeCard {
        static let dockHeight: CGFloat = 252 - chrome
        static let width: CGFloat = 112
        static let titleHeight: CGFloat = 28
        static let subtitleSize: CGFloat = 10
        static let subtitleLines = 3
        static let subtitleHeight: CGFloat = 39

        // 图片上下留白 5 + 3，名称与说明间隔 2
        static func textHeight(subtitle: Bool) -> CGFloat {
            8 + titleHeight + (subtitle ? 2 + subtitleHeight : 0)
        }
    }
}

// ----------------------------------------------------------------------------
//  工具按钮下的名称：宽 72 pt，11 pt 字，只在空格或连字符处换行
//  没有断点的名称（日文、中文、德文复合词）只占一行，放不下就缩小字号，
//  不会出现"ホワイトバラ / ンス"这种从词中间断开的换行
// ----------------------------------------------------------------------------
extension AdjustmentPanelLayout {
    enum ToolCaption {
        static let width: CGFloat = 72
        static let size: CGFloat = 11

        static func breaksBetweenWords(_ title: String) -> Bool { title.contains(" ") || title.contains("-") }
        static func lineLimit(for title: String) -> Int { breaksBetweenWords(title) ? 2 : 1 }
        static func minimumScale(for title: String) -> CGFloat { breaksBetweenWords(title) ? 1 : 0.75 }
    }
}
