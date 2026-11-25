import CoreGraphics
import Foundation
import RawLabKit

public enum ViewportNative {
    public static let defaultTileSize = 1024

    public static func pyramidLevel(zoomScale: CGFloat, baseScale: CGFloat) -> Int? {
        guard zoomScale.isFinite, baseScale.isFinite, zoomScale > 0, baseScale > 0 else {
            return nil
        }
        var level: Int32 = -1
        let status = sony2fuji_pyramid_level(Double(zoomScale), Double(baseScale), &level)
        guard status == SONY2FUJI_STATUS_OK, level >= 0 else {
            return nil
        }
        return Int(level)
    }

    public static func pyramidTiles(
        visibleRect: CGRect,
        fullNativeSize: CGSize,
        zoomScale: CGFloat,
        baseScale: CGFloat,
        tileSize: Int = defaultTileSize,
        overscanRing: Int = 0
    ) -> [PhotoDetailTileSpec] {
        guard tileSize > 0,
              overscanRing >= 0,
              fullNativeSize.width.isFinite, fullNativeSize.height.isFinite,
              fullNativeSize.width > 0, fullNativeSize.height > 0,
              visibleRect.minX.isFinite, visibleRect.minY.isFinite,
              visibleRect.maxX.isFinite, visibleRect.maxY.isFinite,
              visibleRect.width > 0, visibleRect.height > 0,
              zoomScale.isFinite, baseScale.isFinite else {
            return []
        }
        let fullW = Int(fullNativeSize.width.rounded())
        let fullH = Int(fullNativeSize.height.rounded())
        guard fullW > 0, fullH > 0 else { return [] }

        var config = sony2fuji_pyramid_config_v1()
        config.version = SONY2FUJI_PYRAMID_CONFIG_V1_VERSION
        config.struct_size = UInt32(MemoryLayout<sony2fuji_pyramid_config_v1>.size)
        config.full_width = UInt32(fullW)
        config.full_height = UInt32(fullH)
        config.tile_size = UInt32(tileSize)
        config.overscan_ring = UInt32(overscanRing)
        config.zoom_scale = Double(zoomScale)
        config.base_scale = Double(baseScale)
        config.visible_x0 = Double(visibleRect.minX)
        config.visible_y0 = Double(visibleRect.minY)
        config.visible_x1 = Double(visibleRect.maxX)
        config.visible_y1 = Double(visibleRect.maxY)

        var count: UInt32 = 0
        guard sony2fuji_pyramid_tiles(&config, nil, 0, &count) == SONY2FUJI_STATUS_OK, count > 0 else {
            return []
        }
        var buffer = Array(repeating: sony2fuji_pyramid_tile_v1(), count: Int(count))
        let status = buffer.withUnsafeMutableBufferPointer { ptr in
            sony2fuji_pyramid_tiles(&config, ptr.baseAddress, count, &count)
        }
        guard status == SONY2FUJI_STATUS_OK else { return [] }
        return buffer.prefix(Int(count)).map(makeSpec)
    }

    public static func pyramidLevel0Grid(
        fullNativeSize: CGSize,
        tileSize: Int = defaultTileSize
    ) -> [PhotoDetailTileSpec] {
        guard tileSize > 0,
              fullNativeSize.width.isFinite, fullNativeSize.height.isFinite,
              fullNativeSize.width > 0, fullNativeSize.height > 0 else {
            return []
        }
        let fullW = Int(fullNativeSize.width.rounded())
        let fullH = Int(fullNativeSize.height.rounded())
        guard fullW > 0, fullH > 0 else { return [] }

        var count: UInt32 = 0
        guard sony2fuji_pyramid_level0_grid(UInt32(fullW), UInt32(fullH), UInt32(tileSize), nil, 0, &count) == SONY2FUJI_STATUS_OK,
              count > 0 else {
            return []
        }
        var buffer = Array(repeating: sony2fuji_pyramid_tile_v1(), count: Int(count))
        let status = buffer.withUnsafeMutableBufferPointer { ptr in
            sony2fuji_pyramid_level0_grid(UInt32(fullW), UInt32(fullH), UInt32(tileSize), ptr.baseAddress, count, &count)
        }
        guard status == SONY2FUJI_STATUS_OK else { return [] }
        return buffer.prefix(Int(count)).map(makeSpec)
    }

    public static func detailOverlayCovers(
        _ overlay: PhotoDetailOverlay,
        visibleRect: CGRect,
        requiredZoomScale: CGFloat,
        maxOutputLongEdge: Int? = nil
    ) -> Bool {
        guard overlay.normalizedRect.width > 0,
              overlay.normalizedRect.height > 0,
              overlay.fullNativeSize.width > 0,
              overlay.fullNativeSize.height > 0,
              overlay.pixelSize.width > 0,
              overlay.pixelSize.height > 0,
              requiredZoomScale.isFinite else {
            return false
        }
        var query = sony2fuji_detail_coverage_query_v1()
        query.version = SONY2FUJI_DETAIL_COVERAGE_QUERY_V1_VERSION
        query.struct_size = UInt32(MemoryLayout<sony2fuji_detail_coverage_query_v1>.size)
        query.tile_pixel_width = UInt32(max(0, Int(overlay.pixelSize.width.rounded())))
        query.tile_pixel_height = UInt32(max(0, Int(overlay.pixelSize.height.rounded())))
        query.full_width = UInt32(max(0, Int(overlay.fullNativeSize.width.rounded())))
        query.full_height = UInt32(max(0, Int(overlay.fullNativeSize.height.rounded())))
        query.max_output_long_edge = UInt32(max(0, maxOutputLongEdge ?? 0))
        query.reserved = 0
        query.tile_norm_x0 = Double(overlay.normalizedRect.minX)
        query.tile_norm_y0 = Double(overlay.normalizedRect.minY)
        query.tile_norm_x1 = Double(overlay.normalizedRect.maxX)
        query.tile_norm_y1 = Double(overlay.normalizedRect.maxY)
        query.visible_norm_x0 = Double(visibleRect.minX)
        query.visible_norm_y0 = Double(visibleRect.minY)
        query.visible_norm_x1 = Double(visibleRect.maxX)
        query.visible_norm_y1 = Double(visibleRect.maxY)
        query.required_zoom_scale = Double(requiredZoomScale)

        var covers: Int32 = 0
        let status = sony2fuji_detail_overlay_covers(&query, &covers)
        return status == SONY2FUJI_STATUS_OK && covers != 0
    }

    public static func supportsFastFullResGpu(
        session: OpaquePointer,
        inputType: sony2fuji_input_type,
        inputWidth: UInt32,
        inputHeight: UInt32,
        maxPixels: UInt32,
        inputPath: String?,
        editStateJSON: String?
    ) -> Bool {
        var query = sony2fuji_fast_gpu_query_v1()
        query.version = SONY2FUJI_FAST_GPU_QUERY_V1_VERSION
        query.struct_size = UInt32(MemoryLayout<sony2fuji_fast_gpu_query_v1>.size)
        query.input_type = inputType
        query.input_width = inputWidth
        query.input_height = inputHeight
        query.max_pixels = maxPixels

        var supported: Int32 = 0
        let runWithJSON: (UnsafePointer<CChar>?) -> sony2fuji_status = { pathPtr in
            query.input_path = pathPtr
            if let editStateJSON {
                return editStateJSON.withCString { jsonPtr in
                    sony2fuji_session_supports_fast_full_res_gpu(session, &query, jsonPtr, &supported)
                }
            }
            return sony2fuji_session_supports_fast_full_res_gpu(session, &query, nil, &supported)
        }
        let status: sony2fuji_status
        if let inputPath {
            status = inputPath.withCString(runWithJSON)
        } else {
            status = runWithJSON(nil)
        }
        return status == SONY2FUJI_STATUS_OK && supported != 0
    }

    private static func makeSpec(_ tile: sony2fuji_pyramid_tile_v1) -> PhotoDetailTileSpec {
        PhotoDetailTileSpec(
            key: PhotoDetailTileKey(level: Int(tile.level), col: Int(tile.col), row: Int(tile.row)),
            normalizedRect: CGRect(
                x: CGFloat(tile.norm_x0),
                y: CGFloat(tile.norm_y0),
                width: CGFloat(tile.norm_x1 - tile.norm_x0),
                height: CGFloat(tile.norm_y1 - tile.norm_y0)
            ),
            maxOutputLongEdge: Int(tile.max_output_long_edge)
        )
    }
}
