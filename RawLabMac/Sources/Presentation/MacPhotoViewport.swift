import Foundation
import AppKit

struct PhotoViewport: Equatable {
    private(set) var magnification: CGFloat = 1
    private(set) var pixelMode = false
    var focus = CGPoint(x: 0.5, y: 0.5)
    mutating func fit() { self = PhotoViewport() }
    mutating func actualPixels() { magnification = 1; pixelMode = true }
    mutating func toggleActualPixels() {
        if pixelMode || magnification != 1 { fit() } else { actualPixels() }
    }
    mutating func zoom(by multiplier: CGFloat) {
        magnification = min(16, max(0.1, magnification * multiplier))
    }
    func factor(fit: CGFloat, displayScale: CGFloat, sourceWidth: CGFloat = 1, renderedWidth: CGFloat = 1) -> CGFloat {
        let pixelFactor = sourceWidth / max(1, renderedWidth) / max(1, displayScale)
        return (pixelMode ? pixelFactor : fit) * magnification
    }
    func pan(displayed: CGSize) -> CGSize {
        CGSize(width: (0.5 - focus.x) * displayed.width, height: (0.5 - focus.y) * displayed.height)
    }
    mutating func moveFocus(from origin: CGPoint, translation: CGSize, displayed: CGSize) {
        focus = CGPoint(x: min(1, max(0, origin.x - translation.width / max(1, displayed.width))),
                        y: min(1, max(0, origin.y - translation.height / max(1, displayed.height))))
    }
    func previewLongEdge(canvas: CGSize, displayScale: CGFloat, source: CGSize, margin: CGFloat = 12) -> Int {
        let width = max(1, canvas.width - 2 * margin), height = max(1, canvas.height - 2 * margin)
        let sourceEdge = max(source.width, source.height)
        guard source.width > 0, source.height > 0, sourceEdge.isFinite else { return 2000 }
        let fit = min(width / source.width, height / source.height)
        let pixels = (pixelMode ? max(width, height) : fit * sourceEdge * magnification) * max(1, displayScale)
        guard pixels.isFinite else { return 2000 }
        // 按小档位取整，窗口微调不会不断产生新的渲染尺寸。
        return Int(min(65535, sourceEdge, max(1, ceil(pixels / 64) * 64)))
    }
}
