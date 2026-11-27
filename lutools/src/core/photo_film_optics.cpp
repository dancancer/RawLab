#include "photo_film_optics.h"
#include "photo_geometry.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace sony2fuji {
namespace {

inline float srgbToLin(float ch) {
    ch = std::max(ch, 0.0f);
    return ch <= 0.04045f ? (ch / 12.92f) : std::pow(std::max((ch + 0.055f) / 1.055f, 0.0f), 2.4f);
}

inline float linToSrgb(float ch) {
    ch = std::clamp(ch, 0.0f, 1.0f);
    return ch <= 0.0031308f ? (12.92f * ch) : (1.055f * std::pow(std::max(ch, 0.0f), 1.0f / 2.4f) - 0.055f);
}

inline RGB srgbToLin(const RGB& px) {
    return {srgbToLin(px.r), srgbToLin(px.g), srgbToLin(px.b)};
}

inline RGB linToSrgb(const RGB& px) {
    return {linToSrgb(px.r), linToSrgb(px.g), linToSrgb(px.b)};
}

inline float linLuminance(const RGB& px) {
    return std::max(0.0f, 0.2126f * px.r + 0.7152f * px.g + 0.0722f * px.b);
}

// thresholdNorm 来自 filmOpticsThresholdNorm()。
inline float highlightExcess(float sig, float thresholdNorm) {
    const float tn = thresholdNorm;
    const float linThresh = srgbToLin(tn);
    const float knee = std::min(0.06f, 0.5f * linThresh);
    if (sig <= linThresh - knee) return 0.0f;
    if (sig >= linThresh + knee || knee <= 1e-6f) return std::max(0.0f, sig - linThresh);
    const float rq = sig - (linThresh - knee);
    return (rq * rq) / (4.0f * knee);
}

void blurSeparable1Channel(
    const float* src,
    float* dst,
    int width,
    int height,
    float sigma,
    int radiusPx,
    const float* coreBlend = nullptr,
    float coreW = 0.40f,
    float tailW = 0.60f
) {
    const size_t total = static_cast<size_t>(width) * static_cast<size_t>(height);
    std::vector<float> tmp(total, 0.0f);
    std::vector<float> weights(static_cast<size_t>(2 * radiusPx + 1));
    const float invTwoSigSq = 0.5f / std::max(sigma * sigma, 0.01f);
    double wSum = 0.0;
    for (int d = -radiusPx; d <= radiusPx; ++d) {
        const float w = std::exp(-float(d * d) * invTwoSigSq);
        weights[static_cast<size_t>(d + radiusPx)] = w;
        wSum += w;
    }
    const float invWSum = 1.0f / std::max(float(wSum), 1e-6f);
    for (float& w : weights) w *= invWSum;

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const float* row = src + static_cast<size_t>(y) * width;
            float* outRow = tmp.data() + static_cast<size_t>(y) * width;
            for (int x = 0; x < width; ++x) {
                float acc = 0.0f;
                for (int d = -radiusPx; d <= radiusPx; ++d) {
                    const int sx = std::clamp(x + d, 0, width - 1);
                    acc += row[sx] * weights[static_cast<size_t>(d + radiusPx)];
                }
                outRow[x] = acc;
            }
        }
    });

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            float* outRow = dst + static_cast<size_t>(y) * width;
            const float* coreRow = coreBlend ? (coreBlend + static_cast<size_t>(y) * width) : nullptr;
            for (int x = 0; x < width; ++x) {
                float acc = 0.0f;
                for (int d = -radiusPx; d <= radiusPx; ++d) {
                    const int sy = std::clamp(y + d, 0, height - 1);
                    acc += tmp[static_cast<size_t>(sy) * width + x] * weights[static_cast<size_t>(d + radiusPx)];
                }
                outRow[x] = coreRow ? (coreRow[x] * coreW + acc * tailW) : acc;
            }
        }
    });
}

void blurSeparable3Channel(
    const float* src,
    float* dst,
    int width,
    int height,
    float sigma,
    int radiusPx,
    const float* coreBlend = nullptr,
    float coreW = 0.40f,
    float tailW = 0.60f
) {
    const size_t total = static_cast<size_t>(width) * static_cast<size_t>(height) * 3u;
    std::vector<float> tmp(total, 0.0f);
    std::vector<float> weights(static_cast<size_t>(2 * radiusPx + 1));
    const float invTwoSigSq = 0.5f / std::max(sigma * sigma, 0.01f);
    double wSum = 0.0;
    for (int d = -radiusPx; d <= radiusPx; ++d) {
        const float w = std::exp(-float(d * d) * invTwoSigSq);
        weights[static_cast<size_t>(d + radiusPx)] = w;
        wSum += w;
    }
    const float invWSum = 1.0f / std::max(float(wSum), 1e-6f);
    for (float& w : weights) w *= invWSum;

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const float* row = src + static_cast<size_t>(y) * width * 3u;
            float* outRow = tmp.data() + static_cast<size_t>(y) * width * 3u;
            for (int x = 0; x < width; ++x) {
                float r = 0.0f, g = 0.0f, b = 0.0f;
                for (int d = -radiusPx; d <= radiusPx; ++d) {
                    const int sx = std::clamp(x + d, 0, width - 1);
                    const float w = weights[static_cast<size_t>(d + radiusPx)];
                    r += row[sx * 3 + 0] * w;
                    g += row[sx * 3 + 1] * w;
                    b += row[sx * 3 + 2] * w;
                }
                outRow[x * 3 + 0] = r;
                outRow[x * 3 + 1] = g;
                outRow[x * 3 + 2] = b;
            }
        }
    });

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            float* outRow = dst + static_cast<size_t>(y) * width * 3u;
            const float* coreRow = coreBlend ? (coreBlend + static_cast<size_t>(y) * width * 3u) : nullptr;
            for (int x = 0; x < width; ++x) {
                float r = 0.0f, g = 0.0f, b = 0.0f;
                for (int d = -radiusPx; d <= radiusPx; ++d) {
                    const int sy = std::clamp(y + d, 0, height - 1);
                    const float w = weights[static_cast<size_t>(d + radiusPx)];
                    const size_t idx = (static_cast<size_t>(sy) * width + x) * 3u;
                    r += tmp[idx + 0] * w;
                    g += tmp[idx + 1] * w;
                    b += tmp[idx + 2] * w;
                }
                if (coreRow) {
                    outRow[x * 3 + 0] = coreRow[x * 3 + 0] * coreW + r * tailW;
                    outRow[x * 3 + 1] = coreRow[x * 3 + 1] * coreW + g * tailW;
                    outRow[x * 3 + 2] = coreRow[x * 3 + 2] * coreW + b * tailW;
                } else {
                    outRow[x * 3 + 0] = r;
                    outRow[x * 3 + 1] = g;
                    outRow[x * 3 + 2] = b;
                }
            }
        }
    });
}

inline float sampleProxy1(const float* buf, int width, int height, float fx, float fy) {
    const float cx = std::clamp(fx, 0.0f, float(width - 1));
    const float cy = std::clamp(fy, 0.0f, float(height - 1));
    const int x0 = int(std::floor(cx));
    const int y0 = int(std::floor(cy));
    const int x1 = std::min(width - 1, x0 + 1);
    const int y1 = std::min(height - 1, y0 + 1);
    const float tx = cx - float(x0);
    const float ty = cy - float(y0);
    const float v00 = buf[size_t(y0) * width + x0];
    const float v10 = buf[size_t(y0) * width + x1];
    const float v01 = buf[size_t(y1) * width + x0];
    const float v11 = buf[size_t(y1) * width + x1];
    return (v00 * (1.0f - tx) + v10 * tx) * (1.0f - ty) + (v01 * (1.0f - tx) + v11 * tx) * ty;
}

inline RGB sampleProxy3(const float* buf, int width, int height, float fx, float fy) {
    const float cx = std::clamp(fx, 0.0f, float(width - 1));
    const float cy = std::clamp(fy, 0.0f, float(height - 1));
    const int x0 = int(std::floor(cx));
    const int y0 = int(std::floor(cy));
    const int x1 = std::min(width - 1, x0 + 1);
    const int y1 = std::min(height - 1, y0 + 1);
    const float tx = cx - float(x0);
    const float ty = cy - float(y0);
    const size_t i00 = (size_t(y0) * width + x0) * 3u;
    const size_t i10 = (size_t(y0) * width + x1) * 3u;
    const size_t i01 = (size_t(y1) * width + x0) * 3u;
    const size_t i11 = (size_t(y1) * width + x1) * 3u;
    const float w00 = (1.0f - tx) * (1.0f - ty);
    const float w10 = tx * (1.0f - ty);
    const float w01 = (1.0f - tx) * ty;
    const float w11 = tx * ty;
    return {
        buf[i00 + 0] * w00 + buf[i10 + 0] * w10 + buf[i01 + 0] * w01 + buf[i11 + 0] * w11,
        buf[i00 + 1] * w00 + buf[i10 + 1] * w10 + buf[i01 + 1] * w01 + buf[i11 + 1] * w11,
        buf[i00 + 2] * w00 + buf[i10 + 2] * w10 + buf[i01 + 2] * w01 + buf[i11 + 2] * w11
    };
}

// hueNorm 来自 filmOpticsHueNorm()。
inline RGB halationTint(float hueNorm) {
    const float h = hueNorm;
    const float gW = h < 0.0f ? (0.24f + 0.16f * h) : (0.24f + 0.20f * h);
    const float bW = 0.03f + 0.005f * (h + 1.0f);
    return {1.0f, gW, bW};
}

} // namespace

FilmOpticsField buildFilmOpticsField(
    const ImageData& guideSrgb,
    int sourceWidth,
    int sourceHeight,
    const FilmOpticsOptions& options
) {
    FilmOpticsField field;
    if (!options.valid() || !options.active() ||
        guideSrgb.width <= 0 || guideSrgb.height <= 0 ||
        guideSrgb.pixels.size() != static_cast<size_t>(guideSrgb.width) * static_cast<size_t>(guideSrgb.height) ||
        sourceWidth <= 0 || sourceHeight <= 0) {
        return field;
    }

    const int guideW = guideSrgb.width;
    const int guideH = guideSrgb.height;
    const int maxGuideLongEdge = std::max(guideW, guideH);

    if (options.halationAmount > 0.0f) {
        const float halationThresholdNorm = filmOpticsThresholdNorm(options.halationThreshold);
        const auto geom = computeFilmOpticsProxyGeometry(
            sourceWidth, sourceHeight, options.halationRadius, /*isBloom=*/false,
            sourceWidth == guideW ? 1024 : maxGuideLongEdge);
        field.halWidth = geom.proxyWidth;
        field.halHeight = geom.proxyHeight;
        const size_t n = static_cast<size_t>(geom.proxyWidth) * static_cast<size_t>(geom.proxyHeight);
        std::vector<float> excess(n, 0.0f);
        parallelRowRanges(geom.proxyHeight, geom.proxyWidth, [&](int firstRow, int lastRow) {
            for (int py = firstRow; py < lastRow; ++py) {
                const int iy0 = std::max(0, static_cast<int>((static_cast<int64_t>(py) * guideH) / geom.proxyHeight));
                const int iy1 = std::min(guideH, std::max(iy0 + 1, static_cast<int>(
                    (static_cast<int64_t>(py + 1) * guideH + geom.proxyHeight - 1) / geom.proxyHeight)));
                const int stepY = std::max(1, (iy1 - iy0 + 15) / 16);
                for (int px = 0; px < geom.proxyWidth; ++px) {
                    const int ix0 = std::max(0, static_cast<int>((static_cast<int64_t>(px) * guideW) / geom.proxyWidth));
                    const int ix1 = std::min(guideW, std::max(ix0 + 1, static_cast<int>(
                        (static_cast<int64_t>(px + 1) * guideW + geom.proxyWidth - 1) / geom.proxyWidth)));
                    const int stepX = std::max(1, (ix1 - ix0 + 15) / 16);
                    float sum = 0.0f;
                    int count = 0;
                    for (int sy = iy0; sy < iy1; sy += stepY) {
                        const RGB* row = guideSrgb.pixels.data() + static_cast<size_t>(sy) * guideW;
                        for (int sx = ix0; sx < ix1; sx += stepX) {
                            const RGB lin = srgbToLin(row[sx]);
                            const float lum = linLuminance(lin);
                            const float maxCh = std::max(lin.r, std::max(lin.g, lin.b));
                            const float sig = std::max(lum, maxCh * 0.55f);
                            sum += highlightExcess(sig, halationThresholdNorm);
                            ++count;
                        }
                    }
                    excess[static_cast<size_t>(py) * geom.proxyWidth + px] = count > 0 ? (sum / float(count)) : 0.0f;
                }
            }
        });
        std::vector<float> core(n, 0.0f);
        field.halGlow.assign(n, 0.0f);
        blurSeparable1Channel(excess.data(), core.data(), geom.proxyWidth, geom.proxyHeight, geom.coreSigma, geom.coreRadiusPx);
        blurSeparable1Channel(core.data(), field.halGlow.data(), geom.proxyWidth, geom.proxyHeight,
                              geom.tailSigma, geom.tailRadiusPx, core.data(), 0.40f, 0.60f);
    }

    if (options.bloomAmount > 0.0f) {
        const float bloomThresholdNorm = filmOpticsThresholdNorm(options.bloomThreshold);
        const auto geom = computeFilmOpticsProxyGeometry(
            sourceWidth, sourceHeight, options.bloomRadius, /*isBloom=*/true,
            sourceWidth == guideW ? 1024 : maxGuideLongEdge);
        field.bloomWidth = geom.proxyWidth;
        field.bloomHeight = geom.proxyHeight;
        const size_t n = static_cast<size_t>(geom.proxyWidth) * static_cast<size_t>(geom.proxyHeight) * 3u;
        std::vector<float> excess(n, 0.0f);
        parallelRowRanges(geom.proxyHeight, geom.proxyWidth, [&](int firstRow, int lastRow) {
            for (int py = firstRow; py < lastRow; ++py) {
                const int iy0 = std::max(0, static_cast<int>((static_cast<int64_t>(py) * guideH) / geom.proxyHeight));
                const int iy1 = std::min(guideH, std::max(iy0 + 1, static_cast<int>(
                    (static_cast<int64_t>(py + 1) * guideH + geom.proxyHeight - 1) / geom.proxyHeight)));
                const int stepY = std::max(1, (iy1 - iy0 + 15) / 16);
                for (int px = 0; px < geom.proxyWidth; ++px) {
                    const int ix0 = std::max(0, static_cast<int>((static_cast<int64_t>(px) * guideW) / geom.proxyWidth));
                    const int ix1 = std::min(guideW, std::max(ix0 + 1, static_cast<int>(
                        (static_cast<int64_t>(px + 1) * guideW + geom.proxyWidth - 1) / geom.proxyWidth)));
                    const int stepX = std::max(1, (ix1 - ix0 + 15) / 16);
                    float sr = 0.0f, sg = 0.0f, sb = 0.0f;
                    int count = 0;
                    for (int sy = iy0; sy < iy1; sy += stepY) {
                        const RGB* row = guideSrgb.pixels.data() + static_cast<size_t>(sy) * guideW;
                        for (int sx = ix0; sx < ix1; sx += stepX) {
                            const RGB lin = srgbToLin(row[sx]);
                            const float lum = linLuminance(lin);
                            const float ex = highlightExcess(lum, bloomThresholdNorm);
                            const float ratio = lum > 1e-6f ? (ex / lum) : 0.0f;
                            sr += lin.r * ratio;
                            sg += lin.g * ratio;
                            sb += lin.b * ratio;
                            ++count;
                        }
                    }
                    const float inv = count > 0 ? (1.0f / float(count)) : 0.0f;
                    const size_t idx = (static_cast<size_t>(py) * geom.proxyWidth + px) * 3u;
                    excess[idx + 0] = sr * inv;
                    excess[idx + 1] = sg * inv;
                    excess[idx + 2] = sb * inv;
                }
            }
        });
        std::vector<float> core(n, 0.0f);
        field.bloomGlow.assign(n, 0.0f);
        blurSeparable3Channel(excess.data(), core.data(), geom.proxyWidth, geom.proxyHeight, geom.coreSigma, geom.coreRadiusPx);
        blurSeparable3Channel(core.data(), field.bloomGlow.data(), geom.proxyWidth, geom.proxyHeight,
                              geom.tailSigma, geom.tailRadiusPx, core.data(), 0.40f, 0.60f);
    }

    return field;
}

void applyFilmOpticsWithField(
    ImageData& image,
    const FilmOpticsField& field,
    const FilmOpticsOptions& options,
    const SubRectMap& roiMap
) {
    if (!options.valid() || !options.active() || field.empty() ||
        image.width <= 0 || image.height <= 0 ||
        image.pixels.size() != static_cast<size_t>(image.width) * static_cast<size_t>(image.height)) {
        return;
    }

    const int W = image.width;
    const int H = image.height;
    const bool useRoi = roiMap.active();
    const double fullW = useRoi ? double(roiMap.fullWidth) : double(W);
    const double fullH = useRoi ? double(roiMap.fullHeight) : double(H);
    const bool hasHal = options.halationAmount > 0.0f && field.halWidth > 0 && field.halHeight > 0 && !field.halGlow.empty();
    const bool hasBloom = options.bloomAmount > 0.0f && field.bloomWidth > 0 && field.bloomHeight > 0 && !field.bloomGlow.empty();
    const RGB halTint = halationTint(filmOpticsHueNorm(options.halationHue));
    const float halGain = filmOpticsAmountNorm(options.halationAmount) * 1.15f;
    const float bloomGain = filmOpticsAmountNorm(options.bloomAmount) * 1.20f;

    parallelRowRanges(H, W, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            RGB* row = image.pixels.data() + static_cast<size_t>(y) * W;
            const double gy = useRoi ? (roiMap.sourceY0 + (double(y) + 0.5) * roiMap.sourceSpanY / double(H)) : (double(y) + 0.5);
            for (int x = 0; x < W; ++x) {
                const double gx = useRoi ? (roiMap.sourceX0 + (double(x) + 0.5) * roiMap.sourceSpanX / double(W)) : (double(x) + 0.5);
                float halVal = 0.0f;
                if (hasHal) {
                    const float hx = float(gx * (double(field.halWidth) / fullW) - 0.5);
                    const float hy = float(gy * (double(field.halHeight) / fullH) - 0.5);
                    halVal = sampleProxy1(field.halGlow.data(), field.halWidth, field.halHeight, hx, hy);
                }
                RGB bloomVal{0.0f, 0.0f, 0.0f};
                if (hasBloom) {
                    const float bx = float(gx * (double(field.bloomWidth) / fullW) - 0.5);
                    const float by = float(gy * (double(field.bloomHeight) / fullH) - 0.5);
                    bloomVal = sampleProxy3(field.bloomGlow.data(), field.bloomWidth, field.bloomHeight, bx, by);
                }
                const bool activeHal = hasHal && halVal > 0.0f;
                const bool activeBloom = hasBloom && (bloomVal.r > 0.0f || bloomVal.g > 0.0f || bloomVal.b > 0.0f);
                if (!activeHal && !activeBloom) {
                    continue;
                }
                const RGB baseLin = srgbToLin(row[x]);
                RGB acc = baseLin;
                if (activeHal) {
                    const float s = halVal * halGain;
                    acc.r += (halTint.r * s) / (1.0f + 1.5f * std::max(baseLin.r, 0.0f));
                    acc.g += (halTint.g * s) / (1.0f + 1.5f * std::max(baseLin.g, 0.0f));
                    acc.b += (halTint.b * s) / (1.0f + 1.5f * std::max(baseLin.b, 0.0f));
                }
                if (activeBloom) {
                    acc.r += (std::max(bloomVal.r, 0.0f) * bloomGain) / (1.0f + 1.2f * std::max(baseLin.r, 0.0f));
                    acc.g += (std::max(bloomVal.g, 0.0f) * bloomGain) / (1.0f + 1.2f * std::max(baseLin.g, 0.0f));
                    acc.b += (std::max(bloomVal.b, 0.0f) * bloomGain) / (1.0f + 1.2f * std::max(baseLin.b, 0.0f));
                }
                row[x] = linToSrgb(acc);
            }
        }
    });
}

void applyFilmOptics(ImageData& image, const FilmOpticsOptions& options) {
    if (!options.valid() || !options.active() || image.width <= 0 || image.height <= 0) return;
    const FilmOpticsField field = buildFilmOpticsField(image, image.width, image.height, options);
    applyFilmOpticsWithField(image, field, options, {});
}

} // namespace sony2fuji
