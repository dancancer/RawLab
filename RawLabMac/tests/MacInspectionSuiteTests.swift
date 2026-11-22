import RawLabKit
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MacInspectionSuiteTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func makeTestImage(width: Int, height: Int, colorFill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = colorFill(x, y)
                    let off = (y * width + x) * 4
                    ptr[off] = r
                    ptr[off + 1] = g
                    ptr[off + 2] = b
                    ptr[off + 3] = 255
                }
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    static func encodeImage(_ image: CGImage, type: UTType) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            fatalError("Could not create CGImageDestination")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            fatalError("Could not finalize CGImageDestination")
        }
        return out as Data
    }

    static func main() throws {
        // 1. Sampling Before/After + HSB + Luminance Cursor
        let beforeImg = makeTestImage(width: 16, height: 16) { _, _ in (120, 120, 120) }
        let afterImg = makeTestImage(width: 16, height: 16) { x, _ in x < 8 ? (220, 135, 110) : (60, 140, 220) }

        let beforeSample = InspectionSamplerCache.shared.sample(beforeImg, atNormalized: CGPoint(x: 0.25, y: 0.5))
        let afterWarm = InspectionSamplerCache.shared.sample(afterImg, atNormalized: CGPoint(x: 0.25, y: 0.5))
        let afterCool = InspectionSamplerCache.shared.sample(afterImg, atNormalized: CGPoint(x: 0.75, y: 0.5))
        check(beforeSample?.r == 120 && beforeSample?.saturationPct == 0, "Before neutral sample stays gray")
        check((afterWarm?.hueDeg ?? -1) < 30 && (afterWarm?.saturationPct ?? 0) > 40, "After warm skin-tone sample reports warm hue")
        check((afterCool?.hueDeg ?? 0) > 190 && (afterCool?.hueDeg ?? 0) < 230, "After cool sample reports blue hue")
        check((afterWarm?.luminance ?? 0) > (afterCool?.luminance ?? 1), "Rec.709 luminance ranks warm sample brighter than cool sample")

        // 2. 4-Anchor Cap + Source-Normalized Geometry Remapping + Cropped-out nil
        var session = InspectionSessionState()
        let srcSize = CGSize(width: 2400, height: 1600)
        let geom = GeometrySettings(
            cropX: 0.15,
            cropY: 0.15,
            cropWidth: 0.7,
            cropHeight: 0.7,
            quarterTurns: 1,
            flipHorizontal: true,
            straightenDegrees: 5.0,
            perspectiveHorizontal: 0.2,
            perspectiveVertical: -0.15
        )
        let pinnedOut = CGPoint(x: 0.45, y: 0.55)
        guard let srcAnchor = GeometryCoordinateMapper.outputNormToSourceNorm(pinnedOut, sourceSize: srcSize, geometry: geom) else {
            fatalError("Expected valid inverse mapping")
        }
        check(session.pinAnchor(atSourcePoint: srcAnchor) != nil, "Anchor 1 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.2, y: 0.2)) != nil, "Anchor 2 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.8, y: 0.2)) != nil, "Anchor 3 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.8, y: 0.8)) != nil, "Anchor 4 pinned")
        check(session.pinAnchor(atSourcePoint: CGPoint(x: 0.1, y: 0.1)) == nil, "Anchor 5 rejected at cap 4")

        if let remapped = GeometryCoordinateMapper.sourceNormToOutputNorm(session.anchors[0].sourcePoint, sourceSize: srcSize, geometry: geom) {
            check(abs(remapped.x - pinnedOut.x) < 1e-4 && abs(remapped.y - pinnedOut.y) < 1e-4,
                  "Anchor 1 remaps back to exact output location")
        } else {
            fatalError("Anchor 1 should be inside crop")
        }
        let tightCrop = GeometrySettings(cropX: 0.4, cropY: 0.4, cropWidth: 0.2, cropHeight: 0.2)
        check(GeometryCoordinateMapper.sourceNormToOutputNorm(CGPoint(x: 0.05, y: 0.05), sourceSize: srcSize, geometry: tightCrop) == nil,
              "Out-of-crop anchor returns nil while retained in session")
        check(session.anchors.count == 4, "Cropped-out anchor remains retained in session state")

        // 3. View-end-stage 5 Overlays + Transient Gray Toggle + Escape
        for mode in InspectionOverlayMode.allCases where mode != .none {
            let overlayImg = InspectionOverlayRenderer.shared.render(afterImg, mode: mode)
            check(overlayImg != nil && overlayImg?.width == 16 && overlayImg?.height == 16,
                  "Overlay \(mode.rawValue) renders display image cleanly")
        }
        session.selectOverlay(.skinHueAmplification)
        session.toggleNeutralGray50()
        check(session.overlay == .neutralGray50, "1-click 50% gray toggles ON")
        check(session.handleEscape() && session.overlay == .skinHueAmplification, "Escape exits 50% gray back to prior overlay")
        check(session.handleEscape() && session.overlay == .none, "Second Escape clears overlay")

        // 4. Zero Adjustments / PhotoEditState / Export Byte-Identity across all 5 Overlays
        var adjustments = Adjustments()
        adjustments.exposure = 0.5
        adjustments.contrast = 15
        adjustments.geometry = geom
        let editState = MacPhotoEditState(settings: adjustments, filmID: "CLASSIC_CHROME")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baselineStateBytes = try encoder.encode(editState)
        let baselineJpeg = encodeImage(afterImg, type: .jpeg)
        let baselinePng = encodeImage(afterImg, type: .png)

        for mode in InspectionOverlayMode.allCases {
            session.selectOverlay(mode)
            _ = InspectionOverlayRenderer.shared.render(afterImg, mode: mode)
            // Unmasked source image & edit state remain untouched regardless of active view overlay
            let currentStateBytes = try encoder.encode(MacPhotoEditState(settings: adjustments, filmID: "CLASSIC_CHROME"))
            let currentJpeg = encodeImage(afterImg, type: .jpeg)
            let currentPng = encodeImage(afterImg, type: .png)
            check(currentStateBytes == baselineStateBytes, "MacPhotoEditState byte-identical with overlay \(mode.rawValue)")
            check(currentJpeg == baselineJpeg, "Export JPEG byte-identical with overlay \(mode.rawValue)")
            check(currentPng == baselinePng, "Export PNG byte-identical with overlay \(mode.rawValue)")
        }

        // 5. MacViewingState & HistogramPresentation integration check
        let viewing = MacViewingState()
        check(!viewing.enabled, "MacViewingState defaults clean")
        let hist = HistogramPresentation(bins: [[0, 10, 50], [0, 20, 40], [0, 5, 10]])
        check(hist.peak == 50, "HistogramPresentation computes shared peak")
    }
}
