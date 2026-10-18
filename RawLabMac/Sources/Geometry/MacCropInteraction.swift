import Foundation
import CoreGraphics

enum MacCropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
}

enum MacCropDirection {
    case left, right, up, down
}

// Desktop handles use the renderer's normalized, top-down crop coordinates.
enum MacCropInteraction {
    private static let minimumLength: CGFloat = 0.01

    static func rect(from settings: GeometrySettings) -> CGRect {
        CropInteraction.rect(from: settings)
    }

    static func applying(rect: CGRect, to settings: GeometrySettings) -> GeometrySettings {
        guard let rect = bounded(rect) else { return settings }
        return CropInteraction.applying(rect: rect, to: settings)
    }

    static func fitting(ratio: Double?, in canvasSize: CGSize, around rect: CGRect) -> CGRect {
        guard let baseline = bounded(rect), valid(canvasSize) else { return rect }
        guard let ratio else { return baseline }
        guard normalizedRatio(ratio, canvasSize: canvasSize) != nil else { return baseline }
        return bounded(CropInteraction.fitting(ratio: ratio, in: canvasSize, around: baseline)) ?? baseline
    }

    static func dragging(_ rect: CGRect, handle: MacCropHandle, translation: CGSize,
                         canvasSize: CGSize, ratio: Double?) -> CGRect {
        guard let baseline = bounded(rect), valid(canvasSize),
              translation.width.isFinite, translation.height.isFinite else { return rect }
        let lockedRatio: CGFloat?
        if let ratio {
            guard let normalized = normalizedRatio(ratio, canvasSize: canvasSize) else { return baseline }
            lockedRatio = normalized
        } else {
            lockedRatio = nil
        }

        switch handle {
        case .move:
            return bounded(CGRect(x: baseline.minX + translation.width,
                                  y: baseline.minY + translation.height,
                                  width: baseline.width, height: baseline.height)) ?? baseline
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let shared: CropHandle
            switch handle {
            case .topLeft: shared = .topLeft
            case .topRight: shared = .topRight
            case .bottomLeft: shared = .bottomLeft
            default: shared = .bottomRight
            }
            return bounded(CropInteraction.dragging(baseline, handle: shared, translation: translation,
                                                    canvasSize: canvasSize, ratio: ratio)) ?? baseline
        case .left, .right:
            let left = handle == .left
            let anchor = left ? baseline.maxX : baseline.minX
            var maximum = left ? anchor : 1 - anchor
            var minimum = minimumLength
            if let lockedRatio {
                maximum = min(maximum, 2 * min(baseline.midY, 1 - baseline.midY) * lockedRatio)
                minimum = max(minimumLength, minimumLength * lockedRatio)
            }
            let width = clamp(baseline.width + (left ? -translation.width : translation.width),
                              minimum: min(minimum, maximum), maximum: maximum)
            let height = lockedRatio.map { width / $0 } ?? baseline.height
            return bounded(CGRect(x: left ? anchor - width : anchor,
                                  y: lockedRatio == nil ? baseline.minY : baseline.midY - height / 2,
                                  width: width, height: height)) ?? baseline
        case .top, .bottom:
            let top = handle == .top
            let anchor = top ? baseline.maxY : baseline.minY
            var maximum = top ? anchor : 1 - anchor
            var minimum = minimumLength
            if let lockedRatio {
                maximum = min(maximum, 2 * min(baseline.midX, 1 - baseline.midX) / lockedRatio)
                minimum = max(minimumLength, minimumLength / lockedRatio)
            }
            let height = clamp(baseline.height + (top ? -translation.height : translation.height),
                               minimum: min(minimum, maximum), maximum: maximum)
            let width = lockedRatio.map { height * $0 } ?? baseline.width
            return bounded(CGRect(x: lockedRatio == nil ? baseline.minX : baseline.midX - width / 2,
                                  y: top ? anchor - height : anchor,
                                  width: width, height: height)) ?? baseline
        }
    }

    static func imageBounds(canvasSize: CGSize, renderedSize: CGSize, factor: CGFloat, pan: CGSize) -> CGRect {
        guard valid(canvasSize), valid(renderedSize), factor.isFinite, factor > 0,
              pan.width.isFinite, pan.height.isFinite else { return .zero }
        // PhotoCanvas supplies its final points-per-rendered-pixel factor,
        // already including fit, display scale and the viewport's zoom mode.
        let size = CGSize(width: renderedSize.width * factor, height: renderedSize.height * factor)
        let origin = CGPoint(x: (canvasSize.width - size.width) / 2 + pan.width,
                             y: (canvasSize.height - size.height) / 2 + pan.height)
        guard valid(size), origin.x.isFinite, origin.y.isFinite else { return .zero }
        return CGRect(origin: origin, size: size)
    }

    static func selectionBounds(crop: CGRect, imageBounds: CGRect) -> CGRect {
        guard let crop = bounded(crop), valid(imageBounds.size),
              imageBounds.minX.isFinite, imageBounds.minY.isFinite else { return .zero }
        return CGRect(x: imageBounds.minX + crop.minX * imageBounds.width,
                      y: imageBounds.minY + crop.minY * imageBounds.height,
                      width: crop.width * imageBounds.width, height: crop.height * imageBounds.height)
    }

    static func normalizedTranslation(_ translation: CGSize, imageBounds: CGRect) -> CGSize? {
        guard translation.width.isFinite, translation.height.isFinite, valid(imageBounds.size),
              imageBounds.minX.isFinite, imageBounds.minY.isFinite else { return nil }
        let result = CGSize(width: translation.width / imageBounds.width,
                            height: translation.height / imageBounds.height)
        return result.width.isFinite && result.height.isFinite ? result : nil
    }

    // Arrow keys move ten screen points; Shift moves one. Conversion through the
    // visible image bounds keeps the same screen step at every zoom level.
    static func keyboardTranslation(for handle: MacCropHandle, direction: MacCropDirection,
                                    fine: Bool, imageBounds: CGRect) -> CGSize {
        let step: CGFloat = fine ? 1 : 10
        let translation: CGSize
        switch direction {
        case .left: translation = CGSize(width: -step, height: 0)
        case .right: translation = CGSize(width: step, height: 0)
        case .up: translation = CGSize(width: 0, height: -step)
        case .down: translation = CGSize(width: 0, height: step)
        }
        if (handle == .top || handle == .bottom) && translation.width != 0 { return .zero }
        if (handle == .left || handle == .right) && translation.height != 0 { return .zero }
        return normalizedTranslation(translation, imageBounds: imageBounds) ?? .zero
    }

    private static func normalizedRatio(_ ratio: Double, canvasSize: CGSize) -> CGFloat? {
        guard ratio.isFinite, ratio > 0, valid(canvasSize) else { return nil }
        let normalized = CGFloat(ratio) * (canvasSize.height / canvasSize.width)
        return normalized.isFinite && normalized > 0 ? normalized : nil
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }

    // Strict renderer validation uses x + width <= 1, without an epsilon. Keep
    // the size while moving, then repair only an outward rounding error in size.
    private static func bounded(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, valid(rect.size) else { return nil }
        var width = min(1, rect.width)
        var height = min(1, rect.height)
        let x = clamp(rect.minX, minimum: 0, maximum: 1 - width)
        let y = clamp(rect.minY, minimum: 0, maximum: 1 - height)
        if x + width > 1 { width = (1 - x).nextDown }
        if y + height > 1 { height = (1 - y).nextDown }
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
