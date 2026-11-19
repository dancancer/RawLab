#pragma once

#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include "gpu/photo_log_shader.h"
#include "parallel_pixels.h"
#include "photo_rendering.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

inline float encodePhotoLog(float linear, LUTTransfer transfer) {
    return detail::encodePhotoLog(linear, transfer == LUTTransfer::FLog);
}

inline float decodePhotoLog(float encoded, LUTTransfer transfer) {
    return detail::decodePhotoLog(encoded, transfer == LUTTransfer::FLog);
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
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto p = ColorConverter::applyMatrix(image.pixels[i], matrix);
            image.pixels[i] = RGB(encodePhotoLog(p.r, transfer), encodePhotoLog(p.g, transfer),
                encodePhotoLog(p.b, transfer));
        }
    });
}

inline void renderPhotoLUTOutput(ImageData& image, LUTTransfer transfer) {
    if (transfer == LUTTransfer::Display) return;
    // 合同已要求输出 BT.709/D65；Log 解码后可直接使用线性 sRGB 显示转换。
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& p = image.pixels[i];
            p = RGB(neutralDisplay(decodePhotoLog(p.r, transfer)),
                neutralDisplay(decodePhotoLog(p.g, transfer)), neutralDisplay(decodePhotoLog(p.b, transfer)));
        }
    });
}

} // namespace sony2fuji
