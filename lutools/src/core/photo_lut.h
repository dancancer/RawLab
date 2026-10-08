#pragma once

#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include "photo_rendering.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

inline float encodePhotoLog(float linear, LUTTransfer transfer) {
    if (transfer != LUTTransfer::FLog) return GammaConverter::applyFLog2(linear);
    const float encoded = linear < 0.00089f ? 8.735631f * linear + 0.092864f
        : 0.344676f * std::log10(0.555556f * linear + 0.009468f) + 0.790453f;
    return std::clamp(encoded, 0.0f, 1.0f);
}

inline float decodePhotoLog(float encoded, LUTTransfer transfer) {
    if (transfer == LUTTransfer::FLog) {
        return encoded < 0.100537775223865f ? (encoded - 0.092864f) / 8.735631f
            : (std::pow(10.0f, (encoded - 0.790453f) / 0.344676f) - 0.009468f) / 0.555556f;
    }
    return encoded < 0.100686685370811f ? (encoded - 0.092864f) / 8.799461f
        : (std::pow(10.0f, (encoded - 0.384316f) / 0.245281f) - 0.064829f) / 5.555556f;
}

inline ColorConverter::Matrix3x3 photoLUTInputMatrix(LUTTransfer transfer) {
    if (transfer != LUTTransfer::FLog2C) {
        return ColorConverter::getConversionMatrix(ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);
    }
    // 由原厂 F-Log2C Data Sheet v1.0 的原色和 D65 白点推导，不是 F-Gamut 矩阵。
    const ColorConverter::Matrix3x3 fgamutCToXYZ = {{
        {{0.78927497f, 0.02004023f, 0.14114073f}},
        {{0.28500701f, 0.74194570f, -0.02695271f}},
        {{0.0f, 0.0f, 1.08905775f}}
    }};
    return ColorConverter::invertMatrix(ColorConverter::getConversionMatrix(
        fgamutCToXYZ, ColorSpace::sRGB, ColorSpace::sRGB));
}

inline void encodePhotoLUTInput(ImageData& image, LUTTransfer transfer) {
    const auto matrix = photoLUTInputMatrix(transfer);
    const size_t count = image.pixels.size();
#ifdef _OPENMP
#pragma omp parallel for if (count >= (1u << 16))
#endif
    for (size_t i = 0; i < count; ++i) {
        const auto p = ColorConverter::applyMatrix(image.pixels[i], matrix);
        image.pixels[i] = RGB(encodePhotoLog(p.r, transfer), encodePhotoLog(p.g, transfer),
            encodePhotoLog(p.b, transfer));
    }
}

inline void renderPhotoLUTOutput(ImageData& image, LUTTransfer transfer) {
    if (transfer == LUTTransfer::Display) return;
    // 合同已要求输出 BT.709/D65；Log 解码后可直接使用线性 sRGB 显示转换。
    const size_t count = image.pixels.size();
#ifdef _OPENMP
#pragma omp parallel for if (count >= (1u << 16))
#endif
    for (size_t i = 0; i < count; ++i) {
        auto& p = image.pixels[i];
        p = RGB(neutralDisplay(decodePhotoLog(p.r, transfer)),
            neutralDisplay(decodePhotoLog(p.g, transfer)), neutralDisplay(decodePhotoLog(p.b, transfer)));
    }
}

} // namespace sony2fuji
