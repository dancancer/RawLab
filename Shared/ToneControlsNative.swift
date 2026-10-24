import Foundation

extension ToneControlsSettings {
    var nativeConfig: sony2fuji_tone_controls_config {
        var config = sony2fuji_tone_controls_config()
        config.version = UInt32(SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_tone_controls_config>.size)
        config.black_point = Float(blackPoint / 100)
        config.white_point = Float(whitePoint / 100)
        config.vibrance = Float(vibrance / 100)
        return config
    }
}
