#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace rawlab {
inline void convertPng16ToSrgb(uint16_t* pixels, size_t count, const float* eotf,
    const float* matrix, const float* oetf) {
    for (size_t i = 0; i < count; ++i) {
        auto* pixel = pixels + i * 4;
        const float r = eotf[pixel[0]], g = eotf[pixel[1]], b = eotf[pixel[2]];
        for (int c = 0; c < 3; ++c) {
            // 先在源线性空间完成矩阵运算，再裁切 sRGB；提前裁切会改变广色域颜色。
            const float linear = std::clamp(matrix[c] * r + matrix[c + 3] * g + matrix[c + 6] * b, 0.0f, 1.0f);
            const float position = linear * 65535.0f;
            const int low = static_cast<int>(position);
            const float encoded = oetf[low] + (oetf[std::min(low + 1, 65535)] - oetf[low]) * (position - low);
            pixel[c] = static_cast<uint16_t>(std::lround(encoded * 65535.0f));
        }
    }
}
}
