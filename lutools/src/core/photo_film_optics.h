#pragma once

#include "sony2fuji/common.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace sony2fuji {

struct SubRectMap;

struct FilmOpticsOptions {
    float halationAmount = 0.0f;     // [0, 100]
    float halationThreshold = 75.0f; // [0, 100]
    float halationRadius = 35.0f;    // [0, 100]
    float halationHue = 0.0f;        // [-100, 100]
    float bloomAmount = 0.0f;        // [0, 100]
    float bloomThreshold = 70.0f;    // [0, 100]
    float bloomRadius = 40.0f;       // [0, 100]

    bool valid() const {
        auto in0100 = [](float v) { return std::isfinite(v) && v >= 0.0f && v <= 100.0f; };
        return in0100(halationAmount) && in0100(halationThreshold) && in0100(halationRadius) &&
               in0100(bloomAmount) && in0100(bloomThreshold) && in0100(bloomRadius) &&
               std::isfinite(halationHue) && halationHue >= -100.0f && halationHue <= 100.0f;
    }
    bool active() const { return halationAmount > 0.0f || bloomAmount > 0.0f; }
    bool halationIsDefault() const {
        return halationAmount == 0.0f && halationThreshold == 75.0f &&
               halationRadius == 35.0f && halationHue == 0.0f;
    }
    bool bloomIsDefault() const {
        return bloomAmount == 0.0f && bloomThreshold == 70.0f && bloomRadius == 40.0f;
    }
    bool isDefault() const { return halationIsDefault() && bloomIsDefault(); }

    bool operator==(const FilmOpticsOptions& other) const {
        return halationAmount == other.halationAmount && halationThreshold == other.halationThreshold &&
               halationRadius == other.halationRadius && halationHue == other.halationHue &&
               bloomAmount == other.bloomAmount && bloomThreshold == other.bloomThreshold &&
               bloomRadius == other.bloomRadius;
    }
};

// 阈值、色相滑块换算成着色器直接读取的值。CPU 参考路径和三个 GPU 后端都调用这两个函数，
// 着色器不再对 uniform 做“先缩放再夹紧”：在托管 macOS x86_64 runner 的虚拟化 Intel GPU
// （Apple Paravirtualized Graphics Device）上观测到这类表达式被错误折叠（#695）。
inline float filmOpticsThresholdNorm(float thresholdPct) {
    return std::clamp(thresholdPct / 100.0f, 0.0f, 1.0f) * 0.96f;
}

inline float filmOpticsHueNorm(float huePct) {
    return std::clamp(huePct / 100.0f, -1.0f, 1.0f);
}

struct FilmOpticsProxyGeometry {
    int proxyWidth = 1;
    int proxyHeight = 1;
    float proxySigma = 1.0f;
    float coreSigma = 0.55f;
    float tailSigma = 0.835f;
    int coreRadiusPx = 1;
    int tailRadiusPx = 1;
};

inline FilmOpticsProxyGeometry computeFilmOpticsProxyGeometry(
    int sourceWidth,
    int sourceHeight,
    float radiusParam,
    bool isBloom,
    int maxProxyLongEdge = 1024
) {
    FilmOpticsProxyGeometry g;
    if (sourceWidth <= 0 || sourceHeight <= 0) return g;
    const float r = std::clamp(radiusParam, 0.0f, 100.0f) / 100.0f;
    const float diag = std::hypot(float(sourceWidth), float(sourceHeight));
    const float sigmaNorm = isBloom ? (0.0040f + 0.0400f * r) : (0.0020f + 0.0280f * r);
    const float sigmaFull = std::max(0.5f, sigmaNorm * diag);
    const float longEdge = float(std::max(sourceWidth, sourceHeight));
    const float scale = std::min({1.0f, 4.5f / sigmaFull, float(std::max(1, maxProxyLongEdge)) / longEdge});
    g.proxyWidth = std::clamp(int(std::floor(float(sourceWidth) * scale + 0.5f)), 1, sourceWidth);
    g.proxyHeight = std::clamp(int(std::floor(float(sourceHeight) * scale + 0.5f)), 1, sourceHeight);
    const float actualScale = float(g.proxyWidth) / float(sourceWidth);
    g.proxySigma = std::max(0.35f, sigmaFull * actualScale);
    g.coreSigma = std::max(0.35f, 0.55f * g.proxySigma);
    g.tailSigma = std::max(0.35f, 0.835f * g.proxySigma);
    g.coreRadiusPx = std::clamp(int(std::ceil(3.5f * g.coreSigma)), 1, 24);
    g.tailRadiusPx = std::clamp(int(std::ceil(3.5f * g.tailSigma)), 1, 24);
    return g;
}

struct FilmOpticsField {
    int halWidth = 0;
    int halHeight = 0;
    std::vector<float> halGlow;
    int bloomWidth = 0;
    int bloomHeight = 0;
    std::vector<float> bloomGlow; // interleaved RGB (3 floats per proxy texel)

    bool empty() const { return halGlow.empty() && bloomGlow.empty(); }
};

FilmOpticsField buildFilmOpticsField(
    const ImageData& guideSrgb,
    int sourceWidth,
    int sourceHeight,
    const FilmOpticsOptions& options
);

void applyFilmOpticsWithField(
    ImageData& image,
    const FilmOpticsField& field,
    const FilmOpticsOptions& options,
    const SubRectMap& roiMap
);

void applyFilmOptics(ImageData& image, const FilmOpticsOptions& options);

} // namespace sony2fuji
