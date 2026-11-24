#include "core/viewport_pyramid.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_set>

namespace sony2fuji {
namespace {

uint64_t tileKeyHash(int32_t level, int32_t col, int32_t row) noexcept {
    return (static_cast<uint64_t>(static_cast<uint32_t>(level)) << 48) ^
           (static_cast<uint64_t>(static_cast<uint32_t>(col)) << 24) ^
           static_cast<uint64_t>(static_cast<uint32_t>(row));
}

bool makeTileSpec(
    int32_t level,
    int32_t col,
    int32_t row,
    uint64_t nativeSpan,
    double levelScale,
    uint32_t tileSize,
    uint32_t fullW,
    uint32_t fullH,
    PyramidTile& out
) noexcept {
    const uint64_t px0 = static_cast<uint64_t>(col) * nativeSpan;
    const uint64_t px1 = std::min<uint64_t>(fullW, px0 + nativeSpan);
    const uint64_t py0 = static_cast<uint64_t>(row) * nativeSpan;
    const uint64_t py1 = std::min<uint64_t>(fullH, py0 + nativeSpan);
    if (px1 <= px0 || py1 <= py0) {
        return false;
    }
    out.level = level;
    out.col = col;
    out.row = row;
    out.normX0 = static_cast<double>(px0) / static_cast<double>(fullW);
    out.normY0 = static_cast<double>(py0) / static_cast<double>(fullH);
    out.normX1 = static_cast<double>(px1) / static_cast<double>(fullW);
    out.normY1 = static_cast<double>(py1) / static_cast<double>(fullH);
    const uint64_t longSpan = std::max(px1 - px0, py1 - py0);
    const long roundedEdge = std::lround(static_cast<double>(longSpan) * levelScale);
    const long clampedEdge = std::min<long>(
        static_cast<long>(tileSize),
        std::max<long>(1L, roundedEdge)
    );
    out.maxOutputLongEdge = static_cast<uint32_t>(clampedEdge);
    return true;
}

void sortTilesByDistance(std::vector<PyramidTile>& tiles, double targetX, double targetY) {
    std::stable_sort(tiles.begin(), tiles.end(), [targetX, targetY](const PyramidTile& a, const PyramidTile& b) {
        const double midAX = 0.5 * (a.normX0 + a.normX1);
        const double midAY = 0.5 * (a.normY0 + a.normY1);
        const double midBX = 0.5 * (b.normX0 + b.normX1);
        const double midBY = 0.5 * (b.normY0 + b.normY1);
        const double dxA = midAX - targetX;
        const double dyA = midAY - targetY;
        const double dxB = midBX - targetX;
        const double dyB = midBY - targetY;
        return (dxA * dxA + dyA * dyA) < (dxB * dxB + dyB * dyB);
    });
}

} // namespace

int32_t pyramidLevel(double zoomScale, double baseScale) noexcept {
    if (!std::isfinite(zoomScale) || !std::isfinite(baseScale) ||
        zoomScale <= 0.0 || baseScale <= 0.0 ||
        std::min(1.0, zoomScale) <= baseScale * 1.05) {
        return -1;
    }
    const double threshold = baseScale * 1.05;
    const double skipLevel1Threshold = baseScale * 1.35;
    if (zoomScale >= 0.65) {
        return 0;
    }
    if (zoomScale >= 0.325 && 0.5 > skipLevel1Threshold) {
        return 1;
    }
    if (0.25 > threshold) {
        return 2;
    }
    if (0.5 > skipLevel1Threshold) {
        return 1;
    }
    return 0;
}

std::vector<PyramidTile> pyramidTiles(const PyramidConfig& config) {
    const int32_t level = pyramidLevel(config.zoomScale, config.baseScale);
    if (level < 0 || config.tileSize == 0 || config.fullWidth == 0 || config.fullHeight == 0) {
        return {};
    }
    if (!std::isfinite(config.visibleX0) || !std::isfinite(config.visibleY0) ||
        !std::isfinite(config.visibleX1) || !std::isfinite(config.visibleY1) ||
        config.visibleX1 <= config.visibleX0 || config.visibleY1 <= config.visibleY0) {
        return {};
    }
    const int32_t fullW = static_cast<int32_t>(std::min<uint32_t>(config.fullWidth, static_cast<uint32_t>(std::numeric_limits<int32_t>::max())));
    const int32_t fullH = static_cast<int32_t>(std::min<uint32_t>(config.fullHeight, static_cast<uint32_t>(std::numeric_limits<int32_t>::max())));
    const double levelScale = 1.0 / static_cast<double>(1u << static_cast<uint32_t>(level));
    const uint64_t nativeSpan = static_cast<uint64_t>(config.tileSize) << static_cast<uint32_t>(level);
    if (nativeSpan == 0) {
        return {};
    }

    const double fullWD = static_cast<double>(fullW);
    const double fullHD = static_cast<double>(fullH);
    const int64_t vx0 = std::max<int64_t>(0, std::min<int64_t>(fullW - 1, static_cast<int64_t>(std::floor(config.visibleX0 * fullWD))));
    const int64_t vy0 = std::max<int64_t>(0, std::min<int64_t>(fullH - 1, static_cast<int64_t>(std::floor(config.visibleY0 * fullHD))));
    const int64_t vx1 = std::max<int64_t>(vx0 + 1, std::min<int64_t>(fullW, static_cast<int64_t>(std::ceil(config.visibleX1 * fullWD))));
    const int64_t vy1 = std::max<int64_t>(vy0 + 1, std::min<int64_t>(fullH, static_cast<int64_t>(std::ceil(config.visibleY1 * fullHD))));

    const int32_t maxCol = static_cast<int32_t>((static_cast<uint64_t>(fullW) - 1u) / nativeSpan);
    const int32_t maxRow = static_cast<int32_t>((static_cast<uint64_t>(fullH) - 1u) / nativeSpan);
    const int32_t colMin = std::max<int32_t>(0, static_cast<int32_t>(static_cast<uint64_t>(vx0) / nativeSpan));
    const int32_t colMax = std::min<int32_t>(maxCol, std::max<int32_t>(0, static_cast<int32_t>(static_cast<uint64_t>(vx1 - 1) / nativeSpan)));
    const int32_t rowMin = std::max<int32_t>(0, static_cast<int32_t>(static_cast<uint64_t>(vy0) / nativeSpan));
    const int32_t rowMax = std::min<int32_t>(maxRow, std::max<int32_t>(0, static_cast<int32_t>(static_cast<uint64_t>(vy1 - 1) / nativeSpan)));

    const double targetX = 0.5 * (config.visibleX0 + config.visibleX1);
    const double targetY = 0.5 * (config.visibleY0 + config.visibleY1);

    std::vector<PyramidTile> visibleSpecs;
    visibleSpecs.reserve(static_cast<size_t>(colMax - colMin + 1) * static_cast<size_t>(rowMax - rowMin + 1));
    for (int32_t row = rowMin; row <= rowMax; ++row) {
        for (int32_t col = colMin; col <= colMax; ++col) {
            PyramidTile spec;
            if (makeTileSpec(level, col, row, nativeSpan, levelScale, config.tileSize,
                             static_cast<uint32_t>(fullW), static_cast<uint32_t>(fullH), spec)) {
                visibleSpecs.push_back(spec);
            }
        }
    }
    sortTilesByDistance(visibleSpecs, targetX, targetY);

    if (config.overscanRing == 0) {
        return visibleSpecs;
    }

    std::unordered_set<uint64_t> seen;
    seen.reserve(visibleSpecs.size() * 2u + 1u);
    for (const auto& spec : visibleSpecs) {
        seen.insert(tileKeyHash(spec.level, spec.col, spec.row));
    }
    const int32_t ring = static_cast<int32_t>(std::min<uint32_t>(
        config.overscanRing, static_cast<uint32_t>(std::max(maxCol, maxRow) + 1)));
    const int32_t oColMin = std::max<int32_t>(0, colMin - ring);
    const int32_t oColMax = std::min<int32_t>(maxCol, colMax + ring);
    const int32_t oRowMin = std::max<int32_t>(0, rowMin - ring);
    const int32_t oRowMax = std::min<int32_t>(maxRow, rowMax + ring);

    std::vector<PyramidTile> overscanSpecs;
    for (int32_t row = oRowMin; row <= oRowMax; ++row) {
        for (int32_t col = oColMin; col <= oColMax; ++col) {
            if (seen.find(tileKeyHash(level, col, row)) != seen.end()) {
                continue;
            }
            PyramidTile spec;
            if (makeTileSpec(level, col, row, nativeSpan, levelScale, config.tileSize,
                             static_cast<uint32_t>(fullW), static_cast<uint32_t>(fullH), spec)) {
                overscanSpecs.push_back(spec);
            }
        }
    }
    sortTilesByDistance(overscanSpecs, targetX, targetY);

    visibleSpecs.insert(visibleSpecs.end(), overscanSpecs.begin(), overscanSpecs.end());
    return visibleSpecs;
}

std::vector<PyramidTile> pyramidLevel0Grid(uint32_t fullWidth, uint32_t fullHeight, uint32_t tileSize) {
    if (tileSize == 0 || fullWidth == 0 || fullHeight == 0) {
        return {};
    }
    const uint32_t fullW = std::min<uint32_t>(fullWidth, static_cast<uint32_t>(std::numeric_limits<int32_t>::max()));
    const uint32_t fullH = std::min<uint32_t>(fullHeight, static_cast<uint32_t>(std::numeric_limits<int32_t>::max()));
    const int32_t maxCol = static_cast<int32_t>((fullW - 1u) / tileSize);
    const int32_t maxRow = static_cast<int32_t>((fullH - 1u) / tileSize);
    std::vector<PyramidTile> specs;
    specs.reserve(static_cast<size_t>(maxCol + 1) * static_cast<size_t>(maxRow + 1));
    for (int32_t row = 0; row <= maxRow; ++row) {
        for (int32_t col = 0; col <= maxCol; ++col) {
            PyramidTile spec;
            if (makeTileSpec(0, col, row, static_cast<uint64_t>(tileSize), 1.0, tileSize, fullW, fullH, spec)) {
                specs.push_back(spec);
            }
        }
    }
    sortTilesByDistance(specs, 0.5, 0.5);
    return specs;
}

bool detailOverlayCovers(const DetailCoverageQuery& q) noexcept {
    constexpr double kTolerance = 0.0005;
    if (!std::isfinite(q.tileNormX0) || !std::isfinite(q.tileNormY0) ||
        !std::isfinite(q.tileNormX1) || !std::isfinite(q.tileNormY1) ||
        !std::isfinite(q.visibleNormX0) || !std::isfinite(q.visibleNormY0) ||
        !std::isfinite(q.visibleNormX1) || !std::isfinite(q.visibleNormY1) ||
        !std::isfinite(q.requiredZoomScale)) {
        return false;
    }
    if (q.tileNormX0 > q.visibleNormX0 + kTolerance ||
        q.tileNormY0 > q.visibleNormY0 + kTolerance ||
        q.tileNormX1 < q.visibleNormX1 - kTolerance ||
        q.tileNormY1 < q.visibleNormY1 - kTolerance) {
        return false;
    }
    const double tileNormW = q.tileNormX1 - q.tileNormX0;
    const double tileNormH = q.tileNormY1 - q.tileNormY0;
    if (tileNormW <= 0.0 || tileNormH <= 0.0 ||
        q.tilePixelWidth == 0 || q.tilePixelHeight == 0 ||
        q.fullWidth == 0 || q.fullHeight == 0) {
        return false;
    }
    const double nativeW = tileNormW * static_cast<double>(q.fullWidth);
    const double nativeH = tileNormH * static_cast<double>(q.fullHeight);
    const double tileDensity = static_cast<double>(q.tilePixelWidth) / nativeW;
    const double maxAchievable = q.maxOutputLongEdge > 0
        ? std::min(1.0, static_cast<double>(q.maxOutputLongEdge) / std::max(1.0, std::max(nativeW, nativeH)))
        : 1.0;
    const double neededDensity = std::min(1.0, std::min(q.requiredZoomScale, maxAchievable));
    return tileDensity >= neededDensity * 0.9;
}

} // namespace sony2fuji
