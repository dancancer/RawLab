import CoreGraphics
import Foundation
import XCTest
@testable import RawLabKit

final class InspectionSuiteTests: XCTestCase {
    private func makeRGBA8CGImage(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = fill(x, y)
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
        return try XCTUnwrap(CGImage(
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
        ))
    }

    func testColorSampleRGBToHSBAndRec709Luminance() {
        let red = InspectionColorSample(r: 255, g: 0, b: 0)
        XCTAssertEqual(red.hueDeg, 0, accuracy: 0.01)
        XCTAssertEqual(red.saturationPct, 100, accuracy: 0.01)
        XCTAssertEqual(red.brightnessPct, 100, accuracy: 0.01)
        XCTAssertEqual(red.luminance, 0.2126, accuracy: 1e-4)

        let green = InspectionColorSample(r: 0, g: 255, b: 0)
        XCTAssertEqual(green.hueDeg, 120, accuracy: 0.01)
        XCTAssertEqual(green.luminance, 0.7152, accuracy: 1e-4)

        let blue = InspectionColorSample(r: 0, g: 0, b: 255)
        XCTAssertEqual(blue.hueDeg, 240, accuracy: 0.01)
        XCTAssertEqual(blue.luminance, 0.0722, accuracy: 1e-4)

        let cyan = InspectionColorSample(r: 0, g: 255, b: 255)
        XCTAssertEqual(cyan.hueDeg, 180, accuracy: 0.01)

        let magenta = InspectionColorSample(r: 255, g: 0, b: 255)
        XCTAssertEqual(magenta.hueDeg, 300, accuracy: 0.01)

        let gray = InspectionColorSample(r: 128, g: 128, b: 128)
        XCTAssertEqual(gray.hueDeg, 0, accuracy: 0.01)
        XCTAssertEqual(gray.saturationPct, 0, accuracy: 0.01)
        XCTAssertEqual(gray.brightnessPct, 128.0 / 255.0 * 100.0, accuracy: 0.01)
        XCTAssertEqual(gray.luminance, 128.0 / 255.0, accuracy: 1e-4)
    }

    func testPixelSamplerNeighborhoodAndBounds() throws {
        let image = try makeRGBA8CGImage(width: 4, height: 4) { x, _ in
            x < 2 ? (100, 100, 100) : (200, 100, 50)
        }
        let exact = try XCTUnwrap(InspectionSamplerCache.shared.sample(image, atNormalized: CGPoint(x: 0, y: 0), radiusPixels: 0))
        XCTAssertEqual(exact.r, 100)
        let edgeBox = try XCTUnwrap(InspectionSamplerCache.shared.sample(image, atNormalized: CGPoint(x: 0, y: 0), radiusPixels: 1))
        XCTAssertEqual(edgeBox.r, 100)
        let straddle = try XCTUnwrap(InspectionSamplerCache.shared.sample(image, atNormalized: CGPoint(x: 1.0 / 3.0, y: 0.5), radiusPixels: 1))
        // cx=1, cy=2 => x in 0..2: cols 0,1 are 100, col 2 is 200 => average R = (100*6 + 200*3)/9 = 133
        XCTAssertEqual(straddle.r, 133)
    }

    func testGeometryCoordinateMapperRoundTripAndCropOut() throws {
        let sourceSize = CGSize(width: 4000, height: 3000)
        let geometries: [GeometrySettings] = [
            GeometrySettings(),
            GeometrySettings(quarterTurns: 1),
            GeometrySettings(quarterTurns: 2, flipHorizontal: true),
            GeometrySettings(quarterTurns: 3, flipVertical: true),
            GeometrySettings(cropX: 0.1, cropY: 0.2, cropWidth: 0.6, cropHeight: 0.5, quarterTurns: 1, flipHorizontal: true, straightenDegrees: 7.5, perspectiveHorizontal: 0.35, perspectiveVertical: -0.25),
            GeometrySettings(cropX: 0.15, cropY: 0.1, cropWidth: 0.7, cropHeight: 0.75, quarterTurns: 0, flipHorizontal: false, flipVertical: true, straightenDegrees: -12.0, perspectiveHorizontal: -0.4, perspectiveVertical: 0.5),
        ]

        for geometry in geometries {
            for pt in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.35, y: 0.6), CGPoint(x: 0.68, y: 0.42)] {
                let src = try XCTUnwrap(GeometryCoordinateMapper.outputNormToSourceNorm(pt, sourceSize: sourceSize, geometry: geometry))
                let back = try XCTUnwrap(GeometryCoordinateMapper.sourceNormToOutputNorm(src, sourceSize: sourceSize, geometry: geometry))
                XCTAssertEqual(back.x, pt.x, accuracy: 1e-4)
                XCTAssertEqual(back.y, pt.y, accuracy: 1e-4)
            }
        }

        // Cropped-out source point returns nil
        let cropped = GeometrySettings(cropX: 0.25, cropY: 0.25, cropWidth: 0.5, cropHeight: 0.5)
        XCTAssertNil(GeometryCoordinateMapper.sourceNormToOutputNorm(CGPoint(x: 0.1, y: 0.1), sourceSize: sourceSize, geometry: cropped))
        XCTAssertNotNil(GeometryCoordinateMapper.sourceNormToOutputNorm(CGPoint(x: 0.5, y: 0.5), sourceSize: sourceSize, geometry: cropped))

        // inferSourceSize recovers source dimensions across crop, straighten, perspective, and rotation
        let complex = GeometrySettings(
            cropX: 0.1, cropY: 0.2, cropWidth: 0.6, cropHeight: 0.5,
            quarterTurns: 1, straightenDegrees: 10.0,
            perspectiveHorizontal: 0.4, perspectiveVertical: -0.3
        )
        let canvas = GeometryCoordinateMapper.canvasFor(width: Int(sourceSize.width), height: Int(sourceSize.height), options: complex)
        let inferred = GeometryCoordinateMapper.inferSourceSize(
            outputSize: CGSize(width: canvas.outputWidth, height: canvas.outputHeight),
            geometry: complex
        )
        XCTAssertEqual(inferred.width, sourceSize.width, accuracy: sourceSize.width * 0.01)
        XCTAssertEqual(inferred.height, sourceSize.height, accuracy: sourceSize.height * 0.01)
    }

    func testInspectionSessionStateMax4AnchorsAndTransientGrayToggle() {
        var session = InspectionSessionState()
        for i in 0..<4 {
            XCTAssertNotNil(session.pinAnchor(atSourcePoint: CGPoint(x: 0.1 * Double(i + 1), y: 0.5)))
        }
        XCTAssertFalse(session.canPinMore)
        XCTAssertNil(session.pinAnchor(atSourcePoint: CGPoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(session.anchors.count, 4)

        session.selectOverlay(.warmCoolBW)
        session.toggleNeutralGray50()
        XCTAssertEqual(session.overlay, .neutralGray50)
        session.toggleNeutralGray50()
        XCTAssertEqual(session.overlay, .warmCoolBW)

        session.toggleNeutralGray50()
        XCTAssertTrue(session.handleEscape())
        XCTAssertEqual(session.overlay, .warmCoolBW)

        session.resetForNewSource()
        XCTAssertTrue(session.anchors.isEmpty)
        XCTAssertEqual(session.overlay, .none)
    }

    func testAllFiveObservationOverlays() throws {
        // 1. Sketch Luminance: increases contrast around midtones & stays neutral gray
        let dark = InspectionOverlayRenderer.applyOverlayPixel(r: 80, g: 80, b: 80, mode: .sketchLuminance)
        let bright = InspectionOverlayRenderer.applyOverlayPixel(r: 180, g: 180, b: 180, mode: .sketchLuminance)
        XCTAssertEqual(dark.0, dark.1); XCTAssertEqual(dark.1, dark.2)
        XCTAssertEqual(bright.0, bright.1); XCTAssertEqual(bright.1, bright.2)
        XCTAssertLessThan(dark.0, 80)
        XCTAssertGreaterThan(bright.0, 180)

        // 2. Warm/Cool B&W: warm lifts above cool of same luma
        let warm = InspectionOverlayRenderer.applyOverlayPixel(r: 180, g: 140, b: 60, mode: .warmCoolBW)
        let cool = InspectionOverlayRenderer.applyOverlayPixel(r: 60, g: 140, b: 220, mode: .warmCoolBW)
        XCTAssertEqual(warm.0, warm.1); XCTAssertEqual(warm.1, warm.2)
        XCTAssertEqual(cool.0, cool.1); XCTAssertEqual(cool.1, cool.2)
        XCTAssertGreaterThan(warm.0, cool.0)

        // 3. Oversaturation Heatmap: single-channel clip (255, 100, 100) vs neutral muted (128, 128, 128) vs melting (255, 20, 10)
        let neutralHeat = InspectionOverlayRenderer.applyOverlayPixel(r: 128, g: 128, b: 128, mode: .oversaturationHeatmap)
        XCTAssertEqual(neutralHeat.0, neutralHeat.1)
        XCTAssertLessThan(neutralHeat.0, 50)
        let singleClip = InspectionOverlayRenderer.applyOverlayPixel(r: 255, g: 100, b: 100, mode: .oversaturationHeatmap)
        XCTAssertEqual(singleClip.0, 255)
        XCTAssertGreaterThan(singleClip.2, 100)
        let melt = InspectionOverlayRenderer.applyOverlayPixel(r: 230, g: 20, b: 10, mode: .oversaturationHeatmap)
        XCTAssertEqual(melt.0, 255)
        XCTAssertLessThan(melt.2, 50)

        // 4. Skin Hue Amplification: reddish skin (0-10°) separates from sallow skin (40-48°) while neutral gray stays muted
        let redSkin = InspectionOverlayRenderer.applyOverlayPixel(r: 210, g: 130, b: 120, mode: .skinHueAmplification)
        let yellowSkin = InspectionOverlayRenderer.applyOverlayPixel(r: 210, g: 195, b: 120, mode: .skinHueAmplification)
        XCTAssertNotEqual(redSkin.0, redSkin.2)
        XCTAssertGreaterThan(yellowSkin.1, redSkin.1)
        let bg = InspectionOverlayRenderer.applyOverlayPixel(r: 80, g: 120, b: 200, mode: .skinHueAmplification)
        XCTAssertEqual(bg.0, bg.1); XCTAssertEqual(bg.1, bg.2)

        // 5. 50% Neutral Gray
        let gray50 = InspectionOverlayRenderer.applyOverlayPixel(r: 20, g: 200, b: 250, mode: .neutralGray50)
        XCTAssertEqual(gray50.0, 128); XCTAssertEqual(gray50.1, 128); XCTAssertEqual(gray50.2, 128)

        // End-to-end CGImage render + .none identity + 24-entry cache retention
        let img = try makeRGBA8CGImage(width: 8, height: 8) { x, _ in (UInt8(x * 32), 120, 90) }
        XCTAssertTrue(InspectionOverlayRenderer.shared.render(img, mode: .none) === img)
        for mode in InspectionOverlayMode.allCases where mode != .none {
            let out = try XCTUnwrap(InspectionOverlayRenderer.shared.render(img, mode: mode))
            XCTAssertEqual(out.width, 8)
            XCTAssertEqual(out.height, 8)
        }

        let renderer = InspectionOverlayRenderer()
        var sources: [CGImage] = []
        var rendered: [CGImage] = []
        for i in 0..<24 {
            let tile = try makeRGBA8CGImage(width: 4, height: 4) { _, _ in (UInt8(i * 10), 100, 120) }
            sources.append(tile)
            rendered.append(try XCTUnwrap(renderer.render(tile, mode: .sketchLuminance)))
        }
        for (src, first) in zip(sources, rendered) {
            XCTAssertTrue(renderer.render(src, mode: .sketchLuminance) === first)
        }
    }

    private func canonicalSortedJSON(_ raw: String) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [])
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    func testZeroEditStateAndCanonicalRecipePollution() throws {
        var rawSettings = RawSettings.default
        rawSettings.exposure = 0.4
        rawSettings.contrast = 12
        rawSettings.geometry = GeometrySettings(cropX: 0.1, cropY: 0.1, cropWidth: 0.8, cropHeight: 0.8, quarterTurns: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baseState = PhotoEditState(settings: rawSettings, filmID: "PROVIA")
        let baseData = try encoder.encode(baseState)
        let recipeState = CanonicalEditRecipe.State(
            processing: .current,
            x3fMode: .normal,
            exposureMode: "preview",
            isRaster: false,
            geometry: rawSettings.geometry
        )
        let baseRecipe = try canonicalSortedJSON(CanonicalEditRecipe.encode(recipeState))

        var session = InspectionSessionState()
        for mode in InspectionOverlayMode.allCases {
            session.selectOverlay(mode)
            _ = session.pinAnchor(atSourcePoint: CGPoint(x: 0.4, y: 0.6))
            let stateData = try encoder.encode(baseState)
            let recipeAfter = try canonicalSortedJSON(CanonicalEditRecipe.encode(recipeState))
            XCTAssertEqual(stateData, baseData)
            XCTAssertEqual(recipeAfter, baseRecipe)
        }
    }

    func testOverlayRendererAsyncAndCacheClear() throws {
        let sampler = InspectionSamplerCache()
        let renderer = InspectionOverlayRenderer()
        let img = try makeRGBA8CGImage(width: 8, height: 8) { x, _ in (UInt8(x * 32), 120, 90) }

        XCTAssertNil(renderer.cached(img, mode: .sketchLuminance))
        _ = sampler.sample(img, atNormalized: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(sampler.entryCount, 1)

        let exp = expectation(description: "renderAsync completes off main thread")
        final class ResultBox: @unchecked Sendable {
            let lock = NSLock()
            var image: CGImage?
        }
        let box = ResultBox()
        renderer.renderAsync(img, mode: .sketchLuminance) { rendered in
            box.lock.lock()
            box.image = rendered
            box.lock.unlock()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        box.lock.lock()
        let capturedOut = box.image
        box.lock.unlock()
        XCTAssertNotNil(capturedOut)
        XCTAssertEqual(renderer.entryCount, 1)
        XCTAssertTrue(renderer.cached(img, mode: .sketchLuminance) === capturedOut)

        sampler.clear()
        renderer.clear()
        XCTAssertEqual(sampler.entryCount, 0)
        XCTAssertEqual(renderer.entryCount, 0)
        XCTAssertNil(renderer.cached(img, mode: .sketchLuminance))
    }
}
