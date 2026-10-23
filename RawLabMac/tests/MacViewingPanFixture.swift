import AppKit
import SwiftUI

// Visible native-input fixture uses the production PhotoCanvas and its real viewport binding.
// The harness interrupts the first real pan via key-window resignation, then CUA drags again.
final class MacViewingPanFixtureState: ObservableObject {
    @Published var viewport = PhotoViewport()
    let frame: RenderedImage
    init() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 960 * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<8 { for x in 0..<12 {
            context.setFillColor(CGColor(red: CGFloat(x) / 12, green: CGFloat(y) / 8, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: x * 80, y: y * 80, width: 80, height: 80))
        } }
        let image = context.makeImage()!
        frame = RenderedImage(image: image, isFullResolution: true, clipping: image, histogram: [], shadows: 0, highlights: 0,
            baselineEV: 0, metadataEV: 0, asShotWhiteBalance: nil, supportsRawNoiseReduction: false, nativeWidth: 960, nativeHeight: 640)
    }
}
struct MacViewingPanFixture: View {
    @ObservedObject var state: MacViewingPanFixtureState
    var body: some View {
        PhotoCanvas(frame: state.frame, viewport: $state.viewport, sourceWidth: 960, clipping: false, sourceHeight: 640)
            .overlay(alignment: .topLeading) {
                Text(String(format: "Focus %.6f, %.6f", state.viewport.focus.x, state.viewport.focus.y))
                    .padding(8).background(.black.opacity(0.7)).allowsHitTesting(false)
            }
    }
}
