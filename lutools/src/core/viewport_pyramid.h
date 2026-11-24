#pragma once

#include <cstdint>
#include <vector>

namespace sony2fuji {

struct PyramidConfig {
    uint32_t fullWidth = 0;
    uint32_t fullHeight = 0;
    uint32_t tileSize = 1024;
    uint32_t overscanRing = 0;
    double zoomScale = 1.0;
    double baseScale = 1.0;
    double visibleX0 = 0.0;
    double visibleY0 = 0.0;
    double visibleX1 = 1.0;
    double visibleY1 = 1.0;
};

struct PyramidTile {
    int32_t level = 0;
    int32_t col = 0;
    int32_t row = 0;
    uint32_t maxOutputLongEdge = 0;
    double normX0 = 0.0;
    double normY0 = 0.0;
    double normX1 = 0.0;
    double normY1 = 0.0;
};

struct DetailCoverageQuery {
    uint32_t tilePixelWidth = 0;
    uint32_t tilePixelHeight = 0;
    uint32_t fullWidth = 0;
    uint32_t fullHeight = 0;
    uint32_t maxOutputLongEdge = 0;
    double tileNormX0 = 0.0;
    double tileNormY0 = 0.0;
    double tileNormX1 = 0.0;
    double tileNormY1 = 0.0;
    double visibleNormX0 = 0.0;
    double visibleNormY0 = 0.0;
    double visibleNormX1 = 0.0;
    double visibleNormY1 = 0.0;
    double requiredZoomScale = 0.0;
};

constexpr uint32_t kDefaultPyramidTileSize = 1024u;

int32_t pyramidLevel(double zoomScale, double baseScale) noexcept;

std::vector<PyramidTile> pyramidTiles(const PyramidConfig& config);

std::vector<PyramidTile> pyramidLevel0Grid(
    uint32_t fullWidth,
    uint32_t fullHeight,
    uint32_t tileSize = kDefaultPyramidTileSize
);

bool detailOverlayCovers(const DetailCoverageQuery& query) noexcept;

} // namespace sony2fuji
