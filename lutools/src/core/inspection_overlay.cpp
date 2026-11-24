#include "core/inspection_overlay.h"

#include "core/parallel_pixels.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <limits>

namespace sony2fuji {
namespace {

inline uint8_t toByte(double value) noexcept {
    const long long rounded = std::llround(value * 255.0);
    return static_cast<uint8_t>(std::clamp<long long>(rounded, 0, 255));
}

inline void rgbToHsb(double rf, double gf, double bf, double& outHueDeg, double& outSat, double& outBright) noexcept {
    const double maxC = std::max({rf, gf, bf});
    const double minC = std::min({rf, gf, bf});
    const double delta = maxC - minC;
    outBright = maxC;
    outSat = maxC <= 0.0 ? 0.0 : (delta / maxC);
    double hue = 0.0;
    if (delta > 1e-6) {
        double seg = 0.0;
        if (maxC == rf) {
            seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0);
        } else if (maxC == gf) {
            seg = (bf - rf) / delta + 2.0;
        } else {
            seg = (rf - gf) / delta + 4.0;
        }
        hue = seg * 60.0;
        if (hue < 0.0) hue += 360.0;
        if (hue >= 360.0) hue -= 360.0;
    }
    outHueDeg = hue;
}

inline void hsbToRgb(double hueDeg, double saturation, double brightness, double& outR, double& outG, double& outB) noexcept {
    double h = std::fmod(hueDeg, 360.0);
    if (h < 0.0) h += 360.0;
    const double s = std::clamp(saturation, 0.0, 1.0);
    const double v = std::clamp(brightness, 0.0, 1.0);
    const double c = v * s;
    const double hp = h / 60.0;
    const double x = c * (1.0 - std::abs(std::fmod(hp, 2.0) - 1.0));
    const double m = v - c;
    const int sector = static_cast<int>(std::floor(hp)) % 6;
    double r1 = 0.0;
    double g1 = 0.0;
    double b1 = 0.0;
    switch (sector) {
        case 0: r1 = c; g1 = x; b1 = 0.0; break;
        case 1: r1 = x; g1 = c; b1 = 0.0; break;
        case 2: r1 = 0.0; g1 = c; b1 = x; break;
        case 3: r1 = 0.0; g1 = x; b1 = c; break;
        case 4: r1 = x; g1 = 0.0; b1 = c; break;
        default: r1 = c; g1 = 0.0; b1 = x; break;
    }
    outR = std::clamp(r1 + m, 0.0, 1.0);
    outG = std::clamp(g1 + m, 0.0, 1.0);
    outB = std::clamp(b1 + m, 0.0, 1.0);
}

inline bool validInspectionBufferBounds(
    const void* data,
    size_t sizeBytes,
    uint32_t width,
    uint32_t height,
    uint32_t strideBytes,
    size_t bytesPerPixel
) noexcept {
    if (!data || width == 0 || height == 0 ||
        width > static_cast<uint32_t>(INT_MAX) ||
        height > static_cast<uint32_t>(INT_MAX) ||
        width > UINT32_MAX / 8u ||
        static_cast<uint64_t>(width) * height > UINT32_MAX) {
        return false;
    }
    const uint64_t rowBytes = static_cast<uint64_t>(width) * bytesPerPixel;
    if (rowBytes > static_cast<uint64_t>(strideBytes)) {
        return false;
    }
    const uint64_t requiredBytes =
        static_cast<uint64_t>(strideBytes) * (height - 1u) + rowBytes;
    return requiredBytes <= sizeBytes;
}

} // namespace

void computeInspectionSampleFromRgb(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_sample& out
) noexcept {
    const double rf = static_cast<double>(r) / 255.0;
    const double gf = static_cast<double>(g) / 255.0;
    const double bf = static_cast<double>(b) / 255.0;
    double hueDeg = 0.0;
    double sat = 0.0;
    double bright = 0.0;
    rgbToHsb(rf, gf, bf, hueDeg, sat, bright);

    out.version = SONY2FUJI_INSPECTION_SAMPLE_VERSION;
    out.struct_size = sizeof(sony2fuji_inspection_sample);
    out.r = r;
    out.g = g;
    out.b = b;
    out.reserved0 = 0;
    out.reserved1 = 0;
    out.hue_deg = hueDeg;
    out.saturation_pct = sat * 100.0;
    out.brightness_pct = bright * 100.0;
    out.luminance = std::clamp((0.2126 * static_cast<double>(r) +
                                0.7152 * static_cast<double>(g) +
                                0.0722 * static_cast<double>(b)) / 255.0,
                               0.0,
                               1.0);
}

RenderStatus sampleInspectionPatch(
    const PixelBufferView& view,
    double normX,
    double normY,
    uint32_t radiusPx,
    sony2fuji_inspection_sample& out
) noexcept {
    if (!std::isfinite(normX) || !std::isfinite(normY)) {
        return RenderStatus::InvalidArgument;
    }
    size_t bpp = 0;
    size_t rIdx = 0;
    size_t gIdx = 1;
    size_t bIdx = 2;
    switch (view.format) {
        case PixelBufferFormat::RGB8:
            bpp = 3;
            break;
        case PixelBufferFormat::RGBA8:
            bpp = 4;
            break;
        case PixelBufferFormat::BGRA8:
            bpp = 4;
            rIdx = 2;
            bIdx = 0;
            break;
        default:
            return RenderStatus::Unsupported;
    }
    if (!validInspectionBufferBounds(view.data, view.sizeBytes, view.width, view.height, view.strideBytes, bpp)) {
        return RenderStatus::InvalidArgument;
    }

    const double nx = std::clamp(normX, 0.0, 1.0);
    const double ny = std::clamp(normY, 0.0, 1.0);
    const int64_t w = static_cast<int64_t>(view.width);
    const int64_t h = static_cast<int64_t>(view.height);
    const int64_t cx = w == 1 ? 0 : std::clamp<int64_t>(std::llround(nx * static_cast<double>(w - 1)), 0, w - 1);
    const int64_t cy = h == 1 ? 0 : std::clamp<int64_t>(std::llround(ny * static_cast<double>(h - 1)), 0, h - 1);
    const int64_t rad = static_cast<int64_t>(std::min<uint32_t>(radiusPx, std::max(view.width, view.height)));
    const int64_t x0 = std::max<int64_t>(0, cx - rad);
    const int64_t x1 = std::min<int64_t>(w - 1, cx + rad);
    const int64_t y0 = std::max<int64_t>(0, cy - rad);
    const int64_t y1 = std::min<int64_t>(h - 1, cy + rad);

    const auto* base = static_cast<const uint8_t*>(view.data);
    uint64_t sumR = 0;
    uint64_t sumG = 0;
    uint64_t sumB = 0;
    uint64_t count = 0;
    for (int64_t y = y0; y <= y1; ++y) {
        const uint8_t* row = base + static_cast<size_t>(y) * view.strideBytes;
        for (int64_t x = x0; x <= x1; ++x) {
            const size_t off = static_cast<size_t>(x) * bpp;
            sumR += row[off + rIdx];
            sumG += row[off + gIdx];
            sumB += row[off + bIdx];
            ++count;
        }
    }
    if (count == 0) {
        return RenderStatus::InvalidArgument;
    }

    const uint8_t avgR = static_cast<uint8_t>(std::clamp<long long>(
        std::llround(static_cast<double>(sumR) / static_cast<double>(count)), 0, 255));
    const uint8_t avgG = static_cast<uint8_t>(std::clamp<long long>(
        std::llround(static_cast<double>(sumG) / static_cast<double>(count)), 0, 255));
    const uint8_t avgB = static_cast<uint8_t>(std::clamp<long long>(
        std::llround(static_cast<double>(sumB) / static_cast<double>(count)), 0, 255));
    computeInspectionSampleFromRgb(avgR, avgG, avgB, out);
    return RenderStatus::Ok;
}

void applyInspectionOverlayPixel(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_overlay_mode mode,
    uint8_t& outR,
    uint8_t& outG,
    uint8_t& outB
) noexcept {
    switch (mode) {
        case SONY2FUJI_INSPECTION_OVERLAY_NONE:
            outR = r;
            outG = g;
            outB = b;
            return;
        case SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50:
            outR = 128;
            outG = 128;
            outB = 128;
            return;
        case SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE: {
            const double rf = static_cast<double>(r) / 255.0;
            const double gf = static_cast<double>(g) / 255.0;
            const double bf = static_cast<double>(b) / 255.0;
            const double y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
            const double t = std::clamp((y - 0.5) * 2.4 + 0.5, 0.0, 1.0);
            const double v = t * t * (3.0 - 2.0 * t);
            const uint8_t out = toByte(v);
            outR = out;
            outG = out;
            outB = out;
            return;
        }
        case SONY2FUJI_INSPECTION_OVERLAY_WARM_COOL_BW: {
            const double rf = static_cast<double>(r) / 255.0;
            const double gf = static_cast<double>(g) / 255.0;
            const double bf = static_cast<double>(b) / 255.0;
            const double y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
            const double warmth = (rf - bf) + 0.35 * (gf - bf);
            const double v = std::clamp(y + 0.55 * warmth, 0.0, 1.0);
            const uint8_t out = toByte(v);
            outR = out;
            outG = out;
            outB = out;
            return;
        }
        case SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP: {
            const double rf = static_cast<double>(r) / 255.0;
            const double gf = static_cast<double>(g) / 255.0;
            const double bf = static_cast<double>(b) / 255.0;
            const double maxC = std::max({rf, gf, bf});
            const double minC = std::min({rf, gf, bf});
            const double delta = maxC - minC;
            const double bright = maxC;
            const double sat = maxC <= 0.0 ? 0.0 : (delta / maxC);
            const double y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
            const double baseVal = 0.28 * y;

            double or_ = baseVal;
            double og_ = baseVal;
            double ob_ = baseVal;
            if (minC >= 0.996) {
                or_ = 1.0;
                og_ = 0.25;
                ob_ = 0.25;
            } else if (maxC >= 0.996 && minC < 0.96) {
                or_ = 1.0;
                og_ = 0.10;
                ob_ = 0.55;
            } else if (sat > 0.85 && bright > 0.35) {
                const double sev = std::clamp(((sat - 0.85) / 0.15) * 0.7 + ((bright - 0.35) / 0.65) * 0.3, 0.0, 1.0);
                if (sev < 0.5) {
                    const double u = sev * 2.0;
                    or_ = 1.0;
                    og_ = 0.90 + (0.45 - 0.90) * u;
                    ob_ = 0.0;
                } else {
                    const double u = (sev - 0.5) * 2.0;
                    or_ = 1.0;
                    og_ = 0.45 + (0.08 - 0.45) * u;
                    ob_ = 0.12 * u;
                }
            } else if (sat > 0.75 && bright > 0.35) {
                const double t = std::clamp((sat - 0.75) / 0.10, 0.0, 1.0) * 0.65;
                or_ = baseVal + (1.0 - baseVal) * t;
                og_ = baseVal + (0.72 - baseVal) * t;
                ob_ = baseVal + (0.12 - baseVal) * t;
            }
            outR = toByte(or_);
            outG = toByte(og_);
            outB = toByte(ob_);
            return;
        }
        case SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION: {
            const double rf = static_cast<double>(r) / 255.0;
            const double gf = static_cast<double>(g) / 255.0;
            const double bf = static_cast<double>(b) / 255.0;
            double hue = 0.0;
            double sat = 0.0;
            double bright = 0.0;
            rgbToHsb(rf, gf, bf, hue, sat, bright);
            if (hue >= 0.0 && hue <= 50.0 && sat >= 0.05 && bright >= 0.08) {
                double stretchedHue = 0.0;
                if (hue <= 22.0) {
                    stretchedHue = std::fmod(330.0 + 65.0 * (hue / 22.0), 360.0);
                } else {
                    stretchedHue = 35.0 + 115.0 * ((hue - 22.0) / 28.0);
                }
                const double sPrime = std::clamp(std::max(0.55, sat * 1.8), 0.0, 1.0);
                const double bPrime = std::clamp(0.35 + 0.65 * bright, 0.0, 1.0);
                double nr = 0.0;
                double ng = 0.0;
                double nb = 0.0;
                hsbToRgb(stretchedHue, sPrime, bPrime, nr, ng, nb);
                outR = toByte(nr);
                outG = toByte(ng);
                outB = toByte(nb);
            } else {
                const double y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
                const uint8_t muted = toByte(0.35 * y);
                outR = muted;
                outG = muted;
                outB = muted;
            }
            return;
        }
        default:
            outR = r;
            outG = g;
            outB = b;
            return;
    }
}

RenderStatus renderInspectionOverlay(
    const PixelBufferView& src,
    sony2fuji_inspection_overlay_mode mode,
    const MutablePixelBufferView& dst
) {
    if (mode < SONY2FUJI_INSPECTION_OVERLAY_NONE ||
        mode > SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50) {
        return RenderStatus::InvalidArgument;
    }
    if (src.format != PixelBufferFormat::RGBA8 && src.format != PixelBufferFormat::BGRA8) {
        return RenderStatus::Unsupported;
    }
    if (dst.format != src.format || src.width != dst.width || src.height != dst.height) {
        return RenderStatus::InvalidArgument;
    }
    if (!validInspectionBufferBounds(src.data, src.sizeBytes, src.width, src.height, src.strideBytes, 4u) ||
        !validInspectionBufferBounds(dst.data, dst.sizeBytes, dst.width, dst.height, dst.strideBytes, 4u)) {
        return RenderStatus::InvalidArgument;
    }
    if (src.data == dst.data) {
        return RenderStatus::InvalidArgument;
    }
    const size_t srcSpan = static_cast<size_t>(src.strideBytes) * (src.height - 1u) + static_cast<size_t>(src.width) * 4u;
    const size_t dstSpan = static_cast<size_t>(dst.strideBytes) * (dst.height - 1u) + static_cast<size_t>(dst.width) * 4u;
    const auto srcStart = reinterpret_cast<uintptr_t>(src.data);
    const auto dstStart = reinterpret_cast<uintptr_t>(dst.data);
    if (srcStart > std::numeric_limits<uintptr_t>::max() - srcSpan ||
        dstStart > std::numeric_limits<uintptr_t>::max() - dstSpan) {
        return RenderStatus::InvalidArgument;
    }
    const uintptr_t srcEnd = srcStart + srcSpan;
    const uintptr_t dstEnd = dstStart + dstSpan;
    if (srcStart < dstEnd && dstStart < srcEnd) {
        return RenderStatus::InvalidArgument;
    }

    const bool bgra = src.format == PixelBufferFormat::BGRA8;
    const auto* srcBase = static_cast<const uint8_t*>(src.data);
    auto* dstBase = static_cast<uint8_t*>(dst.data);
    const int width = static_cast<int>(src.width);
    const int height = static_cast<int>(src.height);

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const uint8_t* sRow = srcBase + static_cast<size_t>(y) * src.strideBytes;
            uint8_t* dRow = dstBase + static_cast<size_t>(y) * dst.strideBytes;
            for (int x = 0; x < width; ++x) {
                const size_t off = static_cast<size_t>(x) * 4u;
                const uint8_t r = sRow[off + (bgra ? 2u : 0u)];
                const uint8_t g = sRow[off + 1u];
                const uint8_t b = sRow[off + (bgra ? 0u : 2u)];
                uint8_t outR = 0;
                uint8_t outG = 0;
                uint8_t outB = 0;
                applyInspectionOverlayPixel(r, g, b, mode, outR, outG, outB);
                dRow[off + (bgra ? 2u : 0u)] = outR;
                dRow[off + 1u] = outG;
                dRow[off + (bgra ? 0u : 2u)] = outB;
                dRow[off + 3u] = 255u;
            }
        }
    });
    return RenderStatus::Ok;
}

} // namespace sony2fuji
