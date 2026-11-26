#include "core/hdr_display.h"

#include "core/hdr_half.h"
#include "core/hdr_srgb_lut.h"

#include <algorithm>
#include <cmath>
#include <cstring>

// 逐步舍入须与客户端原实现及 GPU 着色器一致：禁止编译器把乘加合并为 FMA。
#if defined(__clang__)
#pragma clang fp contract(off)
#elif defined(_MSC_VER)
#pragma fp_contract(off)
#endif

namespace sony2fuji::hdr {
namespace {

constexpr double kMinimumEV = -8.0;
constexpr double kMaximumEV = 8.0;
constexpr float kHalfMax = 65504.0f;

inline float luminance(float r, float g, float b) {
    return 0.2126f * r + 0.7152f * g + 0.0722f * b;
}

inline bool finite3(const float* p) {
    return std::isfinite(p[0]) && std::isfinite(p[1]) && std::isfinite(p[2]);
}

// D65 线性 sRGB -> 线性 Display P3，保留灰轴；与 HDRCanvas 的 Metal 内核相同的常数。
inline void toDisplayP3(float* v) {
    const float r = v[0], g = v[1], b = v[2];
    v[0] = 0.8224619687143623f * r + 0.17753803128563775f * g;
    v[1] = 0.03319419885096156f * r + 0.9668058011490385f * g;
    v[2] = 0.01708263072112004f * r + 0.07239744066396347f * g + 0.9105199286149166f * b;
}

} // namespace

bool analyzeLuminance(const float* rgb, uint32_t width, uint32_t height, size_t rowStride,
                      LuminanceStatistics& out) {
    LuminanceStatistics result;
    for (uint32_t y = 0; y < height; ++y) {
        const float* row = rgb + static_cast<size_t>(y) * rowStride;
        for (uint32_t x = 0; x < width; ++x) {
            const float* p = row + static_cast<size_t>(x) * 3;
            if (!finite3(p)) return false;
            // 双精度与 Mac 参考实现逐位一致；有限 float 的加权和在 double 下不会溢出。
            const double lum = 0.2126 * double(p[0]) + 0.7152 * double(p[1]) + 0.0722 * double(p[2]);
            const double ev = lum > 0 ? std::log2(lum) : kMinimumEV;
            const double clamped = std::min(kMaximumEV, std::max(kMinimumEV, ev));
            const int bin = std::min(255, std::max(0, static_cast<int>((clamped - kMinimumEV) * 16)));
            ++result.bins[bin];
            if (lum > 1) ++result.aboveWhite;
            result.peak = std::max(result.peak, static_cast<float>(lum));
        }
    }
    if (!std::isfinite(result.peak)) return false;
    out = result;
    return true;
}

DisplayResult mapDisplay(const DisplayPlanes& planes, float displayHeadroom, float contentHeadroom,
                         uint32_t flags) {
    const float h = std::isfinite(displayHeadroom) ? std::min(kHalfMax, std::max(1.0f, displayHeadroom)) : 1.0f;
    const float c = contentHeadroom;
    const bool falseColor = (flags & kDisplayFalseColor) != 0;
    const bool showHdr = (flags & kDisplaySdr) == 0 && h > 1.0f;
    const bool p3 = (flags & kDisplayP3) != 0;
    const bool clampSdr = (flags & kDisplayClampSdr) != 0;
    const bool bgra8 = (flags & kDisplayBgra8Srgb) != 0;
    // 肩部保持参考白与该点一阶导数，仅把内容峰值压到当前屏幕容量。
    const bool shoulder = showHdr && c > h;
    const float a = shoulder ? (c - h) / ((h - 1.0f) * (c - 1.0f)) : 0.0f;

    for (uint32_t y = 0; y < planes.height; ++y) {
        const float* hdrRow = planes.hdr + static_cast<size_t>(y) * planes.hdrStride;
        const float* sdrRow = planes.sdr ? planes.sdr + static_cast<size_t>(y) * planes.sdrStride : nullptr;
        uint8_t* dstRow = planes.dst + static_cast<size_t>(y) * planes.dstStride;
        for (uint32_t x = 0; x < planes.width; ++x) {
            const float* hp = hdrRow + static_cast<size_t>(x) * 3;
            const float* sp = sdrRow ? sdrRow + static_cast<size_t>(x) * 3 : nullptr;
            if (!finite3(hp) || (sp && !finite3(sp))) return DisplayResult::NonFinite;
            float v[3];
            if (falseColor) {
                const float l = luminance(hp[0], hp[1], hp[2]);
                if (l > h) { v[0] = 1.0f; v[1] = 0.0f; v[2] = 0.35f; }
                else if (l > 1.0f) { v[0] = 1.0f; v[1] = 0.6f; v[2] = 0.0f; }
                else if (l <= 0.01f) { v[0] = 0.02f; v[1] = 0.15f; v[2] = 0.7f; }
                else { v[0] = v[1] = v[2] = 0.35f; }
            } else if (!showHdr) {
                std::memcpy(v, sp, sizeof(v));
                if (p3) toDisplayP3(v);
                if (clampSdr) for (float& value : v) value = std::min(1.0f, std::max(0.0f, value));
            } else {
                std::memcpy(v, hp, sizeof(v));
                const float l = luminance(hp[0], hp[1], hp[2]);
                if (shoulder && l > 1.0f) {
                    const float mapped = 1.0f + (l - 1.0f) / (1.0f + a * (l - 1.0f));
                    const float scale = mapped / l;
                    for (float& value : v) value *= scale;
                }
                if (p3) toDisplayP3(v);
            }
            if (bgra8) {
                uint8_t* out = dstRow + static_cast<size_t>(x) * 4;
                out[0] = srgbToUInt8(v[2]);
                out[1] = srgbToUInt8(v[1]);
                out[2] = srgbToUInt8(v[0]);
                out[3] = 255;
            } else {
                uint16_t half[4];
                for (int i = 0; i < 3; ++i) {
                    if (!(std::fabs(v[i]) <= kHalfMax)) return DisplayResult::Unrepresentable;
                    half[i] = floatToHalf(v[i]);
                }
                half[3] = 0x3c00;
                std::memcpy(dstRow + static_cast<size_t>(x) * 8, half, sizeof(half));
            }
        }
    }
    return DisplayResult::Ok;
}

} // namespace sony2fuji::hdr
