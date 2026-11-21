import RawLabKit
import Foundation

extension HSLSettings {
    var nativeConfig: sony2fuji_hsl_config {
        var config = sony2fuji_hsl_config()
        config.version = UInt32(SONY2FUJI_HSL_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_hsl_config>.size)
        withUnsafeMutableBytes(of: &config.hue) { bytes in
            for (index, value) in hue.prefix(8).enumerated() { bytes.bindMemory(to: Float.self)[index] = Float(value) }
        }
        withUnsafeMutableBytes(of: &config.saturation) { bytes in
            for (index, value) in saturation.prefix(8).enumerated() { bytes.bindMemory(to: Float.self)[index] = Float(value) }
        }
        withUnsafeMutableBytes(of: &config.lightness) { bytes in
            for (index, value) in lightness.prefix(8).enumerated() { bytes.bindMemory(to: Float.self)[index] = Float(value) }
        }
        return config
    }
}
