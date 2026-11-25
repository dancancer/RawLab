@_exported import CSony2Fuji
import RawLabKit
import Foundation

public extension AtmosphereSettings {
    var nativeConfig: sony2fuji_atmosphere_config {
        var config = sony2fuji_atmosphere_config()
        config.version = UInt32(SONY2FUJI_ATMOSPHERE_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_atmosphere_config>.size)
        config.clarity = Float(clarity / 100)
        config.dehaze = Float(dehaze / 100)
        return config
    }
}
