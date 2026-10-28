import Foundation

extension ColorGradingWheel {
    // 合法 Double 接近 360 时可能舍入成 Float(360)，在 ABI 边界保留环回语义。
    var nativeHue: Float { Float(hue) == 360 ? 0 : Float(hue) }
}

extension ColorGradingSettings {
    var nativeConfig: sony2fuji_color_grading_config {
        var config = sony2fuji_color_grading_config()
        config.version = UInt32(SONY2FUJI_COLOR_GRADING_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_color_grading_config>.size)
        config.shadows_hue = shadows.nativeHue
        config.shadows_saturation = Float(shadows.saturation)
        config.midtones_hue = midtones.nativeHue
        config.midtones_saturation = Float(midtones.saturation)
        config.highlights_hue = highlights.nativeHue
        config.highlights_saturation = Float(highlights.saturation)
        return config
    }
}
