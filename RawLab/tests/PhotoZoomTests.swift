import CoreGraphics
import Foundation

@main
struct PhotoZoomTests {
    static func main() {
        let geometry = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                         viewport: CGSize(width: 400, height: 600), displayScale: 3)
        precondition(geometry.imageSize == CGSize(width: 800, height: 1600.0 / 3))
        precondition(geometry.fitScale == 0.5)
        precondition(geometry.doubleTapScale(from: 0.5) == 1)
        precondition(geometry.doubleTapScale(from: 1) == 0.5)
        precondition(geometry.doubleTapScale(from: 2) == 0.5)
        precondition(geometry.minimumScale == 0.5 && geometry.maximumScale == 4)
        let small = PhotoZoomGeometry(pixels: CGSize(width: 300, height: 200),
                                     viewport: CGSize(width: 400, height: 600), displayScale: 3)
        precondition(small.fitScale == 4 && small.minimumScale == 1)
        precondition(small.doubleTapScale(from: 4) == 1)
        precondition(small.doubleTapScale(from: 1) == 4)
        let landscape = PhotoZoomGeometry(pixels: CGSize(width: 2400, height: 1600),
                                         viewport: CGSize(width: 600, height: 200), displayScale: 2)
        precondition(landscape.fitScale == 0.25)
        precondition(landscape.doubleTapScale(from: 0.25) == 1)
        print("PASS: fit, native pixels, display density, small images, landscape, double-tap toggle")
    }
}
