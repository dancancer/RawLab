import Foundation
import CoreGraphics

// Normalized crop after rotation, flips, perspective and centered straightening.
struct GeometrySettings: Codable, Equatable {
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1
    var quarterTurns: Int = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var straightenDegrees: Double = 0
    var perspectiveHorizontal: Double = 0
    var perspectiveVertical: Double = 0

    var isIdentity: Bool { self == GeometrySettings() }
    var isValid: Bool {
        [cropX, cropY, cropWidth, cropHeight, straightenDegrees,
         perspectiveHorizontal, perspectiveVertical].allSatisfy { $0.isFinite } &&
        cropX >= 0 && cropY >= 0 && cropWidth > 0 && cropHeight > 0 &&
        cropX + cropWidth <= 1 && cropY + cropHeight <= 1 &&
        (0...3).contains(quarterTurns) && (-45...45).contains(straightenDegrees) &&
        (-1...1).contains(perspectiveHorizontal) && (-1...1).contains(perspectiveVertical)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case cropX, cropY, cropWidth, cropHeight, quarterTurns
        case flipHorizontal, flipVertical, straightenDegrees
        case perspectiveHorizontal, perspectiveVertical
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cropX = try values.decodeIfPresent(Double.self, forKey: .cropX) ?? 0
        cropY = try values.decodeIfPresent(Double.self, forKey: .cropY) ?? 0
        cropWidth = try values.decodeIfPresent(Double.self, forKey: .cropWidth) ?? 1
        cropHeight = try values.decodeIfPresent(Double.self, forKey: .cropHeight) ?? 1
        quarterTurns = try values.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipHorizontal = try values.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try values.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        straightenDegrees = try values.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        perspectiveHorizontal = try values.decodeIfPresent(Double.self, forKey: .perspectiveHorizontal) ?? 0
        perspectiveVertical = try values.decodeIfPresent(Double.self, forKey: .perspectiveVertical) ?? 0
    }
}

// UI-only helpers. The renderer still receives the same normalized crop fields.
enum CropAspectPreset: String, CaseIterable {
    case free, original, square, threeTwo, fourThree, sixteenNine

    var titleKey: String {
        switch self {
        case .free: return "自由"
        case .original: return "原始比例"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }

    func ratio(for canvasSize: CGSize, swapped: Bool = false) -> Double? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let value: Double
        switch self {
        case .free: return nil
        case .original: value = Double(canvasSize.width / canvasSize.height)
        case .square: value = 1
        case .threeTwo: value = 3.0 / 2
        case .fourThree: value = 4.0 / 3
        case .sixteenNine: value = 16.0 / 9
        }
        return swapped ? 1 / value : value
    }
}

enum CropHandle: CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight, move
}

enum CropInteraction {
    static func rect(from settings: GeometrySettings) -> CGRect {
        CGRect(x: settings.cropX, y: settings.cropY, width: settings.cropWidth, height: settings.cropHeight)
    }

    static func applying(rect: CGRect, to settings: GeometrySettings) -> GeometrySettings {
        var result = settings
        result.cropX = Double(rect.minX); result.cropY = Double(rect.minY)
        result.cropWidth = Double(rect.width); result.cropHeight = Double(rect.height)
        return result
    }

    // Fit around a stable center against the full canvas, so cycling ratios does
    // not successively shrink an already cropped rectangle.
    static func fitting(ratio: Double?, in canvasSize: CGSize, around rect: CGRect) -> CGRect {
        guard let ratio, ratio.isFinite, ratio > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return rect }
        let normalizedRatio = CGFloat(ratio) * canvasSize.height / canvasSize.width
        let center = CGPoint(x: min(0.99, max(0.01, rect.midX)), y: min(0.99, max(0.01, rect.midY)))
        let maximumWidth = 2 * min(center.x, 1 - center.x)
        let maximumHeight = 2 * min(center.y, 1 - center.y)
        let width = min(maximumWidth, maximumHeight * normalizedRatio)
        let height = width / normalizedRatio
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    static func dragging(_ rect: CGRect, handle: CropHandle, translation: CGSize,
                         canvasSize: CGSize, ratio: Double?) -> CGRect {
        if handle == .move {
            return CGRect(x: min(1 - rect.width, max(0, rect.minX + translation.width)),
                          y: min(1 - rect.height, max(0, rect.minY + translation.height)),
                          width: rect.width, height: rect.height)
        }
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
        let maximumWidth = left ? anchor.x : 1 - anchor.x
        let maximumHeight = top ? anchor.y : 1 - anchor.y
        var width = rect.width + (left ? -translation.width : translation.width)
        var height = rect.height + (top ? -translation.height : translation.height)
        if let ratio, ratio.isFinite, ratio > 0, canvasSize.width > 0, canvasSize.height > 0 {
            let normalizedRatio = CGFloat(ratio) * canvasSize.height / canvasSize.width
            if abs(translation.width) * canvasSize.width >= abs(translation.height) * canvasSize.height {
                height = width / normalizedRatio
            } else { width = height * normalizedRatio }
            let maximum = min(maximumWidth, maximumHeight * normalizedRatio)
            let minimum = min(maximum, max(0.01, 0.01 * normalizedRatio))
            width = min(maximum, max(minimum, width))
            height = width / normalizedRatio
        } else {
            width = min(maximumWidth, max(min(0.01, maximumWidth), width))
            height = min(maximumHeight, max(min(0.01, maximumHeight), height))
        }
        return CGRect(x: left ? anchor.x - width : anchor.x,
                      y: top ? anchor.y - height : anchor.y, width: width, height: height)
    }
}
