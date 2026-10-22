import CoreGraphics
import Foundation

@main
struct PhotoViewingTests {
    static func main() {
        // 留白关闭不能裁照片；默认留白必须真正减去可用 fit 区，而非只画背景。
        let geometry = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                         viewport: CGSize(width: 400, height: 600), displayScale: 3)
        guard abs(geometry.fitScale - 0.46) < 0.000001 else {
            print("FAIL: default photo margin must leave 16pt on each horizontal side; fit=\(geometry.fitScale), expected=0.46")
            exit(1)
        }
        print("PASS: default margin fits the complete photograph inside the inset viewport")
        let noMargin = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                        viewport: CGSize(width: 400, height: 600), displayScale: 3, margin: 0)
        precondition(abs(noMargin.fitScale - 0.5) < 0.000001)
        let viewport = PhotoViewport(relativeScale: 2, focus: CGPoint(x: 0.75, y: 0.4))
        let wide = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                    viewport: CGSize(width: 600, height: 400), displayScale: 3, margin: 0)
        precondition(abs(viewport.scale(in: noMargin) - 1) < 0.000001)
        precondition(abs(viewport.scale(in: wide) - 1.5) < 0.000001)
        precondition(viewport.focus == CGPoint(x: 0.75, y: 0.4))
        let panes = PhotoComparisonLayout(size: CGSize(width: 800, height: 400), enabled: true)
        precondition(panes.horizontal && panes.paneSize == CGSize(width: 400, height: 400))
        let tall = PhotoComparisonLayout(size: CGSize(width: 300, height: 600), enabled: true)
        precondition(!tall.horizontal && tall.paneSize == CGSize(width: 300, height: 300))
        var state = PhotoViewingState()
        precondition(!state.enabled && state.preferredMode == .sideBySide && state.split == 0.5 && state.photoMargin)
        state.selectMode(.wipe)
        state.setSplit(1.3)
        precondition(state.enabled && state.split == 1)
        state.toggleComparison()
        precondition(!state.enabled && state.preferredMode == .wipe)
        state.beginHolding(isDraft: false)
        precondition(state.holdingBefore)
        state.endTemporaryViewing()
        precondition(!state.holdingBefore)
        state.beginHolding(isDraft: true)
        precondition(!state.holdingBefore)
        state.toggleComparison()
        state.beginHolding(isDraft: false)
        precondition(!state.holdingBefore)
        state.sourceChanged()
        precondition(!state.enabled && state.preferredMode == .wipe && !state.previewOnly && !state.holdingBefore)
        state.togglePreview(isDraft: true)
        precondition(!state.previewOnly)
        state.togglePreview(isDraft: false)
        precondition(state.previewOnly)
        state.endTemporaryViewing()
        precondition(state.previewOnly, "losing a hold does not discard pure-preview navigation")
        print("PASS: shared relative fit/focus, pane projection, mode preference, split clamp, transient and draft guards")
    }
}
