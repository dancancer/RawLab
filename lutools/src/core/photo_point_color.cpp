#include "photo_point_color.h"
#include "core/parallel_pixels.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

namespace {

inline float wrapHue360(float h) {
    float r = std::fmod(h, 360.0f);
    if (r < 0.0f) r += 360.0f;
    if (r >= 360.0f) r -= 360.0f;
    return r;
}

inline float wrappedHueDiff(float target, float current) {
    float d = target - current;
    if (d > 180.0f) d -= 360.0f;
    if (d < -180.0f) d += 360.0f;
    return d;
}

inline float pointColorMask(float h, float s, float l, const PointColorSwatch& sw) {
    const float rangeScale = 0.25f + 1.50f * (sw.range * 0.01f);
    const float hueHalf = std::max(4.0f, (5.0f + 0.55f * sw.hueRange) * rangeScale);
    const float satHalf = std::max(0.05f, (0.08f + 0.44f * (sw.satRange * 0.01f)) * rangeScale);
    const float lumHalf = std::max(0.05f, (0.08f + 0.44f * (sw.lumRange * 0.01f)) * rangeScale);

    float dh = std::abs(h - sw.srcHue);
    if (dh > 180.0f) dh = 360.0f - dh;

    const float nh = std::min(1.0f, dh / hueHalf);
    const float ns = std::min(1.0f, std::abs(s - sw.srcSaturation) / satHalf);
    const float nl = std::min(1.0f, std::abs(l - sw.srcLuminance) / lumHalf);

    const float d = std::min(1.0f, std::sqrt(nh * nh + ns * ns + nl * nl));
    return 1.0f - d * d * (3.0f - 2.0f * d);
}

inline void applyPointColorShifts(
    float& h,
    float& s,
    float& l,
    float hueShift,
    float saturationShift,
    float luminanceShift,
    float mask
) {
    h = wrapHue360(h + hueShift * 0.6f * mask);
    if (saturationShift >= 0.0f) {
        const float k = (saturationShift * 0.01f) * 0.75f * mask;
        s = std::clamp(s + (1.0f - s) * k, 0.0f, 1.0f);
    } else {
        const float k = (saturationShift * 0.01f) * mask;
        s = std::clamp(s * (1.0f + k), 0.0f, 1.0f);
    }
    l = std::clamp(l + (luminanceShift * 0.01f) * 0.40f * mask, 0.0f, 1.0f);
}

} // namespace

bool PointColorSwatch::valid() const {
    if (!std::isfinite(srcHue) || srcHue < 0.0f || srcHue >= 360.0f) return false;
    for (float v : {srcSaturation, srcLuminance}) {
        if (!std::isfinite(v) || v < 0.0f || v > 1.0f) return false;
    }
    for (float v : {hueShift, saturationShift, luminanceShift, variance}) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    for (float v : {range, hueRange, satRange, lumRange}) {
        if (!std::isfinite(v) || v < 0.0f || v > 100.0f) return false;
    }
    return true;
}

bool PointColorOptions::valid() const {
    if (swatchCount > kPointColorMaxSwatches) return false;
    for (uint32_t i = 0; i < swatchCount; ++i) {
        if (!swatches[i].valid()) return false;
    }
    return true;
}

bool PointColorOptions::active() const {
    for (uint32_t i = 0; i < swatchCount; ++i) {
        if (swatches[i].active()) return true;
    }
    return false;
}

void pointColorRgbToHsb(float r, float g, float b, float& outHueDeg, float& outSat, float& outBright) {
    const float rf = std::clamp(r, 0.0f, 1.0f);
    const float gf = std::clamp(g, 0.0f, 1.0f);
    const float bf = std::clamp(b, 0.0f, 1.0f);
    const float maxC = std::max({rf, gf, bf});
    const float minC = std::min({rf, gf, bf});
    const float delta = maxC - minC;
    outBright = maxC;
    outSat = maxC <= 0.0f ? 0.0f : (delta / maxC);
    float hue = 0.0f;
    if (delta > 1e-6f) {
        float seg = 0.0f;
        if (maxC == rf) {
            seg = (gf - bf) / delta + (gf < bf ? 6.0f : 0.0f);
        } else if (maxC == gf) {
            seg = (bf - rf) / delta + 2.0f;
        } else {
            seg = (rf - gf) / delta + 4.0f;
        }
        hue = wrapHue360(seg * 60.0f);
    }
    outHueDeg = hue;
}

void pointColorHsbToRgb(float hueDeg, float saturation, float brightness, float outRgb[3]) {
    const float h = wrapHue360(hueDeg);
    const float s = std::clamp(saturation, 0.0f, 1.0f);
    const float v = std::clamp(brightness, 0.0f, 1.0f);
    const float c = v * s;
    const float hp = h / 60.0f;
    const float x = c * (1.0f - std::abs(std::fmod(hp, 2.0f) - 1.0f));
    const float m = v - c;
    const int sector = static_cast<int>(std::floor(hp)) % 6;
    float r1 = 0.0f;
    float g1 = 0.0f;
    float b1 = 0.0f;
    switch (sector) {
        case 0: r1 = c; g1 = x; b1 = 0.0f; break;
        case 1: r1 = x; g1 = c; b1 = 0.0f; break;
        case 2: r1 = 0.0f; g1 = c; b1 = x; break;
        case 3: r1 = 0.0f; g1 = x; b1 = c; break;
        case 4: r1 = x; g1 = 0.0f; b1 = c; break;
        default: r1 = c; g1 = 0.0f; b1 = x; break;
    }
    outRgb[0] = std::clamp(r1 + m, 0.0f, 1.0f);
    outRgb[1] = std::clamp(g1 + m, 0.0f, 1.0f);
    outRgb[2] = std::clamp(b1 + m, 0.0f, 1.0f);
}

bool pointColorPreviewSwatch(
    float srcHue,
    float srcSaturation,
    float srcLuminance,
    float hueShift,
    float saturationShift,
    float luminanceShift,
    float outSrcRgb[3],
    float outShiftedRgb[3]
) {
    if (!outSrcRgb || !outShiftedRgb) return false;
    if (!std::isfinite(srcHue) || srcHue < 0.0f || srcHue >= 360.0f ||
        !std::isfinite(srcSaturation) || srcSaturation < 0.0f || srcSaturation > 1.0f ||
        !std::isfinite(srcLuminance) || srcLuminance < 0.0f || srcLuminance > 1.0f ||
        !std::isfinite(hueShift) || hueShift < -100.0f || hueShift > 100.0f ||
        !std::isfinite(saturationShift) || saturationShift < -100.0f || saturationShift > 100.0f ||
        !std::isfinite(luminanceShift) || luminanceShift < -100.0f || luminanceShift > 100.0f) {
        return false;
    }
    pointColorHsbToRgb(srcHue, srcSaturation, srcLuminance, outSrcRgb);
    float h = srcHue;
    float s = srcSaturation;
    float l = srcLuminance;
    applyPointColorShifts(h, s, l, hueShift, saturationShift, luminanceShift, 1.0f);
    pointColorHsbToRgb(h, s, l, outShiftedRgb);
    return true;
}

RGB applyPointColorPixel(const RGB& pixel, const PointColorOptions& options) {
    if (!options.active()) return pixel;

    float h = 0.0f;
    float s = 0.0f;
    float l = 0.0f;
    pointColorRgbToHsb(pixel.r, pixel.g, pixel.b, h, s, l);
    bool modified = false;

    for (uint32_t i = 0; i < options.swatchCount; ++i) {
        const PointColorSwatch& sw = options.swatches[i];
        if (!sw.active()) continue;
        const float mask = pointColorMask(h, s, l, sw);
        if (mask <= 0.0f) continue;

        modified = true;
        if (sw.variance < 0.0f) {
            const float pull = std::clamp((-sw.variance * 0.01f) * mask, 0.0f, 1.0f);
            h = wrapHue360(h + pull * wrappedHueDiff(sw.srcHue, h));
            s = std::clamp(s + pull * (sw.srcSaturation - s), 0.0f, 1.0f);
            l = std::clamp(l + pull * (sw.srcLuminance - l), 0.0f, 1.0f);
        } else if (sw.variance > 0.0f) {
            const float push = (sw.variance * 0.01f) * mask * 0.75f;
            h = wrapHue360(h - push * wrappedHueDiff(sw.srcHue, h));
            s = std::clamp(s - push * (sw.srcSaturation - s), 0.0f, 1.0f);
            l = std::clamp(l - push * (sw.srcLuminance - l), 0.0f, 1.0f);
        }

        applyPointColorShifts(h, s, l, sw.hueShift, sw.saturationShift, sw.luminanceShift, mask);
    }

    if (!modified) return pixel;
    float rgb[3]{};
    pointColorHsbToRgb(h, s, l, rgb);
    return RGB(rgb[0], rgb[1], rgb[2]);
}

void applyPointColor(ImageData& image, const PointColorOptions& options) {
    if (!options.valid() || !options.active()) return;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applyPointColorPixel(image.pixels[i], options);
        }
    });
}

} // namespace sony2fuji
