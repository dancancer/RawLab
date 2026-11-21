import Foundation
import XCTest
@testable import RawLabKit

final class HDRDisplayTests: XCTestCase {
    func testHDRDisplayMathStatisticsAndFP16() throws {
        let hdr = SIMD3<Float>(4, 4, 4), sdr = SIMD3<Float>(0.5, 0.5, 0.5)
        for headroom in [1.0, 2, 4, 8] {
            let result = try HDRDisplayMath.pixel(
                hdr: hdr, sdr: sdr, contentHeadroom: 4,
                parameters: HDRDisplayParameters(headroom: headroom)
            )
            let expected: Float = headroom == 1 ? 0.5 : Float(min(4, headroom))
            XCTAssertEqual(result.x, expected, accuracy: 1e-5)
            XCTAssertEqual(result.y, expected, accuracy: 1e-5)
            XCTAssertEqual(result.z, expected, accuracy: 1e-5)
        }

        let white = SIMD3<Float>(1, 1, 1)
        let kept = try HDRDisplayMath.pixel(hdr: white, sdr: sdr, contentHeadroom: 8, parameters: .init(headroom: 2))
        XCTAssertEqual(kept.x, 1, accuracy: 1e-5)
        XCTAssertEqual(kept.y, 1, accuracy: 1e-5)

        var compatibility = HDRDisplayParameters(headroom: 8)
        compatibility.mode = .sdr
        let preview = try HDRDisplayMath.pixel(hdr: hdr, sdr: sdr, contentHeadroom: 4, parameters: compatibility)
        XCTAssertEqual(preview.x, 0.5, accuracy: 1e-5)

        let input: [Float] = [0, 0, 0, 1, 1, 1, 2, 2, 2, 4, 4, 4]
        let before = input
        let stats = try input.withUnsafeBufferPointer { try HDRStatistics.analyze($0, width: 4, height: 1, stride: 12) }
        XCTAssertEqual(stats.bins.reduce(0, +), 4)
        XCTAssertEqual(stats.aboveWhite, 2)
        XCTAssertEqual(stats.headroom, 4)

        for headroom in [1.0, 2, 4, 8] {
            _ = try HDRDisplayMath.pixel(hdr: hdr, sdr: sdr, contentHeadroom: 4, parameters: .init(headroom: headroom))
        }
        XCTAssertEqual(input, before)

        let packed = try HDRDisplayMath.half(SIMD3<Float>(-0.25, 2, 4))
        XCTAssertEqual(packed[0], 0xb400)
        XCTAssertEqual(packed[1], 0x4000)
        XCTAssertEqual(packed[2], 0x4400)
        XCTAssertEqual(packed[3], 0x3c00)

        let vectors: [(Float, UInt16)] = [
            (0, 0x0000), (-Float.zero, 0x8000), (1, 0x3c00), (65504, 0x7bff), (65519, 0x7bff),
            (pow(2, -14), 0x0400), (pow(2, -24), 0x0001), (pow(2, -25), 0x0000),
            (3 * pow(2, -25), 0x0002), (1 + pow(2, -11), 0x3c00), (1 + 3 * pow(2, -11), 0x3c02)
        ]
        for (value, expected) in vectors {
            let bits = try HDRDisplayMath.half(SIMD3(repeating: value))
            XCTAssertEqual(bits[0], expected)
            XCTAssertEqual(bits[1], expected)
            XCTAssertEqual(bits[2], expected)
            XCTAssertEqual(bits[3], 0x3c00)
        }

        for value: Float in [65520, 70000, -.infinity, .infinity, .nan] {
            XCTAssertThrowsError(try HDRDisplayMath.half(SIMD3<Float>(value, 1, 1))) { error in
                XCTAssertEqual(error as? HDRDisplayFailure, .unrepresentable)
            }
        }
    }

    func testPhotoDetailTilePlanAndCappedCoverage() {
        let baseScale = 1280.0 / 6000.0
        XCTAssertNil(PhotoDetailTilePlan.level(forZoomScale: baseScale * 1.04, baseScale: baseScale))
        XCTAssertEqual(PhotoDetailTilePlan.level(forZoomScale: 0.25, baseScale: baseScale), 2)
        XCTAssertEqual(PhotoDetailTilePlan.level(forZoomScale: 0.45, baseScale: baseScale), 1)
        XCTAssertEqual(PhotoDetailTilePlan.level(forZoomScale: 1.0, baseScale: baseScale), 0)

        let fullSize = CGSize(width: 6000, height: 4000)
        let centerVisible = CGRect(x: 0.40, y: 0.35, width: 0.20, height: 0.30)
        let specs = PhotoDetailTilePlan.tiles(
            visibleRect: centerVisible,
            fullNativeSize: fullSize,
            zoomScale: 1.0,
            baseScale: baseScale
        )
        XCTAssertFalse(specs.isEmpty)
        XCTAssertTrue(specs.allSatisfy { $0.key.level == 0 && $0.maxOutputLongEdge == 1024 })
        let firstCenterDist = hypot(specs[0].normalizedRect.midX - centerVisible.midX,
                                    specs[0].normalizedRect.midY - centerVisible.midY)
        let lastCenterDist = hypot(specs.last!.normalizedRect.midX - centerVisible.midX,
                                   specs.last!.normalizedRect.midY - centerVisible.midY)
        XCTAssertLessThanOrEqual(firstCenterDist, lastCenterDist + 1e-6)

        // Trailing edge tile uses actual native edge (6000 - 5120 = 880) instead of upsampling to 1024.
        let edgeSpecs = PhotoDetailTilePlan.tiles(
            visibleRect: CGRect(x: 0.90, y: 0.85, width: 0.10, height: 0.15),
            fullNativeSize: fullSize,
            zoomScale: 1.0,
            baseScale: baseScale
        )
        XCTAssertEqual(edgeSpecs.count, 1)
        XCTAssertEqual(edgeSpecs[0].key, PhotoDetailTileKey(level: 0, col: 5, row: 3))
        XCTAssertEqual(edgeSpecs[0].maxOutputLongEdge, 928)

        // HDR overlay capped at 1280px must still report covered when requested at deep zoom.
        let hdrRect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let hdrOverlay = PhotoDetailOverlay(
            cgImage: nil, beforeCGImage: nil, hdr: nil, beforeHDR: nil,
            normalizedRect: hdrRect,
            pixelSize: CGSize(width: 1280, height: 853),
            fullNativeSize: fullSize,
            renderID: UUID()
        )
        XCTAssertTrue(hdrOverlay.covers(visibleRect: CGRect(x: 0.25, y: 0.25, width: 0.3, height: 0.3),
                                        requiredZoomScale: 1.0, maxOutputLongEdge: 1280))

        // Overscan ring appends unique surrounding tiles strictly after visible tiles.
        let visibleOnly = PhotoDetailTilePlan.tiles(
            visibleRect: centerVisible,
            fullNativeSize: fullSize,
            zoomScale: 1.0,
            baseScale: baseScale,
            overscanRing: 0
        )
        let withRing = PhotoDetailTilePlan.tiles(
            visibleRect: centerVisible,
            fullNativeSize: fullSize,
            zoomScale: 1.0,
            baseScale: baseScale,
            overscanRing: 1
        )
        XCTAssertGreaterThan(withRing.count, visibleOnly.count)
        XCTAssertEqual(Array(withRing.prefix(visibleOnly.count)), visibleOnly)
        XCTAssertEqual(Set(withRing.map(\.key)).count, withRing.count)

        // level0Grid covers the entire 6000x4000 frame in 6x4 = 24 exact clamped tiles.
        let grid = PhotoDetailTilePlan.level0Grid(fullNativeSize: fullSize)
        XCTAssertEqual(grid.count, 24)
        XCTAssertTrue(grid.allSatisfy { $0.key.level == 0 })

        // 48MP (8064px) with 3072px backing jumps straight to level 0 at 50% zoom.
        XCTAssertEqual(PhotoDetailTilePlan.level(forZoomScale: 0.5, baseScale: 3072.0 / 8064.0), 0)
    }
}
