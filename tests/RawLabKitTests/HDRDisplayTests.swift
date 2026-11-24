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
}
