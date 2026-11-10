import Foundation

extension ToneCurveShape {
    var nativeConfig: sony2fuji_tone_curve_config {
        var config = sony2fuji_tone_curve_config()
        config.version = UInt32(SONY2FUJI_TONE_CURVE_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_tone_curve_config>.size)
        config.mode = mode == .custom ? SONY2FUJI_CURVE_CUSTOM : SONY2FUJI_CURVE_LEGACY
        config.count = UInt32(points.count)
        withUnsafeMutableBytes(of: &config.points) { bytes in
            let values = bytes.bindMemory(to: sony2fuji_curve_point.self)
            for (index, point) in points.prefix(33).enumerated() {
                values[index] = sony2fuji_curve_point(x: point.x, y: point.y)
            }
        }
        return config
    }
}

extension ToneCurveSettings {
    var nativeConfig: sony2fuji_tone_curve_config { master.nativeConfig }
    var nativeSetConfig: sony2fuji_tone_curve_set_config {
        var config = sony2fuji_tone_curve_set_config()
        config.version = UInt32(SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_tone_curve_set_config>.size)
        withUnsafeMutableBytes(of: &config.curves) { bytes in
            let curves = bytes.bindMemory(to: sony2fuji_tone_curve_config.self)
            for (index, channel) in ToneCurveChannel.allCases.enumerated() { curves[index] = shape(channel).nativeConfig }
        }
        return config
    }
}
