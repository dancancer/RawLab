#include "photo_sharpen_v2.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace sony2fuji {
namespace {

inline float smoothstep01(float x) {
    x = std::clamp(x, 0.0f, 1.0f);
    return x * x * (3.0f - 2.0f * x);
}

inline float lumaAt(const RGB& p) {
    return 0.2126f * p.r + 0.7152f * p.g + 0.0722f * p.b;
}

void buildGaussianWeights(float sigma, int maxRadius, int& outRadius, std::vector<float>& outWeights) {
    outRadius = std::clamp(static_cast<int>(std::ceil(3.0f * sigma)), 1, maxRadius);
    outWeights.resize(static_cast<size_t>(2 * outRadius + 1));
    const float invTwoSigmaSq = 0.5f / (sigma * sigma);
    float sum = 0.0f;
    for (int k = -outRadius; k <= outRadius; ++k) {
        const float w = std::exp(-float(k * k) * invTwoSigmaSq);
        outWeights[static_cast<size_t>(k + outRadius)] = w;
        sum += w;
    }
    for (float& w : outWeights) w /= sum;
}

std::vector<float> separableGaussian(const std::vector<float>& src, int w, int h, float sigma, int maxRadius) {
    int r = 0;
    std::vector<float> weights;
    buildGaussianWeights(sigma, maxRadius, r, weights);
    const size_t count = static_cast<size_t>(w) * static_cast<size_t>(h);
    std::vector<float> horiz(count, 0.0f), out(count, 0.0f);

    parallelRowRanges(h, w, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t rowBase = static_cast<size_t>(y) * static_cast<size_t>(w);
            for (int x = 0; x < w; ++x) {
                float sum = 0.0f;
                for (int k = -r; k <= r; ++k) {
                    const int sx = std::clamp(x + k, 0, w - 1);
                    sum += src[rowBase + static_cast<size_t>(sx)] * weights[static_cast<size_t>(k + r)];
                }
                horiz[rowBase + static_cast<size_t>(x)] = sum;
            }
        }
    });

    parallelRowRanges(h, w, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t rowBase = static_cast<size_t>(y) * static_cast<size_t>(w);
            for (int x = 0; x < w; ++x) {
                float sum = 0.0f;
                for (int k = -r; k <= r; ++k) {
                    const int sy = std::clamp(y + k, 0, h - 1);
                    sum += horiz[static_cast<size_t>(sy) * static_cast<size_t>(w) + static_cast<size_t>(x)] *
                           weights[static_cast<size_t>(k + r)];
                }
                out[rowBase + static_cast<size_t>(x)] = sum;
            }
        }
    });
    return out;
}

} // namespace

bool SharpenV2Options::valid() const {
    if (!std::isfinite(radius) || radius < 0.5f || radius > 3.0f) return false;
    if (!std::isfinite(detail) || detail < 0.0f || detail > 100.0f) return false;
    if (!std::isfinite(masking) || masking < 0.0f || masking > 100.0f) return false;
    return true;
}

SharpenMaskRange sharpenMaskRange(float masking) {
    SharpenMaskRange range;
    if (std::isfinite(masking) && masking > 0.0f) {
        const float m = std::clamp(masking / 100.0f, 0.0f, 1.0f);
        range.low = 0.06f * m;
        range.span = 0.05f * m;
    }
    return range;
}

SharpenV2Coefficients sharpenV2Coefficients(float amount, const SharpenV2Options& options) {
    SharpenV2Coefficients c;
    const float strength = std::clamp(amount, 0.0f, 2.0f);
    const float detailNorm = std::clamp(options.detail / 100.0f, 0.0f, 1.0f);
    c.coring = 0.012f * (1.0f - detailNorm);
    c.detailGain = strength * (0.7f + 1.2f * detailNorm);
    const SharpenMaskRange mask = sharpenMaskRange(options.masking);
    c.maskLow = mask.low;
    c.maskSpan = mask.span;
    return c;
}

void computeSharpenEdgeMask(
    const std::vector<float>& luma,
    int width,
    int height,
    float radius,
    float masking,
    std::vector<float>& outMask
) {
    outMask.clear();
    if (width <= 0 || height <= 0) return;
    const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (luma.size() != count) return;
    outMask.resize(count, 1.0f);

    if (!std::isfinite(masking) || masking <= 0.0f) return;
    const SharpenMaskRange maskRange = sharpenMaskRange(masking);
    const float clampedRadius = std::clamp(std::isfinite(radius) ? radius : 1.0f, 0.5f, 3.0f);

    // 3x3 normalized Sobel gradient magnitude on display luminance.
    std::vector<float> sobelMag(count, 0.0f);
    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const int y0 = std::max(0, y - 1);
            const int y2 = std::min(height - 1, y + 1);
            const size_t r0 = static_cast<size_t>(y0) * static_cast<size_t>(width);
            const size_t r1 = static_cast<size_t>(y) * static_cast<size_t>(width);
            const size_t r2 = static_cast<size_t>(y2) * static_cast<size_t>(width);
            for (int x = 0; x < width; ++x) {
                const int x0 = std::max(0, x - 1);
                const int x2 = std::min(width - 1, x + 1);
                const float gx = ((luma[r0 + x2] + 2.0f * luma[r1 + x2] + luma[r2 + x2]) -
                                  (luma[r0 + x0] + 2.0f * luma[r1 + x0] + luma[r2 + x0])) * 0.125f;
                const float gy = ((luma[r2 + x0] + 2.0f * luma[r2 + x] + luma[r2 + x2]) -
                                  (luma[r0 + x0] + 2.0f * luma[r0 + x] + luma[r0 + x2])) * 0.125f;
                sobelMag[r1 + static_cast<size_t>(x)] = std::hypot(gx, gy);
            }
        }
    });

    // Separable 3x3 maximum preserves thin 1px edges/eyelashes on exact center pixels.
    std::vector<float> maxH(count, 0.0f), dilated(count, 0.0f);
    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t row = static_cast<size_t>(y) * static_cast<size_t>(width);
            for (int x = 0; x < width; ++x) {
                const int x0 = std::max(0, x - 1);
                const int x2 = std::min(width - 1, x + 1);
                maxH[row + static_cast<size_t>(x)] = std::max({sobelMag[row + x0], sobelMag[row + x], sobelMag[row + x2]});
            }
        }
    });
    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const size_t r0 = static_cast<size_t>(std::max(0, y - 1)) * static_cast<size_t>(width);
            const size_t r1 = static_cast<size_t>(y) * static_cast<size_t>(width);
            const size_t r2 = static_cast<size_t>(std::min(height - 1, y + 1)) * static_cast<size_t>(width);
            for (int x = 0; x < width; ++x) {
                dilated[r1 + static_cast<size_t>(x)] = std::max({maxH[r0 + x], maxH[r1 + x], maxH[r2 + x]});
            }
        }
    });

    const std::vector<float> edgeField = separableGaussian(dilated, width, height, 0.5f * clampedRadius, 5);
    const float low = maskRange.low;
    const float span = maskRange.span;

    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            outMask[i] = smoothstep01((edgeField[i] - low) / span);
        }
    });
}

void applySharpenV2(ImageData& image, float amount, const SharpenV2Options& options) {
    // Exact zero-value bypass when luminanceV2 is off or amount == 0.
    if (!options.valid() || !options.active() || !std::isfinite(amount) || amount <= 0.0f) return;
    const int w = image.width;
    const int h = image.height;
    if (w <= 0 || h <= 0) return;
    const size_t count = static_cast<size_t>(w) * static_cast<size_t>(h);
    if (image.pixels.size() != count) return;

    const float radius = std::clamp(options.radius, 0.5f, 3.0f);
    const SharpenV2Coefficients coefficients = sharpenV2Coefficients(amount, options);

    std::vector<float> luma(count, 0.0f);
    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto& p = image.pixels[i];
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) continue;
            luma[i] = lumaAt(RGB(std::clamp(p.r, 0.0f, 1.0f),
                                 std::clamp(p.g, 0.0f, 1.0f),
                                 std::clamp(p.b, 0.0f, 1.0f)));
        }
    });

    const std::vector<float> blur = separableGaussian(luma, w, h, radius, 9);
    std::vector<float> edgeMask;
    computeSharpenEdgeMask(luma, w, h, radius, options.masking, edgeMask);

    const float coring = coefficients.coring;
    const float detailGain = coefficients.detailGain;

    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& p = image.pixels[i];
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) continue;
            const float mask = edgeMask[i];
            if (mask <= 0.0f) continue;

            const float diff = luma[i] - blur[i];
            const float detailWeight = coring <= 1e-4f
                ? 1.0f
                : smoothstep01(std::abs(diff) / coring);
            float delta = std::clamp(mask * detailWeight * detailGain * diff, -0.35f, 0.35f);
            if (delta == 0.0f) continue;

            // Clamp delta within neutral channel headroom when in-gamut to prevent chromatic clipping halos.
            const float minC = std::min({p.r, p.g, p.b});
            const float maxC = std::max({p.r, p.g, p.b});
            if (minC >= 0.0f && maxC <= 1.0f) {
                delta = std::clamp(delta, -minC, 1.0f - maxC);
            }
            p.r = std::clamp(p.r + delta, 0.0f, 1.0f);
            p.g = std::clamp(p.g + delta, 0.0f, 1.0f);
            p.b = std::clamp(p.b + delta, 0.0f, 1.0f);
        }
    });
}

} // namespace sony2fuji
