import Foundation

enum MacWorkspaceMode: String, CaseIterable {
    case editing, selection, preview
}

enum MacLibraryPresentation: Equatable {
    case hidden, pinned, drawer
}

struct MacWorkspaceLayout {
    static let compactThreshold: CGFloat = 1180
    static let libraryRange: ClosedRange<CGFloat> = 200...288
    static let inspectorRange: ClosedRange<CGFloat> = 280...360
    static let defaultLibraryWidth: CGFloat = 232
    static let defaultInspectorWidth: CGFloat = 304
    static let drawerWidth: CGFloat = 264

    private(set) var mode: MacWorkspaceMode = .editing
    private var modeBeforePreview: MacWorkspaceMode = .editing
    private var libraryPinned = true
    private var inspectorPinned = true
    private var drawerOpen = false
    private var drawerBeforePreview = false

    static func isCompact(_ width: CGFloat) -> Bool { width < compactThreshold }

    static func libraryWidth(_ width: CGFloat) -> CGFloat {
        min(libraryRange.upperBound, max(libraryRange.lowerBound, width))
    }

    static func inspectorWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        if isCompact(windowWidth) { return inspectorRange.lowerBound }
        return min(inspectorRange.upperBound, max(inspectorRange.lowerBound, width))
    }

    func libraryPresentation(width: CGFloat) -> MacLibraryPresentation {
        guard mode != .preview else { return .hidden }
        if Self.isCompact(width) { return drawerOpen ? .drawer : .hidden }
        return libraryPinned ? .pinned : .hidden
    }

    func showsInspector(hasPhoto: Bool) -> Bool { mode == .editing && inspectorPinned && hasPhoto }

    mutating func toggleLibrary(width: CGFloat) {
        guard mode != .preview else { return }
        if Self.isCompact(width) { drawerOpen.toggle() }
        else { libraryPinned.toggle() }
    }

    mutating func toggleInspector() { inspectorPinned.toggle() }
    mutating func showInspector() { inspectorPinned = true }

    mutating func setMode(_ next: MacWorkspaceMode) {
        guard mode != next else { return }
        if next == .preview {
            modeBeforePreview = mode
            drawerBeforePreview = drawerOpen
        }
        drawerOpen = mode == .preview && next == modeBeforePreview && drawerBeforePreview
        mode = next
    }

    mutating func windowResized(from oldWidth: CGFloat, to newWidth: CGFloat) {
        if Self.isCompact(oldWidth) != Self.isCompact(newWidth) {
            drawerOpen = false
            drawerBeforePreview = false
        }
    }

    mutating func photoOpened() {
        drawerOpen = false
        drawerBeforePreview = false
        if mode == .selection { setMode(.editing) }
    }

    @discardableResult mutating func dismissTransient() -> Bool {
        if drawerOpen { drawerOpen = false; return true }
        if mode == .preview { setMode(modeBeforePreview); return true }
        return false
    }
}

// Recipe artwork keeps its own stable size inside the scrolling inspector.
enum AdjustmentPanelLayout {}

// ----------------------------------------------------------------------------
//  大师配方卡片：与胶片一致的三列纵向网格，文字随宽度自然换行，不固定高度截断
// ----------------------------------------------------------------------------
extension AdjustmentPanelLayout {
    enum RecipeCard {
        static let columns = 3
        static let columnSpacing: CGFloat = 5
        static let rowSpacing: CGFloat = 7
        static let cardPadding: CGFloat = 4
        static let artworkSize: CGFloat = 46
        static let titleSize: CGFloat = 11
        static let subtitleSize: CGFloat = 10

        static func textWidth(inspectorWidth: CGFloat, sectionHorizontalPadding: CGFloat = 20) -> CGFloat {
            let gridWidth = inspectorWidth - sectionHorizontalPadding - columnSpacing * CGFloat(columns - 1)
            return max(0, gridWidth / CGFloat(columns) - cardPadding * 2)
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
