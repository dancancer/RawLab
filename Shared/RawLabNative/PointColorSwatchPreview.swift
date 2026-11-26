@_exported import CSony2Fuji
@_exported import RawLabInspectionNative
import Foundation
import RawLabKit

public struct PointColorSwatchPreview: Equatable, Sendable {
    public let srcRed: Float
    public let srcGreen: Float
    public let srcBlue: Float
    public let shiftedRed: Float
    public let shiftedGreen: Float
    public let shiftedBlue: Float

    public init?(swatch: PointColorSwatch) {
        var src = [Float](repeating: 0, count: 3)
        var shifted = [Float](repeating: 0, count: 3)
        let status = sony2fuji_point_color_preview_swatch(
            Float(swatch.srcHue),
            Float(swatch.srcSaturation),
            Float(swatch.srcLuminance),
            Float(swatch.hueShift),
            Float(swatch.saturationShift),
            Float(swatch.luminanceShift),
            &src,
            &shifted
        )
        guard status == SONY2FUJI_STATUS_OK else { return nil }
        self.srcRed = src[0]
        self.srcGreen = src[1]
        self.srcBlue = src[2]
        self.shiftedRed = shifted[0]
        self.shiftedGreen = shifted[1]
        self.shiftedBlue = shifted[2]
    }
}

public extension PointColorSwatch {
    static func fromSample(_ sample: InspectionColorSample) -> PointColorSwatch {
        let clampedHue = sample.hueDeg.isFinite ? max(0, min(359.999, sample.hueDeg)) : 0
        let clampedSat = sample.saturationPct.isFinite ? max(0, min(1, sample.saturationPct / 100.0)) : 0
        let clampedLum = sample.brightnessPct.isFinite ? max(0, min(1, sample.brightnessPct / 100.0)) : 0
        return PointColorSwatch(srcHue: clampedHue, srcSaturation: clampedSat, srcLuminance: clampedLum)
    }
}
