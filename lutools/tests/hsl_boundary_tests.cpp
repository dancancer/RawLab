#include "core/photo_color.h"
#include <algorithm>
#include <cmath>
#include <iostream>

using namespace sony2fuji;

int main() {
    HslOptions options;
    options.hue[4] = 12;
    options.saturation[0] = -20;
    options.lightness[5] = 10;
    float maximum = 0;
    // 色调/对比度可产生超出 [0,1] 的工作值；极小色相误差不能改变未调整颜色的基准。
    for (const auto range : {RGB(.975f, 1.015f, 0), RGB(-.015f, .025f, 0),
                            RGB(1.1f, 1.2f, 0), RGB(-.2f, -.1f, 0)}) {
        const float low = range.r, high = range.g;
        for (const RGB source : {RGB(high, low, low), RGB(high, high, low),
                 RGB(low, high, low), RGB(low, high, high), RGB(low, low, high), RGB(high, low, high)}) {
            const auto reference = applyHsl(source, options);
            for (int channel = 0; channel < 3; ++channel) for (float delta : {-1e-7f, 1e-7f}) {
                auto perturbed = source;
                if (channel == 0) perturbed.r += delta;
                if (channel == 1) perturbed.g += delta;
                if (channel == 2) perturbed.b += delta;
                const auto actual = applyHsl(perturbed, options);
                maximum = std::max({maximum, std::abs(actual.r - reference.r),
                    std::abs(actual.g - reference.g), std::abs(actual.b - reference.b)});
            }
        }
    }
    std::cout << "HSL hue-boundary maximum change=" << maximum << '\n';
    if (!std::isfinite(maximum) || maximum > 1e-5f) return 1;
    // Green is outside every active channel in this recipe; preserve its original working values.
    const RGB green(.975f, 1.015f, .975f);
    const auto result = applyHsl(green, options);
    if (result.r != green.r || result.g != green.g || result.b != green.b) return 1;
    options.lightness[3] = 10;
    const auto brightened = applyHsl(green, options);
    if (std::abs(brightened.r - .985f) > 1e-6f || std::abs(brightened.g - 1.015f) > 1e-6f ||
        std::abs(brightened.b - .985f) > 1e-6f) return 1;
    return 0;
}
