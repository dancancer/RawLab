#pragma once

#include "sony2fuji/common.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji::detail {
/* 输入已归一化到 [0,1]；有效表含 size^3 个 R-fast 元素，size 为 2..256。 */
static inline RGB interpolateLUT(const RGB* table, int lutSize, float r, float g, float b) {

    // 将 [0, 1] 映射到 [0, lutSize-1]
    float fr = r * (lutSize - 1);
    float fg = g * (lutSize - 1);
    float fb = b * (lutSize - 1);

    // 获取整数部分和小数部分
    int r0 = static_cast<int>(std::floor(fr));
    int g0 = static_cast<int>(std::floor(fg));
    int b0 = static_cast<int>(std::floor(fb));

    int r1 = std::min(r0 + 1, lutSize - 1);
    int g1 = std::min(g0 + 1, lutSize - 1);
    int b1 = std::min(b0 + 1, lutSize - 1);

    // 插值因子
    float dr = fr - r0;
    float dg = fg - g0;
    float db = fb - b0;

    /* 归一化输入保证索引有效；边界处步长为零，复用同一顶点。 */
    const int base = (b0 * lutSize + g0) * lutSize + r0;
    const int red = r1 - r0;
    const int green = (g1 - g0) * lutSize;
    const int blue = (b1 - b0) * lutSize * lutSize;
    RGB c000 = table[base];
    RGB c001 = table[base + blue];
    RGB c010 = table[base + green];
    RGB c011 = table[base + green + blue];
    RGB c100 = table[base + red];
    RGB c101 = table[base + red + blue];
    RGB c110 = table[base + red + green];
    RGB c111 = table[base + red + green + blue];

    // 沿 B 轴插值
    auto lerpRGB = [](const RGB& a, const RGB& b, float t) {
        return RGB(a.r + t * (b.r - a.r), a.g + t * (b.g - a.g), a.b + t * (b.b - a.b));
    };
    RGB c00 = lerpRGB(c000, c001, db);
    RGB c01 = lerpRGB(c010, c011, db);
    RGB c10 = lerpRGB(c100, c101, db);
    RGB c11 = lerpRGB(c110, c111, db);

    // 沿 G 轴插值
    RGB c0 = lerpRGB(c00, c01, dg);
    RGB c1 = lerpRGB(c10, c11, dg);

    // 沿 R 轴插值
    return lerpRGB(c0, c1, dr);
}
} // namespace sony2fuji::detail
