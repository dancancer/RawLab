import RawLabKit
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

    var nativeV2Config: sony2fuji_color_grading_v2_config {
        var config = sony2fuji_color_grading_v2_config()
        config.version = UInt32(SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_color_grading_v2_config>.size)
        config.shadows_hue = shadows.nativeHue
        config.shadows_saturation = Float(shadows.saturation)
        config.shadows_luminance = Float(shadows.luminance)
        config.midtones_hue = midtones.nativeHue
        config.midtones_saturation = Float(midtones.saturation)
        config.midtones_luminance = Float(midtones.luminance)
        config.highlights_hue = highlights.nativeHue
        config.highlights_saturation = Float(highlights.saturation)
        config.highlights_luminance = Float(highlights.luminance)
        config.global_hue = global.nativeHue
        config.global_saturation = Float(global.saturation)
        config.global_luminance = Float(global.luminance)
        config.blending = Float(blending)
        config.balance = Float(balance)
        return config
    }
}
