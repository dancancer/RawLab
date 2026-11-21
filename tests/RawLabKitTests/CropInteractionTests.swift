import CoreGraphics
import Foundation
import XCTest
@testable import RawLabKit

final class CropInteractionTests: XCTestCase {
    func testCropInteractionRatiosDraggingAndClamping() {
        let canvas = CGSize(width: 1200, height: 800)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let square = CropInteraction.fitting(ratio: 1, in: canvas, around: full)
        XCTAssertEqual(Double(square.width * 1200 / (square.height * 800)), 1, accuracy: 1e-9)

        let restored = CropInteraction.fitting(ratio: 1.5, in: canvas, around: square)
        XCTAssertEqual(restored, full)

        var rect = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        rect = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: 0.02, height: 0.02), canvasSize: canvas, ratio: nil)
        rect = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: 0.02, height: 0.02), canvasSize: canvas, ratio: nil)
        XCTAssertEqual(rect.minX, 0.14, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.14, accuracy: 1e-9)

        let moved = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: -2, height: 2), canvasSize: canvas, ratio: nil)
        XCTAssertEqual(moved.minX, 0)
        XCTAssertEqual(moved.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.size, rect.size)

        for handle in [CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for translation in [CGSize(width: 0.08, height: -0.06), CGSize(width: -2, height: 2)] {
                for ratio in [Double?.none, 1.0, 16.0 / 9] {
                    let adjusted = CropInteraction.dragging(rect, handle: handle, translation: translation, canvasSize: canvas, ratio: ratio)
                    let geometry = CropInteraction.applying(rect: adjusted, to: GeometrySettings())
                    XCTAssertTrue(geometry.isValid)
                    if let ratio {
                        XCTAssertEqual(Double(adjusted.width * canvas.width / (adjusted.height * canvas.height)), ratio, accuracy: 1e-8)
                    }
                }
            }
        }

        var settings = GeometrySettings()
        settings.perspectiveHorizontal = 0.5
        settings.quarterTurns = 2
        let cropped = CropInteraction.applying(rect: square, to: settings)
        XCTAssertEqual(cropped.perspectiveHorizontal, 0.5)
        XCTAssertEqual(cropped.quarterTurns, 2)
        XCTAssertEqual(CropAspectPreset.threeTwo.ratio(for: canvas, swapped: true), 2.0 / 3)
    }
}
