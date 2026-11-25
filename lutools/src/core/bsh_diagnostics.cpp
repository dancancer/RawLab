#include "core/bsh_diagnostics.h"

#include "core/hdr_srgb_lut.h"
#include "core/parallel_pixels.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

namespace sony2fuji {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct HslChannelDef {
    sony2fuji_hsl_channel id;
    double centerDeg;
};

constexpr std::array<HslChannelDef, SONY2FUJI_HSL_CHANNELS> kHslChannels = {{
    {SONY2FUJI_HSL_CHANNEL_RED, 0.0},
    {SONY2FUJI_HSL_CHANNEL_ORANGE, 30.0},
    {SONY2FUJI_HSL_CHANNEL_YELLOW, 60.0},
    {SONY2FUJI_HSL_CHANNEL_GREEN, 120.0},
    {SONY2FUJI_HSL_CHANNEL_AQUA, 180.0},
    {SONY2FUJI_HSL_CHANNEL_BLUE, 240.0},
    {SONY2FUJI_HSL_CHANNEL_PURPLE, 270.0},
    {SONY2FUJI_HSL_CHANNEL_MAGENTA, 300.0},
}};

inline double roundHalfEven(double value) noexcept {
    // Default IEEE-754 rounding mode is FE_TONEAREST (round-half-to-even), matching Python 3 round().
    return std::nearbyint(value);
}

inline double roundN(double value, int decimals) noexcept {
    double scale = 1.0;
    for (int i = 0; i < decimals; ++i) {
        scale *= 10.0;
    }
    const double rounded = roundHalfEven(value * scale) / scale;
    return rounded == 0.0 ? 0.0 : rounded;
}

inline double srgbToLinearExact(double encoded) noexcept {
    if (encoded <= 0.04045) {
        return encoded / 12.92;
    }
    return std::pow((encoded + 0.055) / 1.055, 2.4);
}

inline void rgbToHsvExact(double r, double g, double b, double& outHNorm, double& outS, double& outV) noexcept {
    const double mx = std::max({r, g, b});
    const double mn = std::min({r, g, b});
    outV = mx;
    if (mn == mx) {
        outHNorm = 0.0;
        outS = 0.0;
        return;
    }
    const double df = mx - mn;
    outS = df / mx;
    double h = 0.0;
    if (mx == r) {
        h = (g - b) / df;
    } else if (mx == g) {
        h = 2.0 + (b - r) / df;
    } else {
        h = 4.0 + (r - g) / df;
    }
    h /= 6.0;
    h = h - std::floor(h);
    if (h >= 1.0) {
        h -= 1.0;
    }
    outHNorm = h;
}

inline sony2fuji_hsl_channel nearestHslChannel(double hueDeg) noexcept {
    sony2fuji_hsl_channel best = SONY2FUJI_HSL_CHANNEL_RED;
    double bestDist = 999.0;
    for (const auto& ch : kHslChannels) {
        double d = std::abs(hueDeg - ch.centerDeg);
        if (d > 180.0) {
            d = 360.0 - d;
        }
        if (d < bestDist) {
            bestDist = d;
            best = ch.id;
        }
    }
    return best;
}

bool validBufferView(const PixelBufferView& view, uint32_t& outChannels, uint32_t& outBitDepth, size_t& outBpp) noexcept {
    if (!view.data || view.width == 0 || view.height == 0 ||
        view.width > UINT32_MAX / 8u ||
        static_cast<uint64_t>(view.width) * view.height > UINT32_MAX) {
        return false;
    }
    switch (view.format) {
        case PixelBufferFormat::RGB8:
            outChannels = 3;
            outBitDepth = 8;
            outBpp = 3;
            break;
        case PixelBufferFormat::RGBA8:
            outChannels = 4;
            outBitDepth = 8;
            outBpp = 4;
            break;
        case PixelBufferFormat::RGBA16:
            outChannels = 4;
            outBitDepth = 16;
            outBpp = 8;
            break;
        default:
            return false;
    }
    const uint64_t rowBytes = static_cast<uint64_t>(view.width) * outBpp;
    if (rowBytes > static_cast<uint64_t>(view.strideBytes)) {
        return false;
    }
    const uint64_t requiredBytes =
        static_cast<uint64_t>(view.strideBytes) * (view.height - 1u) + rowBytes;
    return requiredBytes <= view.sizeBytes;
}

inline void decodePixelRgb(const uint8_t* px, uint32_t bitDepth, double& r, double& g, double& b) noexcept {
    if (bitDepth == 16) {
        const uint16_t r16 = static_cast<uint16_t>(px[0]) | (static_cast<uint16_t>(px[1]) << 8);
        const uint16_t g16 = static_cast<uint16_t>(px[2]) | (static_cast<uint16_t>(px[3]) << 8);
        const uint16_t b16 = static_cast<uint16_t>(px[4]) | (static_cast<uint16_t>(px[5]) << 8);
        r = static_cast<double>(r16) / 65535.0;
        g = static_cast<double>(g16) / 65535.0;
        b = static_cast<double>(b16) / 65535.0;
        return;
    }
    r = static_cast<double>(px[0]) / 255.0;
    g = static_cast<double>(px[1]) / 255.0;
    b = static_cast<double>(px[2]) / 255.0;
}

} // namespace

RenderStatus diagnosePixelBuffer(
    const PixelBufferView& view,
    uint32_t sampleStride,
    sony2fuji_bsh_diagnosis& out
) {
    uint32_t channels = 0;
    uint32_t bitDepth = 0;
    size_t bpp = 0;
    if (!validBufferView(view, channels, bitDepth, bpp)) {
        return RenderStatus::InvalidArgument;
    }

    const uint32_t preservedVersion = out.version;
    const uint32_t preservedSize = out.struct_size;
    std::memset(&out, 0, sizeof(out));
    out.version = preservedVersion;
    out.struct_size = preservedSize;
    out.width = view.width;
    out.height = view.height;
    out.bit_depth = bitDepth;
    out.channels = channels;

    const uint32_t stride = sampleStride > 0
        ? sampleStride
        : std::max<uint32_t>(1u, std::max(view.width, view.height) / 360u);

    const uint64_t approxCols = (static_cast<uint64_t>(view.width) + stride - 1u) / stride;
    const uint64_t approxRows = (static_cast<uint64_t>(view.height) + stride - 1u) / stride;
    std::vector<double> lumas;
    std::vector<double> sats;
    lumas.reserve(static_cast<size_t>(approxCols * approxRows));
    sats.reserve(static_cast<size_t>(approxCols * approxRows));

    uint64_t blacks = 0;
    uint64_t shadows = 0;
    uint64_t midtones = 0;
    uint64_t lights = 0;
    uint64_t highlights = 0;
    uint64_t shadowCrush = 0;
    uint64_t whiteBlowout = 0;
    uint64_t clipR = 0;
    uint64_t clipG = 0;
    uint64_t clipB = 0;
    uint64_t clipAny = 0;
    uint64_t meltingSat = 0;
    uint64_t lowSat = 0;
    uint64_t neutralCount = 0;
    double neutralRSum = 0.0;
    double neutralGSum = 0.0;
    double neutralBSum = 0.0;
    double lumaSum = 0.0;
    double satSum = 0.0;

    struct ChAcc {
        double count = 0.0;
        double sinSum = 0.0;
        double cosSum = 0.0;
        double sSum = 0.0;
        double vSum = 0.0;
    };
    std::array<ChAcc, SONY2FUJI_HSL_CHANNELS> chStats{};

    const uint8_t* base = static_cast<const uint8_t*>(view.data);
    uint64_t total = 0;

    for (uint32_t y = 0; y < view.height; y += stride) {
        const uint8_t* row = base + static_cast<size_t>(y) * view.strideBytes;
        for (uint32_t x = 0; x < view.width; x += stride) {
            double r = 0.0, g = 0.0, b = 0.0;
            decodePixelRgb(row + static_cast<size_t>(x) * bpp, bitDepth, r, g, b);
            ++total;

            const double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            lumaSum += lum;
            lumas.push_back(lum);

            if (lum < 0.10) {
                ++blacks;
            } else if (lum < 0.35) {
                ++shadows;
            } else if (lum < 0.65) {
                ++midtones;
            } else if (lum < 0.90) {
                ++lights;
            } else {
                ++highlights;
            }

            const double cMax = std::max({r, g, b});
            const double cMin = std::min({r, g, b});
            if (cMax <= (1.0 / 255.0)) {
                ++shadowCrush;
            }
            if (cMin >= (254.0 / 255.0)) {
                ++whiteBlowout;
            }
            const bool hr = r >= 0.996;
            const bool hg = g >= 0.996;
            const bool hb = b >= 0.996;
            if (hr) ++clipR;
            if (hg) ++clipG;
            if (hb) ++clipB;
            if (hr || hg || hb) ++clipAny;

            double hNorm = 0.0, sVal = 0.0, vVal = 0.0;
            rgbToHsvExact(r, g, b, hNorm, sVal, vVal);
            satSum += sVal;
            sats.push_back(sVal);
            if (sVal < 0.15) {
                ++lowSat;
            }
            if (sVal > 0.85 && vVal > 0.35) {
                ++meltingSat;
            }

            if (lum >= 0.18 && lum <= 0.82 && sVal <= 0.35) {
                ++neutralCount;
                neutralRSum += r;
                neutralGSum += g;
                neutralBSum += b;
            }

            if (sVal >= 0.08) {
                double hDeg = std::fmod(hNorm * 360.0, 360.0);
                if (hDeg < 0.0) hDeg += 360.0;
                const auto cname = nearestHslChannel(hDeg);
                auto& entry = chStats[static_cast<size_t>(cname)];
                const double rad = hDeg * (kPi / 180.0);
                entry.count += 1.0;
                entry.sinSum += std::sin(rad);
                entry.cosSum += std::cos(rad);
                entry.sSum += sVal;
                entry.vSum += vVal;
            }
        }
    }

    std::sort(lumas.begin(), lumas.end());
    std::sort(sats.begin(), sats.end());

    auto pctAt = [](const std::vector<double>& arr, double q) -> double {
        if (arr.empty()) return 0.0;
        const int64_t n = static_cast<int64_t>(arr.size());
        int64_t idx = static_cast<int64_t>(roundHalfEven(q * static_cast<double>(n - 1)));
        idx = std::clamp<int64_t>(idx, 0, n - 1);
        return roundN(arr[static_cast<size_t>(idx)], 4);
    };

    auto share = [total](uint64_t count) -> double {
        return total > 0 ? roundN((static_cast<double>(count) * 100.0) / static_cast<double>(total), 2) : 0.0;
    };

    const double rOverG = (neutralGSum > 1e-6) ? roundN(neutralRSum / neutralGSum, 4) : 1.0;
    const double bOverG = (neutralGSum > 1e-6) ? roundN(neutralBSum / neutralGSum, 4) : 1.0;

    sony2fuji_bsh_cast_hint castHint = SONY2FUJI_BSH_CAST_BALANCED;
    if (static_cast<double>(neutralCount) < std::max(20.0, static_cast<double>(total) * 0.01)) {
        castHint = SONY2FUJI_BSH_CAST_INSUFFICIENT_NEUTRALS;
    } else if (rOverG > 1.07 && bOverG < 0.94) {
        castHint = SONY2FUJI_BSH_CAST_WARM_YELLOW_AMBER;
    } else if (bOverG > 1.07 && rOverG < 0.95) {
        castHint = SONY2FUJI_BSH_CAST_COOL_BLUE;
    } else if (rOverG < 0.94 && bOverG < 0.94) {
        castHint = SONY2FUJI_BSH_CAST_GREEN;
    } else if (rOverG > 1.05 && bOverG > 1.05) {
        castHint = SONY2FUJI_BSH_CAST_MAGENTA;
    } else {
        castHint = SONY2FUJI_BSH_CAST_BALANCED;
    }

    const double p01 = pctAt(lumas, 0.01);
    const double p05 = pctAt(lumas, 0.05);
    const double p25 = pctAt(lumas, 0.25);
    const double p50 = pctAt(lumas, 0.50);
    const double p75 = pctAt(lumas, 0.75);
    const double p95 = pctAt(lumas, 0.95);
    const double p99 = pctAt(lumas, 0.99);
    const double meltPct = share(meltingSat);

    out.sampled_pixels = total;
    out.blacks_0_10_pct = static_cast<float>(share(blacks));
    out.shadows_10_35_pct = static_cast<float>(share(shadows));
    out.midtones_35_65_pct = static_cast<float>(share(midtones));
    out.lights_65_90_pct = static_cast<float>(share(lights));
    out.highlights_90_100_pct = static_cast<float>(share(highlights));
    out.mean_luma_0_1 = static_cast<float>(total > 0 ? roundN(lumaSum / static_cast<double>(total), 4) : 0.0);
    out.luma_p01 = static_cast<float>(p01);
    out.luma_p05 = static_cast<float>(p05);
    out.luma_p25 = static_cast<float>(p25);
    out.luma_p50 = static_cast<float>(p50);
    out.luma_p75 = static_cast<float>(p75);
    out.luma_p95 = static_cast<float>(p95);
    out.luma_p99 = static_cast<float>(p99);
    out.dynamic_spread_p95_minus_p05 = static_cast<float>(roundN(p95 - p05, 4));

    out.shadow_crush_pct = static_cast<float>(share(shadowCrush));
    out.white_blowout_pct = static_cast<float>(share(whiteBlowout));
    out.channel_clip_high_any_pct = static_cast<float>(share(clipAny));
    out.channel_clip_high_r_pct = static_cast<float>(share(clipR));
    out.channel_clip_high_g_pct = static_cast<float>(share(clipG));
    out.channel_clip_high_b_pct = static_cast<float>(share(clipB));

    out.neutral_midtone_coverage_pct = static_cast<float>(share(neutralCount));
    out.r_over_g = static_cast<float>(rOverG);
    out.b_over_g = static_cast<float>(bOverG);
    out.cast_hint = castHint;

    out.mean_s_pct = static_cast<float>(total > 0 ? roundN((satSum / static_cast<double>(total)) * 100.0, 2) : 0.0);
    out.p95_s_pct = static_cast<float>(roundN(pctAt(sats, 0.95) * 100.0, 2));
    out.low_sat_pct = static_cast<float>(share(lowSat));
    out.melting_saturation_pct = static_cast<float>(meltPct);
    out.melting_warning = (meltPct > 2.0) ? 1 : 0;

    for (size_t i = 0; i < SONY2FUJI_HSL_CHANNELS; ++i) {
        const auto& st = chStats[i];
        const double cov = total > 0 ? roundN((st.count * 100.0) / static_cast<double>(total), 2) : 0.0;
        auto& dst = out.hsl_channels[i];
        dst.coverage_pct = static_cast<float>(cov);
        if (st.count > 0.0) {
            double meanH = std::fmod(std::atan2(st.sinSum, st.cosSum) * (180.0 / kPi), 360.0);
            if (meanH < 0.0) meanH += 360.0;
            dst.mean_hue_deg = static_cast<float>(roundN(meanH, 1));
            dst.mean_sat_pct = static_cast<float>(roundN((st.sSum / st.count) * 100.0, 1));
            dst.mean_brightness_pct = static_cast<float>(roundN((st.vSum / st.count) * 100.0, 1));
        }
        dst.active = (cov >= 0.2) ? 1 : 0;
    }

    return RenderStatus::Ok;
}

RenderStatus sampleRegionBshBuffer(
    const PixelBufferView& view,
    float normX,
    float normY,
    float radiusNorm,
    sony2fuji_bsh_sample_result& out
) {
    uint32_t channels = 0;
    uint32_t bitDepth = 0;
    size_t bpp = 0;
    if (!validBufferView(view, channels, bitDepth, bpp) ||
        !std::isfinite(normX) || normX < 0.0f || normX > 1.0f ||
        !std::isfinite(normY) || normY < 0.0f || normY > 1.0f ||
        !std::isfinite(radiusNorm) || radiusNorm < 0.0f) {
        return RenderStatus::InvalidArgument;
    }

    const uint32_t preservedVersion = out.version;
    const uint32_t preservedSize = out.struct_size;
    std::memset(&out, 0, sizeof(out));
    out.version = preservedVersion;
    out.struct_size = preservedSize;
    out.width = view.width;
    out.height = view.height;

    const int64_t w = static_cast<int64_t>(view.width);
    const int64_t h = static_cast<int64_t>(view.height);
    const int64_t cx = std::clamp<int64_t>(
        static_cast<int64_t>(roundHalfEven(static_cast<double>(normX) * static_cast<double>(w - 1))),
        0, w - 1);
    const int64_t cy = std::clamp<int64_t>(
        static_cast<int64_t>(roundHalfEven(static_cast<double>(normY) * static_cast<double>(h - 1))),
        0, h - 1);
    const int64_t maxDim = std::max(w, h);
    const double rawHalf = (radiusNorm > 0.0f)
        ? roundHalfEven(static_cast<double>(radiusNorm) * static_cast<double>(maxDim))
        : 0.0;
    const int64_t half = (rawHalf >= static_cast<double>(maxDim))
        ? maxDim
        : std::max<int64_t>(0, static_cast<int64_t>(rawHalf));

    const int64_t yStart = std::max<int64_t>(0, cy - half);
    const int64_t yEnd = std::min<int64_t>(h, cy + half + 1);
    const int64_t xStart = std::max<int64_t>(0, cx - half);
    const int64_t xEnd = std::min<int64_t>(w, cx + half + 1);

    double sr = 0.0, sg = 0.0, sb = 0.0;
    double lr = 0.0, lg = 0.0, lb = 0.0;
    uint32_t scnt = 0;

    const uint8_t* base = static_cast<const uint8_t*>(view.data);
    for (int64_t yy = yStart; yy < yEnd; ++yy) {
        const uint8_t* row = base + static_cast<size_t>(yy) * view.strideBytes;
        for (int64_t xx = xStart; xx < xEnd; ++xx) {
            double r = 0.0, g = 0.0, b = 0.0;
            decodePixelRgb(row + static_cast<size_t>(xx) * bpp, bitDepth, r, g, b);
            sr += r;
            sg += g;
            sb += b;
            lr += srgbToLinearExact(r);
            lg += srgbToLinearExact(g);
            lb += srgbToLinearExact(b);
            ++scnt;
        }
    }

    if (scnt == 0) {
        return RenderStatus::ProcessingError;
    }

    const double inv = 1.0 / static_cast<double>(scnt);
    const double mr = sr * inv;
    const double mg = sg * inv;
    const double mb = sb * inv;

    double hNorm = 0.0, sVal = 0.0, vVal = 0.0;
    rgbToHsvExact(mr, mg, mb, hNorm, sVal, vVal);
    double hDeg = std::fmod(hNorm * 360.0, 360.0);
    if (hDeg < 0.0) hDeg += 360.0;

    out.pixel_x = static_cast<uint32_t>(cx);
    out.pixel_y = static_cast<uint32_t>(cy);
    out.sample_count = scnt;
    out.linear_rgb[0] = static_cast<float>(lr * inv);
    out.linear_rgb[1] = static_cast<float>(lg * inv);
    out.linear_rgb[2] = static_cast<float>(lb * inv);
    out.srgb_rgb[0] = static_cast<float>(mr);
    out.srgb_rgb[1] = static_cast<float>(mg);
    out.srgb_rgb[2] = static_cast<float>(mb);
    out.hsb[0] = static_cast<float>(roundN(hDeg, 1));
    out.hsb[1] = static_cast<float>(roundN(sVal * 100.0, 1));
    out.hsb[2] = static_cast<float>(roundN(vVal * 100.0, 1));
    out.rgb_8bit[0] = static_cast<uint32_t>(std::clamp<int64_t>(static_cast<int64_t>(roundHalfEven(mr * 255.0)), 0, 255));
    out.rgb_8bit[1] = static_cast<uint32_t>(std::clamp<int64_t>(static_cast<int64_t>(roundHalfEven(mg * 255.0)), 0, 255));
    out.rgb_8bit[2] = static_cast<uint32_t>(std::clamp<int64_t>(static_cast<int64_t>(roundHalfEven(mb * 255.0)), 0, 255));
    out.nearest_hsl_channel = nearestHslChannel(static_cast<double>(out.hsb[0]));
    return RenderStatus::Ok;
}

OwnedPixelBuffer encodeRgba16BufferFromFloatRgb(
    const float* data,
    uint32_t width,
    uint32_t height,
    uint64_t strideBytes,
    bool linearToSrgb
) {
    OwnedPixelBuffer buf;
    if (!data || width == 0 || height == 0 ||
        width > UINT32_MAX / 8u ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) > UINT32_MAX) {
        return buf;
    }
    const uint64_t minRowBytes = static_cast<uint64_t>(width) * 3u * sizeof(float);
    if (strideBytes < minRowBytes ||
        (height > 1u && strideBytes > (std::numeric_limits<uint64_t>::max() - minRowBytes) / (height - 1u))) {
        return buf;
    }
    const uint64_t dstStride64 = static_cast<uint64_t>(width) * 8u;
    const uint64_t dstTotal64 = dstStride64 * static_cast<uint64_t>(height);
    if (dstTotal64 > std::numeric_limits<size_t>::max()) {
        return buf;
    }
    const size_t stride = static_cast<size_t>(dstStride64);
    const size_t total = static_cast<size_t>(dstTotal64);
    void* mem = std::malloc(total);
    if (!mem) {
        return buf;
    }
    uint8_t* dst = static_cast<uint8_t*>(mem);
    const uint8_t* srcBase = reinterpret_cast<const uint8_t*>(data);
    auto toUnit = [linearToSrgb](float v) -> float {
        const float clamped = !(v > 0.0f) ? 0.0f : (v >= 1.0f ? 1.0f : v);
        const float unit = linearToSrgb ? hdr::linearToSrgbUnit(clamped) : clamped;
        return !(unit > 0.0f) ? 0.0f : (unit >= 1.0f ? 1.0f : unit);
    };
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t* srcRow = srcBase + static_cast<uint64_t>(y) * strideBytes;
        uint8_t* dstRow = dst + static_cast<size_t>(y) * stride;
        for (uint32_t x = 0; x < width; ++x) {
            float rgb[3]{};
            std::memcpy(rgb, srcRow + static_cast<size_t>(x) * 3u * sizeof(float), sizeof(rgb));
            const uint16_t r16 = static_cast<uint16_t>(toUnit(rgb[0]) * 65535.0f + 0.5f);
            const uint16_t g16 = static_cast<uint16_t>(toUnit(rgb[1]) * 65535.0f + 0.5f);
            const uint16_t b16 = static_cast<uint16_t>(toUnit(rgb[2]) * 65535.0f + 0.5f);
            uint8_t* outPx = dstRow + static_cast<size_t>(x) * 8u;
            outPx[0] = static_cast<uint8_t>(r16 & 0xFFu);
            outPx[1] = static_cast<uint8_t>((r16 >> 8) & 0xFFu);
            outPx[2] = static_cast<uint8_t>(g16 & 0xFFu);
            outPx[3] = static_cast<uint8_t>((g16 >> 8) & 0xFFu);
            outPx[4] = static_cast<uint8_t>(b16 & 0xFFu);
            outPx[5] = static_cast<uint8_t>((b16 >> 8) & 0xFFu);
            outPx[6] = 0xFFu;
            outPx[7] = 0xFFu;
        }
    }
    buf.data = mem;
    buf.sizeBytes = total;
    buf.width = width;
    buf.height = height;
    buf.strideBytes = static_cast<uint32_t>(stride);
    buf.format = PixelBufferFormat::RGBA16;
    return buf;
}

OwnedPixelBuffer encodeRgba16BufferFromImageData(
    const ImageData& image,
    bool linearToSrgb
) {
    if (image.width <= 0 || image.height <= 0 ||
        image.pixels.size() < static_cast<size_t>(image.width) * static_cast<size_t>(image.height)) {
        return {};
    }
    static_assert(sizeof(RGB) == 3 * sizeof(float), "RGB must be tightly packed 3 floats");
    return encodeRgba16BufferFromFloatRgb(
        &image.pixels[0].r,
        static_cast<uint32_t>(image.width),
        static_cast<uint32_t>(image.height),
        static_cast<uint64_t>(image.width) * sizeof(RGB),
        linearToSrgb);
}

RenderStatus encodeDisplay8IntoFloatRgb(
    const float* data,
    uint32_t width,
    uint32_t height,
    uint64_t srcStrideBytes,
    bool bgra,
    void* dst,
    uint64_t dstSizeBytes,
    uint64_t dstStrideBytes
) {
    if (!data || !dst || width == 0 || height == 0 ||
        width > UINT32_MAX / 4u ||
        height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) > UINT32_MAX) {
        return RenderStatus::InvalidArgument;
    }
    const uint64_t minSrcRowBytes = static_cast<uint64_t>(width) * 3u * sizeof(float);
    if (srcStrideBytes < minSrcRowBytes ||
        (height > 1u && srcStrideBytes > (std::numeric_limits<uint64_t>::max() - minSrcRowBytes) / (height - 1u))) {
        return RenderStatus::InvalidArgument;
    }
    const uint64_t minDstRowBytes = static_cast<uint64_t>(width) * 4u;
    if (dstStrideBytes < minDstRowBytes ||
        (height > 1u && dstStrideBytes > (std::numeric_limits<uint64_t>::max() - minDstRowBytes) / (height - 1u))) {
        return RenderStatus::InvalidArgument;
    }
    const uint64_t requiredDstBytes = static_cast<uint64_t>(height - 1u) * dstStrideBytes + minDstRowBytes;
    if (requiredDstBytes > dstSizeBytes) {
        return RenderStatus::InvalidArgument;
    }

    (void)hdr::srgbToUInt8(0.5f);
    const uint8_t* srcBase = reinterpret_cast<const uint8_t*>(data);
    uint8_t* dstBase = static_cast<uint8_t*>(dst);
    std::atomic<bool> invalidFloat{false};

    parallelRowRanges(static_cast<int>(height), static_cast<int>(width), [&](int firstRow, int lastRow) {
        if (invalidFloat.load(std::memory_order_acquire)) {
            return;
        }
        for (int rowIndex = firstRow; rowIndex < lastRow; ++rowIndex) {
            if (invalidFloat.load(std::memory_order_acquire)) {
                return;
            }
            const uint8_t* srcRow = srcBase + static_cast<uint64_t>(rowIndex) * srcStrideBytes;
            uint8_t* dstRow = dstBase + static_cast<uint64_t>(rowIndex) * dstStrideBytes;
            for (uint32_t x = 0; x < width; ++x) {
                float rgb[3]{};
                std::memcpy(rgb, srcRow + static_cast<size_t>(x) * 3u * sizeof(float), sizeof(rgb));
                if (!std::isfinite(rgb[0]) || !std::isfinite(rgb[1]) || !std::isfinite(rgb[2])) {
                    invalidFloat.store(true, std::memory_order_release);
                    return;
                }
                const uint8_t r8 = hdr::srgbToUInt8(rgb[0]);
                const uint8_t g8 = hdr::srgbToUInt8(rgb[1]);
                const uint8_t b8 = hdr::srgbToUInt8(rgb[2]);
                uint8_t* outPx = dstRow + static_cast<size_t>(x) * 4u;
                outPx[0] = bgra ? b8 : r8;
                outPx[1] = g8;
                outPx[2] = bgra ? r8 : b8;
                outPx[3] = 255u;
            }
        }
    });

    if (invalidFloat.load(std::memory_order_acquire)) {
        return RenderStatus::InvalidArgument;
    }
    return RenderStatus::Ok;
}

RenderStatus encodeDisplay8BufferFromFloatRgb(
    const float* data,
    uint32_t width,
    uint32_t height,
    uint64_t srcStrideBytes,
    bool bgra,
    OwnedPixelBuffer& outBuffer
) {
    outBuffer.reset();
    if (!data || width == 0 || height == 0 ||
        width > UINT32_MAX / 4u ||
        height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) > UINT32_MAX) {
        return RenderStatus::InvalidArgument;
    }
    const uint64_t minSrcRowBytes = static_cast<uint64_t>(width) * 3u * sizeof(float);
    if (srcStrideBytes < minSrcRowBytes ||
        (height > 1u && srcStrideBytes > (std::numeric_limits<uint64_t>::max() - minSrcRowBytes) / (height - 1u))) {
        return RenderStatus::InvalidArgument;
    }
    const uint64_t dstStride64 = static_cast<uint64_t>(width) * 4u;
    const uint64_t dstTotal64 = dstStride64 * static_cast<uint64_t>(height);
    if (dstTotal64 > std::numeric_limits<size_t>::max()) {
        return RenderStatus::InvalidArgument;
    }
    const size_t total = static_cast<size_t>(dstTotal64);
    void* mem = std::malloc(total);
    if (!mem) {
        return RenderStatus::OutOfMemory;
    }
    const RenderStatus status = encodeDisplay8IntoFloatRgb(
        data, width, height, srcStrideBytes, bgra, mem, dstTotal64, dstStride64);
    if (status != RenderStatus::Ok) {
        std::free(mem);
        return status;
    }
    outBuffer.data = mem;
    outBuffer.sizeBytes = total;
    outBuffer.width = width;
    outBuffer.height = height;
    outBuffer.strideBytes = static_cast<uint32_t>(dstStride64);
    outBuffer.format = bgra ? PixelBufferFormat::BGRA8 : PixelBufferFormat::RGBA8;
    return RenderStatus::Ok;
}

} // namespace sony2fuji
