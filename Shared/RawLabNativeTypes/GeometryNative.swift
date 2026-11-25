@_exported import CSony2Fuji
import RawLabKit
import Foundation

public extension GeometrySettings {
    var nativeConfig: sony2fuji_geometry_config {
        var config = sony2fuji_geometry_config()
        config.version = UInt32(SONY2FUJI_GEOMETRY_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_geometry_config>.size)
        config.crop_x = Float(cropX)
        config.crop_y = Float(cropY)
        config.crop_width = Float(cropWidth)
        config.crop_height = Float(cropHeight)
        config.quarter_turns = Int32(quarterTurns)
        config.flip_horizontal = flipHorizontal ? 1 : 0
        config.flip_vertical = flipVertical ? 1 : 0
        config.straighten_degrees = Float(straightenDegrees)
        return config
    }

    var nativePerspectiveConfig: sony2fuji_perspective_config {
        var config = sony2fuji_perspective_config()
        config.version = UInt32(SONY2FUJI_PERSPECTIVE_CONFIG_VERSION)
        config.struct_size = UInt32(MemoryLayout<sony2fuji_perspective_config>.size)
        config.horizontal = Float(perspectiveHorizontal)
        config.vertical = Float(perspectiveVertical)
        return config
    }
}
