#include "photo_tone_endpoints.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {

bool ToneEndpointOptions::valid() const {
    return std::isfinite(blackPoint) && std::abs(blackPoint) <= 1
        && std::isfinite(whitePoint) && std::abs(whitePoint) <= 1;
}

bool ToneEndpointOptions::active() const {
    return blackPoint != 0 || whitePoint != 0;
}

static double smooth(double value) {
    const double t = std::clamp(value, 0., 1.);
    return t * t * (3 - 2 * t);
}

RGB applyToneEndpoints(const RGB& pixel, const ToneEndpointOptions& options) {
    if (!options.active()) return pixel;
    // 差值形式使灰色的 Y 精确等于输入，避免系数求和带来灰阶偏移。
    const double y = double(pixel.g) + .2126 * (double(pixel.r) - pixel.g)
        + .0722 * (double(pixel.b) - pixel.g);
    const double delta = .20 * (options.blackPoint * (1 - smooth(y / .35))
        + options.whitePoint * smooth((y - .65) / .35));
    return RGB(float(std::clamp(double(pixel.r) + delta, 0., 1.)),
               float(std::clamp(double(pixel.g) + delta, 0., 1.)),
               float(std::clamp(double(pixel.b) + delta, 0., 1.)));
}

void applyToneEndpoints(ImageData& image, const ToneEndpointOptions& options) {
    if (!options.active()) return;
    for (auto& pixel : image.pixels) pixel = applyToneEndpoints(pixel, options);
}

} // namespace sony2fuji
