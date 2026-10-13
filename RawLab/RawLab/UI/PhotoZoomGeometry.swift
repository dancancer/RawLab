import Foundation

struct PhotoZoomGeometry {
    let imageSize: CGSize
    let fitScale: CGFloat
    let pixelEdge: CGFloat

    init(pixels: CGSize, viewport: CGSize, displayScale: CGFloat) {
        imageSize = CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
        fitScale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        pixelEdge = max(pixels.width, pixels.height)
    }

    func previewLongEdge(scale: CGFloat, limit: Int = 1280) -> Int {
        guard scale.isFinite, scale > 0, pixelEdge.isFinite, pixelEdge > 0 else { return limit }
        return min(limit, Int(pixelEdge), max(64, Int(ceil(pixelEdge * scale / 64)) * 64))
    }

    var minimumScale: CGFloat { min(fitScale, 1) }
    var maximumScale: CGFloat { max(fitScale * 8, 1) }

    func isFit(_ scale: CGFloat) -> Bool {
        abs(scale - fitScale) < fitScale * 0.001
    }

    func doubleTapScale(from scale: CGFloat) -> CGFloat {
        isFit(scale) ? 1 : fitScale
    }
}
