import Foundation
import CoreGraphics

@main enum MacCropInteractionTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            precondition(condition, name)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
        func valid(_ rect: CGRect) -> Bool {
            CropInteraction.applying(rect: rect, to: GeometrySettings()).isValid
        }
        func physicalRatio(_ rect: CGRect, _ canvas: CGSize) -> CGFloat {
            rect.width * canvas.width / (rect.height * canvas.height)
        }

        let canvas = CGSize(width: 1200, height: 800)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let baseline = CGRect(x: 0.15, y: 0.2, width: 0.6, height: 0.5)
        let resizeHandles = MacCropHandle.allCases.filter { $0 != .move }
        check(MacCropHandle.allCases.count == 9, "eight resize handles and interior move")
        for canvas in [canvas, CGSize(width: 800, height: 1200)] {
            for ratio in [0.25, 1, 1.5, 16.0 / 9, 4] {
                let fitted = MacCropInteraction.fitting(ratio: ratio, in: canvas, around: full)
                check(valid(fitted) && near(physicalRatio(fitted, canvas), CGFloat(ratio)), "fit preserves physical ratio")
                for handle in resizeHandles {
                    for translation in [CGSize.zero, CGSize(width: 0.1, height: -0.08),
                                        CGSize(width: -100, height: 100), CGSize(width: 100, height: -100)] {
                        let adjusted = MacCropInteraction.dragging(fitted, handle: handle, translation: translation,
                                                                  canvasSize: canvas, ratio: ratio)
                        check(valid(adjusted), "locked handle strictly respects normalized bounds")
                        check(near(physicalRatio(adjusted, canvas), CGFloat(ratio)), "locked handle preserves physical ratio")
                    }
                }
            }
        }

        for handle in resizeHandles {
            for translation in [CGSize(width: -100, height: 100), CGSize(width: 100, height: -100)] {
                let adjusted = MacCropInteraction.dragging(baseline, handle: handle, translation: translation,
                                                          canvasSize: canvas, ratio: nil)
                check(valid(adjusted) && adjusted.width >= 0.01 && adjusted.height >= 0.01,
                      "free resize keeps a useful minimum size")
            }
        }
        let left = MacCropInteraction.dragging(baseline, handle: .left, translation: CGSize(width: 0.1, height: 0.3),
                                              canvasSize: canvas, ratio: nil)
        check(near(left.minX, 0.25) && near(left.maxX, baseline.maxX) && left.minY == baseline.minY && left.height == baseline.height,
              "free left handle changes only left edge")
        let right = MacCropInteraction.dragging(baseline, handle: .right, translation: CGSize(width: 0.1, height: 0.3),
                                               canvasSize: canvas, ratio: nil)
        check(right.minX == baseline.minX && near(right.maxX, baseline.maxX + 0.1) && right.minY == baseline.minY && right.height == baseline.height,
              "free right handle changes only right edge")
        let top = MacCropInteraction.dragging(baseline, handle: .top, translation: CGSize(width: 0.3, height: 0.1),
                                             canvasSize: canvas, ratio: nil)
        check(top.minX == baseline.minX && top.width == baseline.width && near(top.minY, 0.3) && near(top.maxY, baseline.maxY),
              "free top handle changes only top edge")
        let bottom = MacCropInteraction.dragging(baseline, handle: .bottom, translation: CGSize(width: 0.3, height: 0.1),
                                                canvasSize: canvas, ratio: nil)
        check(bottom.minX == baseline.minX && bottom.width == baseline.width && bottom.minY == baseline.minY && near(bottom.maxY, 0.8),
              "free bottom handle changes only bottom edge")

        let square = MacCropInteraction.fitting(ratio: 1, in: canvas, around: baseline)
        for handle in [MacCropHandle.left, .right, .top, .bottom] {
            let adjusted = MacCropInteraction.dragging(square, handle: handle, translation: CGSize(width: 0.04, height: 0.03),
                                                      canvasSize: canvas, ratio: 1)
            switch handle {
            case .left: check(near(adjusted.maxX, square.maxX) && near(adjusted.midY, square.midY), "locked left anchors opposite edge and center")
            case .right: check(near(adjusted.minX, square.minX) && near(adjusted.midY, square.midY), "locked right anchors opposite edge and center")
            case .top: check(near(adjusted.maxY, square.maxY) && near(adjusted.midX, square.midX), "locked top anchors opposite edge and center")
            default: check(near(adjusted.minY, square.minY) && near(adjusted.midX, square.midX), "locked bottom anchors opposite edge and center")
            }
        }
        let originalRatio = MacCropInteraction.fitting(ratio: 1.5, in: canvas, around: MacCropInteraction.fitting(ratio: 1, in: canvas, around: full))
        check(originalRatio == full, "ratio cycling recovers full framing without cumulative shrink")
        let first = MacCropInteraction.dragging(baseline, handle: .move, translation: CGSize(width: 0.02, height: 0.03), canvasSize: canvas, ratio: nil)
        let second = MacCropInteraction.dragging(first, handle: .move, translation: CGSize(width: 0.02, height: 0.03), canvasSize: canvas, ratio: nil)
        check(near(second.minX, 0.19) && near(second.minY, 0.26), "new gesture baseline accumulates an independent second drag")
        let updated = MacCropInteraction.dragging(baseline, handle: .move, translation: CGSize(width: 0.04, height: 0.06), canvasSize: canvas, ratio: nil)
        check(near(second.minX, updated.minX) && near(second.minY, updated.minY) && second.size == updated.size,
              "absolute translation from a stable baseline does not compound change events")
        for delta in [CGSize(width: -100, height: 100), CGSize(width: 100, height: -100)] {
            let moved = MacCropInteraction.dragging(baseline, handle: .move, translation: delta, canvasSize: canvas, ratio: 1)
            check(valid(moved) && moved.size == baseline.size, "move preserves size at extreme bounds")
        }

        var transforms = GeometrySettings()
        transforms.quarterTurns = 3; transforms.flipHorizontal = true; transforms.flipVertical = true
        transforms.straightenDegrees = 12.5; transforms.perspectiveHorizontal = -0.4; transforms.perspectiveVertical = 0.7
        let applied = MacCropInteraction.applying(rect: square, to: transforms)
        check(applied.isValid && MacCropInteraction.rect(from: applied) == square, "valid crop maps to existing geometry payload")
        check(applied.quarterTurns == 3 && applied.flipHorizontal && applied.flipVertical && applied.straightenDegrees == 12.5 &&
              applied.perspectiveHorizontal == -0.4 && applied.perspectiveVertical == 0.7, "crop edits preserve all other transforms")
        for handle in MacCropHandle.allCases {
            check(MacCropInteraction.dragging(baseline, handle: handle, translation: CGSize(width: CGFloat.nan, height: 0), canvasSize: canvas, ratio: 1) == baseline,
                  "nonfinite drag is ignored")
            check(MacCropInteraction.dragging(baseline, handle: handle, translation: .zero, canvasSize: .zero, ratio: 1) == baseline,
                  "invalid canvas is ignored")
            check(MacCropInteraction.dragging(baseline, handle: handle, translation: CGSize(width: 0.1, height: 0.1), canvasSize: canvas, ratio: .infinity) == baseline,
                  "nonfinite ratio is ignored")
        }
        check(MacCropInteraction.applying(rect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), to: transforms) == transforms,
              "nonfinite application preserves settings")
        check(MacCropInteraction.fitting(ratio: .nan, in: canvas, around: baseline) == baseline, "nonfinite fitting ratio is ignored")
        let rounded = CGRect(x: 0.1, y: 0.7, width: 0.9.nextUp, height: 0.3.nextUp)
        check(MacCropInteraction.applying(rect: rounded, to: GeometrySettings()).isValid, "outward rounding remains strictly renderer-valid")

        let bounds = MacCropInteraction.imageBounds(canvasSize: CGSize(width: 1000, height: 800), renderedSize: canvas, factor: 5.0 / 6, pan: .zero)
        check(near(bounds.minX, 0) && near(bounds.minY, 200.0 / 3) && near(bounds.width, 1000) && near(bounds.height, 2000.0 / 3),
              "fit centers a landscape image in letterboxed canvas")
        let zoomed = MacCropInteraction.imageBounds(canvasSize: CGSize(width: 1000, height: 800), renderedSize: canvas,
                                                   factor: 5.0 / 3, pan: CGSize(width: 30, height: -20))
        check(near(zoomed.minX, -470) && near(zoomed.minY, -860.0 / 3) && near(zoomed.width, 2000) && near(zoomed.height, 4000.0 / 3),
              "zoom and pan share image and crop coordinates")
        let native = MacCropInteraction.imageBounds(canvasSize: CGSize(width: 1000, height: 800), renderedSize: canvas, factor: 1, pan: .zero)
        check(native == CGRect(x: -100, y: 0, width: 1200, height: 800), "factor one displays native rendered dimensions without a second fit")
        let scaled = MacCropInteraction.imageBounds(canvasSize: CGSize(width: 1000, height: 800), renderedSize: canvas, factor: 0.4956, pan: .zero)
        check(near(scaled.width, 594.72) && near(scaled.height, 396.48) && near(scaled.minX, 202.64) && near(scaled.minY, 201.76),
              "small final viewport factor is not multiplied by canvas fit again")
        let selection = MacCropInteraction.selectionBounds(crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), imageBounds: zoomed)
        check(near(selection.minX, 30) && near(selection.minY, 140.0 / 3) && near(selection.width, 1000) && near(selection.height, 2000.0 / 3),
              "crop overlay follows zoomed and panned image")
        let translation = MacCropInteraction.normalizedTranslation(CGSize(width: 20, height: -40), imageBounds: zoomed)
        check(translation != nil && near(translation!.width, 0.01) && near(translation!.height, -0.03), "screen translation converts to top-down normalized delta")
        check(MacCropInteraction.normalizedTranslation(CGSize(width: CGFloat.infinity, height: 0), imageBounds: zoomed) == nil &&
              MacCropInteraction.normalizedTranslation(.zero, imageBounds: .zero) == nil, "invalid translation and image bounds have no delta")
        check(MacCropInteraction.imageBounds(canvasSize: .zero, renderedSize: canvas, factor: 1, pan: .zero) == .zero &&
              MacCropInteraction.imageBounds(canvasSize: canvas, renderedSize: canvas, factor: .infinity, pan: .zero) == .zero,
              "invalid viewport geometry has no image bounds")
        let normal = MacCropInteraction.keyboardTranslation(for: .move, direction: .right, fine: false, imageBounds: zoomed)
        let fine = MacCropInteraction.keyboardTranslation(for: .move, direction: .up, fine: true, imageBounds: zoomed)
        check(near(normal.width * zoomed.width, 10) && normal.height == 0 && fine.width == 0 && near(fine.height * zoomed.height, -1),
              "keyboard steps remain ten or one screen points at current zoom")
        check(MacCropInteraction.keyboardTranslation(for: .left, direction: .up, fine: false, imageBounds: zoomed) == .zero &&
              MacCropInteraction.keyboardTranslation(for: .top, direction: .right, fine: false, imageBounds: zoomed) == .zero,
              "edge keys affect only the selected edge axis")
        print("PASS \(count) macOS crop interaction checks")
    }
}
