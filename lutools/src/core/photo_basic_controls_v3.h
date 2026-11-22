#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "photo_geometry.h"
#include "photo_tone_controls.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace sony2fuji {

struct BasicToneV3 {
    float highlights = 0;
    float shadows = 0;
    bool active() const { return highlights != 0 || shadows != 0; }
};

struct BasicToneV3Field {
    int width = 0;
    int height = 0;
    std::vector<float> slope;
    std::vector<float> intercept;
    bool empty() const { return width <= 0 || height <= 0 || slope.empty() || intercept.empty(); }
};

// 在线性光中改变照明基底，保留局部细节和进入外观曲线前的高光余量。
BasicToneV3Field buildBasicToneV3Field(const ImageData& image,
    int sourceWidth = 0, int sourceHeight = 0);
BasicToneV3Field buildBasicToneV3Field(const ImageData& image,
    const ColorConverter::Matrix3x3& toSrgb, const RGB& exposureWB,
    int sourceWidth = 0, int sourceHeight = 0);
void applyBasicToneV3WithField(ImageData& image, const BasicToneV3& options,
    const BasicToneV3Field& field, const SubRectMap& roiMap = {});
void applyBasicToneV3(ImageData& image, const BasicToneV3& options,
    int sourceWidth = 0, int sourceHeight = 0);

float basicContrastV3(float value, float amount);
RGB basicBlackWhiteV3(const RGB& pixel, const ToneControlsOptions& options);
RGB basicVibranceV3(const RGB& pixel, float amount);
void applyBasicBlackWhiteV3(ImageData& image, const ToneControlsOptions& options);
void applyBasicVibranceV3(ImageData& image, float amount);

struct BasicContrastV3Lut {
    static constexpr int kTableSize = 4096;
    static constexpr float kMin = 1.0f / 256.0f;
    static constexpr float kMax = 255.0f / 256.0f;
    static constexpr float kSpan = kMax - kMin;
    static constexpr float kScale = static_cast<float>(kTableSize) / kSpan;

    bool active = false;
    float exponent = 1.0f;
    std::array<float, kTableSize + 1> table{};

    explicit BasicContrastV3Lut(float amount) {
        if (amount == 0.0f) return;
        active = true;
        exponent = std::exp2(std::clamp(amount, -1.0f, 1.0f) * 0.75f);
        const double expD = static_cast<double>(exponent);
        for (int i = 0; i <= kTableSize; ++i) {
            const double v = static_cast<double>(kMin) + (static_cast<double>(i) / kTableSize) * kSpan;
            const double low = std::pow(v, expD);
            const double high = std::pow(1.0 - v, expD);
            table[i] = static_cast<float>(low / (low + high));
        }
    }

    inline float apply(float value) const noexcept {
        if (!active || value <= 0.0f || value >= 1.0f) return value;
        if (value >= kMin && value <= kMax) {
            const float scaled = (value - kMin) * kScale;
            const int idx = std::min(kTableSize - 1, static_cast<int>(scaled));
            const float frac = scaled - static_cast<float>(idx);
            return table[idx] + (table[idx + 1] - table[idx]) * frac;
        }
        const float low = std::pow(value, exponent);
        const float high = std::pow(1.0f - value, exponent);
        return low / (low + high);
    }
};

struct BasicBlackWhiteV3Prepared {
    bool active = false;
    bool blackNeg = false;
    bool blackPos = false;
    bool whiteNeg = false;
    bool whitePos = false;
    float blackNegVal = 0.0f;
    float blackNegScale = 1.0f;
    float blackPosPow = 0.0f;
    float whitePoint = 0.0f;
    float whitePosGain = 0.0f;

    explicit BasicBlackWhiteV3Prepared(const ToneControlsOptions& options) {
        if (options.blackPoint == 0.0f && options.whitePoint == 0.0f) return;
        active = true;
        if (options.blackPoint < 0.0f) {
            blackNeg = true;
            blackNegVal = 0.24f * options.blackPoint * options.blackPoint;
            blackNegScale = 1.0f / (1.0f - blackNegVal);
        } else if (options.blackPoint > 0.0f) {
            blackPos = true;
            blackPosPow = std::pow(options.blackPoint, 1.4f);
        }
        if (options.whitePoint < 0.0f) {
            whiteNeg = true;
            whitePoint = options.whitePoint;
        } else if (options.whitePoint > 0.0f) {
            whitePos = true;
            whitePosGain = 0.18f * std::pow(options.whitePoint, 1.4f);
        }
    }

    inline RGB apply(const RGB& pixel) const noexcept {
        if (!active) return pixel;
        auto lum = [](const RGB& p) {
            return p.g + 0.2126f * (p.r - p.g) + 0.0722f * (p.b - p.g);
        };
        RGB result = pixel;
        if (blackNeg) {
            result = RGB(
                (result.r - blackNegVal) * blackNegScale,
                (result.g - blackNegVal) * blackNegScale,
                (result.b - blackNegVal) * blackNegScale);
        } else if (blackPos) {
            const float y = std::clamp(lum(result), 0.0f, 1.0f);
            const float o = 1.0f - y;
            const float o2 = o * o;
            const float o7 = o2 * o2 * o2 * o;
            const float black = blackPosPow * (0.15f * (1.0f - std::exp(-y / 0.06f)) + 0.01f * o7);
            result = RGB(
                result.r * (1.0f - black) + black,
                result.g * (1.0f - black) + black,
                result.b * (1.0f - black) + black);
        }
        if (whiteNeg) {
            const float y = std::max(0.0f, lum(result));
            const float scale = 1.0f / (1.0f - 0.18f * whitePoint * y);
            result.r *= scale;
            result.g *= scale;
            result.b *= scale;
        } else if (whitePos) {
            const float y = std::max(0.0f, lum(result));
            if (y > 0.0f) {
                const float t = std::clamp(y / 0.8f, 0.0f, 1.0f);
                const float scale = 1.0f + whitePosGain * (t * t * (3.0f - 2.0f * t)) / y;
                result.r *= scale;
                result.g *= scale;
                result.b *= scale;
            }
        }
        return result;
    }
};

} // namespace sony2fuji
