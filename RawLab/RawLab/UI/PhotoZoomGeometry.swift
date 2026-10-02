import Foundation

struct PhotoZoomGeometry {
    let imageSize: CGSize
    let fitScale: CGFloat

    init(pixels: CGSize, viewport: CGSize, displayScale: CGFloat) {
        imageSize = CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
        fitScale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
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
