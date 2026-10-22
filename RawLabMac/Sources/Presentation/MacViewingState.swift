import Foundation

// Workspace-only state; never part of a photo edit or recipe.
enum MacCompareMode: Equatable { case sideBySide, wipe }
struct MacViewingState: Equatable {
    var enabled = false
    var preferredMode = MacCompareMode.sideBySide
    var split = 0.5
    var holdingBefore = false
    var margins = true
    mutating func toggle() { enabled.toggle(); holdingBefore = false }
    mutating func select(_ mode: MacCompareMode) { preferredMode = mode; enabled = true; holdingBefore = false }
    mutating func close() { enabled = false; holdingBefore = false }
    mutating func sourceChanged() { enabled = false; holdingBefore = false; split = 0.5 }
    mutating func hold(_ value: Bool, allowed: Bool) { holdingBefore = value && allowed && !enabled }
    mutating func setSplit(_ value: Double) { if value.isFinite { split = min(1, max(0, value)) } }
    mutating func moveSplit(_ delta: Double) { setSplit(split + delta) }
    static func horizontalPanes(in size: CGSize) -> Bool { size.width >= size.height }
}
