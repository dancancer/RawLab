import Foundation
import CoreGraphics

@main enum CropInteractionTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            precondition(condition, name)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
        let canvas = CGSize(width: 1200, height: 800)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let square = CropInteraction.fitting(ratio: 1, in: canvas, around: full)
        check(near(square.width * 1200 / (square.height * 800), 1), "physical square ratio")
        let restored = CropInteraction.fitting(ratio: 1.5, in: canvas, around: square)
        check(restored == full, "switching ratios restores full framing without cumulative shrink")
        var rect = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        rect = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: 0.02, height: 0.02), canvasSize: canvas, ratio: nil)
        rect = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: 0.02, height: 0.02), canvasSize: canvas, ratio: nil)
        check(near(rect.minX, 0.14) && near(rect.minY, 0.14), "separate drag baselines accumulate correctly")
        let moved = CropInteraction.dragging(rect, handle: .move, translation: CGSize(width: -2, height: 2), canvasSize: canvas, ratio: nil)
        check(moved.minX == 0 && near(moved.maxY, 1) && moved.size == rect.size, "moving clamps without resizing")
        for handle in [CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for translation in [CGSize(width: 0.08, height: -0.06), CGSize(width: -2, height: 2)] {
                for ratio in [Double?.none, 1.0, 16.0 / 9] {
                    let adjusted = CropInteraction.dragging(rect, handle: handle, translation: translation, canvasSize: canvas, ratio: ratio)
                    let geometry = CropInteraction.applying(rect: adjusted, to: GeometrySettings())
                    check(geometry.isValid, "corner stays within valid normalized crop")
                    if let ratio {
                        check(abs(Double(adjusted.width * canvas.width / (adjusted.height * canvas.height)) - ratio) < 1e-8,
                              "corner preserves selected physical ratio")
                    }
                }
            }
        }
        var settings = GeometrySettings()
        settings.perspectiveHorizontal = 0.5; settings.quarterTurns = 2
        let cropped = CropInteraction.applying(rect: square, to: settings)
        check(cropped.perspectiveHorizontal == 0.5 && cropped.quarterTurns == 2, "crop helpers preserve transforms")
        check(CropAspectPreset.threeTwo.ratio(for: canvas, swapped: true) == 2.0 / 3, "portrait ratio swap")
        print("PASS \(count) crop interaction checks")
    }
}
