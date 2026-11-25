import CoreGraphics
import Foundation

@main
struct PhotoZoomTests {
    static func main() {
        let geometry = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                         viewport: CGSize(width: 400, height: 600), displayScale: 3, margin: 0)
        precondition(geometry.imageSize == CGSize(width: 800, height: 1600.0 / 3))
        precondition(geometry.fitScale == 0.5)
        precondition(geometry.doubleTapScale(from: 0.5) == 1)
        precondition(geometry.doubleTapScale(from: 1) == 0.5)
        precondition(geometry.doubleTapScale(from: 2) == 0.5)
        precondition(geometry.minimumScale == 0.5 && geometry.maximumScale == 4)
        precondition(geometry.previewLongEdge(scale: geometry.fitScale) == 1216)
        precondition(geometry.previewLongEdge(scale: 1) == 1280)
        let small = PhotoZoomGeometry(pixels: CGSize(width: 300, height: 200),
                                     viewport: CGSize(width: 400, height: 600), displayScale: 3, margin: 0)
        precondition(small.fitScale == 4 && small.minimumScale == 1)
        precondition(small.doubleTapScale(from: 4) == 1)
        precondition(small.doubleTapScale(from: 1) == 4)
        precondition(small.previewLongEdge(scale: small.fitScale) == 300)
        let landscape = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                         viewport: CGSize(width: 600, height: 200), displayScale: 2, margin: 0)
        precondition(landscape.fitScale == 0.25)
        precondition(landscape.doubleTapScale(from: 0.25) == 1)
        precondition(landscape.previewLongEdge(scale: landscape.fitScale) == 640)

        let raw6k = PhotoZoomGeometry(pixels: CGSize(width: 6000, height: 4000),
                                      viewport: CGSize(width: 400, height: 600), displayScale: 3, margin: 0)
        precondition(raw6k.fitScale == 0.2)
        precondition(raw6k.maximumScale == 4)
        precondition(raw6k.doubleTapScale(from: 0.2) == 1)
        precondition(raw6k.detailRegion(contentOffset: .zero, boundsSize: CGSize(width: 400, height: 600),
                                        zoomScale: raw6k.fitScale, baseLongEdge: 1280) == nil)
        let thresholdScale = (1280.0 / 6000.0) * 1.04
        precondition(raw6k.detailRegion(contentOffset: CGPoint(x: 100, y: 100), boundsSize: CGSize(width: 400, height: 600),
                                        zoomScale: thresholdScale, baseLongEdge: 1280) == nil)
        let detail = raw6k.detailRegion(contentOffset: CGPoint(x: 400, y: 300),
                                        boundsSize: CGSize(width: 400, height: 600),
                                        zoomScale: 1.0, baseLongEdge: 1280, maxOutputLongEdge: 2048)!
        precondition(abs(detail.visibleRect.minX - 0.2) < 0.0001 && abs(detail.visibleRect.width - 0.2) < 0.0001)
        precondition(detail.overscanRect.minX < detail.visibleRect.minX && detail.overscanRect.maxX > detail.visibleRect.maxX)
        precondition(detail.overscanRect.minX >= 0 && detail.overscanRect.maxX <= 1)
        print("PASS: fit, native pixels, display density, small images, landscape, double-tap toggle, ROI detail threshold")
    }
}
