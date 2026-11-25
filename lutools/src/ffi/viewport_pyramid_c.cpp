#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/viewport_pyramid.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

namespace {

sony2fuji_pyramid_tile_v1 toFfiTile(const sony2fuji::PyramidTile& src) noexcept {
    sony2fuji_pyramid_tile_v1 dst{};
    dst.level = src.level;
    dst.col = src.col;
    dst.row = src.row;
    dst.max_output_long_edge = src.maxOutputLongEdge;
    dst.norm_x0 = src.normX0;
    dst.norm_y0 = src.normY0;
    dst.norm_x1 = src.normX1;
    dst.norm_y1 = src.normY1;
    return dst;
}

sony2fuji_status writeTileVector(
    const std::vector<sony2fuji::PyramidTile>& tiles,
    sony2fuji_pyramid_tile_v1* out_tiles,
    uint32_t capacity,
    uint32_t* out_count
) noexcept {
    if (!out_count) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (tiles.size() > std::numeric_limits<uint32_t>::max()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t total = static_cast<uint32_t>(tiles.size());
    *out_count = total;
    if (!out_tiles) {
        return capacity == 0 ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (capacity < total) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    for (uint32_t i = 0; i < total; ++i) {
        out_tiles[i] = toFfiTile(tiles[i]);
    }
    return SONY2FUJI_STATUS_OK;
}

} // namespace

extern "C" {

sony2fuji_status sony2fuji_pyramid_level(
    double zoom_scale,
    double base_scale,
    int32_t* out_level
) {
    if (!out_level || !std::isfinite(zoom_scale) || !std::isfinite(base_scale)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_level = sony2fuji::pyramidLevel(zoom_scale, base_scale);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_pyramid_tiles(
    const sony2fuji_pyramid_config_v1* config,
    sony2fuji_pyramid_tile_v1* out_tiles,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) {
        *out_count = 0;
    }
    if (!config || !out_count ||
        config->version != SONY2FUJI_PYRAMID_CONFIG_V1_VERSION ||
        config->struct_size < sizeof(*config) ||
        config->full_width == 0 || config->full_height == 0 || config->tile_size == 0 ||
        !std::isfinite(config->zoom_scale) || !std::isfinite(config->base_scale) ||
        !std::isfinite(config->visible_x0) || !std::isfinite(config->visible_y0) ||
        !std::isfinite(config->visible_x1) || !std::isfinite(config->visible_y1) ||
        config->visible_x1 <= config->visible_x0 || config->visible_y1 <= config->visible_y0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::PyramidConfig coreConfig{};
        coreConfig.fullWidth = config->full_width;
        coreConfig.fullHeight = config->full_height;
        coreConfig.tileSize = config->tile_size;
        coreConfig.overscanRing = config->overscan_ring;
        coreConfig.zoomScale = config->zoom_scale;
        coreConfig.baseScale = config->base_scale;
        coreConfig.visibleX0 = config->visible_x0;
        coreConfig.visibleY0 = config->visible_y0;
        coreConfig.visibleX1 = config->visible_x1;
        coreConfig.visibleY1 = config->visible_y1;
        const auto tiles = sony2fuji::pyramidTiles(coreConfig);
        return writeTileVector(tiles, out_tiles, capacity, out_count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_pyramid_level0_grid(
    uint32_t full_width,
    uint32_t full_height,
    uint32_t tile_size,
    sony2fuji_pyramid_tile_v1* out_tiles,
    uint32_t capacity,
    uint32_t* out_count
) {
    if (out_count) {
        *out_count = 0;
    }
    if (!out_count || full_width == 0 || full_height == 0 || tile_size == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        const auto tiles = sony2fuji::pyramidLevel0Grid(full_width, full_height, tile_size);
        return writeTileVector(tiles, out_tiles, capacity, out_count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_detail_overlay_covers(
    const sony2fuji_detail_coverage_query_v1* query,
    int32_t* out_covers
) {
    if (out_covers) {
        *out_covers = 0;
    }
    if (!query || !out_covers ||
        query->version != SONY2FUJI_DETAIL_COVERAGE_QUERY_V1_VERSION ||
        query->struct_size < sizeof(*query) ||
        query->reserved != 0 ||
        !std::isfinite(query->tile_norm_x0) || !std::isfinite(query->tile_norm_y0) ||
        !std::isfinite(query->tile_norm_x1) || !std::isfinite(query->tile_norm_y1) ||
        !std::isfinite(query->visible_norm_x0) || !std::isfinite(query->visible_norm_y0) ||
        !std::isfinite(query->visible_norm_x1) || !std::isfinite(query->visible_norm_y1) ||
        !std::isfinite(query->required_zoom_scale)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::DetailCoverageQuery coreQuery{};
    coreQuery.tilePixelWidth = query->tile_pixel_width;
    coreQuery.tilePixelHeight = query->tile_pixel_height;
    coreQuery.fullWidth = query->full_width;
    coreQuery.fullHeight = query->full_height;
    coreQuery.maxOutputLongEdge = query->max_output_long_edge;
    coreQuery.tileNormX0 = query->tile_norm_x0;
    coreQuery.tileNormY0 = query->tile_norm_y0;
    coreQuery.tileNormX1 = query->tile_norm_x1;
    coreQuery.tileNormY1 = query->tile_norm_y1;
    coreQuery.visibleNormX0 = query->visible_norm_x0;
    coreQuery.visibleNormY0 = query->visible_norm_y0;
    coreQuery.visibleNormX1 = query->visible_norm_x1;
    coreQuery.visibleNormY1 = query->visible_norm_y1;
    coreQuery.requiredZoomScale = query->required_zoom_scale;
    *out_covers = sony2fuji::detailOverlayCovers(coreQuery) ? 1 : 0;
    return SONY2FUJI_STATUS_OK;
}

} // extern "C"
